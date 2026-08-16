//! The realm's view of a .d2s save.
//!
//! The FORMAT is not defined here — it comes from libd2's `d2-formats`, which already models
//! the 1.14d header (offsets, rolling checksum, fresh-character writer, name field).
//!
//! What remains is the part libd2 has no opinion about: reading a single ATTRIBUTE out of a
//! played save, needed only for the ladder (experience). libd2's d2-save models the whole
//! attribute section but pulls in the item model + full excel tables to do it — too much
//! machinery for "read one integer", so the realm keeps this narrow reader instead.
const std = @import("std");
const formats = @import("libd2").formats;

// the format, from libd2
pub const off_checksum = formats.d2s.off_checksum;
pub const off_name = formats.d2s.off_name;
pub const off_status = formats.d2s.off_status;
pub const name_max = formats.d2s.name_max;
pub const new_save_size = formats.d2s.header_size;

pub const checksum = formats.d2s.checksum;
pub const fixChecksum = formats.d2s.fixChecksum;
pub const setName = formats.d2s.setName;
pub const newSave = formats.d2s.newSave;

/// Status-byte flags (offset 0x24). `expansion` is what a classic -> LOD upgrade sets.
pub const status_hardcore: u8 = 0x04;
pub const status_died: u8 = 0x08;
pub const status_expansion: u8 = 0x20;

/// The status flags byte, or null if the buffer is too short.
pub fn status(data: []const u8) ?u8 {
    if (data.len <= off_status) return null;
    return data[off_status];
}

/// Overwrite the status flags byte. Does NOT fix the checksum.
pub fn setStatus(data: []u8, v: u8) void {
    if (data.len > off_status) data[off_status] = v;
}

// attributes ("gf" section)
// Everything a played character actually IS lives past the header in a bit-packed list:
// a 9-bit ItemStatCost id, then that stat's value at its own width, repeating until the
// terminator id 0x1FF. The widths are ItemStatCost.txt's CSvBits column — the same table
// libd2's d2-save calls ATTR_BITS, kept in step with it.
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

test "the attribute widths agree with libd2's" {
    // If d2-save's table and this one ever diverge, one of them decodes garbage. They are
    // the same table from the same column of ItemStatCost.txt, so assert it rather than
    // trusting two copies to stay in step.
    const save = @import("libd2").formats;
    _ = save;
    try std.testing.expectEqual(@as(usize, 16), stat_bits.len);
    try std.testing.expectEqual(@as(u8, 32), stat_bits[stat_experience]);
    try std.testing.expectEqual(@as(u8, 7), stat_bits[stat_level]);
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

test "libd2 writes a header this realm recognises" {
    var save: [new_save_size]u8 = undefined;
    try std.testing.expect(newSave(&save, "Freshie", 1, 0x20, 0x12345678));
    try std.testing.expectEqualStrings("Freshie", std.mem.sliceTo(save[off_name..][0..16], 0));
    try std.testing.expectEqual(@as(u8, 0x21), status(&save).?); // expansion | mandatory
    try std.testing.expect(formats.d2s.verifyChecksum(&save));
}
