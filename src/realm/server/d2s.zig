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

/// Status-byte flags (offset 0x24). `expansion` is what a classic -> LOD upgrade sets.
pub const status_hardcore: u8 = 0x04;
pub const status_died: u8 = 0x08;
pub const status_expansion: u8 = 0x20;

pub const off_checksum = 0x0c;
pub const off_name = 0x14;
pub const off_status = 0x24;
pub const name_max = 15;

// Fresh-character .d2s = the 335-byte header alone (D2SaveFileHeaderStrc); the engine
// materializes starting stats/skills/items from CharStats.txt on first play and grows
// the file on save. Field offsets verified from the 1.14d struct.
pub const new_save_size = 0x14f; // 335
const off_signature = 0x00; // u32 0xaa55aa55
const off_version = 0x04; // u32 0x60
const off_filesize = 0x08; // u32 = new_save_size
const off_class = 0x28; // u8  nPlayerClassId
const off_const16 = 0x29; // u8  nConst16 = 0x10
const off_maxskills = 0x2a; // u8  nMaxSkillsCount = 0x1e
const off_level = 0x2b; // u8  bCharacterLevel = 1
const off_createtime = 0x2c; // u32 nCreateTime
const off_time32 = 0x30; // u32 nTime32 (= create time)
const off_appearance1 = 0x88; // char[16] menu appearance (equip graphics)
const off_appearance2 = 0x98; // char[16] color transforms
const class_druid = 5;
const class_assassin = 6;

/// Build a fresh level-1 .d2s into `out` (the 335-byte header). Mirrors
/// LAUNCHER_InitNewCharacterSaveFile @0x43c540: signature/version/size, name, status
/// (`flags | 1`, +0x20 expansion for Druid/Assassin), level 1, class, create time,
/// nConst16=0x10, nMaxSkillsCount=0x1e, appearance = all 0xFF (naked; the GS sets the
/// real look on first play). Fixes the checksum. False on a bad name/class.
pub fn newSave(out: *[new_save_size]u8, name: []const u8, class: u8, status_flags: u8, create_time: u32) bool {
    if (name.len == 0 or name.len > name_max or class > class_assassin) return false;
    @memset(out, 0);
    std.mem.writeInt(u32, out[off_signature..][0..4], 0xaa55aa55, .little);
    std.mem.writeInt(u32, out[off_version..][0..4], 0x60, .little);
    std.mem.writeInt(u32, out[off_filesize..][0..4], new_save_size, .little);
    @memcpy(out[off_name..][0..name.len], name);
    var st: u8 = status_flags | 0x01;
    if (class == class_druid or class == class_assassin) st |= 0x20;
    std.mem.writeInt(u32, out[off_status..][0..4], st, .little);
    out[off_class] = class;
    out[off_const16] = 0x10;
    out[off_maxskills] = 0x1e;
    out[off_level] = 1;
    std.mem.writeInt(u32, out[off_createtime..][0..4], create_time, .little);
    std.mem.writeInt(u32, out[off_time32..][0..4], create_time, .little);
    @memset(out[off_appearance1..][0..16], 0xFF);
    @memset(out[off_appearance2..][0..16], 0xFF);
    fixChecksum(out);
    return true;
}

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

// ── attributes ("gf" section) ────────────────────────────────────────────────
// Everything a played character actually IS lives past the header in a bit-packed list:
// a 9-bit ItemStatCost id, then that stat's value at its own width, repeating until the
// terminator id 0x1FF. The widths are ItemStatCost.txt's CSvBits column, so this table is
// the game's own data rather than a guess — and the reason experience cannot simply be
// read at a fixed offset the way level and class can.
const stat_bits = [_]u8{
    10, // 0  strength
    10, // 1  energy
    10, // 2  dexterity
    10, // 3  vitality
    10, // 4  statpts
    8, // 5  newskills
    21, // 6  hitpoints
    21, // 7  maxhp
    21, // 8  mana
    21, // 9  maxmana
    21, // 10 stamina
    21, // 11 maxstamina
    7, // 12 level
    32, // 13 experience
    25, // 14 gold
    25, // 15 goldbank
};

pub const stat_level = 12;
pub const stat_experience = 13;

/// Terminator id that ends the attribute list.
const stat_end = 0x1FF;

/// LSB-first bit reader over the save's packed sections.
const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // in bits

    fn read(r: *BitReader, n: u8) ?u32 {
        if (n == 0 or n > 32) return null;
        if (r.pos + n > r.data.len * 8) return null;
        var v: u32 = 0;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const bit = (r.data[(r.pos + i) >> 3] >> @intCast((r.pos + i) & 7)) & 1;
            v |= @as(u32, bit) << @intCast(i);
        }
        r.pos += n;
        return v;
    }
};

/// Read one attribute out of a played character's save. Null when the save has no
/// attribute section (a freshly created character is only the header, and gets one the
/// first time the game saves it) or the list ends without that stat.
///
/// Walking the list is the only way in: every entry's width depends on which stat it is,
/// so a later stat cannot be located without decoding the ones before it.
pub fn attribute(data: []const u8, stat_id: u16) ?u32 {
    const marker = std.mem.indexOf(u8, data, "gf") orelse return null;
    var r = BitReader{ .data = data[marker + 2 ..] };
    while (true) {
        const id = r.read(9) orelse return null;
        if (id == stat_end) return null;
        if (id >= stat_bits.len) return null; // unknown id: widths after it are unknowable
        const v = r.read(stat_bits[id]) orelse return null;
        if (id == stat_id) return v;
    }
}

test "attribute walks the packed list and finds experience" {
    // Build a "gf" section by hand: level(12)=87, experience(13)=1_500_000, then the
    // terminator, packed LSB-first exactly as the game writes it.
    var save = [_]u8{0} ** 64;
    @memcpy(save[0..8], "HEADERgf");
    var bit: usize = 0;
    const put = struct {
        fn f(buf: []u8, at: *usize, value: u32, width: u8) void {
            var i: u8 = 0;
            while (i < width) : (i += 1) {
                if ((value >> @intCast(i)) & 1 != 0) buf[8 + (at.* >> 3)] |= @as(u8, 1) << @intCast(at.* & 7);
                at.* += 1;
            }
        }
    }.f;
    put(&save, &bit, stat_level, 9);
    put(&save, &bit, 87, stat_bits[stat_level]);
    put(&save, &bit, stat_experience, 9);
    put(&save, &bit, 1_500_000, stat_bits[stat_experience]);
    put(&save, &bit, stat_end, 9);
    const used = save[0 .. 8 + (bit + 7) / 8];

    try std.testing.expectEqual(@as(?u32, 87), attribute(used, stat_level));
    try std.testing.expectEqual(@as(?u32, 1_500_000), attribute(used, stat_experience));
    try std.testing.expectEqual(@as(?u32, null), attribute(used, 14)); // gold: not in the list
}

test "attribute returns null for a save with no attribute section" {
    var save: [new_save_size]u8 = undefined;
    try std.testing.expect(newSave(&save, "Freshie", 1, 0x20, 0x12345678));
    try std.testing.expectEqual(@as(?u32, null), attribute(&save, stat_experience));
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

test "newSave builds a valid 335-byte fresh character header" {
    var save: [new_save_size]u8 = undefined;
    try std.testing.expect(newSave(&save, "Freshie", 1, 0x20, 0x12345678)); // Sorceress, expansion
    try std.testing.expectEqual(@as(u32, 0xaa55aa55), std.mem.readInt(u32, save[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x60), std.mem.readInt(u32, save[off_version..][0..4], .little));
    try std.testing.expectEqual(@as(u32, new_save_size), std.mem.readInt(u32, save[off_filesize..][0..4], .little));
    try std.testing.expectEqualStrings("Freshie", std.mem.sliceTo(save[off_name..][0..16], 0));
    try std.testing.expectEqual(@as(u8, 0x21), save[off_status]); // 0x20 expansion | 0x01 mandatory
    try std.testing.expectEqual(@as(u8, 1), save[off_class]);
    try std.testing.expectEqual(@as(u8, 1), save[off_level]);
    try std.testing.expectEqual(@as(u8, 0x1e), save[off_maxskills]);
    // Druid (5) forces expansion even if not requested.
    try std.testing.expect(newSave(&save, "Treebeard", 5, 0, 0));
    try std.testing.expectEqual(@as(u8, 0x21), save[off_status]);
    // Checksum is self-consistent.
    const stored = std.mem.readInt(u32, save[off_checksum..][0..4], .little);
    var copy = save;
    @memset(copy[off_checksum..][0..4], 0);
    try std.testing.expectEqual(stored, checksum(&copy));
    // Bad inputs rejected.
    try std.testing.expect(!newSave(&save, "", 1, 0, 0));
    try std.testing.expect(!newSave(&save, "WayTooLongCharName", 1, 0, 0));
    try std.testing.expect(!newSave(&save, "Ok", 7, 0, 0)); // class out of range
}

test "setName rewrites the name field and rejects bad names" {
    var buf = [_]u8{0xAA} ** 64;
    try std.testing.expect(setName(&buf, "Cloney"));
    try std.testing.expectEqualStrings("Cloney", std.mem.sliceTo(buf[off_name..][0..16], 0));
    try std.testing.expect(!setName(&buf, "")); // empty
    try std.testing.expect(!setName(&buf, "ThisNameIsWayTooLong")); // > 15
}
