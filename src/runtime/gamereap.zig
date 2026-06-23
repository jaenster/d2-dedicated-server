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

pub fn applyDefault() void {
    apply(default_idle_ms);
}
