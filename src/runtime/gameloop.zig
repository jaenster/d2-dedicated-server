//! Per-frame hooks into the game's main loops (ported from aether's game_hooks).
//! Patches the "sleep" call in the in-game loop and the out-of-game (menu) loop
//! to run our callback each frame instead — the foothold for driving the client
//! through menus into a game (via the async fiber tasks).

const patch = @import("patch.zig");
const async_ = @import("async.zig");

const ADDR_GAME_LOOP: usize = 0x00451C2A; // sleep call in game loop, CALL + 2 NOP
const ADDR_OOG_LOOP: usize = 0x004FA663; // sleep call in OOG loop, CALL + 18 NOP

/// Called every out-of-game (menu) frame.
pub var on_oog: ?*const fn () void = null;
/// Called every in-game frame.
pub var on_game: ?*const fn () void = null;

fn hookGameLoop() callconv(.c) void {
    async_.init(); // idempotent; runs on the game thread
    if (on_game) |cb| cb();
}

fn hookOogLoop() callconv(.c) void {
    async_.init();
    if (on_oog) |cb| cb();
}

pub fn install() void {
    _ = patch.writeCall(ADDR_GAME_LOOP, @intFromPtr(&hookGameLoop));
    _ = patch.writeNops(ADDR_GAME_LOOP + 5, 2);
    _ = patch.writeCall(ADDR_OOG_LOOP, @intFromPtr(&hookOogLoop));
    _ = patch.writeNops(ADDR_OOG_LOOP + 5, 18);
}
