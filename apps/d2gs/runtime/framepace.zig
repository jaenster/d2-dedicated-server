//! Sleep until the engine's next frame is actually due, instead of polling at a rate we invented.
//!
//! `QSERVER_TickAllGames` and `QSERVER_DispatchAndCleanup` both self-gate on an accumulator:
//! they return immediately unless `timeGetTime() - LastUpdateTick` has reached
//! `Frames_TimeBetweenFrames` (40 ms at 25 fps), then advance one period and carry the
//! remainder — polling faster just burns wakeups, it doesn't speed up the sim. Retail's own
//! loop slept a fixed 30 ms (`QSERVER_CooperativeThreadMain` @0x44cf20); we do better by
//! reading the accumulator and sleeping exactly to the next due frame — one wakeup per frame,
//! phase-locked, no drift.

const log = @import("../log.zig");

// Set by the engine; all three sit together in .data.
const LAST_UPDATE_TICK: usize = 0x0088_3d58; // DWORD — logical frame time, carries the remainder
const TIME_BETWEEN_FRAMES: usize = 0x0088_3d60; // DWORD — frame period, 40 ms at 25 fps

extern "winmm" fn timeGetTime() callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn u32At(addr: usize) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}

var announced = false;

/// Sleep until the engine's next frame falls due. `fallback_ms` covers the window before the
/// accumulator is running (period or LastUpdateTick still zero), where there is no frame to
/// aim at yet.
pub fn sleepToNextFrame(fallback_ms: u32) void {
    const period = u32At(TIME_BETWEEN_FRAMES);
    const last = u32At(LAST_UPDATE_TICK);
    if (period == 0 or last == 0) {
        Sleep(fallback_ms);
        return;
    }
    if (!announced) {
        announced = true;
        log.hex("framepace: locked to the engine's frame period (ms) 0x", period);
    }
    // The engine masks the clock to 31 bits before comparing, so match it or the arithmetic
    // disagrees with the accumulator once the tick count passes 0x7fffffff.
    const now = timeGetTime() & 0x7fff_ffff;
    const due = (last +% period) & 0x7fff_ffff;
    const wait: u32 = if (due > now) due - now else 0;
    // Floor of 1 ms so a frame that is already due yields rather than spinning; ceiling of one
    // period so a stalled accumulator can never park the loop indefinitely.
    Sleep(@min(@max(wait, 1), period));
}
