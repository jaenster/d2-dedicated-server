//! Reap empty games promptly so their FOG pools don't leak.
//!
//! QSERVER_DispatchAndCleanup @0x0052fd90 destroys an empty game only after 300000 ms idle
//! (`CMP EDX, 0x493e0; JA <destroy>` at 0x0052fe57, imm32 at 0x0052fe59). FOG supports only
//! 8 pool managers (Fog/Memory.cpp: `7 < nManagers` -> RaiseException(0xe0000001)), so empty
//! games piling up for 5 minutes each exhausts them and kills the process. Shrinking the idle
//! window lets the engine's own destroy path collect empties almost immediately.
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

/// Overridable: this window throttles game THROUGHPUT, not the 8-manager ceiling — a finished
/// game keeps its manager until reap, so churning games faster than this exhausts managers.
/// Measured: at 5000ms, 3 games/~4s saturates the table. Trade-off: too short evicts a player
/// who drops mid-game before they can rejoin.
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
