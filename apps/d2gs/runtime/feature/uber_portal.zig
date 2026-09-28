//! Where an uber red portal says it leads.
//!
//! A portal object carries its destination level in one byte of its object data, and that byte is
//! the whole of what the client knows: `NET_D2GS_SERVER_Send_0x60_SETWARPDEST` @0x53d900 and
//! `_0x51_NEWOBJECT` both send it, and `DRAW_UnitUnderMouse` @0x454f30 names the portal with
//! `CLIENT_GetLevelNameByLevelId(byte)`. Travel does not use it, which is why a wrong byte shows up
//! only as a wrong name.
//!
//! `SERVER_SpawnPortal` @0x56d130 never writes that byte on the portal it creates in town. It is
//! left to the object's init function, and the red portal's (`Objects_InitFn12` @0x54fe70) knows
//! only the portals retail places itself: in Harrogath it stamps Nihlathak's Temple (0x79 @0x54ff6a).
//! Every uber portal is opened in Harrogath, so each one would read "Nihlathak's Temple" unless the
//! opener overwrites the byte with the level it actually linked. Retail's own openers never needed
//! to; ours must. The portal on the far side is fine: `LinkPortal` @0x56cf40 stamps it with the
//! source level.
//!
//! No engine, no Windows, no pointers here, so it is host-testable.
const std = @import("std");

/// The leading bytes of the engine's object data (`D2ObjectDataStrc`). Only the destination byte
/// is ours to touch; the pointer before it is 32-bit in the engine, so it is spelled as a u32 to
/// keep the layout identical on a 64-bit test host.
pub const ObjectData = extern struct {
    objects_txt: u32, // 0x00 ObjectsTxt line
    interact_type: u8, // 0x04 portal destination level

    comptime {
        std.debug.assert(@offsetOf(ObjectData, "interact_type") == 0x04);
    }
};

pub const Level = enum(u8) {
    nihlathaks_temple = 121,
    matrons_den = 133,
    forgotten_sands = 134,
    furnace_of_pain = 135,
    uber_tristram = 136,
};

/// What `Objects_InitFn12` writes on a red portal created in Harrogath.
pub const harrogath_init_default: Level = .nihlathaks_temple;

/// The three levels the key recipe opens, in the order the recipe draws from them.
pub const key_portal_levels = [_]Level{ .matrons_den, .forgotten_sands, .furnace_of_pain };

/// The level the organ recipe opens.
pub const organ_portal_level: Level = .uber_tristram;

/// Stamp `level` as the portal's destination. Must run after `SERVER_SpawnPortal` returns and
/// before the tick ends: the portal is only queued for broadcast then, so the first 0x51/0x60 any
/// client sees already carries the right level.
pub fn setDestination(data: *ObjectData, level: u32) void {
    std.debug.assert(level <= std.math.maxInt(u8));
    data.interact_type = @intCast(level);
}

test "a Harrogath red portal is stamped with the level it links, not the init default" {
    const cases = key_portal_levels ++ [_]Level{organ_portal_level};
    for (cases) |level| {
        // Raw bytes the way the engine lays them out, with the init function's default in place.
        var raw = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, @intFromEnum(harrogath_init_default), 0xEE, 0xEE, 0xEE };
        const data: *ObjectData = @ptrCast(@alignCast(&raw));
        setDestination(data, @intFromEnum(level));
        try std.testing.expectEqualSlices(
            u8,
            &.{ 0xAA, 0xBB, 0xCC, 0xDD, @intFromEnum(level), 0xEE, 0xEE, 0xEE },
            &raw,
        );
    }
}

test "uber levels are the Levels.txt rows the client names" {
    try std.testing.expectEqual(@as(u8, 121), @intFromEnum(harrogath_init_default));
    try std.testing.expectEqualSlices(Level, &.{ .matrons_den, .forgotten_sands, .furnace_of_pain }, &key_portal_levels);
    try std.testing.expectEqual(@as(u8, 133), @intFromEnum(Level.matrons_den));
    try std.testing.expectEqual(@as(u8, 134), @intFromEnum(Level.forgotten_sands));
    try std.testing.expectEqual(@as(u8, 135), @intFromEnum(Level.furnace_of_pain));
    try std.testing.expectEqual(@as(u8, 136), @intFromEnum(Level.uber_tristram));
}
