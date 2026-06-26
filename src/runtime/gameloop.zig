//! Per-frame hooks into the game's main loops (ported from aether's game_hooks).
//! Patches the "sleep" call in the in-game loop and the out-of-game (menu) loop
//! to run our callback each frame instead — the foothold for driving the client
//! through menus into a game (via the async fiber tasks).

const patch = @import("patch.zig");
const async_ = @import("async.zig");
const feature = @import("../engine/feature.zig");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const ADDR_GAME_LOOP: usize = 0x00451C2A; // sleep call in game loop, CALL + 2 NOP
const ADDR_OOG_LOOP: usize = 0x004FA663; // sleep call in OOG loop, CALL + 18 NOP

// The two patches above overwrite the engine's own Sleep() calls that paced
// these loops (the game loop's `Sleep(10)` gate, the OOG loop's `Sleep(<=20)`),
// so without yielding here the loop spins flat-out and pegs a core. Restore the
// per-frame yield ourselves. The game's logic advances on an internal wall-clock
// timer, not on this sleep, so frame rate is unaffected.
const GAME_FRAME_SLEEP_MS: u32 = 10;
const OOG_FRAME_SLEEP_MS: u32 = 10;

/// Called every out-of-game (menu) frame.
pub var on_oog: ?*const fn () void = null;
/// Called every in-game frame.
pub var on_game: ?*const fn () void = null;

fn hookGameLoop() callconv(.c) void {
    async_.init(); // idempotent; runs on the game thread
    if (on_game) |cb| cb();
    feature.fanGameFrame(); // fan out to every enabled feature's gameFrame()
    Sleep(GAME_FRAME_SLEEP_MS); // yield: we clobbered the engine's own loop sleep
}

fn hookOogLoop() callconv(.c) void {
    async_.init();
    if (on_oog) |cb| cb();
    feature.fanOogFrame();
    Sleep(OOG_FRAME_SLEEP_MS); // yield: we clobbered the engine's own loop sleep
}

pub fn install() void {
    _ = patch.MemoryPatch(ADDR_GAME_LOOP).call(@intFromPtr(&hookGameLoop)).nops(2).commit();
    _ = patch.MemoryPatch(ADDR_OOG_LOOP).call(@intFromPtr(&hookOogLoop)).nops(18).commit();
}

// A headless dedicated server never enters a game locally, so the engine's WinMain
// sits in the out-of-game (main-menu) loop forever — and that loop's frame work pegs
// ~50% of a core on the cluster (verified: tid 1, the unparked WinMain, is the idle
// cost — NOT the server tick). It has no UI to drive, so just pace it down hard.
const SERVER_OOG_SLEEP_MS: u32 = 100; // ~10 Hz menu loop instead of ~50 Hz

fn serverOogPacer() callconv(.c) void {
    Sleep(SERVER_OOG_SLEEP_MS);
}

/// Replace the OOG loop's per-frame sleep with a long one for a headless GS. Same
/// patch site/shape as install()'s OOG hook, but a Sleep-only callback (no async/
/// feature fan-out — a dedicated server has no menu to drive). Idempotent-safe to
/// call once at GS boot.
pub fn installServerOogPacing() void {
    _ = patch.MemoryPatch(ADDR_OOG_LOOP).call(@intFromPtr(&serverOogPacer)).nops(18).commit();
}
