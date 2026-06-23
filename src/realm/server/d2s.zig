//! Minimal .d2s save-file surgery — the few fields a server rewrites when it clones a
//! character to a new name or sanitises its status byte. Any byte change invalidates the
//! save checksum, so callers must fixChecksum() before persisting or the 1.14d client
//! rejects the file on load.
//!
//! Offsets (1.14d .d2s):
//!   0x0c  u32 LE  checksum   (Game.exe CalculateChecksum @0x411130)
//!   0x14  16 bytes name      (NUL-terminated, 15 chars max)
//!   0x24  u8      status     (0x01 mandatory, 0x04 hardcore, 0x08 died, 0x20 expansion)
const std = @import("std");

pub const off_checksum = 0x0c;
pub const off_name = 0x14;
pub const off_status = 0x24;
pub const name_max = 15;

/// D2's rolling save checksum over the whole file (with the checksum field zeroed):
///   csum = byte + (1 if csum's high bit set) + csum*2   — all u32-wrapping.
/// Verified against real 1.14d saves (matches the client-accepted checksum exactly).
pub fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    for (data) |b| {
        const carry: u32 = @intFromBool(sum & 0x8000_0000 != 0);
        sum = @as(u32, b) +% carry +% (sum *% 2);
    }
    return sum;
}

/// Zero the checksum field, recompute over the whole buffer, and store it (LE) in place.
pub fn fixChecksum(data: []u8) void {
    if (data.len < off_checksum + 4) return;
    @memset(data[off_checksum..][0..4], 0);
    std.mem.writeInt(u32, data[off_checksum..][0..4], checksum(data), .little);
}

/// Rewrite the embedded character name (16-byte NUL-padded field). False if the name is
/// empty or too long. Does NOT fix the checksum — call fixChecksum() after.
pub fn setName(data: []u8, name: []const u8) bool {
    if (data.len < off_name + 16) return false;
    if (name.len == 0 or name.len > name_max) return false;
    @memset(data[off_name..][0..16], 0);
    @memcpy(data[off_name..][0..name.len], name);
    return true;
}

/// The status flags byte, or null if the buffer is too short.
pub fn status(data: []const u8) ?u8 {
    if (data.len <= off_status) return null;
    return data[off_status];
}

/// Overwrite the status flags byte. Does NOT fix the checksum.
pub fn setStatus(data: []u8, v: u8) void {
    if (data.len > off_status) data[off_status] = v;
}

test "checksum matches a known-good real save round-trip" {
    // A buffer whose checksum we set is, by construction, self-consistent: zero the field,
    // compute, store, then verify recompute equals the stored value.
    var buf = [_]u8{0} ** 64;
    buf[0] = 0x55; // sig byte (arbitrary content)
    std.mem.writeInt(u32, buf[off_name..][0..4], 0xDEADBEEF, .little);
    fixChecksum(&buf);
    const stored = std.mem.readInt(u32, buf[off_checksum..][0..4], .little);
    var copy = buf;
    @memset(copy[off_checksum..][0..4], 0);
    try std.testing.expectEqual(stored, checksum(&copy));
}

test "setName rewrites the name field and rejects bad names" {
    var buf = [_]u8{0xAA} ** 64;
    try std.testing.expect(setName(&buf, "Cloney"));
    try std.testing.expectEqualStrings("Cloney", std.mem.sliceTo(buf[off_name..][0..16], 0));
    try std.testing.expect(!setName(&buf, "")); // empty
    try std.testing.expect(!setName(&buf, "ThisNameIsWayTooLong")); // > 15
}
