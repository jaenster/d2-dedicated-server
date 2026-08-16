//! Lift the engine's eight-manager ceiling so a GS can host more than seven games.
//!
//! `Fog::Memory::InitializePoolSystem` @0x409dd0 hands one pool manager per game from a fixed
//! array of EIGHT in `pGlobalPoolSystem`; the ninth raises 0xe0000001 and kills the process. One
//! manager is permanently the Global Pool System, so the engine caps at seven games (measured).
//! Eight is a 1.14d CLIENT-build constant, not a design invariant.
//!
//! The array can't be relocated (already in use at DLL_PROCESS_ATTACH; pGame->pMemoryPool and the
//! null-manager fallback point into it), so all eight engine slots stay untouched and we step in
//! only once they're exhausted. Alloc/Free/ReAlloc need no patching.

const std = @import("std");

const patch = @import("patch.zig");
const log = @import("../log.zig");

extern "kernel32" fn InitializeCriticalSection(cs: usize) callconv(.winapi) void;
extern "kernel32" fn EnterCriticalSection(cs: usize) callconv(.winapi) void;
extern "kernel32" fn LeaveCriticalSection(cs: usize) callconv(.winapi) void;

const INIT_POOL_SYSTEM: usize = 0x0040_9dd0; // void __stdcall(D2PoolManagerStrc**, char*, int)
const FREE_MEMORY_POOL: usize = 0x0040_9c80; // void __cdecl(D2PoolManagerStrc*)

// We patch the CALL SITES, not the function entries: entry-detouring these two needs a trampoline,
// and a wrong handoff faults inside the very first game creation with no useful evidence (it did —
// we ended up executing our own DLL's PE header). Replacing a single 5-byte E8 leaves both originals
// callable at their real addresses. Only the GAME paths are redirected.
const CREATE_GAME_CALLSITE: usize = 0x0053_09ec; // CALL InitializePoolSystem in GAME_CreateBattleNetGame
const DESTROY_GAME_CALLSITE: usize = 0x0052_c8a3; // CALL FreeMemoryPool in GAME_DestroyGame

const N_MANAGERS: usize = 0x0075_af64; // int — managers handed out from the engine array
const N_FREE_INDEX: usize = 0x0075_af88; // int — depth of the engine's free list
const ENGINE_MAX: u32 = 8; // `if (7 < nManagers) raise` — eight slots, no more

// D2PoolManagerStrc (0x17cc bytes)
const STRIDE: usize = 0x17cc;
const M_SYNC: usize = 0x004; // CRITICAL_SECTION
const M_NPOOLS: usize = 0x01c; // size_t nPools
const M_POOLS: usize = 0x020; // D2PoolStrc[40]
const M_PBLOCKS: usize = 0x7a8; // D2PoolBlockEntryStrc* pBlocks
const M_OVERFLOW: usize = 0x7ac; // BYTE*[1023]
const M_OVERFLOW_BYTES: usize = 0xffc;
const M_NAME: usize = 0x17ac; // char szName[32]
const MAX_POOLS: usize = 0x28; // the engine halts above this

// D2PoolStrc (48 bytes)
const P_STRIDE: usize = 48;
const P_SYNC: usize = 0; // CRITICAL_SECTION
const P_BLOCKSIZE: usize = 24;
const P_NBLOCKS: usize = 28;
const P_NSIZE: usize = 32;

/// How many managers we add on top of the engine's eight. Each is 0x17cc (~6 KB) of bookkeeping
/// in our own .bss — the memory a game actually uses is VirtualAlloc'd on demand and freed on
/// destroy, so this array costs ~150 KB regardless of how many games run.
pub const EXTRA: u32 = 24;

var slots: [EXTRA * STRIDE]u8 align(16) = [_]u8{0} ** (EXTRA * STRIDE);
var free_list: [EXTRA]u32 = [_]u32{0} ** EXTRA;
var free_count: u32 = 0;
var next_slot: u32 = 0;
var handed_out: u32 = 0; // ours currently in use, for the census

// Our free list is touched from whichever thread creates or destroys a game; the engine guards
// its own with the pool-system critical section, and we cannot take that one from here without
// risking an ordering we have not proven, so we use our own.
var lock = std.atomic.Value(bool).init(false);

fn acquire() void {
    while (lock.swap(true, .acquire)) {}
}
fn release() void {
    lock.store(false, .release);
}

fn u32At(addr: usize) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}
fn setU32(addr: usize, v: u32) void {
    @as(*u32, @ptrFromInt(addr)).* = v;
}

fn base() usize {
    return @intFromPtr(&slots);
}

fn owns(p: usize) bool {
    const b = base();
    return p >= b and p < b + slots.len and (p - b) % STRIDE == 0;
}

/// Set only once both call sites are actually redirected. Until then we hand out nothing: a
/// create-game guard that counted our slots while the engine still owned the call site would
/// wave through the create that raises 0xe0000001.
var installed: bool = false;

/// Managers we can still hand out. poolstat adds this to the engine's own free count, so the
/// create-game guard sees the true capacity rather than refusing at seven.
pub fn freeSlots() u32 {
    if (!installed) return 0;
    acquire();
    defer release();
    return (EXTRA - next_slot) + free_count;
}

/// Ours currently in use (for the census).
pub fn inUse() u32 {
    return handed_out;
}

/// Port of InitializePoolSystem's manager setup, for a slot in our array. Allocates nothing —
/// the original only memsets, installs critical sections and fills the block-size table; the
/// actual memory arrives later through Alloc, which works on our manager unchanged.
fn initManager(m: usize, sz_name: usize, n_param: u32) void {
    @memset(@as([*]u8, @ptrFromInt(m))[0..STRIDE], 0);
    InitializeCriticalSection(m + M_SYNC);
    EnterCriticalSection(m + M_SYNC);
    defer LeaveCriticalSection(m + M_SYNC);

    if (sz_name != 0) {
        const src: [*:0]const u8 = @ptrFromInt(sz_name);
        const dst: [*]u8 = @ptrFromInt(m + M_NAME);
        var i: usize = 0;
        while (i < 0x1f and src[i] != 0) : (i += 1) dst[i] = src[i];
        dst[i] = 0;
        dst[0x1f] = 0; // the original forces the last byte, so a 32-char name stays terminated
    }

    // Pool count: one pool for anything up to 0x10 bytes, otherwise a pool per power of two
    // from 0x10 upwards — i.e. bitlength(nParam-1) - 4, plus one. Mirrors the original's
    // bit-scan loop.
    var pools: usize = 1;
    if (n_param >= 0x11) {
        const v = n_param - 1;
        const bitlen: usize = 32 - @clz(v);
        pools = (bitlen - 4) + 1;
    }
    if (pools > MAX_POOLS) pools = MAX_POOLS; // the engine HALTs here; clamping is kinder
    setU32(m + M_NPOOLS, @intCast(pools));
    setU32(m + M_PBLOCKS, 0);

    var i: usize = 0;
    while (i < pools) : (i += 1) {
        const p = m + M_POOLS + i * P_STRIDE;
        InitializeCriticalSection(p + P_SYNC);
        const block: u32 = if (i == 0) 0x10 else @as(u32, 1) << @intCast(i + 4);
        setU32(p + P_BLOCKSIZE, block);
        // Region sizing, faithfully: the original compares with 32-bit signed wraparound, so a
        // huge block size lands in the 0x80000 branch rather than looking small.
        const prod: i32 = @bitCast(block *% 0x100);
        var blocks: u32 = undefined;
        if (block < 0xf4241 and prod < 0x40000) {
            blocks = 0x100;
            if (prod < 0x10000) blocks = 0x10000 / block;
        } else {
            blocks = 0x80000 / block;
        }
        setU32(p + P_NBLOCKS, blocks);
        setU32(p + P_NSIZE, block *% blocks);
    }
    @memset(@as([*]u8, @ptrFromInt(m + M_OVERFLOW))[0..M_OVERFLOW_BYTES], 0);
}

// The originals, called at their real addresses — nothing about them is patched.
//
// InitializePoolSystem is __cdecl with FOUR args, verified against 1.14d Game.exe: the call site
// at 0x5309ec pushes 0x1000, 0x8000, ebx, eax and every return is a plain `ret`, so the CALLER
// cleans. A stdcall `ret $12` here unbalances the frame (0xc0000005, eip in stack region on first
// create). arg3 is what the body bit-scans (`bsr [ebp+0x10]`) to size the pool table — that's
// `n_param`; arg4 passes through untouched.
const initOriginal: *const fn (usize, usize, u32, u32) callconv(.c) void = @ptrFromInt(INIT_POOL_SYSTEM);
const freeOriginal: *const fn (usize) callconv(.c) void = @ptrFromInt(FREE_MEMORY_POOL);

/// Always returns 1: either we served the request or we ran the original ourselves.
fn tryInit(pp_manager: usize, sz_name: usize, n_param: u32, arg4: u32) callconv(.c) u32 {
    // The system-init call passes null and must stay with the original: it is what creates
    // pGlobalPoolSystem and manager zero, which everything else defaults to.
    if (pp_manager == 0) {
        initOriginal(pp_manager, sz_name, n_param, arg4);
        return 1;
    }
    // Let the engine use its own slots first — same order it always had, so nothing changes
    // until the eighth is gone. Its condition: a free-list entry, or room below the cap.
    if (u32At(N_FREE_INDEX) != 0 or u32At(N_MANAGERS) < ENGINE_MAX) {
        initOriginal(pp_manager, sz_name, n_param, arg4);
        return 1;
    }

    acquire();
    var slot: u32 = undefined;
    if (free_count > 0) {
        free_count -= 1;
        slot = free_list[free_count];
    } else if (next_slot < EXTRA) {
        slot = next_slot;
        next_slot += 1;
    } else {
        release();
        // Out of ours too. Fall through to the original, which raises 0xe0000001 exactly as it
        // did before — the create-game guard should have refused long before this.
        log.print("poolgrow: extra managers exhausted — falling through to the engine's raise");
        initOriginal(pp_manager, sz_name, n_param, arg4);
        return 1;
    }
    handed_out += 1;
    release();

    const m = base() + slot * STRIDE;
    initManager(m, sz_name, n_param);
    @as(*usize, @ptrFromInt(pp_manager)).* = m;
    return 1;
}

/// Always returns 1: ours are released here, anything else goes to the original.
fn tryFree(p_manager: usize) callconv(.c) u32 {
    if (!owns(p_manager)) {
        freeOriginal(p_manager);
        return 1;
    }

    // The original's teardown is correct for any manager. The ONE thing it gets wrong for us is the
    // last step: it computes (ptr - pManagers) / 0x17cc and pushes that index onto the engine's
    // 8-entry free list. For our pointer that index is nonsense and would eventually overrun the
    // list. So snapshot the counter, let it run, then put the counter back — the bogus entry lands
    // above the live region where nothing reads it.
    const saved = u32At(N_FREE_INDEX);
    freeOriginal(p_manager);
    setU32(N_FREE_INDEX, saved);

    acquire();
    const slot: u32 = @intCast((p_manager - base()) / STRIDE);
    if (free_count < EXTRA) {
        free_list[free_count] = slot;
        free_count += 1;
    }
    if (handed_out > 0) handed_out -= 1;
    release();
    return 1;
}

// Four args, and the original is __cdecl — so we re-push all four for our own cdecl handler,
// clean only OUR copies, and `ret` without touching the caller's, exactly as the original does.
// Each `push 16(%esp)` reads one slot further back because the previous push moved esp, so the
// four together replay arg4..arg1.
fn initShim() callconv(.naked) void {
    asm volatile (
        \\push 16(%%esp)
        \\push 16(%%esp)
        \\push 16(%%esp)
        \\push 16(%%esp)
        \\call %[f:P]
        \\add $16, %%esp
        \\ret
        :
        : [f] "X" (&tryInit),
    );
}

fn freeShim() callconv(.naked) void {
    asm volatile (
        \\push 4(%%esp)
        \\call %[f:P]
        \\add $4, %%esp
        \\ret
        :
        : [f] "X" (&tryFree),
    );
}

/// Install both detours. Must run before any game is created; the engine's own eight slots and
/// whatever already lives in them are left exactly as they are.
pub fn install() void {
    const a = patch.MemoryPatch(CREATE_GAME_CALLSITE).call(@intFromPtr(&initShim)).commit();
    const b = patch.MemoryPatch(DESTROY_GAME_CALLSITE).call(@intFromPtr(&freeShim)).commit();
    if (a and b) {
        installed = true;
        log.hex("poolgrow: game pools can exceed the engine's eight — extra managers: 0x", EXTRA);
    } else {
        // Leave `installed` false: freeSlots() then reports zero and the create-game guard falls
        // back to refusing at seven, which is survivable. Claiming capacity we cannot serve is not.
        log.print("poolgrow: FAILED to hook the game pool call sites — the 8-manager limit still applies");
    }
}
