//! How long an empty game stays open.
//!
//! QSERVER_DispatchAndCleanup @0x0052fd90 destroys an empty game only after 300000 ms idle
//! (`CMP EDX, 0x493e0; JA <destroy>` at 0x0052fe57, imm32 at 0x0052fe59): five minutes, during
//! which the same players can rejoin it as they left it. That is kept, because a game closing
//! seconds after its last player left sends a rejoin to a game that is gone or being destroyed.
//!
//! The same check also destroys an empty game at once while its frame counter is between 1500 and
//! 7500 (`CMP EAX, 0x5dc; JLE keep; CMP EAX, 0x1d4c; JGE keep` at 0x0052fe65), so a game one to
//! five minutes old closed the moment its last player left. That rule is jumped over: the idle
//! window is the only way an empty game closes.
//!
//! A game holds one of the engine's few Fog pool managers until it is destroyed, and a process
//! that runs out of them dies (Fog/Memory.cpp: `7 < nManagers` -> RaiseException(0xe0000001)).
//! So the window shrinks while the server has no spare slot (see gs_reap) and is restored after.
const patch = @import("patch.zig");
const log = @import("../log.zig");
const gs_reap = @import("gs_reap");

const IDLE_MS_IMM_ADDR: usize = 0x0052fe59; // imm32 of `CMP EDX, 0x493e0` in QSERVER_DispatchAndCleanup
const YOUNG_GAME_JLE_ADDR: usize = 0x0052fe6a; // `JLE keep` after `CMP EAX, 0x5dc` (game frame)

var keep_ms: u32 = gs_reap.retail_ms;
var current_ms: u32 = gs_reap.retail_ms; // what the engine runs with now
var young_patched = false;

fn write(ms: u32) void {
    if (patch.MemoryPatch(IDLE_MS_IMM_ADDR).data(ms).commit()) {
        current_ms = ms;
    } else {
        log.print("gamereap: FAILED to patch empty-game idle timeout");
    }
}

/// Drop retail's young-game rule, once at startup.
fn keepYoungGames() void {
    if (patch.MemoryPatch(YOUNG_GAME_JLE_ADDR).expect(&gs_reap.young_game_retail).bytes(&gs_reap.young_game_skip).commit()) {
        log.print("gamereap: empty games of any age wait for the idle window");
    } else {
        log.print("gamereap: FAILED to patch the young-game rule");
    }
}

/// Set the idle time an empty game is kept while there is room, in ms.
pub fn apply(idle_ms: u32) void {
    if (!young_patched) {
        young_patched = true;
        keepYoungGames();
    }
    keep_ms = idle_ms;
    write(idle_ms);
    log.hex("gamereap: empty-game idle timeout (ms) 0x", idle_ms);
}

/// Retail's five minutes.
pub fn applyDefault() void {
    apply(gs_reap.retail_ms);
}

/// `ms` from --reap-ms / D2GS_REAP_MS. Clamped: zero would destroy a game the instant its last
/// player left, including one mid-rejoin, and the engine's own value is the longest worth having.
pub fn applyConfigured(ms: u32) void {
    apply(@min(@max(ms, 250), gs_reap.retail_ms));
}

/// Follow the server's load: call from the engine's tick thread, which also runs the reap check.
/// Cheap and idempotent; writes the engine only when the window changes.
pub fn tune(live: u32, max: u32) void {
    const want = gs_reap.window(live, max, keep_ms);
    if (want != current_ms) {
        write(want);
        log.hex("gamereap: empty-game idle timeout now (ms) 0x", want);
    }
}
