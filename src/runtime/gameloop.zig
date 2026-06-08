//! Per-frame hooks into the game's main loops (ported from aether's game_hooks).
//! Patches the "sleep" call in the in-game loop and the out-of-game (menu) loop
//! to run our callback each frame instead — the foothold for driving the client
//! through menus into a game (via the async fiber tasks).

const patch = @import("patch.zig");
const async_ = @import("async.zig");
const feature = @import("../engine/feature.zig");

const ADDR_GAME_LOOP: usize = 0x00451C2A; // sleep call in game loop, CALL + 2 NOP
const ADDR_OOG_LOOP: usize = 0x004FA663; // sleep call in OOG loop, CALL + 18 NOP

/// Called every out-of-game (menu) frame.
pub var on_oog: ?*const fn () void = null;
/// Called every in-game frame.
pub var on_game: ?*const fn () void = null;

fn hookGameLoop() callconv(.c) void {
    async_.init(); // idempotent; runs on the game thread
    if (on_game) |cb| cb();
    feature.fanGameFrame(); // fan out to every enabled feature's gameFrame()
}

fn hookOogLoop() callconv(.c) void {
    async_.init();
    if (on_oog) |cb| cb();
    feature.fanOogFrame();
}

pub fn install() void {
    _ = patch.MemoryPatch(ADDR_GAME_LOOP).call(@intFromPtr(&hookGameLoop)).nops(2).commit();
    _ = patch.MemoryPatch(ADDR_OOG_LOOP).call(@intFromPtr(&hookOogLoop)).nops(18).commit();
}
