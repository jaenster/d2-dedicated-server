//! Reap empty games promptly so their FOG pools don't leak.
//!
//! QSERVER_DispatchAndCleanup @0x0052fd90 destroys a game with zero clients only after it
//! has been idle for 300000 ms (5 minutes): `CMP EDX, 0x493e0; JA <destroy>` at 0x0052fe57,
//! so the imm32 (e0 93 04 00) lives at 0x0052fe59. On a dedicated server that holds no value
//! — empty games created and abandoned in quick succession pile up, and FOG only supports 8
//! pool managers (Fog/Memory.cpp: `7 < nManagers` -> RaiseException(0xe0000001)); the ~9th
//! game then can't allocate and the engine raises 0xe0000001 and dies. Shrinking the idle
//! window to a few seconds makes the engine's own (safe, locked) destroy path collect empty
//! games almost immediately, which keeps the pool-manager count bounded.
const patch = @import("patch.zig");
const log = @import("../log.zig");

const IDLE_MS_IMM_ADDR: usize = 0x0052fe59; // imm32 of `CMP EDX, 0x493e0` in QSERVER_DispatchAndCleanup
const default_idle_ms: u32 = 5000; // reap an empty game after 5s idle (was 300000)

/// Shrink the empty-game idle timeout. Safe to run any time before games are created.
pub fn apply(idle_ms: u32) void {
    if (patch.MemoryPatch(IDLE_MS_IMM_ADDR).data(idle_ms).commit()) {
        log.hex("gamereap: empty-game idle timeout patched to (ms) 0x", idle_ms);
    } else {
        log.print("gamereap: FAILED to patch empty-game idle timeout");
    }
}

/// Overridable, because this window is the real throttle on game THROUGHPUT, not the 8-manager
/// ceiling: a finished game keeps its pool manager for this long, so a server churning games
/// faster than the window runs out of managers while nothing is actually being played. Measured
/// at 5000 ms: 3 games created every ~4 s saturates the table and one client per round is turned
/// away. The trade is the other direction — too short and a player who drops for a moment loses
/// the game rather than getting back into it.
pub fn applyDefault() void {
    apply(default_idle_ms);
}

/// `ms` from --reap-ms / D2GS_REAP_MS, else the default. Clamped to something sane: zero would
/// destroy a game the instant its last player left (including mid-rejoin), and a huge value
/// reintroduces the manager exhaustion this patch exists to avoid.
pub fn applyConfigured(ms: u32) void {
    const clamped = @min(@max(ms, 250), 300_000);
    apply(clamped);
}
