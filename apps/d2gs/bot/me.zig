//! The local player. A small focused module so bot scripts read like kolbot's
//! `me.*` — "am I in a game?", "where am I?", "how far is that NPC?". Backed by
//! the engine's player-unit global; everything else composes on top.

const globals = @import("../engine/d2/globals.zig");
const unit_mod = @import("unit.zig");

const Unit = unit_mod.Unit;
pub const Pos = unit_mod.Pos;

/// The local player unit, or null before a game world exists.
pub fn unit() ?Unit {
    const p = globals.playerUnit().* orelse return null;
    return Unit.from(p);
}

/// True once a player unit exists AND has a resolved path — i.e. we are actually
/// inside a game world (not still on a menu / loading). This is the gate a bot
/// waits on before doing anything in-world.
pub fn inGame() bool {
    const p = globals.playerUnit().* orelse return false;
    return p.dynamicPath() != null;
}

/// The player's world tile position, or null if not in game yet.
pub fn pos() ?Pos {
    const p = globals.playerUnit().* orelse return null;
    _ = p.dynamicPath() orelse return null;
    const pp = p.getPos();
    return .{ .x = pp.x, .y = pp.y };
}

/// Squared tile distance from the player to `u`, or a large number if the player
/// isn't in a game yet.
pub fn distanceToUnit(u: Unit) i64 {
    const me_pos = pos() orelse return @import("std").math.maxInt(i64);
    return u.distanceToXY(me_pos.x, me_pos.y);
}
