//! Darwin-internal names the host libc does not spell at all.
//!
//! These are the ones the compiler emits rather than the ones the game wrote: `__memcpy_chk` behind
//! a fortified `memcpy`, `__error` behind the `errno` macro, `__maskrune` and `_DefaultRuneLocale`
//! behind `isspace`, `__udivdi3` behind a 64-bit divide on a 32-bit machine. None of them exist on
//! Linux under any name, and all of them are small enough to be written out here rather than guessed
//! at through a thunk.
//!
//! Keyed on the name exactly as the image spells it, because normalise() cannot help here: `___error`
//! would come out as `__error` and `__DefaultRuneLocale` as `_DefaultRuneLocale`, and neither is the
//! name of anything.

const std = @import("std");
const builtin = @import("builtin");

/// Address of an import name as the image spells it, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "___memcpy_chk", &memcpyChk },
        .{ "___memmove_chk", &memmoveChk },
        .{ "___strcpy_chk", &strcpyChk },
        .{ "___strncpy_chk", &strncpyChk },
        .{ "___bzero", &bzero },
        .{ "___error", &errorLocation },
        .{ "___tolower", &toLower },
        .{ "___toupper", &toUpper },
        .{ "___maskrune", &maskRune },
        .{ "__DefaultRuneLocale", &DefaultRuneLocale },
        .{ "___divdi3", &divdi3 },
        .{ "___udivdi3", &udivdi3 },
        .{ "___umoddi3", &umoddi3 },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

// ── the fortified string family ──

/// How a fortified call reports that the game asked for a copy longer than the destination it
/// declared. Darwin's `__chk_fail` aborts; replaced by the host so this package does not decide how
/// the server dies. It must not return — if it does, the shim writes nothing at all.
pub const ChkFail = *const fn (what: [*:0]const u8) callconv(.c) void;

var chk_fail: ChkFail = defaultChkFail;

fn defaultChkFail(what: [*:0]const u8) callconv(.c) void {
    std.debug.panic("fortified {s} would overrun its destination", .{what});
}

pub fn setChkFail(f: ChkFail) void {
    chk_fail = f;
}

/// The fortified forms are the normal call plus a trailing `size_t` the compiler filled in from the
/// destination's declared size, and they return what the normal call returns.
pub fn memcpyChk(dst: [*]u8, src: [*]const u8, len: usize, destlen: usize) callconv(.c) [*]u8 {
    if (len > destlen) {
        chk_fail("memcpy");
        return dst;
    }
    @memcpy(dst[0..len], src[0..len]);
    return dst;
}

pub fn memmoveChk(dst: [*]u8, src: [*]const u8, len: usize, destlen: usize) callconv(.c) [*]u8 {
    if (len > destlen) {
        chk_fail("memmove");
        return dst;
    }
    if (@intFromPtr(dst) <= @intFromPtr(src)) {
        std.mem.copyForwards(u8, dst[0..len], src[0..len]);
    } else {
        std.mem.copyBackwards(u8, dst[0..len], src[0..len]);
    }
    return dst;
}

/// The terminator counts against `destlen`, which is the off-by-one this check exists to catch.
pub fn strcpyChk(dst: [*]u8, src: [*:0]const u8, destlen: usize) callconv(.c) [*]u8 {
    const len = std.mem.len(src);
    if (len + 1 > destlen) {
        chk_fail("strcpy");
        return dst;
    }
    @memcpy(dst[0 .. len + 1], src[0 .. len + 1]);
    return dst;
}

/// strncpy zero-fills the rest of `n` and does not terminate a truncated copy, so the bound checked
/// is `n` against `destlen` and not the length of the source.
pub fn strncpyChk(dst: [*]u8, src: [*:0]const u8, n: usize, destlen: usize) callconv(.c) [*]u8 {
    if (n > destlen) {
        chk_fail("strncpy");
        return dst;
    }
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dst[i] = src[i];
    @memset(dst[i..n], 0);
    return dst;
}

/// Darwin's internal name for `bzero`. No fortification, no length to check against.
pub fn bzero(dst: [*]u8, len: usize) callconv(.c) void {
    @memset(dst[0..len], 0);
}

// ── errno ──

const errnoLocation = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => struct {
        extern fn __error() *c_int;
    }.__error,
    else => struct {
        extern fn __errno_location() *c_int;
    }.__errno_location,
};

/// `errno` is a macro over this call on both platforms; only the name differs.
pub fn errorLocation() callconv(.c) *c_int {
    return errnoLocation();
}

// ── ctype and the C locale ──

/// Darwin's `_CTYPE_*`. The low eight bits of a `__runetype` entry are the digit value, which is
/// what `digittoint` reads out of a hex digit.
const CT = struct {
    const A: u32 = 0x0000_0100; // alpha
    const C: u32 = 0x0000_0200; // control
    const D: u32 = 0x0000_0400; // digit
    const G: u32 = 0x0000_0800; // graph
    const L: u32 = 0x0000_1000; // lower
    const P: u32 = 0x0000_2000; // punct
    const S: u32 = 0x0000_4000; // space
    const U: u32 = 0x0000_8000; // upper
    const X: u32 = 0x0001_0000; // hex digit
    const B: u32 = 0x0002_0000; // blank
    const R: u32 = 0x0004_0000; // print
    const SW1: u32 = 0x4000_0000; // one column wide
};

const cached_runes = 256;

/// The C locale, and nothing else. Entries 0x80..0xFF stay zero, which is correct for "C" and wrong
/// for every locale the game cannot select anyway: there is no setlocale here, so this is the only
/// table there will ever be.
const runetype: [cached_runes]u32 = blk: {
    var t: [cached_runes]u32 = @splat(0);
    for (0..128) |i| {
        const c: u8 = @intCast(i);
        var f: u32 = 0;
        if (c < 0x20 or c == 0x7f) f |= CT.C;
        if (c == ' ' or (c >= 0x09 and c <= 0x0d)) f |= CT.S;
        if (c == ' ' or c == '\t') f |= CT.B;
        if (c >= '0' and c <= '9') f |= CT.D | CT.X | (c - '0');
        if (c >= 'A' and c <= 'Z') f |= CT.U | CT.A;
        if (c >= 'a' and c <= 'z') f |= CT.L | CT.A;
        if (c >= 'A' and c <= 'F') f |= CT.X | (c - 'A' + 10);
        if (c >= 'a' and c <= 'f') f |= CT.X | (c - 'a' + 10);
        if (c > 0x20 and c != 0x7f) f |= CT.G;
        if (c >= 0x20 and c != 0x7f) f |= CT.R | CT.SW1;
        if (f & CT.G != 0 and f & (CT.A | CT.D) == 0) f |= CT.P;
        t[i] = f;
    }
    break :blk t;
};

const maplower: [cached_runes]i32 = blk: {
    var t: [cached_runes]i32 = undefined;
    for (0..cached_runes) |i| {
        const c: u8 = @intCast(i);
        t[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    break :blk t;
};

const mapupper: [cached_runes]i32 = blk: {
    var t: [cached_runes]i32 = undefined;
    for (0..cached_runes) |i| {
        const c: u8 = @intCast(i);
        t[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    break :blk t;
};

const RuneRange = extern struct { nranges: c_int = 0, ranges: ?*anyopaque = null };

/// Darwin's `_RuneLocale`. The layout is load-bearing rather than decorative: `isspace(c)` and its
/// siblings are macros that index `_DefaultRuneLocale.__runetype[c]` inline, so the game reads this
/// object directly and every offset has to be Darwin's.
pub const RuneLocale = extern struct {
    magic: [8]u8,
    encoding: [32]u8,
    sgetrune: ?*const anyopaque,
    sputrune: ?*const anyopaque,
    invalid_rune: i32,
    runetype: [cached_runes]u32,
    maplower: [cached_runes]i32,
    mapupper: [cached_runes]i32,
    runetype_ext: RuneRange,
    maplower_ext: RuneRange,
    mapupper_ext: RuneRange,
    variable: ?*anyopaque,
    variable_len: c_int,
};

/// Data, not a function: the resolver binds the game's pointer straight at this object. Not covered,
/// and it does not need to be for a headless server — the three `_ext` ranges are empty, so nothing
/// outside the 256 cached runes classifies, and `__sgetrune`/`__sputrune` are null, so any multibyte
/// conversion routed through this struct would call through a null pointer rather than convert.
pub var DefaultRuneLocale: RuneLocale = .{
    .magic = "RuneMagi".*,
    .encoding = ("NONE" ++ [_]u8{0} ** 28).*,
    .sgetrune = null,
    .sputrune = null,
    .invalid_rune = 0xFFFD,
    .runetype = runetype,
    .maplower = maplower,
    .mapupper = mapupper,
    .runetype_ext = .{},
    .maplower_ext = .{},
    .mapupper_ext = .{},
    .variable = null,
    .variable_len = 0,
};

/// What `isalpha` and friends fall back to for a rune outside the cached range. In the C locale
/// that is nothing, so the answer is always zero.
pub fn maskRune(c: c_int, f: c_ulong) callconv(.c) c_int {
    if (c < 0 or c >= cached_runes) return 0;
    return @bitCast(DefaultRuneLocale.runetype[@intCast(c)] & @as(u32, @truncate(f)));
}

/// The raw forms behind the `tolower`/`toupper` macros. ASCII only, which is what the C locale is.
pub fn toLower(c: c_int) callconv(.c) c_int {
    if (c < 0 or c >= cached_runes) return c;
    return DefaultRuneLocale.maplower[@intCast(c)];
}

pub fn toUpper(c: c_int) callconv(.c) c_int {
    if (c < 0 or c >= cached_runes) return c;
    return DefaultRuneLocale.mapupper[@intCast(c)];
}

// ── 64-bit division on a 32-bit machine ──

/// i386 has no 64-bit divide, so the compiler calls these. Truncating division and a remainder that
/// takes the dividend's sign, which is C's rule and Zig's `@divTrunc`/`@rem`.
pub fn divdi3(a: i64, b: i64) callconv(.c) i64 {
    return @divTrunc(a, b);
}

pub fn udivdi3(a: u64, b: u64) callconv(.c) u64 {
    return a / b;
}

pub fn umoddi3(a: u64, b: u64) callconv(.c) u64 {
    return a % b;
}

const testing = std.testing;

var chk_fired: usize = 0;

fn recordChkFail(what: [*:0]const u8) callconv(.c) void {
    _ = what;
    chk_fired += 1;
}

test "strncpy_chk copies inside the declared size and refuses outside it" {
    setChkFail(recordChkFail);
    defer setChkFail(defaultChkFail);
    chk_fired = 0;

    var buf: [16]u8 = @splat('x');
    _ = strncpyChk(&buf, "abc", 8, buf.len);
    try testing.expectEqual(@as(usize, 0), chk_fired);
    try testing.expectEqualStrings("abc", buf[0..3]);
    // strncpy zero-fills the rest of n and leaves everything past it alone.
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0 }, buf[3..8]);
    try testing.expectEqual(@as(u8, 'x'), buf[8]);

    // n exceeds the destination: the fortified form reports it and writes nothing.
    @memset(&buf, 'x');
    _ = strncpyChk(&buf, "abc", 9, 8);
    try testing.expectEqual(@as(usize, 1), chk_fired);
    try testing.expectEqual(@as(u8, 'x'), buf[0]);

    // Exactly the declared size is legal; one more is not.
    _ = strncpyChk(&buf, "abc", 8, 8);
    try testing.expectEqual(@as(usize, 1), chk_fired);
}

test "the other fortified forms count the terminator and the overlap" {
    setChkFail(recordChkFail);
    defer setChkFail(defaultChkFail);
    chk_fired = 0;

    var buf: [16]u8 = @splat('x');

    // "hello" needs six bytes, not five.
    _ = strcpyChk(&buf, "hello", 5);
    try testing.expectEqual(@as(usize, 1), chk_fired);
    _ = strcpyChk(&buf, "hello", 6);
    try testing.expectEqual(@as(usize, 1), chk_fired);
    try testing.expectEqualStrings("hello", buf[0..5]);
    try testing.expectEqual(@as(u8, 0), buf[5]);

    _ = memcpyChk(&buf, "abcd", 4, 4);
    try testing.expectEqualStrings("abcd", buf[0..4]);
    _ = memcpyChk(&buf, "abcd", 4, 3);
    try testing.expectEqual(@as(usize, 2), chk_fired);

    // Overlapping backwards is the case a plain memcpy gets wrong.
    @memcpy(buf[0..6], "abcdef");
    _ = memmoveChk(buf[2..].ptr, &buf, 6, buf.len - 2);
    try testing.expectEqualStrings("ababcdef", buf[0..8]);
    _ = memmoveChk(&buf, "xy", 2, 1);
    try testing.expectEqual(@as(usize, 3), chk_fired);

    @memset(&buf, 'x');
    bzero(&buf, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 'x' }, buf[0..5]);
}

test "errno is the calling thread's own" {
    const p = errorLocation();
    p.* = 0;
    _ = std.c.close(-1);
    try testing.expect(p.* != 0);
    try testing.expectEqual(p, errorLocation());
}

test "the rune table classifies ASCII the way the C locale does" {
    // The offsets the game's inline ctype macros index through. i386 puts __runetype at 52.
    try testing.expectEqual(40 + 2 * @sizeOf(usize) + 4, @offsetOf(RuneLocale, "runetype"));
    if (@sizeOf(usize) == 4) try testing.expectEqual(@as(usize, 52), @offsetOf(RuneLocale, "runetype"));
    try testing.expectEqualStrings("RuneMagi", &DefaultRuneLocale.magic);

    try testing.expect(maskRune(' ', CT.S) != 0);
    try testing.expect(maskRune(' ', CT.B) != 0);
    try testing.expect(maskRune('\n', CT.S) != 0);
    try testing.expect(maskRune('\n', CT.B) == 0);
    try testing.expect(maskRune('7', CT.D | CT.X) != 0);
    try testing.expect(maskRune('g', CT.X) == 0);
    try testing.expect(maskRune('f', CT.X) != 0);
    try testing.expect(maskRune('.', CT.P) != 0);
    try testing.expect(maskRune('.', CT.A) == 0);
    try testing.expect(maskRune('Z', CT.U | CT.A) != 0);
    try testing.expect(maskRune(0, CT.C) != 0);

    // Outside the cached range nothing classifies, and neither does a negative rune.
    try testing.expectEqual(@as(c_int, 0), maskRune(0x2028, CT.S));
    try testing.expectEqual(@as(c_int, 0), maskRune(-1, CT.C));

    // The digit value lives in the low byte, which is what digittoint reads.
    try testing.expectEqual(@as(u32, 15), DefaultRuneLocale.runetype['f'] & 0xff);
    try testing.expectEqual(@as(u32, 7), DefaultRuneLocale.runetype['7'] & 0xff);

    try testing.expectEqual(@as(c_int, 'a'), toLower('A'));
    try testing.expectEqual(@as(c_int, 'a'), toLower('a'));
    try testing.expectEqual(@as(c_int, 'Q'), toUpper('q'));
    try testing.expectEqual(@as(c_int, '!'), toUpper('!'));
    try testing.expectEqual(@as(c_int, 0x2028), toLower(0x2028));
}

test "the 64-bit division helpers" {
    try testing.expectEqual(@as(u64, 0x1_0000_0000), udivdi3(0x1_0000_0000_0000, 0x1_0000));
    try testing.expectEqual(@as(u64, 3), udivdi3(0xFFFF_FFFF_FFFF_FFFF, 0x5555_5555_5555_5555));

    // A divisor above 2^32 is the case a 32-bit shortcut gets wrong.
    try testing.expectEqual(@as(u64, 4), udivdi3(0x4_0000_0000_0000, 0x1_0000_0000_0000));
    try testing.expectEqual(@as(u64, 1), udivdi3(0xFFFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000));
    try testing.expectEqual(@as(u64, 0), udivdi3(0x1_0000_0000, 0x1_0000_0001));

    try testing.expectEqual(@as(u64, 7), umoddi3(0x1_0000_0000_0007, 0x1_0000_0000_0000));
    try testing.expectEqual(@as(u64, 0x7FFF_FFFF_FFFF_FFFF), umoddi3(0xFFFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000));
    try testing.expectEqual(@as(u64, 1), umoddi3(0xFFFF_FFFF_FFFF_FFFF, 2));

    // Signed division truncates toward zero and the remainder follows the dividend.
    try testing.expectEqual(@as(i64, -3), divdi3(-10, 3));
    try testing.expectEqual(@as(i64, 3), divdi3(-10, -3));
    try testing.expectEqual(@as(i64, -0x1_0000_0000), divdi3(-0x1_0000_0000_0000, 0x1_0000));
}

test "only the names the image asks for are answered here" {
    for ([_][]const u8{
        "___memcpy_chk", "___memmove_chk", "___strcpy_chk", "___strncpy_chk", "___bzero",
        "___error",      "___tolower",     "___toupper",    "___maskrune",    "__DefaultRuneLocale",
        "___divdi3",     "___udivdi3",     "___umoddi3",
    }) |n| try testing.expect(address(n).? != 0);

    // The normalised spellings are not names of anything, and the C++ ABI stays with the thunks.
    try testing.expectEqual(@as(?usize, null), address("__error"));
    try testing.expectEqual(@as(?usize, null), address("_DefaultRuneLocale"));
    try testing.expectEqual(@as(?usize, null), address("___cxa_throw"));
    try testing.expectEqual(@as(?usize, null), address("___stack_chk_fail"));
}
