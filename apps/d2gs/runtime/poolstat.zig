//! Census of the engine's memory-pool managers — the thing that actually caps games per GS.
//!
//! Fog::Memory::InitializePoolSystem @0x409dd0 hands out ONE pool manager per caller, and there are
//! exactly EIGHT: `if (7 < nManagers) { OutOfMemoryHandler(); RaiseException(0xe0000001); }`. Fixed
//! array in a static struct (pGlobalPoolSystem, 0xbea4 bytes = 8*0x17cc + header/tail), so eight is
//! a wall in the data layout, not a tunable — raising the compare alone writes manager nine past the
//! end. A game returns its manager on destroy (nManagerIndex free list), so the cap is on CONCURRENT
//! games; hitting it kills the process with 0xe0000001. Verified vs 1.14d Game.exe: pManagers[0]
//! @0x74f104 + 8*0x17cc = 0x75af64, exactly nManagers's address.

const log = @import("../log.zig");
const memstat = @import("memstat.zig");
const poolgrow = @import("poolgrow.zig");

const MANAGERS: usize = 0x0074_f104; // D2PoolManagerStrc[8]
const MANAGER_STRIDE: usize = 0x17cc; // sizeof(D2PoolManagerStrc) = 6092
const MAX_MANAGERS: usize = 8;
const N_MANAGERS: usize = 0x0075_af64; // int nManagers — how many have ever been handed out
const N_FREE_INDEX: usize = 0x0075_af88; // int nFreeManagerIndex — depth of the free list

const M_MEMORY: usize = 0x17a8; // DWORD dwMemory — bytes this manager currently holds
const M_NAME: usize = 0x17ac; // char szName[32] — who asked for it

fn u32At(addr: usize) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}

/// Managers currently in use: handed out, minus the ones returned to the free list.
pub fn inUse() u32 {
    const handed = u32At(N_MANAGERS);
    const freed = u32At(N_FREE_INDEX);
    return if (handed > freed) handed - freed else 0;
}

/// Manager state at DLL attach, recorded before the engine has run any of our code. Relocating
/// the manager array is only safe while the table is still EMPTY: a live manager cannot be moved,
/// because every pGame->pMemoryPool points into it and its CRITICAL_SECTIONs are self-referential.
pub var at_attach_in_use: u32 = 0;
pub var at_attach_handed: u32 = 0;

/// Record the table state at attach. Safe before logging exists.
pub fn markAttach() void {
    at_attach_handed = u32At(N_MANAGERS);
    at_attach_in_use = inUse();
}

/// Managers still available. Zero means the next game to start raises 0xe0000001 and takes the whole
/// process down with it, so check this BEFORE creating a game.
///
/// Includes poolgrow's spare managers — without them the create-game guard refuses at seven while
/// the allocator can serve more. poolgrow reports zero until both its call-site detours are live, so
/// a failed install leaves this reading unchanged.
pub fn freeManagers() u32 {
    const used = inUse();
    const engine_free: u32 = if (used < MAX_MANAGERS) @intCast(MAX_MANAGERS - used) else 0;
    return engine_free + poolgrow.freeSlots();
}

/// Print every live manager with the memory it is holding. Cheap (eight reads) but noisy, so
/// callers decide when it is worth saying — `report()` only speaks when the picture changes.
pub fn dump() void {
    const handed = u32At(N_MANAGERS);
    const freed = u32At(N_FREE_INDEX);
    log.hex3("pools: in-use / handed-out / free-list:", inUse(), handed, freed);
    var total: usize = 0;
    var i: usize = 0;
    while (i < handed and i < MAX_MANAGERS) : (i += 1) {
        const m = MANAGERS + i * MANAGER_STRIDE;
        const bytes = u32At(m + M_MEMORY);
        total += bytes;
        // Name first so the line reads as "who", then "how much" — an unnamed manager prints
        // empty, which is itself the answer to which allocation forgot to name itself.
        log.cstr("pools:   holder=", m + M_NAME);
        log.hex("pools:     bytes=0x", bytes);
    }
    log.hex("pools: total bytes held=0x", total);
    // The check in InitializePoolSystem is `7 < nManagers` BEFORE the increment, so the eighth
    // manager is still handed out and the NINTH request is the one that raises. One of the eight
    // is the Global Pool System, which never goes back — hence seven concurrent games, measured.
    const used = inUse();
    const spare = poolgrow.freeSlots();
    if (used >= MAX_MANAGERS) {
        if (spare > 0) {
            // Not the wall it used to be: the engine's eight are gone, but poolgrow serves the
            // next create out of its own array.
            log.hex2("pools: engine slots gone — poolgrow serving, extra in-use / free:", poolgrow.inUse(), spare);
        } else {
            log.print("pools: manager table FULL — the next game to start kills the process (0xe0000001)");
        }
    } else if (used == MAX_MANAGERS - 1 and spare == 0) {
        log.print("pools: one manager left — room for exactly one more game");
    }
}

// Only worth a log line when it moves: the count is what predicts the wall, and printing it
// every tick would bury the moment it changes.
var last_in_use: u32 = 0xffff_ffff;

// A game's pool is NOT preallocated — the manager is a fixed 0x17cc of bookkeeping, but its
// memory regions are VirtualAlloc'd as the game touches them and freed when it dies. So a game's
// cost GROWS while it is played, and a census taken only when the count changes measures a game
// that has barely started. Sample on a timer too, or capacity planning is built on a floor.
var ticks_since_census: u32 = 0;
const CENSUS_EVERY_TICKS: u32 = 500;

/// Call freely (once per tick is fine): prints when the manager count changes, and periodically
/// so a long-lived game's growth is visible rather than assumed flat.
pub fn report() void {
    const now = inUse();
    ticks_since_census +%= 1;
    if (now != last_in_use) {
        const went_idle = now == 1 and last_in_use > 1;
        last_in_use = now;
        ticks_since_census = 0;
        dump();
        // The moment the last game is gone is the only honest time to weigh the heap: anything
        // still held now is held across games. Walking heaps takes their locks, so it happens
        // here and nowhere near the tick path.
        // Only with --memdiag: walking heaps and the address space is far too heavy to do
        // every time a game ends.
        if (went_idle and memstat.diag_enabled) {
            memstat.heapCensus("heap at idle: heaps / blocks / busy bytes:");
            memstat.regionCensus("commit at idle (KB): private / mapped / image:");
            memstat.guiCensus("gui at idle: gdi objects / user objects:");
        }
        return;
    }
    if (now > 1 and ticks_since_census >= CENSUS_EVERY_TICKS) {
        ticks_since_census = 0;
        // A line, not the whole census: the per-manager dump is worth it when the count moves,
        // but repeating it every few seconds for every live game just buries the log.
        log.hex2("pools: in use / free:", now, freeManagers());
    }
}
