//! What the GS process is actually holding, and which boot step took it.
//!
//! The engine's own pool census (poolstat.zig) accounts for a few MB; the rest of an ~83 MB
//! idle GS is data tables, string tables, MPQ handles and the image itself. "Strip things out
//! to save memory" needs to know WHICH step spent it before anything is cut, so this samples
//! the working set around each bootstrap phase and reports the delta per phase.
//!
//! Note what this can and cannot buy: games are capped by the count of Fog pool managers
//! (eight, one per game — see poolstat.zig), not by bytes, so trimming the baseline never
//! yields an eighth game on one process. It yields a smaller pod, i.e. more GS processes per
//! node, which is where the fleet actually scales.

const std = @import("std");
const log = @import("../log.zig");

const DWORD = u32;
const SIZE_T = usize;

// PROCESS_MEMORY_COUNTERS (psapi). cb must be set to the struct size before the call.
const ProcessMemoryCounters = extern struct {
    cb: DWORD = @sizeOf(ProcessMemoryCounters),
    PageFaultCount: DWORD = 0,
    PeakWorkingSetSize: SIZE_T = 0,
    WorkingSetSize: SIZE_T = 0,
    QuotaPeakPagedPoolUsage: SIZE_T = 0,
    QuotaPagedPoolUsage: SIZE_T = 0,
    QuotaPeakNonPagedPoolUsage: SIZE_T = 0,
    QuotaNonPagedPoolUsage: SIZE_T = 0,
    PagefileUsage: SIZE_T = 0,
    PeakPagefileUsage: SIZE_T = 0,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "psapi" fn GetProcessMemoryInfo(
    process: ?*anyopaque,
    counters: *ProcessMemoryCounters,
    cb: DWORD,
) callconv(.winapi) i32;

/// Resident bytes right now, or 0 if the query failed (wine's psapi is present, but a failed
/// probe must read as "unknown" rather than as "free", or a phase would look weightless).
pub fn workingSet() usize {
    var c = ProcessMemoryCounters{};
    if (GetProcessMemoryInfo(GetCurrentProcess(), &c, @sizeOf(ProcessMemoryCounters)) == 0) return 0;
    return c.WorkingSetSize;
}

/// Working set at DLL attach — wine plus the loaded image, before the engine initialises
/// anything. Captured rather than logged, because at attach time the log is not wired up yet.
/// Expensive diagnostics (heap walking, region walking, tick timing) are OFF unless --memdiag
/// asks for them. heapCensus takes every heap's lock and regionCensus walks the whole address
/// space; neither belongs in the path of a server that is just hosting games.
pub var diag_enabled: bool = false;

pub var at_attach: usize = 0;

// PROCESS_HEAP_ENTRY (32-bit): lpData@0, cbData@4, cbOverhead@8, iRegionIndex@9, wFlags@10,
// then a 16-byte union. 28 bytes total.
const HEAP_ENTRY_SIZE = 28;
const PROCESS_HEAP_ENTRY_BUSY: u16 = 0x0004;

extern "kernel32" fn GetProcessHeaps(count: u32, heaps: [*]?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn HeapWalk(heap: ?*anyopaque, entry: [*]u8) callconv(.winapi) i32;
extern "kernel32" fn HeapLock(heap: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn HeapUnlock(heap: ?*anyopaque) callconv(.winapi) i32;

/// Sum the BUSY (allocated) bytes across every heap in the process.
///
/// RSS cannot tell a leak from allocator slack, and the engine's pool census only covers memory
/// that went through Fog. Anything malloc'd directly — by the engine's CRT or by wine on our
/// behalf — is invisible to both. This walks the actual heaps, so "idle RSS crept 2 KB per game"
/// can be answered with "and here is how much of it is live allocations".
///
/// Walking is O(number of blocks) and takes the heap lock, so call it at IDLE, never per tick.
pub fn heapBusyBytes(out_heaps: *u32, out_blocks: *u32) usize {
    var heaps: [32]?*anyopaque = undefined;
    const n = GetProcessHeaps(heaps.len, &heaps);
    out_heaps.* = n;
    var busy: usize = 0;
    var blocks: u32 = 0;
    var h: usize = 0;
    while (h < n and h < heaps.len) : (h += 1) {
        const heap = heaps[h];
        if (HeapLock(heap) == 0) continue;
        defer _ = HeapUnlock(heap);
        var entry: [HEAP_ENTRY_SIZE]u8 = [_]u8{0} ** HEAP_ENTRY_SIZE;
        // A corrupt or enormous heap must not park the server here; the cap is generous but hard.
        var guard: u32 = 0;
        while (HeapWalk(heap, &entry) != 0 and guard < 2_000_000) : (guard += 1) {
            const flags = @as(*const u16, @ptrCast(@alignCast(entry[10..12]))).*;
            if ((flags & PROCESS_HEAP_ENTRY_BUSY) != 0) {
                busy += @as(*const u32, @ptrCast(@alignCast(entry[4..8]))).*;
                blocks += 1;
            }
        }
    }
    out_blocks.* = blocks;
    return busy;
}

// MEMORY_BASIC_INFORMATION (32-bit) — 28 bytes.
const MBI = extern struct {
    BaseAddress: usize,
    AllocationBase: usize,
    AllocationProtect: u32,
    RegionSize: usize,
    State: u32,
    Protect: u32,
    Type: u32,
};
extern "kernel32" fn VirtualQuery(addr: usize, mbi: *MBI, len: usize) callconv(.winapi) usize;

const MEM_COMMIT: u32 = 0x1000;
const MEM_PRIVATE: u32 = 0x20000;
const MEM_MAPPED: u32 = 0x40000;
const MEM_IMAGE: u32 = 0x100_0000;

/// Split committed address space by TYPE. This is what says whether growth is ours or wine's:
/// PRIVATE is this process's own commit (heap, thread stacks, VirtualAlloc), MAPPED is shared /
/// file-backed memory — under wine that includes the wineserver mappings behind Win32 objects,
/// which a native Windows build would account for entirely differently. IMAGE is loaded modules
/// and should never move once boot is done.
pub fn regionCensus(tag: []const u8) void {
    var addr: usize = 0;
    var private: usize = 0;
    var mapped: usize = 0;
    var image: usize = 0;
    var mbi: MBI = undefined;
    // Bounded: a wedged walk must not hang the tick thread that called us.
    var guard: u32 = 0;
    while (addr < 0x7fff_0000 and guard < 200_000) : (guard += 1) {
        if (VirtualQuery(addr, &mbi, @sizeOf(MBI)) == 0) break;
        if (mbi.RegionSize == 0) break;
        if ((mbi.State & MEM_COMMIT) != 0) {
            if ((mbi.Type & MEM_IMAGE) != 0) {
                image += mbi.RegionSize;
            } else if ((mbi.Type & MEM_MAPPED) != 0) {
                mapped += mbi.RegionSize;
            } else if ((mbi.Type & MEM_PRIVATE) != 0) {
                private += mbi.RegionSize;
            }
        }
        addr = mbi.BaseAddress + mbi.RegionSize;
    }
    log.hex3(tag, private / 1024, mapped / 1024, image / 1024); // KB: private / mapped / image
}

extern "user32" fn GetGuiResources(process: ?*anyopaque, flags: u32) callconv(.winapi) u32;
const GR_GDIOBJECTS: u32 = 0;
const GR_USEROBJECTS: u32 = 1;

/// GDI and USER handle counts for this process.
///
/// These live in the window manager, not in any heap — so a leaked window, DC, brush or bitmap is
/// invisible to both the pool census and the heap walk, and would show up only as resident bytes
/// with no owner. A headless GS still creates a hidden window, so "something UI-shaped is
/// allocated per game outside the FOG arena" is a real hypothesis, and this is what tests it: if
/// these climb per game, that is the leak; if they are flat, the UI is exonerated.
pub fn guiCensus(tag: []const u8) void {
    const me = GetCurrentProcess();
    log.hex2(tag, GetGuiResources(me, GR_GDIOBJECTS), GetGuiResources(me, GR_USEROBJECTS));
}

// The client's graphics caches — the thing a headless server must never be paying for.
// CLIENT_AdjustMemoryBudget @0x457300 reserves 24-64 MB of CEL cache, a 6 MB sprite LRU, a 2 MB
// COF system and a sound budget; GFX_InitCelDataCache @0x5ffd40 is what actually builds them.
// Both write these two statics, and the sprite-cache pool manager at 0x88cadc is NOT one of the
// eight in pGlobalPoolSystem, so the pool census cannot see it. Reading them is the only way to
// be sure rather than inferring from a call graph.
const GFX_SPRITE_CACHE: usize = 0x0089_db60; // D2GfxMemoryStrc — fpFunction at +0, set by GFX_AllocSpriteCache
const GFX_CACHE_POOL: usize = 0x0088_cadc; // D2PoolManagerStrc used by the CEL cache
const POOL_NPOOLS: usize = 0x01c;
const POOL_MEMORY: usize = 0x17a8;
const POOL_NAME: usize = 0x17ac;

/// Say whether the client graphics caches were ever built. All zeros = never initialised.
pub fn graphicsCacheCensus() void {
    const fp = @as(*const u32, @ptrFromInt(GFX_SPRITE_CACHE)).*;
    const npools = @as(*const u32, @ptrFromInt(GFX_CACHE_POOL + POOL_NPOOLS)).*;
    const bytes = @as(*const u32, @ptrFromInt(GFX_CACHE_POOL + POOL_MEMORY)).*;
    log.hex3("gfx cache: spriteCache fp / celPool nPools / celPool bytes:", fp, npools, bytes);
    log.cstr("gfx cache:   celPool name=", GFX_CACHE_POOL + POOL_NAME);
    if (fp == 0 and npools == 0 and bytes == 0) {
        log.print("gfx cache: NOT initialised — the 24-64 MB CEL cache, sprite LRU and COF system were never built");
    } else {
        log.print("gfx cache: INITIALISED — this server is paying for client graphics memory");
    }
}

/// One line: how many heaps, how many live blocks, how many bytes they hold.
pub fn heapCensus(tag: []const u8) void {
    var nheaps: u32 = 0;
    var nblocks: u32 = 0;
    const busy = heapBusyBytes(&nheaps, &nblocks);
    log.hex3(tag, nheaps, nblocks, busy);
}

var last: usize = 0;

/// Record the attach-time working set. Safe to call before logging exists.
pub fn markAttach() void {
    at_attach = workingSet();
    last = at_attach;
}

/// Report the working set and what it grew by since the previous phase. `name` should say what
/// just FINISHED, so the delta reads as the price of that step.
pub fn phase(name: []const u8) void {
    const now = workingSet();
    if (now == 0) return;
    const grew = if (now > last) now - last else 0;
    last = now;
    log.hex2(name, now / 1024, grew / 1024); // KB resident, KB added by this step
}
