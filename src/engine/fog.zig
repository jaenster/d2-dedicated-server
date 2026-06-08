//! D2's own FOG memory pools, wrapped as a `std.mem.Allocator`.
//!
//! The point of this module is per-game lifetime: each D2 game has its own FOG
//! pool, so allocating a feature's state from *that game's* pool binds the state
//! to the game — when the engine tears the game's pool down, the memory is freed
//! and any `registerCleanup` callback fires. That's how a feature "hangs data on
//! the game" without tracking lifetimes by hand.
//!
//! Ported from aether's fog_allocator.zig (was ~Zig 0.15) to this repo's 0.16:
//! x86_* callconvs and the current `Allocator.VTable` shape (Alignment + remap).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const patch = @import("../runtime/patch.zig");
const trampoline = @import("../runtime/trampoline.zig");

const DWORD = u32;
const BYTE = u8;

/// D2's pool-manager handle (defined in engine/d2types.zig, re-exported here for
/// the existing call sites). Opaque: we only pass the pointer to the pool fns.
pub const D2PoolManagerStrc = @import("d2types.zig").D2PoolManagerStrc;

const ThiscallConv = std.builtin.CallingConvention{ .x86_thiscall = .{} };
const StdcallConv = std.builtin.CallingConvention{ .x86_stdcall = .{} };
const FastcallConv = std.builtin.CallingConvention{ .x86_fastcall = .{} };

// FOG pool function addresses (D2 1.14d, image base 0x00400000, no ASLR).
const ADDR_INIT_POOL_SYSTEM: usize = 0x00409DD0; // stdcall (D2PoolManagerStrc**, char*, i32)
const ADDR_POOL_ALLOC: usize = 0x0040A080; // thiscall (this, size, char*, i32) -> void*
const ADDR_POOL_FREE: usize = 0x00409AB0; // thiscall (this, void**, char*, i32)
const ADDR_POOL_REALLOC: usize = 0x0040A1F0; // fastcall (this, void*, size, char*, i32) -> void*
const ADDR_FREE_MEMORY_POOL: usize = 0x00409C80; // thiscall — the teardown hook target

const PoolAllocFn = *const fn (*D2PoolManagerStrc, usize, [*:0]const u8, i32) callconv(ThiscallConv) ?[*]BYTE;
const PoolFreeFn = *const fn (*D2PoolManagerStrc, *?[*]BYTE, [*:0]const u8, i32) callconv(ThiscallConv) void;
const PoolReallocFn = *const fn (*D2PoolManagerStrc, ?[*]BYTE, usize, [*:0]const u8, i32) callconv(FastcallConv) ?[*]BYTE;

pub const pool_alloc: PoolAllocFn = @ptrFromInt(ADDR_POOL_ALLOC);
pub const pool_free: PoolFreeFn = @ptrFromInt(ADDR_POOL_FREE);
pub const pool_realloc: PoolReallocFn = @ptrFromInt(ADDR_POOL_REALLOC);

const InitPoolSystemFn = *const fn (**D2PoolManagerStrc, [*:0]const u8, i32) callconv(StdcallConv) void;
const init_pool_system: InitPoolSystemFn = @ptrFromInt(ADDR_INIT_POOL_SYSTEM);

const FILE_TAG: [*:0]const u8 = "d2gs";

var d2gs_pool: ?*D2PoolManagerStrc = null;

/// Create our own FOG memory pool (DLL-lifetime). Call after FOG is initialised
/// (DLL attach is fine). Used for feature state that is NOT tied to a game.
pub fn initPool() ?*D2PoolManagerStrc {
    if (d2gs_pool != null) return d2gs_pool;
    var pool_ptr: *D2PoolManagerStrc = undefined;
    init_pool_system(&pool_ptr, FILE_TAG, 0);
    d2gs_pool = pool_ptr;
    return d2gs_pool;
}

pub fn getPool() ?*D2PoolManagerStrc {
    return d2gs_pool;
}

// ── pool teardown notifications ──────────────────────────────────────────────

const CleanupFn = *const fn (?*anyopaque) void;

const CleanupNode = struct {
    callback: CleanupFn,
    ctx: ?*anyopaque,
    next: ?*CleanupNode,
};

const FogPoolMeta = struct {
    pool: *D2PoolManagerStrc,
    cleanup_list: ?*CleanupNode,
};

// Registry: pool ptr -> FogPoolMeta ptr (max 8 active pools).
const MAX_POOLS = 8;
const RegistryEntry = struct {
    pool: *D2PoolManagerStrc,
    meta: *FogPoolMeta,
};
var pool_registry: [MAX_POOLS]?RegistryEntry = .{null} ** MAX_POOLS;

fn findRegistryEntry(pool: *D2PoolManagerStrc) ?*RegistryEntry {
    for (&pool_registry) |*entry| {
        if (entry.*) |*e| {
            if (e.pool == pool) return e;
        }
    }
    return null;
}

fn lazyInitMeta(pool: *D2PoolManagerStrc) ?*FogPoolMeta {
    if (findRegistryEntry(pool)) |e| return e.meta;

    // Allocate the FogPoolMeta from the pool itself, so it dies with the pool.
    const raw = pool_alloc(pool, @sizeOf(FogPoolMeta), FILE_TAG, 0) orelse return null;
    const meta: *FogPoolMeta = @ptrCast(@alignCast(raw));
    meta.* = .{ .pool = pool, .cleanup_list = null };

    for (&pool_registry) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .pool = pool, .meta = meta };
            return meta;
        }
    }

    // Registry full — free and fail.
    var ptr_to_raw: ?[*]BYTE = raw;
    pool_free(pool, &ptr_to_raw, FILE_TAG, 0);
    return null;
}

/// Register a callback that fires when `pool` is destroyed (e.g. the game ends).
pub fn registerCleanup(pool: *D2PoolManagerStrc, callback: CleanupFn, ctx: ?*anyopaque) bool {
    const meta = lazyInitMeta(pool) orelse return false;

    const raw = pool_alloc(pool, @sizeOf(CleanupNode), FILE_TAG, 0) orelse return false;
    const node: *CleanupNode = @ptrCast(@alignCast(raw));
    node.* = .{ .callback = callback, .ctx = ctx, .next = meta.cleanup_list };
    meta.cleanup_list = node;
    return true;
}

// ── FreeMemoryPool hook ──────────────────────────────────────────────────────
// Intercept FreeMemoryPool to run cleanup callbacks before the pool is destroyed.

var free_pool_trampoline: ?trampoline.Trampoline = null;
const FreePoolFn = *const fn (*D2PoolManagerStrc) callconv(ThiscallConv) void;
var original_free_pool: ?FreePoolFn = null;

fn hookFreeMemoryPool(this: *D2PoolManagerStrc) callconv(ThiscallConv) void {
    for (&pool_registry) |*slot| {
        if (slot.*) |entry| {
            if (entry.pool == this) {
                var node = entry.meta.cleanup_list;
                while (node) |n| {
                    n.callback(n.ctx);
                    node = n.next;
                }
                slot.* = null;
                break;
            }
        }
    }

    // Call the original — it nukes everything in the pool, including our metadata.
    if (original_free_pool) |f| f(this);
}

pub fn installFreePoolHook() void {
    if (free_pool_trampoline != null) return;
    if (trampoline.build(ADDR_FREE_MEMORY_POOL, 5)) |tramp| {
        free_pool_trampoline = tramp;
        original_free_pool = @ptrCast(@alignCast(tramp.buffer));
        _ = patch.MemoryPatch(ADDR_FREE_MEMORY_POOL).jump(@intFromPtr(&hookFreeMemoryPool)).commit();
    }
}

// ── std.mem.Allocator interface ──────────────────────────────────────────────

fn fogAlloc(pool: *D2PoolManagerStrc, n: usize, alignment: usize) ?[*]u8 {
    // FOG pools use power-of-2 bucket sizes; alignment <= word size is natural.
    if (alignment <= @sizeOf(usize)) {
        return pool_alloc(pool, n, FILE_TAG, 0);
    }

    // Over-allocate `n + alignment` and store a 1-byte offset header just before
    // the aligned pointer so fogFree can recover the raw pointer.
    const total = n + alignment;
    const raw = pool_alloc(pool, total, FILE_TAG, 0) orelse return null;
    const raw_addr = @intFromPtr(raw);
    const aligned_addr = std.mem.alignForward(usize, raw_addr + 1, alignment);
    const offset: u8 = @intCast(aligned_addr - raw_addr);
    const header: *u8 = @ptrFromInt(aligned_addr - 1);
    header.* = offset;
    return @ptrFromInt(aligned_addr);
}

fn fogFree(pool: *D2PoolManagerStrc, ptr: [*]u8, alignment: usize) void {
    if (alignment <= @sizeOf(usize)) {
        var raw_ptr: ?[*]BYTE = ptr;
        pool_free(pool, &raw_ptr, FILE_TAG, 0);
        return;
    }
    const aligned_addr = @intFromPtr(ptr);
    const header: *const u8 = @ptrFromInt(aligned_addr - 1);
    const raw_addr = aligned_addr - @as(usize, header.*);
    var raw_ptr: ?[*]BYTE = @ptrFromInt(raw_addr);
    pool_free(pool, &raw_ptr, FILE_TAG, 0);
}

fn fogAllocFn(ctx: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const pool: *D2PoolManagerStrc = @ptrCast(@alignCast(ctx));
    return fogAlloc(pool, n, alignment.toByteUnits());
}

fn fogResizeFn(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    return false; // FOG pools don't support in-place resize.
}

fn fogRemapFn(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    return null; // No in-place remap — caller falls back to alloc+copy+free.
}

fn fogFreeFn(ctx: *anyopaque, buf: []u8, alignment: Alignment, _: usize) void {
    const pool: *D2PoolManagerStrc = @ptrCast(@alignCast(ctx));
    fogFree(pool, buf.ptr, alignment.toByteUnits());
}

const fog_vtable = Allocator.VTable{
    .alloc = fogAllocFn,
    .resize = fogResizeFn,
    .remap = fogRemapFn,
    .free = fogFreeFn,
};

/// A `std.mem.Allocator` backed by a specific FOG pool. Pass a game's pool to get
/// an allocator whose allocations die with that game.
pub fn forPool(pool: *D2PoolManagerStrc) Allocator {
    return .{ .ptr = @ptrCast(pool), .vtable = &fog_vtable };
}

// ── bootstrap allocator ──────────────────────────────────────────────────────
// Static 64KB bump for DLL_PROCESS_ATTACH, before FOG pools are available.

var bootstrap_buf: [64 * 1024]u8 align(16) = undefined;
var bootstrap_offset: usize = 0;

fn bootstrapAllocFn(_: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const a = alignment.toByteUnits();
    const aligned = std.mem.alignForward(usize, bootstrap_offset, a);
    if (aligned + n > bootstrap_buf.len) return null;
    bootstrap_offset = aligned + n;
    return @ptrCast(&bootstrap_buf[aligned]);
}

fn bootstrapResizeFn(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    return false;
}

fn bootstrapRemapFn(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn bootstrapFreeFn(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {
    // Bump allocator doesn't free.
}

const bootstrap_vtable = Allocator.VTable{
    .alloc = bootstrapAllocFn,
    .resize = bootstrapResizeFn,
    .remap = bootstrapRemapFn,
    .free = bootstrapFreeFn,
};

/// Static bump allocator for use before FOG pools are available.
pub fn bootstrapAllocator() Allocator {
    return .{ .ptr = undefined, .vtable = &bootstrap_vtable };
}

comptime {
    // Keep the whole API analyzed even before every call site is wired (the
    // per-game pool dispatch lands once the D2GameStrc pool offset is RE'd).
    _ = &initPool;
    _ = &getPool;
    _ = &registerCleanup;
    _ = &installFreePoolHook;
    _ = &bootstrapAllocator;
    _ = &pool_realloc;
}
