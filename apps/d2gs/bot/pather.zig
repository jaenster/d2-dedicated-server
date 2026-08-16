//! Movement. kolbot's `Pather.moveTo` analogue: step the player toward a tile,
//! re-reading positions each step, until in range or a frame budget runs out.
//!
//! VIEWPORT LIMITATION: real movement uses ClickMap (`clickAtWorld`), which projects a
//! world tile to a screen point (needs the engine's viewport-offset globals, valid only
//! with a display up). Headless, the player can NOT be moved this way — nor via
//! `sendRunToLocation` (packet 0x04), also rejected without a viewport. This module is
//! correct but only takes effect under a real viewport (e.g. Xvfb). Don't block on testing
//! it headless: `town.interact` works fine, since the server auto-walks on vendor interact.

const std = @import("std");
const oog = @import("../test/oog.zig");
const fns = @import("../engine/d2/functions.zig");
const me = @import("me.zig");
const unit = @import("unit.zig");

const Unit = unit.Unit;

// Clamp every step to ~STEP tiles toward the target. Sending a far/edge tile (at
// the limit of the client's unit view) makes the pather drift; short hops keep the
// path valid and let the target's position stabilize as we approach.
const STEP: i32 = 10;
const FRAMES_PER_STEP: u32 = 8; // let the server advance the player along the path
const MAX_STEPS: u32 = 60; // overall frame budget before giving up

/// Walk the player toward world tile (x,y), stopping within `stop_tiles`. Tries
/// `clickAtWorld` (ClickMap, viewport) each step AND `sendRunToLocation` as a
/// fallback. Returns true if it arrived within range. Frame-driven — call from a
/// fiber task; yields between steps.
pub fn moveTo(x: i32, y: i32, stop_tiles: i64) bool {
    const want = stop_tiles * stop_tiles;
    var i: u32 = 0;
    while (i < MAX_STEPS) : (i += 1) {
        const here = me.pos() orelse return false;
        const dx_total: i64 = here.x - x;
        const dy_total: i64 = here.y - y;
        if (dx_total * dx_total + dy_total * dy_total <= want) return true;

        // Clamp a one-step destination toward the target tile.
        var dx = x - here.x;
        var dy = y - here.y;
        if (dx > STEP) dx = STEP;
        if (dx < -STEP) dx = -STEP;
        if (dy > STEP) dy = STEP;
        if (dy < -STEP) dy = -STEP;
        const step_x = here.x + dx;
        const step_y = here.y + dy;

        // ClickMap move (needs a viewport) plus the run-to-location packet fallback.
        fns.clickAtWorld(0, step_x, step_y);
        fns.sendRunToLocation(@intCast(step_x), @intCast(step_y));
        oog.waitFrames(FRAMES_PER_STEP);
    }
    const here = me.pos() orelse return false;
    const dx: i64 = here.x - x;
    const dy: i64 = here.y - y;
    return dx * dx + dy * dy <= want;
}

/// Walk the player to a unit, stopping within `stop_tiles`. Re-reads the unit's
/// position each step (NPCs wander), so it tracks a moving target.
pub fn moveToUnit(target: Unit, stop_tiles: i64) bool {
    const want = stop_tiles * stop_tiles;
    var i: u32 = 0;
    while (i < MAX_STEPS) : (i += 1) {
        if (me.distanceToUnit(target) <= want) return true;
        const here = me.pos() orelse return false;
        const dst = target.pos();
        var dx = dst.x - here.x;
        var dy = dst.y - here.y;
        if (dx > STEP) dx = STEP;
        if (dx < -STEP) dx = -STEP;
        if (dy > STEP) dy = STEP;
        if (dy < -STEP) dy = -STEP;
        const step_x = here.x + dx;
        const step_y = here.y + dy;
        fns.clickAtWorld(0, step_x, step_y);
        fns.sendRunToLocation(@intCast(step_x), @intCast(step_y));
        oog.waitFrames(FRAMES_PER_STEP);
    }
    return me.distanceToUnit(target) <= want;
}
