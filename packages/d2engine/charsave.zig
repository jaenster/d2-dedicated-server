//! The character save the engine hands its host, decoded from the raw callback arguments.
//!
//! `fpSaveDatabaseCharacter` (slot 0x0C) has the same shape on every build we host. 1.14d's call
//! site @0x53220d and pvpgn's 1.09d GS header agree argument for argument:
//!
//!     __fastcall (pGameOrRealmId, char *szCharName, char *szAccountName,
//!                 void *pSave, u32 nSize, u32 nClientContainer)
//!
//! `pSave` is NOT the .d2s. It points at a `u16` byte count followed by the save, and `nSize` is
//! that same count — pvpgn's handler copies `pdata + sizeof(short)` for `dwSize - sizeof(short)`
//! bytes, which is the whole of what it forwards to d2dbs. Getting that two-byte offset wrong
//! stores a save the game will never read back and the mistake is invisible until a player logs
//! in, so the decode lives here once rather than in each host.
//!
//! Everything below is pure: give it the bytes and it tells you whether they are a save and what
//! character they belong to. The hosts do the pointer reading, because only they know their own
//! engine's memory.

const std = @import("std");

/// `0xaa55aa55` — the first dword of every .d2s, on every version. A blob without it is not a
/// save, and storing it would replace a character with rubbish.
pub const signature: u32 = 0xaa55_aa55;

/// The character's name inside the .d2s: 16 bytes at 0x14, NUL-padded. It is taken from here
/// rather than from the callback's `szCharName` argument on purpose — the save is the thing being
/// written, so the name it carries is the one it should be filed under.
pub const name_offset = 0x14;
pub const name_len = 16;

/// The smallest blob that can be a save: the two length bytes plus enough .d2s to hold the header
/// through the name field.
pub const min_blob = 2 + name_offset + name_len;

/// A save the engine considers big enough to be worth refusing rather than storing. Real saves are
/// a few KB; anything past this is a length field we misread, and writing it would put megabytes
/// of unrelated memory in the store under a character's name.
pub const max_d2s = 32 * 1024;

pub const Error = error{
    /// The blob is too short to contain a save header.
    TooShort,
    /// The declared length disagrees with the bytes actually available.
    LengthMismatch,
    /// Missing the 0xaa55aa55 signature — not a .d2s.
    BadSignature,
    /// Implausibly large; see `max_d2s`.
    TooLarge,
    /// The name field is empty, or has no terminator inside its 16 bytes.
    BadName,
};

pub const Save = struct {
    /// The character's name, as the save itself spells it.
    charname: []const u8,
    /// The .d2s, ready to store verbatim.
    d2s: []const u8,
};

/// How many bytes the engine says are at `pSave`, read from its first two bytes. The host uses
/// this to bound the slice it then hands to `decode`; it is separate because reading engine memory
/// is the host's job, not this file's.
pub fn declaredLen(first_two: [2]u8) usize {
    return std.mem.readInt(u16, &first_two, .little);
}

/// Decode `{u16 total; .d2s}` as the callback's 4th argument points at it.
///
/// `blob.len` must be exactly the declared total: the caller has already read the length to know
/// how much to slice, and checking it again here is what catches a host that sliced by its own
/// buffer size instead.
pub fn decode(blob: []const u8) Error!Save {
    if (blob.len < min_blob) return Error.TooShort;
    const declared = std.mem.readInt(u16, blob[0..2], .little);
    if (declared != blob.len) return Error.LengthMismatch;

    const d2s = blob[2..];
    if (d2s.len > max_d2s) return Error.TooLarge;
    if (std.mem.readInt(u32, d2s[0..4], .little) != signature) return Error.BadSignature;

    const field = d2s[name_offset..][0..name_len];
    const end = std.mem.indexOfScalar(u8, field, 0) orelse return Error.BadName;
    if (end == 0) return Error.BadName;
    return .{ .charname = field[0..end], .d2s = d2s };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn build(name: []const u8, extra: usize) [256]u8 {
    var buf: [256]u8 = @splat(0);
    const total: u16 = @intCast(2 + name_offset + name_len + extra);
    std.mem.writeInt(u16, buf[0..2], total, .little);
    std.mem.writeInt(u32, buf[2..6], signature, .little);
    @memcpy(buf[2 + name_offset ..][0..name.len], name);
    return buf;
}

test "a well-formed save decodes to its name and its bytes" {
    const buf = build("Persist", 0);
    const s = try decode(buf[0..min_blob]);
    try testing.expectEqualStrings("Persist", s.charname);
    try testing.expectEqual(@as(usize, min_blob - 2), s.d2s.len);
    // The .d2s starts AT the signature — the two length bytes are not part of it. A host that
    // stored `blob` instead of `s.d2s` would prepend two bytes to every character it saved.
    try testing.expectEqual(signature, std.mem.readInt(u32, s.d2s[0..4], .little));
}

test "a name filling the whole field has no terminator, and is refused" {
    // 16 bytes with no NUL is not a name we can read; guessing the length would silently rename
    // the character and file the save somewhere new.
    var buf = build("", 0);
    @memcpy(buf[2 + name_offset ..][0..name_len], "AAAAAAAAAAAAAAAA");
    try testing.expectError(Error.BadName, decode(buf[0..min_blob]));
}

test "an empty name is refused" {
    const buf = build("", 0);
    try testing.expectError(Error.BadName, decode(buf[0..min_blob]));
}

test "a blob without the signature is not a save" {
    var buf = build("Persist", 0);
    std.mem.writeInt(u32, buf[2..6], 0xdead_beef, .little);
    try testing.expectError(Error.BadSignature, decode(buf[0..min_blob]));
}

test "a declared length that disagrees with the slice is refused" {
    // This is the host-sliced-by-its-own-buffer bug: the blob is real, the slice is not what the
    // engine described, and storing it would truncate or over-read the save.
    var buf = build("Persist", 0);
    std.mem.writeInt(u16, buf[0..2], min_blob + 8, .little);
    try testing.expectError(Error.LengthMismatch, decode(buf[0..min_blob]));
}

test "a blob too short to hold a header is refused before anything is read from it" {
    var buf: [8]u8 = @splat(0);
    std.mem.writeInt(u16, buf[0..2], 8, .little);
    try testing.expectError(Error.TooShort, decode(&buf));
}

test "the declared length is read little-endian" {
    try testing.expectEqual(@as(usize, 0x1234), declaredLen(.{ 0x34, 0x12 }));
}

test "a save decodes the same whatever follows the name" {
    // Real saves are a few KB of sections after the header; the decode must not care.
    const buf = build("Tail", 64);
    const s = try decode(buf[0 .. min_blob + 64]);
    try testing.expectEqualStrings("Tail", s.charname);
    try testing.expectEqual(@as(usize, min_blob + 64 - 2), s.d2s.len);
}
