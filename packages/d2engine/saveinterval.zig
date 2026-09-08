//! How often the engine saves a character mid-game, expressed the way the engine tests it.
//!
//! `UpdateClients` reaches `SaveAllPlayers` on `dwGameFrame % 8192 == 0`, and the compiler wrote
//! that as the signed-modulo idiom rather than a division:
//!
//!     AND EAX, 0x80001fff      ; sign bit | (8192 - 1)
//!     JNS  +7                  ; non-negative frames: the AND is already the remainder
//!     DEC EAX / OR EAX, 0xffffe000 / INC EAX    ; negative frames: sign-extend the remainder
//!     JNZ  +5                  ; zero -> save
//!
//! So the interval is two immediates that have to agree, and shortening it is arithmetic, not new
//! code. The arithmetic lives here — apart from the patching — because it is a fact about the
//! engine and because getting it wrong writes a plausible constant that silently changes the
//! interval to something nobody chose. The tests below re-derive 1.14d's own shipped pair as the
//! proof that the formula matches what the compiler emitted.
//!
//! Only powers of two are expressible: a mask tests a set of low bits, so any other value would
//! fire on a pattern of frames rather than at an interval.

const std = @import("std");

/// The interval the engine ships: 8192 frames, ~5.5 minutes at 25 fps.
pub const stock_frames: u32 = 8192;

/// Frames per second the server simulates at. Only used to talk about intervals in seconds.
pub const fps: u32 = 25;

/// The `AND` immediate that tests `frame % frames == 0`.
pub fn mask(frames: u32) u32 {
    return 0x8000_0000 | (frames - 1);
}

/// The `OR` immediate in the negative-frame fixup. It must be the complement of the mask's low
/// bits or the two disagree; `dwGameFrame` would have to run ~994 days at 25 fps to reach that
/// path, but a mask and a fixup that contradict each other is a landmine, not a saving.
pub fn fixup(frames: u32) u32 {
    return ~(frames - 1);
}

pub fn isExpressible(frames: u32) bool {
    return frames != 0 and (frames & (frames - 1)) == 0;
}

/// The largest expressible interval not longer than `frames`, clamped to something a server
/// should actually run at.
///
/// Rounds DOWN, because the value is a duration to whoever set it and rounding up would quietly
/// give them a longer window than they asked for — the wrong direction for a setting whose whole
/// purpose is bounding how much play a crash can cost.
pub fn round(frames: u32) u32 {
    const clamped = @min(@max(frames, min_frames), stock_frames);
    // floorPowerOfTwo rather than a hand-rolled clz shift: `31 - @clz(x)` gives the shift the
    // smallest type that holds it, which is not u5, and the expression stops compiling — or worse,
    // narrows something else the same way somewhere it still does.
    return std.math.floorPowerOfTwo(u32, clamped);
}

/// Below this the save stops being periodic and starts being per-action.
pub const min_frames: u32 = 64;

// ── finding the instruction in an engine we have not measured ────────────────
//
// 1.14d's site is known by address. The five pre-1.14 engines are five more binaries, and rather
// than measure each one the site is FOUND: the mask is a 32-bit constant specific enough to
// identify itself. 0x80001fff is the sign bit plus 8191 — the signed-modulo-8192 idiom — and a
// game engine has no other reason to hold that number.
//
// The rule for using this is exactly one match. Zero means the engine does something else and the
// stock interval stands; more than one means the constant is not the identity we assumed it was,
// and guessing which to patch is how a byte lands in the middle of an unrelated instruction. Both
// are refusals, not fallbacks.

/// Where a mask instruction sits, and where its immediate is inside it.
pub const Site = struct {
    /// Offset of the first opcode byte within the scanned slice.
    at: usize,
    /// Offset of the 32-bit immediate within the scanned slice.
    imm_at: usize,
    len: usize,
};

/// `AND r32, imm32` in the two encodings a compiler emits: `25 id` (EAX only, 5 bytes) and
/// `81 /4 id` (any register, 6 bytes — ModRM 0xE0..0xE7 is register-direct with /4 = AND).
fn matchAnd(code: []const u8, i: usize, imm: u32) ?Site {
    if (i + 5 <= code.len and code[i] == 0x25 and std.mem.readInt(u32, code[i + 1 ..][0..4], .little) == imm) {
        return .{ .at = i, .imm_at = i + 1, .len = 5 };
    }
    if (i + 6 <= code.len and code[i] == 0x81 and code[i + 1] >= 0xE0 and code[i + 1] <= 0xE7 and
        std.mem.readInt(u32, code[i + 2 ..][0..4], .little) == imm)
    {
        return .{ .at = i, .imm_at = i + 2, .len = 6 };
    }
    return null;
}

/// `OR r32, imm32`: `0D id` (EAX, 5 bytes) and `81 /1 id` (ModRM 0xC8..0xCF, 6 bytes).
fn matchOr(code: []const u8, i: usize, imm: u32) ?Site {
    if (i + 5 <= code.len and code[i] == 0x0D and std.mem.readInt(u32, code[i + 1 ..][0..4], .little) == imm) {
        return .{ .at = i, .imm_at = i + 1, .len = 5 };
    }
    if (i + 6 <= code.len and code[i] == 0x81 and code[i + 1] >= 0xC8 and code[i + 1] <= 0xCF and
        std.mem.readInt(u32, code[i + 2 ..][0..4], .little) == imm)
    {
        return .{ .at = i, .imm_at = i + 2, .len = 6 };
    }
    return null;
}

/// Every `AND r32, <mask(frames)>` in `code`. Returns how many were written to `out`; a count
/// equal to `out.len` means there may be more, which is itself a reason to refuse.
pub fn findMaskSites(code: []const u8, frames: u32, out: []Site) usize {
    var n: usize = 0;
    var i: usize = 0;
    const imm = mask(frames);
    while (i + 5 <= code.len) : (i += 1) {
        if (matchAnd(code, i, imm)) |site| {
            if (n < out.len) out[n] = site;
            n += 1;
            if (n >= out.len) break;
        }
    }
    return n;
}

/// The negative-frame fixup belonging to a mask site: the first `OR r32, <fixup(frames)>` within
/// `window` bytes after it. Null when there is none, which is not an error — it is an unreachable
/// path either way, and a mask patched without it is still correct for every real frame count.
pub fn findFixupAfter(code: []const u8, from: usize, frames: u32, window: usize) ?Site {
    const imm = fixup(frames);
    var i = from;
    const end = @min(code.len, from + window);
    while (i + 5 <= end) : (i += 1) {
        if (matchOr(code, i, imm)) |site| return site;
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the formula reproduces the pair 1.14d actually ships" {
    // 0x80001fff is the imm32 of `AND EAX, 0x80001fff` @0x52d45c and 0xffffe000 the imm32 of
    // `OR EAX, 0xffffe000` @0x52d46a. If this ever fails, the formula and the engine disagree and
    // the patch would be writing a constant that means something else.
    try testing.expectEqual(@as(u32, 0x8000_1fff), mask(stock_frames));
    try testing.expectEqual(@as(u32, 0xffff_e000), fixup(stock_frames));
}

test "mask and fixup stay complements at every expressible interval" {
    var f: u32 = 1;
    while (f <= stock_frames) : (f <<= 1) {
        // The low bits the mask keeps are exactly the ones the fixup restores.
        try testing.expectEqual(f - 1, mask(f) & 0x7fff_ffff);
        try testing.expectEqual(~(mask(f) & 0x7fff_ffff), fixup(f));
    }
}

test "only powers of two are expressible" {
    try testing.expect(isExpressible(1));
    try testing.expect(isExpressible(512));
    try testing.expect(isExpressible(8192));
    try testing.expect(!isExpressible(0));
    try testing.expect(!isExpressible(3));
    try testing.expect(!isExpressible(1000));
}

test "rounding never hands back a longer interval than asked for" {
    try testing.expectEqual(@as(u32, 512), round(512));
    try testing.expectEqual(@as(u32, 512), round(1000));
    try testing.expectEqual(@as(u32, 4096), round(8191));
    try testing.expectEqual(@as(u32, 8192), round(8192));
    var v: u32 = min_frames;
    while (v <= stock_frames) : (v += 1) {
        try testing.expect(round(v) <= v);
    }
}

test "rounding is clamped at both ends and always expressible" {
    try testing.expectEqual(@as(u32, min_frames), round(0));
    try testing.expectEqual(@as(u32, min_frames), round(1));
    try testing.expectEqual(@as(u32, stock_frames), round(100_000));
    for ([_]u32{ 0, 1, 63, 64, 100, 511, 512, 8191, 8192, 99_999 }) |x| {
        try testing.expect(isExpressible(round(x)));
    }
}

test "the interval we default to is well inside the engine's own" {
    // ~20s vs ~5.5min. Stated as a relationship rather than a number so a change to either has to
    // be deliberate.
    const chosen: u32 = 512;
    try testing.expect(isExpressible(chosen));
    try testing.expect(chosen < stock_frames);
    try testing.expect(chosen / fps <= 30);
}

test "the mask instruction is found in both encodings" {
    // `AND EAX, 0x80001fff` is what 1.14d emits; the ModRM form is what another register would
    // give, and a pre-1.14 build is free to use either.
    const eax = [_]u8{ 0x90, 0x25, 0xff, 0x1f, 0x00, 0x80, 0x90 };
    var sites: [4]Site = undefined;
    try testing.expectEqual(@as(usize, 1), findMaskSites(&eax, stock_frames, &sites));
    try testing.expectEqual(@as(usize, 1), sites[0].at);
    try testing.expectEqual(@as(usize, 2), sites[0].imm_at);
    try testing.expectEqual(@as(usize, 5), sites[0].len);

    const ecx = [_]u8{ 0x90, 0x81, 0xE1, 0xff, 0x1f, 0x00, 0x80 };
    try testing.expectEqual(@as(usize, 1), findMaskSites(&ecx, stock_frames, &sites));
    try testing.expectEqual(@as(usize, 1), sites[0].at);
    try testing.expectEqual(@as(usize, 3), sites[0].imm_at);
    try testing.expectEqual(@as(usize, 6), sites[0].len);
}

test "a different constant is not the instruction we are looking for" {
    // The whole method rests on the constant being an identity. A near miss must not match.
    const near = [_]u8{ 0x25, 0xff, 0x1f, 0x00, 0x00 }; // 0x00001fff, no sign bit
    var sites: [4]Site = undefined;
    try testing.expectEqual(@as(usize, 0), findMaskSites(&near, stock_frames, &sites));
}

test "an AND that is not register-direct is not matched" {
    // 0x81 with a memory ModRM is `AND [mem], imm32` — a different instruction of a different
    // length, and patching its immediate would corrupt whatever follows.
    const mem = [_]u8{ 0x81, 0x20, 0xff, 0x1f, 0x00, 0x80 }; // ModRM 0x20 = [eax], /4
    var sites: [4]Site = undefined;
    try testing.expectEqual(@as(usize, 0), findMaskSites(&mem, stock_frames, &sites));
}

test "two matches are reported as two, so a caller can refuse" {
    const twice = [_]u8{
        0x25, 0xff, 0x1f, 0x00, 0x80,
        0x90, 0x90,
        0x25, 0xff, 0x1f, 0x00, 0x80,
    };
    var sites: [4]Site = undefined;
    try testing.expectEqual(@as(usize, 2), findMaskSites(&twice, stock_frames, &sites));
}

test "the fixup is found after its mask, and only within the window" {
    const code = [_]u8{
        0x25, 0xff, 0x1f, 0x00, 0x80, // AND EAX, 0x80001fff
        0x79, 0x07, 0x48, // JNS +7 ; DEC EAX
        0x0D, 0x00, 0xe0, 0xff, 0xff, // OR EAX, 0xffffe000
    };
    const site = findFixupAfter(&code, 5, stock_frames, 32).?;
    try testing.expectEqual(@as(usize, 8), site.at);
    try testing.expectEqual(@as(usize, 9), site.imm_at);
    // Too small a window finds nothing rather than reaching past where it belongs.
    try testing.expect(findFixupAfter(&code, 5, stock_frames, 2) == null);
}

test "scanning a slice with no matches is not an error" {
    const noise = [_]u8{0x90} ** 64;
    var sites: [4]Site = undefined;
    try testing.expectEqual(@as(usize, 0), findMaskSites(&noise, stock_frames, &sites));
    try testing.expect(findFixupAfter(&noise, 0, stock_frames, 64) == null);
}

test "a scan never runs past the end of the slice" {
    // A truncated instruction at the very end must not be read as a match.
    const truncated = [_]u8{ 0x25, 0xff, 0x1f, 0x00 };
    var sites: [4]Site = undefined;
    try testing.expectEqual(@as(usize, 0), findMaskSites(&truncated, stock_frames, &sites));
}
