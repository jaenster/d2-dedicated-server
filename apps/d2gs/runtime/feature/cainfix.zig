//! Put Deckard Cain at the Act 5 (Harrogath) waypoint, like an online game does.
//!
//! Town NPC positions come from the .ds1 preset (identical for SP and online), so the headless GS
//! spawns Cain at the single-player spot. Fixed server-side at room-init (before any client renders
//! the town): find Cain (monster class 520 = DeckardCain6, the Act-5 variant) and the town waypoint
//! object, and place Cain next to it. DISCOVERY mode logs Cain + every object id/pos in Act 5 so the
//! waypoint's real class id and coords can be read from the live game.
const std = @import("std");
const log = @import("../../log.zig");
const feature = @import("../../engine/feature.zig");
const d2 = struct {
    const types = @import("../../engine/d2/types.zig");
};
const UnitAny = d2.types.UnitAny;

const UNIT_MONSTER: usize = 1;
const UNIT_OBJECT: usize = 2;
const CAIN6: u32 = 520; // MonsterUnitDeckardCain6 — Act 5 Cain
const UNITLIST_OFF: usize = 0x1120; // D2GameStrc.pUnitList[5][128]
const BUCKETS: usize = 128;

var done_for_game: bool = false;
var last_game: usize = 0;

/// Bucket head for (unit_type) in the game's server unit hash. Units chain via pListNext.
fn bucketHead(game: *const anyopaque, unit_type: usize, bucket: usize) ?*UnitAny {
    const base = @intFromPtr(game) + UNITLIST_OFF + (unit_type * BUCKETS + bucket) * @sizeOf(usize);
    return @as(*const ?*UnitAny, @ptrFromInt(base)).*;
}

/// Find the first unit of `unit_type` whose class id matches `class`, or null.
fn findByClass(game: *const anyopaque, unit_type: usize, class: u32) ?*UnitAny {
    var b: usize = 0;
    while (b < BUCKETS) : (b += 1) {
        var u = bucketHead(game, unit_type, b);
        while (u) |unit| : (u = unit.pListNext) {
            if (unit.dwTxtFileNo == class) return unit;
        }
    }
    return null;
}

// roomInit fans out per room as the town is built; ctx.game is the server D2GameStrc.
pub fn roomInit(ctx: *const feature.GameCtx, room: *anyopaque) void {
    _ = room;
    const game: *const anyopaque = @ptrCast(ctx.game);
    // Reset per game (pointer identity changes between games).
    if (@intFromPtr(game) != last_game) {
        last_game = @intFromPtr(game);
        done_for_game = false;
    }
    if (done_for_game) return;

    // Cain6 (520) only exists in Act 5, so finding him IS the "we're in Harrogath" gate.
    const cain = findByClass(game, UNIT_MONSTER, CAIN6) orelse return;
    done_for_game = true;

    const cp = cain.getPos();
    log.hex("cainfix: found Cain6 (520) x=", @intCast(cp.x));
    log.hex("cainfix:   Cain6 y=", @intCast(cp.y));

    // Dump every object's class id + position so we can identify the waypoint from the log.
    var b: usize = 0;
    var n: u32 = 0;
    while (b < BUCKETS) : (b += 1) {
        var u = bucketHead(game, UNIT_OBJECT, b);
        while (u) |obj| : (u = obj.pListNext) {
            const p = obj.getPos();
            log.hex("cainfix: object class=", obj.dwTxtFileNo);
            log.hex("cainfix:   obj x=", @intCast(p.x));
            log.hex("cainfix:   obj y=", @intCast(p.y));
            n += 1;
            if (n > 64) return; // safety
        }
    }
}

pub fn install() void {
    log.print("cainfix: armed (Act 5 Cain reposition — discovery pass)");
}
