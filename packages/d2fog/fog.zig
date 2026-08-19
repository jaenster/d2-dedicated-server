//! Our own Fog.dll.
//!
//! D2Game and D2Common import exactly 53 Fog ordinals plus two data symbols, and none of them are
//! networking — `FOG_InitializeServer` is not in the set, so the QServer is the host's business and
//! this module is pure support: memory, files, data-table parsing, bit twiddling and asserts.
//! Replacing Fog rather than driving it removes the whole class of bring-up problem we hit with the
//! real one (an undocumented one-time init, a pool system, globals nothing tells you to publish).
//!
//! Every signature here comes from `docs/fog-abi-1.10f.md`, which was read out of the real 1.10f
//! binary. The conventions are load-bearing: the engine cleans the stack with `RET n`, so a wrong
//! `n` desynchronises D2Common at the call site rather than merely misbehaving.
//!
//! Build: `zig build d2fog` → Fog.dll (x86-windows). Drop it in beside the real D2Game/D2Common.

const std = @import("std");
const mpq = @import("libd2").formats.mpq;
const fogabi = @import("d2engine").fogabi;

extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: *anyopaque, buf: [*]const u8, n: u32, wrote: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn HeapAlloc(h: *anyopaque, flags: u32, n: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapFree(h: *anyopaque, flags: u32, p: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn HeapReAlloc(h: *anyopaque, flags: u32, p: ?*anyopaque, n: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessHeap() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
extern "kernel32" fn InitializeCriticalSection(cs: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn EnterCriticalSection(cs: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn SetLastError(err: u32) callconv(.winapi) void;
extern "kernel32" fn CreateFileA(
    name: [*:0]const u8,
    access: u32,
    share: u32,
    sec: ?*anyopaque,
    disp: u32,
    flags: u32,
    templ: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetFileSize(h: *anyopaque, hi: ?*u32) callconv(.winapi) u32;
extern "kernel32" fn ReadFile(h: *anyopaque, buf: [*]u8, n: u32, read: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;

const HEAP_ZERO: u32 = 0x08;
const ERROR_FILE_NOT_FOUND: u32 = 2;

fn heapAlloc(n: usize) ?[*]u8 {
    return @ptrCast(HeapAlloc(GetProcessHeap(), 0, n));
}
fn heapZeroed(n: usize) ?[*]u8 {
    return @ptrCast(HeapAlloc(GetProcessHeap(), HEAP_ZERO, n));
}
fn heapFree(p: ?*anyopaque) void {
    if (p) |q| _ = HeapFree(GetProcessHeap(), 0, q);
}

/// The archive reader wants a `std.mem.Allocator`, and everything else here is already on the
/// process heap. Nothing asks for more than pointer alignment, so an over-aligned request is
/// refused rather than silently mis-served.
const HeapAllocator = struct {
    var ctx: u8 = 0;

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        if (alignment.toByteUnits() > 8) return null;
        return heapAlloc(len);
    }
    fn resize(_: *anyopaque, m: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        return new_len <= m.len;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, m: []u8, _: std.mem.Alignment, _: usize) void {
        heapFree(m.ptr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const mpq_gpa: std.mem.Allocator = .{ .ptr = &HeapAllocator.ctx, .vtable = &HeapAllocator.vtable };

// ── the log is the instrument ────────────────────────────────────────────────

var out: ?*anyopaque = null;
var call_seq: u32 = 0;

fn say(msg: []const u8) void {
    const h = out orelse blk: {
        out = GetStdHandle(@bitCast(@as(i32, -11)));
        break :blk out orelse return;
    };
    var wrote: u32 = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &wrote, null);
    _ = WriteFile(h, "\r\n", 2, &wrote, null);
}

/// Announce a call in order, so the log is the engine's actual init sequence.
fn trace(comptime name: []const u8) void {
    call_seq += 1;
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "fog[{d}]: esp~0x{x} {s}", .{ call_seq, esp(), name }) catch return;
    say(s);
}

/// Roughly where the caller's stack is. Only the *trend* matters: every ordinal here is stdcall, so
/// two calls made from the same place in the engine's own call tree must see the same value. A
/// baseline that walks between them is an ordinal whose `ret N` pops the wrong amount, which is
/// invisible until some unrelated function returns to whatever the drift left behind.
inline fn esp() usize {
    return asm volatile (""
        : [ret] "={esp}" (-> usize),
    );
}

fn sayFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    say(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn cstr(p: ?[*:0]const u8) []const u8 {
    return if (p) |q| std.mem.sliceTo(q, 0) else "(null)";
}

/// Enough of C's `%` vocabulary to make the engine's own traces readable. Anything we do not know
/// is emitted verbatim, so an unhandled directive loses formatting but never the message.
fn cformat(buf: []u8, fmt: [*:0]const u8, ap: anytype) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (fmt[i] != 0 and n < buf.len) {
        if (fmt[i] != '%') {
            buf[n] = fmt[i];
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        while (fmt[i] != 0 and (fmt[i] == '-' or fmt[i] == '+' or fmt[i] == ' ' or fmt[i] == '#' or
            fmt[i] == '.' or fmt[i] == 'l' or fmt[i] == 'h' or (fmt[i] >= '0' and fmt[i] <= '9'))) i += 1;
        const rest = buf[n..];
        switch (fmt[i]) {
            0 => break,
            's' => n += (std.fmt.bufPrint(rest, "{s}", .{cstr(@cVaArg(ap, ?[*:0]const u8))}) catch break).len,
            'd', 'i' => n += (std.fmt.bufPrint(rest, "{d}", .{@cVaArg(ap, i32)}) catch break).len,
            'u' => n += (std.fmt.bufPrint(rest, "{d}", .{@cVaArg(ap, u32)}) catch break).len,
            'x' => n += (std.fmt.bufPrint(rest, "{x}", .{@cVaArg(ap, u32)}) catch break).len,
            'X' => n += (std.fmt.bufPrint(rest, "{X}", .{@cVaArg(ap, u32)}) catch break).len,
            'c' => n += (std.fmt.bufPrint(rest, "{c}", .{@as(u8, @truncate(@cVaArg(ap, u32)))}) catch break).len,
            else => |c| {
                buf[n] = c; // '%%' and anything we do not know, emitted as written
                n += 1;
            },
        }
        i += 1;
    }
    return buf[0..n];
}

// ── fastcall shims ───────────────────────────────────────────────────────────
//
// Zig's x86 fastcall callconv is unreliable (ziglang/zig#10363), so the engine's ECX/EDX ABI is
// adapted by hand exactly as apps/d2gs/runtime/fastcall.zig does it: a naked shim re-pushes the
// stack args, then EDX and ECX, calls a plain cdecl handler and does the callee cleanup itself.

fn shimAsm(comptime n_stack: usize) []const u8 {
    comptime {
        var s: []const u8 = "push %%ebp\nmov %%esp, %%ebp\npush %%ebx\npush %%esi\npush %%edi\n";
        var i: usize = n_stack;
        while (i > 0) : (i -= 1) s = s ++ std.fmt.comptimePrint("pushl {d}(%%ebp)\n", .{8 + (i - 1) * 4});
        s = s ++ "push %%edx\npush %%ecx\ncall %[impl:P]\n";
        s = s ++ std.fmt.comptimePrint("add ${d}, %%esp\n", .{(n_stack + 2) * 4});
        s = s ++ "pop %%edi\npop %%esi\npop %%ebx\npop %%ebp\n";
        // Plain `RET` when there are no stack args — that is what the real Fog emits.
        s = s ++ (if (n_stack == 0) "ret\n" else std.fmt.comptimePrint("ret ${d}\n", .{n_stack * 4}));
        return s;
    }
}

// ── entry points whose arity is not the same on every engine build ───────────
//
// Fog is stdcall: the callee pops. Where two builds disagree about how many arguments an ordinal
// takes, a fixed `ret N` is wrong for one of them, and wrong quietly — ESP shifts and the fault
// lands somewhere unrelated much later. So the cleanup for those entry points is a variable the
// host sets once, before the engine modules are loaded, via `FOG_SetEngineVersion`.
//
// Exported (not `var` in a comptime block) because the shims below name it from inline asm.

export var d2fog_alloc_linker_pop: u32 = fogabi.default.alloc_linker * 4;

/// Tell Fog which engine build it is standing in for. Takes the integer value of
/// `d2engine.version.Version`. A host that never calls this gets `fogabi.default`, which is 1.10f.
///
/// cdecl, unlike every other entry point here, and deliberately: the engine never calls this one,
/// only our own host does, and mingw decorates a stdcall export as `name@4` — which neither the
/// .def nor a GetProcAddress by plain name will match.
export fn FOG_SetEngineVersion(v: u32) callconv(.c) i32 {
    const tags = @typeInfo(fogabi.version_enum).@"enum".fields;
    inline for (tags) |f| {
        if (f.value == v) {
            const abi = fogabi.ordinalArgs(@enumFromInt(f.value)) orelse {
                sayFmt("fog: no measured Fog ABI for {s} — keeping 1.10f's", .{f.name});
                return 0;
            };
            d2fog_alloc_linker_pop = @as(u32, abi.alloc_linker) * 4;
            sayFmt("fog: ABI set for {s} (AllocLinker pops {d})", .{ f.name, d2fog_alloc_linker_pop });
            return 1;
        }
    }
    sayFmt("fog: unknown engine version {d} — keeping 1.10f's ABI", .{v});
    return 0;
}


/// Export `impl` at `name` as a stdcall entry point whose stack cleanup is read from `pop_symbol`
/// at call time instead of being baked into a `ret N`. `impl` takes no arguments — an entry point
/// in here only needs a runtime-variable pop when the arguments differ between builds, and none of
/// those arguments are ones we use.
fn exportStdcallVarPop(comptime name: []const u8, comptime pop_symbol: []const u8, comptime impl: anytype) void {
    const shim = struct {
        fn f() callconv(.naked) void {
            asm volatile ("call %[impl:P]\n" ++
                    "pop %%ecx\n" ++ // our own return address, out of the way of the cleanup
                    "addl " ++ pop_symbol ++ ", %%esp\n" ++
                    "jmp *%%ecx\n"
                :
                : [impl] "X" (&impl),
            );
        }
    }.f;
    @export(&shim, .{ .name = name });
}

/// Export `impl` at `name` as a __fastcall entry point with `n_stack` stack args past ECX/EDX.
/// `impl` is `fn (ecx, edx, s1..sN) callconv(.c) T`.
fn exportFastcall(comptime name: []const u8, comptime n_stack: usize, comptime impl: anytype) void {
    const shim = struct {
        fn f() callconv(.naked) void {
            asm volatile (shimAsm(n_stack)
                :
                : [impl] "X" (&impl),
            );
        }
    }.f;
    @export(&shim, .{ .name = name });
}

// ── exported data ────────────────────────────────────────────────────────────
//
// D2Game and D2Common read these arrays directly, and the real Fog's init ASSERTS their contents
// (`gdwBitMasks[i] == 1<<i`, `gdwInvBitMasks[i] == ~(1<<i)`), which is where this definition comes
// from — the check in the disassembly is the specification.

export var gdwBitMasks: [32]u32 = blk: {
    var m: [32]u32 = undefined;
    for (&m, 0..) |*e, i| e.* = @as(u32, 1) << @intCast(i);
    break :blk m;
};

export var gdwInvBitMasks: [32]u32 = blk: {
    var m: [32]u32 = undefined;
    for (&m, 0..) |*e, i| e.* = ~(@as(u32, 1) << @intCast(i));
    break :blk m;
};

// ── memory ───────────────────────────────────────────────────────────────────
//
// The process heap for now. The real thing is a segregated-slab pool; libd2 already carries a
// faithful replica, and swapping it in is a body change, not an interface change.
// The real Alloc/AllocPool do NOT zero — D2Common memsets where it cares — but zeroing is the
// safer divergence while the rest of this file is still growing bodies.

fn fcAlloc(size: u32, file: ?[*:0]const u8, line: u32, _: u32) callconv(.c) ?*anyopaque {
    _ = file;
    _ = line;
    trace("FOG_Alloc @10042");
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO, size);
}
comptime {
    exportFastcall("FOG_Alloc", 2, fcAlloc);
}

fn fcFree(p: ?*anyopaque, file: ?[*:0]const u8, line: u32, _: u32) callconv(.c) i32 {
    _ = file;
    _ = line;
    trace("FOG_Free @10043");
    heapFree(p);
    return 1; // the real one always reports success
}
comptime {
    exportFastcall("FOG_Free", 2, fcFree);
}

fn fcAllocPool(pool: ?*anyopaque, size: u32, file: ?[*:0]const u8, line: u32, _: u32) callconv(.c) ?*anyopaque {
    _ = pool; // D2Common always passes 0 = default pool
    _ = file;
    _ = line;
    trace("FOG_AllocPool @10045");
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO, size);
}
comptime {
    exportFastcall("FOG_AllocPool", 3, fcAllocPool);
}

// 10046/10047 are not in the spec table; their shape is taken from D2MOO, which the spec found
// correct for every ordinal it did check.
fn fcFreePool(pool: ?*anyopaque, p: ?*anyopaque, file: ?[*:0]const u8, line: u32, _: u32) callconv(.c) void {
    _ = pool;
    _ = file;
    _ = line;
    trace("FOG_FreePool @10046");
    heapFree(p);
}
comptime {
    exportFastcall("FOG_FreePool", 3, fcFreePool);
}

fn fcReallocPool(pool: ?*anyopaque, p: ?*anyopaque, size: u32, file: ?[*:0]const u8, line: u32, _: u32) callconv(.c) ?*anyopaque {
    _ = pool;
    _ = file;
    _ = line;
    trace("FOG_ReallocPool @10047");
    if (p) |q| return HeapReAlloc(GetProcessHeap(), HEAP_ZERO, q, size);
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO, size);
}
comptime {
    exportFastcall("FOG_ReallocPool", 4, fcReallocPool);
}

/// cdecl: `(void** ppSystem, const char* szName, uint32_t nPools, uint32_t nUnused)`. The out
/// parameter is the pool system; callers only ever test it for NULL.
export fn FOG_CreateNewPoolSystem(pp: ?*?*anyopaque, name: ?[*:0]const u8, pools: u32, unused: u32) callconv(.c) void {
    _ = name;
    _ = pools;
    _ = unused;
    trace("FOG_CreateNewPoolSystem @10142");
    if (pp) |p| p.* = @ptrFromInt(0x1);
}

export fn FOG_DestroyMemoryPoolSystem(sys: ?*anyopaque) callconv(.c) void {
    _ = sys;
    trace("FOG_DestroyMemoryPoolSystem @10143");
}

export fn FOG_GetMemoryUsage(sys: ?*anyopaque) callconv(.c) u32 {
    _ = sys;
    trace("FOG_GetMemoryUsage @10147");
    return 0;
}

// ── errors, tracing ──────────────────────────────────────────────────────────
//
// All cdecl in the binary. The real Fog pops dialogs here; ours must never block, since a blocked
// assert is exactly the failure mode that cost us an afternoon with the original.
//
// DisplayAssert *returns* — the caller executes `exit(-1)` itself — so a non-fatal stub only
// changes what gets logged, not whether the engine dies.

export fn FOG_DisplayAssert(msg: ?[*:0]const u8, file: ?[*:0]const u8, line: u32) callconv(.c) void {
    trace("FOG_DisplayAssert @10023  *** ENGINE ASSERT ***");
    sayFmt("  assert \"{s}\" at {s}:{d}", .{ cstr(msg), cstr(file), line });
}

export fn FOG_DisplayHalt(msg: ?[*:0]const u8, file: ?[*:0]const u8, line: u32) callconv(.c) void {
    trace("FOG_DisplayHalt @10024  *** ENGINE HALT ***");
    sayFmt("  halt \"{s}\" at {s}:{d}", .{ cstr(msg), cstr(file), line });
}

export fn FOG_DisplayWarning(msg: ?[*:0]const u8, file: ?[*:0]const u8, line: u32) callconv(.c) void {
    trace("FOG_DisplayWarning @10025");
    sayFmt("  warning \"{s}\" at {s}:{d}", .{ cstr(msg), cstr(file), line });
}

/// Note the leading category: `FOG_DisplayError(int nCategory, szMsg, szFile, nLine)`.
/// ARCHIVE_GetFileSize calls it with category 3 just before `exit(-1)`.
export fn FOG_DisplayError(category: u32, msg: ?[*:0]const u8, file: ?[*:0]const u8, line: u32) callconv(.c) void {
    trace("FOG_DisplayError @10026  *** ENGINE ERROR ***");
    sayFmt("  error {d} \"{s}\" at {s}:{d}", .{ category, cstr(msg), cstr(file), line });
}

export fn FOG_Trace(fmt: ?[*:0]const u8, ...) callconv(.c) void {
    trace("FOG_Trace @10029");
    const f = fmt orelse return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var buf: [512]u8 = undefined;
    say(cformat(&buf, f, &ap));
}

export fn FOG_TraceF(sub: ?[*:0]const u8, fmt: ?[*:0]const u8, ...) callconv(.c) void {
    trace("FOG_TraceF @10030");
    const f = fmt orelse return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var buf: [512]u8 = undefined;
    sayFmt("  [{s}] {s}", .{ cstr(sub), cformat(&buf, f, &ap) });
}

export fn FOG_csprintf(dst: ?[*]u8, fmt: ?[*:0]const u8, ...) callconv(.c) ?[*]u8 {
    trace("FOG_csprintf @10018");
    const d = dst orelse return null;
    const f = fmt orelse {
        d[0] = 0;
        return d;
    };
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    // Format locally: the caller's buffer has no length, so only bytes we produced get written.
    var buf: [512]u8 = undefined;
    const s = cformat(&buf, f, &ap);
    @memcpy(d[0..s.len], s);
    d[s.len] = 0;
    return d;
}

// ── sync, time, math ─────────────────────────────────────────────────────────

/// Sections we have already initialised. Sized well past what the engine uses: overflowing this
/// silently was a hang, because the fallback entered a section nobody had initialised.
var known_sections: [256]usize = @splat(0);
var known_count: usize = 0;
var section_overflow_reported = false;

/// The lock D2Game takes on its game list — and it takes it *before anything initialises it*.
/// Entering an uninitialised section blocks forever (wine: "blocked by 0000"), which is exactly the
/// wall the real Fog put us behind. The real one does not initialise either; owning Fog means we
/// get to decide, so we initialise on first sight.
// Not traced: the engine takes locks constantly, and tracing each one buried the log under 74k
// lines. First sight of a section is logged instead, which is the part that carries information.
fn fcEnterCriticalSection(cs: ?*anyopaque, line: u32) callconv(.c) void {
    _ = line;
    const c = cs orelse return;
    const key = @intFromPtr(c);
    for (known_sections[0..known_count]) |k| {
        if (k == key) {
            EnterCriticalSection(c);
            return;
        }
    }
    if (known_count < known_sections.len) {
        known_sections[known_count] = key;
        known_count += 1;
        sayFmt("  lock: init section {d} @0x{x}", .{ known_count, key });
        InitializeCriticalSection(c);
        EnterCriticalSection(c);
        return;
    }
    // Entering an unknown section here would block forever on zeroed memory. Say so once rather
    // than hanging silently; the table is meant to be large enough that this never happens.
    if (!section_overflow_reported) {
        section_overflow_reported = true;
        sayFmt("  lock: SECTION TABLE FULL at {d}, unknown section @0x{x}", .{ known_count, key });
    }
    InitializeCriticalSection(c);
    EnterCriticalSection(c);
}
comptime {
    exportFastcall("FOG_EnterCriticalSection", 0, fcEnterCriticalSection);
}

/// The engine's clock, and **not** milliseconds. D2 runs at 25 frames a second and the task
/// scheduler re-arms a game with `*task += 0x28` — 40 ms, one frame — so sync time counts frames.
/// The game idle timeout compares against `0x708` (1800): 1800 frames is 72 seconds, which is a
/// sensible reap window, while 1800 *milliseconds* is 1.8 s and reaps every game before anyone can
/// join it. Returning GetTickCount() here made the engine delete each game seconds after creating
/// it, reported as "Deleting game from sSrvTaskProcessGame(), I/O timeout".
const frame_ms = 40;

fn fcGetSyncTime(_: u32, _: u32) callconv(.c) u32 {
    return GetTickCount() / frame_ms;
}
comptime {
    exportFastcall("FOG_GetSyncTime", 0, fcGetSyncTime);
}

fn fcIsExpansion(_: u32, _: u32) callconv(.c) u32 {
    trace("FOG_IsExpansion @10227");
    return 1;
}
comptime {
    exportFastcall("FOG_IsExpansion", 0, fcIsExpansion);
}

/// stdcall, and it returns a float in ST(0). The index is a 16-bit angle but still occupies a full
/// stack slot, so the callee cleanup is 4 either way.
export fn FOG_Cos_LUT(index: i32) callconv(.winapi) f32 {
    trace("FOG_Cos_LUT @10083");
    _ = index;
    return 0;
}

export fn FOG_Sin_LUT(index: i32) callconv(.winapi) f32 {
    trace("FOG_Sin_LUT @10084");
    _ = index;
    return 0;
}

export fn FOG_Encode14BitsToString(chars: ?*[2]u16, value: u32) callconv(.winapi) void {
    trace("FOG_Encode14BitsToString @10086");
    _ = chars;
    _ = value;
}

/// `(void* pData, size_t dwSize)` — two args, not one value.
export fn FOG_ComputeChecksum(p: ?[*]const u8, n: u32) callconv(.winapi) u32 {
    trace("FOG_ComputeChecksum @10229");
    var sum: u32 = 0;
    if (p) |q| for (q[0..n]) |b| {
        sum = sum *% 33 +% b;
    };
    return sum;
}

/// Also `(void* pData, size_t dwSize)` — it counts the set bits of a buffer, not of one word.
export fn FOG_PopCount(p: ?[*]const u8, n: u32) callconv(.winapi) u32 {
    var bits: u32 = 0;
    if (p) |q| for (q[0..n]) |b| {
        bits += @popCount(b);
    };
    return bits;
}

export fn FOG_LeadingZeroesCount(v: u32) callconv(.winapi) u32 {
    return @clz(v);
}

/// One argument: the string. Returns a 16-bit CRC.
export fn FOG_ComputeStringCRC16(s: ?[*:0]const u8) callconv(.winapi) u32 {
    trace("FOG_ComputeStringCRC16 @10137");
    var crc: u16 = 0;
    for (cstr(s)) |c| crc = (crc << 1) +% c;
    return crc;
}

// ── files ────────────────────────────────────────────────────────────────────
//
// Loose files under the process working directory, which is all D2Common's table loader needs:
// `DATA\GLOBAL\EXCEL\monstats.txt` is read as `./data/global/excel/monstats.txt`. MPQ comes later
// behind the same handle table, so the shape here is the shape it keeps.
//
// The whole file is pulled into the heap at open time and the handle is ours, never the OS's: the
// engine treats HSFILE as opaque and we want the read cursor and the size answer to come from one
// place. Zero-length files are refused at open — #10105 returning 0 is fatal to the engine, so a
// file we cannot answer a non-zero size for must never get a handle.

const MAX_OPEN_FILES = 32;

const OpenFile = struct {
    used: bool = false,
    data: ?[*]u8 = null,
    size: u32 = 0,
    pos: u32 = 0,
};

var open_files: [MAX_OPEN_FILES]OpenFile = @splat(.{});

fn handleOf(slot: *OpenFile) usize {
    return @intFromPtr(slot);
}

fn slotOf(h: usize) ?*OpenFile {
    if (h == 0) return null;
    const base = @intFromPtr(&open_files[0]);
    const end = base + @sizeOf(OpenFile) * MAX_OPEN_FILES;
    if (h < base or h >= end) return null;
    if ((h - base) % @sizeOf(OpenFile) != 0) return null;
    const s: *OpenFile = @ptrFromInt(h);
    return if (s.used) s else null;
}

/// Copy an engine path into `buf`, dropping any leading separator so it stays relative to cwd.
/// Backslashes are kept: under wine they are the native separator and the lookup is
/// case-insensitive, and on Windows they are correct outright.
fn toLocalPath(buf: []u8, name: [*:0]const u8, lower: bool) ?[:0]u8 {
    const src = std.mem.sliceTo(name, 0);
    var start: usize = 0;
    while (start < src.len and (src[start] == '\\' or src[start] == '/')) start += 1;
    const n = src.len - start;
    if (n == 0 or n + 1 > buf.len) return null;
    for (src[start..], 0..) |c, i| buf[i] = if (lower) std.ascii.toLower(c) else c;
    buf[n] = 0;
    return buf[0..n :0];
}

const GENERIC_READ: u32 = 0x8000_0000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const INVALID_HANDLE: usize = ~@as(usize, 0);

/// Size of a file next to the cwd, without reading it — used to tell "absent" from "too big".
fn probeFileSize(path: [*:0]const u8) ?u32 {
    const raw = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (raw == null or @intFromPtr(raw) == INVALID_HANDLE) return null;
    defer _ = CloseHandle(raw.?);
    const size = GetFileSize(raw.?, null);
    return if (size == 0 or size == 0xFFFF_FFFF) null else size;
}

/// Slurp a file next to the cwd. Used for the archives, which stay mapped for the process life.
fn readWholeFile(path: [*:0]const u8) ?[]u8 {
    const raw = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (raw == null or @intFromPtr(raw) == INVALID_HANDLE) return null;
    const file = raw.?;
    defer _ = CloseHandle(file);
    const size = GetFileSize(file, null);
    if (size == 0 or size == 0xFFFF_FFFF) return null;
    const data = heapAlloc(size) orelse return null;
    var done: u32 = 0;
    while (done < size) {
        var got: u32 = 0;
        if (ReadFile(file, data + done, size - done, &got, null) == 0 or got == 0) {
            heapFree(data);
            return null;
        }
        done += got;
    }
    return data[0..size];
}

fn openLoose(name: [*:0]const u8) ?*OpenFile {
    const INVALID = INVALID_HANDLE;

    var buf: [512]u8 = undefined;
    var h: ?*anyopaque = null;
    // Try the path as given, then all-lowercase: our loose data trees are lowercase and the engine
    // asks in mixed case, which only matters on a case-sensitive mount.
    for ([_]bool{ false, true }) |lower| {
        const path = toLocalPath(&buf, name, lower) orelse return null;
        const raw = CreateFileA(path.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
        if (raw != null and @intFromPtr(raw) != INVALID) {
            h = raw;
            break;
        }
    }
    const file = h orelse return null;
    defer _ = CloseHandle(file);

    const size = GetFileSize(file, null);
    if (size == 0 or size == 0xFFFF_FFFF) return null;

    const slot = for (&open_files) |*s| {
        if (!s.used) break s;
    } else return null;

    const data = heapAlloc(size) orelse return null;
    var done: u32 = 0;
    while (done < size) {
        var got: u32 = 0;
        if (ReadFile(file, data + done, size - done, &got, null) == 0 or got == 0) {
            heapFree(data);
            return null;
        }
        done += got;
    }

    slot.* = .{ .used = true, .data = data, .size = size, .pos = 0 };
    return slot;
}

// ── the archives ─────────────────────────────────────────────────────────────
//
// A loose file wins, then the archives in D2's own precedence. Serving from the MPQs rather than a
// pre-extracted tree is not convenience: an MPQ's listfile is an ordinary member and an optional
// one — retail's Patch_D2.mpq has none — so extraction only ever recovers the members someone
// already knew to name, while lookup by name hash finds every one. `data\global\excel\CompCode.bin`
// is the case that proves it: absent from every listing, present in the archive, and required.

/// Retail's own search order, patch first. Held for the process life — `Archive` borrows the bytes
/// it was opened over. An archive that is not present is skipped, so a minimal install works and a
/// full one costs nothing extra: the ones a headless server never reads are simply never hit.
const archive_names = [_][:0]const u8{
    "Patch_D2.mpq",
    "d2exp.mpq",
    "d2xtalk.mpq",
    "d2xmusic.mpq",
    "d2xvideo.mpq",
    "d2data.mpq",
    "d2char.mpq",
    "d2sfx.mpq",
    "d2music.mpq",
    "d2speech.mpq",
    "d2video.mpq",
};
var archives: [archive_names.len]?mpq.Archive = @splat(null);
var archives_loaded = false;

fn ensureArchives() void {
    if (archives_loaded) return;
    archives_loaded = true;
    for (archive_names, 0..) |name, i| {
        // An archive that is simply absent is normal and silent. One that is present and still
        // fails to load is not: say so, because a silently skipped archive looks exactly like a
        // missing game file thousands of opens later. The usual cause is size — this is a 32-bit
        // process and the whole archive is read into the heap.
        const present = probeFileSize(name.ptr);
        const bytes = readWholeFile(name.ptr) orelse {
            if (present) |sz| sayFmt("  archive: {s} PRESENT BUT NOT LOADED ({d} bytes)", .{ name, sz });
            continue;
        };
        archives[i] = mpq.Archive.open(mpq_gpa, bytes) catch {
            sayFmt("  archive: {s} UNREADABLE ({d} bytes)", .{ name, bytes.len });
            heapFree(bytes.ptr);
            continue;
        };
        sayFmt("  archive: {s} ({d} bytes)", .{ name, bytes.len });
    }
}

fn openArchive(name: [*:0]const u8) ?*OpenFile {
    ensureArchives();
    const full = std.mem.sliceTo(name, 0);
    var start: usize = 0;
    while (start < full.len and (full[start] == '\\' or full[start] == '/')) start += 1;
    const want = full[start..];
    if (want.len == 0) return null;

    for (&archives) |*maybe| {
        var a = maybe.* orelse continue;
        const data = a.read(mpq_gpa, want) catch continue;
        if (data.len == 0 or data.len > 0xFFFF_FFFF) {
            heapFree(data.ptr);
            continue;
        }
        const slot = for (&open_files) |*s| {
            if (!s.used) break s;
        } else {
            heapFree(data.ptr);
            return null;
        };
        slot.* = .{ .used = true, .data = data.ptr, .size = @intCast(data.len), .pos = 0 };
        return slot;
    }
    return null;
}

/// `BOOL __fastcall (const char* szFileName /*ECX*/, HSFILE* phFile /*EDX*/)`.
/// On a miss it must set ERROR_FILE_NOT_FOUND: D2Common's ARCHIVE_OpenFile suppresses its
/// "Error opening file: %s" trace only for error 2 when it is being quiet.
fn fcFOpenFile(name: ?[*:0]const u8, phandle: ?*usize) callconv(.c) u32 {
    trace("FOG_FOpenFile @10102");
    if (phandle) |p| p.* = 0;
    const n = name orelse {
        SetLastError(ERROR_FILE_NOT_FOUND);
        return 0;
    };
    const slot = openLoose(n) orelse openArchive(n) orelse {
        sayFmt("  miss: {s}", .{cstr(n)});
        SetLastError(ERROR_FILE_NOT_FOUND);
        return 0;
    };
    sayFmt("  open: {s} ({d} bytes)", .{ cstr(n), slot.size });
    if (phandle) |p| p.* = handleOf(slot);
    return 1;
}
comptime {
    exportFastcall("FOG_FOpenFile", 0, fcFOpenFile);
}

fn fcFCloseFile(h: usize, _: u32) callconv(.c) u32 {
    trace("FOG_FCloseFile @10103");
    const slot = slotOf(h) orelse return 0;
    heapFree(slot.data);
    slot.* = .{};
    return 1;
}
comptime {
    exportFastcall("FOG_FCloseFile", 0, fcFCloseFile);
}

/// `*pBytesRead` must come back equal to `nBytesToRead`: ARCHIVE_ReadFileToBuffer asserts on it.
fn fcFReadFile(h: usize, buf: ?[*]u8, want: u32, pread: ?*u32, _: u32, _: u32, _: u32) callconv(.c) u32 {
    trace("FOG_FReadFile @10104");
    if (pread) |p| p.* = 0;
    const slot = slotOf(h) orelse return 0;
    const dst = buf orelse return 0;
    const avail = slot.size - slot.pos;
    const n = @min(want, avail);
    @memcpy(dst[0..n], (slot.data.?)[slot.pos..][0..n]);
    slot.pos += n;
    if (pread) |p| p.* = n;
    return if (n == want) 1 else 0;
}
comptime {
    exportFastcall("FOG_FReadFile", 5, fcFReadFile);
}

/// Returning 0 is fatal — ARCHIVE_GetFileSize calls FOG_DisplayError(3, ...) and exit(-1) — which
/// is why openLoose refuses zero-length files rather than handing out a handle we cannot size.
fn fcFGetFileSize(h: usize, phigh: ?*u32) callconv(.c) u32 {
    trace("FOG_FGetFileSize @10105");
    if (phigh) |p| p.* = 0;
    const slot = slotOf(h) orelse return 0;
    return slot.size;
}
comptime {
    exportFastcall("FOG_FGetFileSize", 0, fcFGetFileSize);
}

/// `BOOL __fastcall (char* pBuffer /*ECX*/, size_t nBufferSize /*EDX*/)` — the BOOL is
/// CreatePathHierarchy's, and every known caller ignores it. No registry: saves live beside us.
fn fcGetSavePath(buf: ?[*]u8, size: u32) callconv(.c) u32 {
    trace("FOG_GetSavePath @10115");
    const b = buf orelse return 0;
    const path = "Save\\";
    if (size < path.len + 1) return 0;
    @memcpy(b[0..path.len], path);
    b[path.len] = 0;
    return 1;
}
comptime {
    exportFastcall("FOG_GetSavePath", 0, fcGetSavePath);
}

// ── bit streams (BITMANIP_) ──────────────────────────────────────────────────
//
// All stdcall. The three bit-poking entries take (pBitStream, nBit) — two args, not three.

export fn BITMANIP_SetBitState(p: ?[*]u8, bit: i32) callconv(.winapi) void {
    _ = p;
    _ = bit;
    trace("BITMANIP_SetBitState @10118");
}
export fn BITMANIP_GetBitState(p: ?[*]const u8, bit: i32) callconv(.winapi) i32 {
    _ = p;
    _ = bit;
    trace("BITMANIP_GetBitState @10119");
    return 0;
}
export fn BITMANIP_MaskBitstate(p: ?[*]u8, bit: i32) callconv(.winapi) void {
    _ = p;
    _ = bit;
    trace("BITMANIP_MaskBitstate @10120");
}
export fn BITMANIP_Initialize(s: ?*anyopaque, stream: ?[*]u8, n: u32) callconv(.winapi) void {
    _ = s;
    _ = stream;
    _ = n;
    trace("BITMANIP_Initialize @10126");
}
export fn BITMANIP_GetSize(s: ?*anyopaque) callconv(.winapi) u32 {
    _ = s;
    trace("BITMANIP_GetSize @10127");
    return 0;
}
export fn BITMANIP_Write(s: ?*anyopaque, v: u32, bits: u32) callconv(.winapi) void {
    _ = s;
    _ = v;
    _ = bits;
    trace("BITMANIP_Write @10128");
}
export fn BITMANIP_ReadSigned(s: ?*anyopaque, bits: i32) callconv(.winapi) i32 {
    _ = s;
    _ = bits;
    trace("BITMANIP_ReadSigned @10129");
    return 0;
}
export fn BITMANIP_Read(s: ?*anyopaque, bits: i32) callconv(.winapi) u32 {
    _ = s;
    _ = bits;
    trace("BITMANIP_Read @10130");
    return 0;
}
export fn BITMANIP_GoToNextByte(s: ?*anyopaque) callconv(.winapi) void {
    _ = s;
    trace("BITMANIP_GoToNextByte @10131");
}

// ── .bin / .txt data tables ──────────────────────────────────────────────────
//
// All stdcall. #10208 tokenises the .txt buffer in place: tabs and the CRLF become NULs, the first
// line is the column header, and "Expansion" rows are cut out with a memmove. The engine then walks
// rows by stepping over those NULs, so the layout is the contract, not the struct.

const BinFile = extern struct {
    data: ?[*]u8 = null,
    first_row: ?[*]u8 = null,
    rows: i32 = 0,
    columns: i32 = 0,
};

const EXCEL_MAX_CELLS = 0x118;

/// Turn one line's separators into NULs and report where the next line starts.
/// Returns null at end of buffer.
fn tokenizeLine(buf: []u8, from: usize, tabs: *i32) ?usize {
    var i = from;
    tabs.* = 0;
    while (i < buf.len) : (i += 1) {
        switch (buf[i]) {
            '\t' => {
                buf[i] = 0;
                tabs.* += 1;
            },
            '\r' => {
                buf[i] = 0;
                if (i + 1 < buf.len and buf[i + 1] == '\n') {
                    buf[i + 1] = 0;
                    return i + 2;
                }
                return i + 1;
            },
            '\n' => {
                buf[i] = 0;
                return i + 1;
            },
            else => {},
        }
    }
    return null;
}

export fn FOG_CreateBinFile(data: ?[*]u8, size: i32) callconv(.winapi) ?*BinFile {
    trace("FOG_CreateBinFile @10208");
    const p = data orelse return null;
    if (size <= 0) return null;
    var buf = p[0..@intCast(size)];

    // Counts separators, and a line with one tab has two cells. The decoder loops `columns` times
    // per row, so an off-by-one here silently drops the last column of every table — which is how
    // a generated storepage.bin came out all zeros while still being the right size.
    var columns: i32 = 0;
    const first = tokenizeLine(buf, 0, &columns) orelse {
        heapFree(p);
        return null;
    };
    columns += 1;
    if (columns >= EXCEL_MAX_CELLS) columns = EXCEL_MAX_CELLS - 1;

    var rows: i32 = 0;
    var at = first;
    while (at < buf.len) {
        var tabs: i32 = 0;
        const next = tokenizeLine(buf, at, &tabs) orelse buf.len;
        // Expansion markers are separators in the .txt, never records: cut them out entirely.
        if (std.mem.eql(u8, std.mem.sliceTo(buf[at..], 0), "Expansion")) {
            std.mem.copyForwards(u8, buf[at..], buf[next..]);
            buf = buf[0 .. buf.len - (next - at)];
            continue;
        }
        rows += 1;
        at = next;
    }

    if (rows == 0) { // header only: the real Fog frees the caller's buffer too
        heapFree(p);
        return null;
    }
    const bin: *BinFile = @ptrCast(@alignCast(heapZeroed(@sizeOf(BinFile)) orelse return null));
    bin.* = .{ .data = p, .first_row = p + first, .rows = rows, .columns = columns };
    sayFmt("  bin: {d} rows x {d} columns", .{ rows, columns });
    return bin;
}

export fn FOG_FreeBinFile(bin: ?*BinFile) callconv(.winapi) void {
    trace("FOG_FreeBinFile @10209");
    const b = bin orelse return;
    heapFree(b.data);
    heapFree(b);
}

export fn FOG_GetRecordCountFromBinFile(bin: ?*BinFile) callconv(.winapi) i32 {
    trace("FOG_GetRecordCountFromBinFile @10210");
    return if (bin) |b| b.rows else 0;
}

/// One column of a table, as D2Common describes it to Fog. 0x14 bytes, and the array is
/// terminated by a zero `kind` — the real @10207 walks it exactly that way.
const BinField = extern struct {
    /// The column header this binds to. Matched against the `.txt`'s first line.
    name: ?[*:0]const u8,
    /// What to do with the cell. Zero ends the array. See `fieldHandler`.
    kind: u32,
    /// Bytes, for the string kinds; the bit index, for kind 0x1A.
    size: u32,
    /// Where in the record this column's value goes.
    offset: u32,
    /// For the linked kinds, a pointer TO the linker pointer (the table's linker is allocated
    /// separately and stored by the caller); for the callback kinds, the callback itself.
    link: ?*?*Linker,
};

/// What each column kind does. Read out of 1.10f Fog's own dispatch: a byte table at 0x6ff5b667
/// indexed by kind, selecting one of eight handlers.
const Handler = enum(u8) { string, integer, code4, skip, link_index, row_index, cb_word, cb_void };

fn fieldHandler(kind: u32) ?Handler {
    return switch (kind) {
        1, 7 => .string,
        2, 3, 4, 5, 6, 8, 0x1A => .integer,
        9 => .code4,
        // Registered in the first pass and deliberately not decoded in the second.
        0xA, 0xC, 0xE, 0x10, 0x11, 0x12 => .skip,
        0xB, 0xD, 0xF => .link_index,
        0x13, 0x14, 0x15 => .row_index,
        0x16 => .cb_word,
        0x17, 0x18, 0x19 => .cb_void,
        else => null,
    };
}

/// Cells are NUL-separated in place (that is what @10208 did to the buffer) and a row ends with a
/// newline, so walking is: read up to the NUL, step past it.
const Cells = struct {
    p: [*]u8,

    fn next(self: *Cells) []const u8 {
        const start = self.p;
        var n: usize = 0;
        while (start[n] != 0 and start[n] != '\n') n += 1;
        self.p = start + n + 1;
        return start[0..n];
    }

    /// Step over the row separator. @10208 NULs the tabs AND the CRLF in place, so a row ends in
    /// two NULs — the last cell's, then the line's — and there is no '\n' left to look for. Miss
    /// this and every row after the first is read one cell late, which shows up as a table of the
    /// right size holding its neighbours' columns.
    fn endOfRow(self: *Cells) void {
        if (self.p[0] == 0) self.p += 1;
    }
};

fn parseInt(cell: []const u8) i32 {
    var i: usize = 0;
    var neg = false;
    if (i < cell.len and (cell[i] == '-' or cell[i] == '+')) {
        neg = cell[i] == '-';
        i += 1;
    }
    var v: i32 = 0;
    while (i < cell.len and cell[i] >= '0' and cell[i] <= '9') : (i += 1) {
        v = v *% 10 +% @as(i32, cell[i] - '0');
    }
    return if (neg) -v else v;
}

/// A four-character code, space-padded — the engine's own normalisation, so a short cell compares
/// equal to the padded form already in the linking table.
fn code4(cell: []const u8) u32 {
    var b: [4]u8 = @splat(' ');
    for (cell[0..@min(cell.len, 4)], 0..) |c, i| b[i] = c;
    return std.mem.readInt(u32, &b, .little);
}

fn writeSized(rec: [*]u8, off: u32, bytes: u32, v: i32) void {
    switch (bytes) {
        1 => rec[off] = @truncate(@as(u32, @bitCast(v))),
        2 => std.mem.writeInt(i16, rec[off..][0..2], @truncate(v), .little),
        else => std.mem.writeInt(i32, rec[off..][0..4], v, .little),
    }
}

/// Width of the destination for the kinds that encode it in the kind itself.
fn kindWidth(kind: u32) u32 {
    return switch (kind) {
        3, 0xF, 0x14, 0x16 => 2,
        4, 5, 6, 0xD, 0x15 => 1,
        else => 4,
    };
}

/// @10207. Fill `records` from the tokenised `.txt`, one row at a time, driven by the column
/// descriptors D2Common hands us.
///
/// Two passes, because the table is self-referential: the first registers every code and name into
/// the linking tables (kinds 0xA/0xC/0xE add a 4CC, 0x10 adds a string), so that the second can
/// resolve columns that refer to rows of this very table. Doing it in one pass would fail on any
/// forward reference — which is why the engine's own second-pass dispatch marks those kinds
/// `skip`: they were already consumed.
///
/// `n_records`/`stride` are the engine's `nMemHgt`/`nMemSpan`, and it asserts both are non-zero
/// before touching anything.
export fn FOG_10207(
    bin: ?*BinFile,
    fields: ?[*]BinField,
    records: ?[*]u8,
    n_records: u32,
    stride: u32,
) callconv(.winapi) void {
    trace("FOG_10207 @10207 (txt -> records)");
    const b = bin orelse return;
    const f = fields orelse return;
    const rec = records orelse return;
    if (n_records == 0 or stride == 0) {
        say("  10207: refusing a zero-sized table");
        return;
    }
    const header = b.data orelse return;
    const body = b.first_row orelse return;
    const columns: usize = @intCast(@max(b.columns, 0));
    const rows: usize = @min(@as(usize, @intCast(@max(b.rows, 0))), n_records);

    // Bind each of the file's columns to a descriptor, by header name. A column the descriptors do
    // not mention is skipped rather than guessed at — tables carry columns the server ignores.
    var bound: [EXCEL_MAX_CELLS]?*BinField = @splat(null);
    var head = Cells{ .p = header };
    for (0..@min(columns, EXCEL_MAX_CELLS)) |c| {
        const name = head.next();
        var i: usize = 0;
        while (f[i].kind != 0) : (i += 1) {
            const dn = cstr(f[i].name);
            if (dn.len == name.len and std.ascii.eqlIgnoreCase(dn, name)) {
                bound[c] = &f[i];
                break;
            }
        }
    }

    // Pass 1: register codes and names, so the second pass can resolve references into this table.
    var needs_registration = false;
    for (bound[0..@min(columns, EXCEL_MAX_CELLS)]) |maybe| {
        const d = maybe orelse continue;
        switch (d.kind) {
            0xA, 0xC, 0xE, 0x10, 0x11, 0x12 => needs_registration = true,
            else => {},
        }
    }
    if (needs_registration) {
        var cur = Cells{ .p = body };
        for (0..rows) |row| {
            for (0..columns) |c| {
                const cell = cur.next();
                const d = (if (c < EXCEL_MAX_CELLS) bound[c] else null) orelse continue;
                const link = if (d.link) |pp| pp.* else null;
                switch (d.kind) {
                    // Registering is only half of it: the real @10207 also writes, and what it
                    // writes depends on the kind — 0xA stores the 4CC itself, 0xC and 0xE store
                    // the index the linking table just handed back. Registering without storing
                    // leaves a correctly sized table full of zeros.
                    0xA, 0xC, 0xE => {
                        const code = code4(cell);
                        const idx = FOG_AddCodeToLinkingTable(link, code);
                        const dst = rec + row * stride + d.offset;
                        switch (d.kind) {
                            0xA => std.mem.writeInt(u32, dst[0..4], code, .little),
                            0xC => dst[0] = @truncate(@as(u32, @bitCast(idx))),
                            else => std.mem.writeInt(i16, dst[0..2], @truncate(idx), .little),
                        }
                    },
                    0x10, 0x11, 0x12 => {
                        var key: [0x21]u8 = @splat(0);
                        const n = @min(cell.len, key.len - 1);
                        @memcpy(key[0..n], cell[0..n]);
                        FOG_AddRecordToLinkingTable(link, @ptrCast(&key));
                    },
                    else => {},
                }
            }
            cur.endOfRow();
        }
    }

    // Pass 2: decode every cell into its record.
    var cur = Cells{ .p = body };
    for (0..rows) |row| {
        const dst = rec + row * stride;
        for (0..columns) |c| {
            const cell = cur.next();
            const d = (if (c < EXCEL_MAX_CELLS) bound[c] else null) orelse continue;
            const handler = fieldHandler(d.kind) orelse continue;
            const link = if (d.link) |pp| pp.* else null;
            switch (handler) {
                .skip => {},
                .string => {
                    const cap = if (d.size == 0) 1 else d.size;
                    const n = @min(cell.len, cap - 1);
                    @memcpy((dst + d.offset)[0..n], cell[0..n]);
                    dst[d.offset + n] = 0;
                },
                .code4 => std.mem.writeInt(u32, (dst + d.offset)[0..4], code4(cell), .little),
                .integer => {
                    if (d.kind == 0x1A) {
                        // A flag column: `size` is the bit, not a width.
                        const bit = d.size;
                        const at = d.offset + bit / 8;
                        const mask: u8 = @as(u8, 1) << @intCast(bit % 8);
                        if (parseInt(cell) != 0) dst[at] |= mask else dst[at] &= ~mask;
                    } else if (d.kind == 5 and cell.len != 1) {
                        // Kind 5 takes a single character only; anything else is left alone.
                    } else {
                        writeSized(dst, d.offset, kindWidth(d.kind), parseInt(cell));
                    }
                },
                .link_index => writeSized(dst, d.offset, kindWidth(d.kind), FOG_GetLinkIndex(link, code4(cell), 1)),
                .row_index => {
                    var key: [0x21]u8 = @splat(0);
                    const n = @min(cell.len, key.len - 1);
                    @memcpy(key[0..n], cell[0..n]);
                    writeSized(dst, d.offset, kindWidth(d.kind), FOG_GetRowFromTxt(link, @ptrCast(&key), 1));
                },
                // The callback kinds hand the cell to a per-column function D2Common supplies. We
                // do not know its convention yet, so the column is left zero rather than called
                // with a guess — a wrong call here would corrupt the engine's stack.
                .cb_word, .cb_void => {},
            }
        }
        cur.endOfRow();
    }
    sayFmt("  10207: {d} rows x {d} bytes decoded", .{ rows, stride });
}

// ── the linker (D2TxtLinkStrc) ───────────────────────────────────────────────
//
// One linker is either a code table or a string tree, never both — the real 10215 asserts on
// pStrTbl and 10216 asserts on pTbl. Layout is the ABI: 16 bytes, and the string nodes are 0x2C.

const CodeEntry = extern struct { code: u32, index: i32 };

const StrNode = extern struct {
    key: [0x20]u8,
    index: i32,
    left: ?*StrNode,
    right: ?*StrNode,
};

const Linker = extern struct {
    size: i32 = 0,
    capacity: i32 = 0,
    tbl: ?[*]CodeEntry = null,
    str: ?*StrNode = null,
};

const LINK_GROW = 0x40;

fn foldKey(dst: *[0x20]u8, src: ?[*:0]const u8) void {
    @memset(dst, 0);
    const s = cstr(src);
    const n = @min(s.len, dst.len - 1);
    for (s[0..n], 0..) |c, i| dst[i] = std.ascii.toLower(c);
}

/// @10211. Takes `(__FILE__, __LINE__)` on 1.10f and nothing on 1.09d, so neither the arguments
/// nor the cleanup can be fixed here — see `d2fog_alloc_linker_pop`. We ignore the debug pair
/// either way, which is what makes one implementation able to serve both.
fn allocLinkerImpl() callconv(.c) ?*Linker {
    trace("FOG_AllocLinker @10211");
    return @ptrCast(@alignCast(heapZeroed(@sizeOf(Linker))));
}
comptime {
    // The asm names the symbol as the linker sees it: x86 COFF prefixes an underscore.
    exportStdcallVarPop("FOG_AllocLinker", "_d2fog_alloc_linker_pop", allocLinkerImpl);
}

fn freeTree(node: ?*StrNode) void {
    const n = node orelse return;
    freeTree(n.left);
    freeTree(n.right);
    heapFree(n);
}

export fn FOG_FreeLinker(linker: ?*Linker) callconv(.winapi) void {
    trace("FOG_FreeLinker @10212");
    const l = linker orelse return;
    freeTree(l.str);
    heapFree(l.tbl);
    heapFree(l);
}

/// Binary search for `code`. The index is the RETURN VALUE — there is no out-parameter.
export fn FOG_GetLinkIndex(linker: ?*Linker, code: u32, log_error: i32) callconv(.winapi) i32 {
    trace("FOG_GetLinkIndex @10213");
    const l = linker orelse return -1;
    const tbl = l.tbl orelse return -1;
    var lo: i32 = 0;
    var hi: i32 = l.size - 1;
    while (lo <= hi) {
        const mid = lo + @divTrunc(hi - lo, 2);
        const e = tbl[@intCast(mid)];
        if (e.code == code) return e.index;
        if (e.code < code) lo = mid + 1 else hi = mid - 1;
    }
    if (log_error != 0) sayFmt("  link: code 0x{x} not found", .{code});
    return -1;
}

/// Unpacks the four code bytes into the caller's buffer, `' '` becoming `'\0'`.
/// `szOut` must be at least 5 bytes — the fifth is always the terminator.
export fn FOG_GetStringFromLinkIndex(linker: ?*Linker, index: i32, out_str: ?[*]u8) callconv(.winapi) i32 {
    trace("FOG_GetStringFromLinkIndex @10214");
    const o = out_str orelse return 0;
    o[0] = 0;
    o[4] = 0;
    const l = linker orelse return 0;
    const tbl = l.tbl orelse return 0;
    var i: i32 = 0;
    while (i < l.size) : (i += 1) {
        const e = tbl[@intCast(i)];
        if (e.index != index) continue;
        for (0..4) |b| {
            const c: u8 = @truncate(e.code >> @intCast(b * 8));
            o[b] = if (c == ' ') 0 else c;
        }
        o[4] = 0;
        return 1;
    }
    return 0;
}

/// Grows by 0x40, keeps the table sorted by code, and returns the assigned index.
///
/// A duplicate code retries at `code + 1` until it finds a free one — which is the real Fog's own
/// behaviour (@10215 @0x6ff5b990), not a convenience: the binary loops `uVar6 = uVar6 + 1` around
/// its binary search until the insert succeeds. Two details of that loop are load-bearing and were
/// both wrong here:
///
///   - It **wraps**. The increment is a plain 32-bit add, so a table holding 0xFFFFFFFF (an empty
///     cell reads as one) rolls over to 0 and keeps going. Zig traps that, so this has to say `+%`
///     out loud. A 1.09d run reached it after 26 tables and panicked in our own Fog.
///   - It **loops rather than recurses**, which matters for the same input: rolling over from
///     0xFFFFFFFF can retry a great many times before it lands, and recursion would take the stack
///     with it.
///
/// The duplicate warning is likewise conditional in the original — only on the first attempt, and
/// only above 0x202020A0, so blank and low codes stay quiet instead of flooding the log.
export fn FOG_AddCodeToLinkingTable(linker: ?*Linker, code: u32) callconv(.winapi) i32 {
    trace("FOG_AddCodeToLinkingTable @10215");
    const l = linker orelse return -1;
    if (l.size >= l.capacity) {
        const want: usize = @intCast(l.capacity + LINK_GROW);
        const bytes = want * @sizeOf(CodeEntry);
        const grown = if (l.tbl) |t|
            HeapReAlloc(GetProcessHeap(), HEAP_ZERO, t, bytes)
        else
            HeapAlloc(GetProcessHeap(), HEAP_ZERO, bytes);
        l.tbl = @ptrCast(@alignCast(grown orelse return -1));
        l.capacity = @intCast(want);
    }
    const tbl = l.tbl.?;
    var want_code = code;
    while (true) {
        var at: i32 = 0;
        while (at < l.size and tbl[@intCast(at)].code < want_code) at += 1;
        if (at < l.size and tbl[@intCast(at)].code == want_code) {
            if (want_code == code and want_code > 0x202020a0)
                sayFmt("  link: duplicate code 0x{x}, retrying at +1", .{want_code});
            want_code +%= 1;
            continue;
        }
        var i: i32 = l.size;
        while (i > at) : (i -= 1) tbl[@intCast(i)] = tbl[@intCast(i - 1)];
        tbl[@intCast(at)] = .{ .code = want_code, .index = l.size };
        l.size += 1;
        return l.size - 1;
    }
}

/// Returns nothing: the binary leaves EAX undefined here, whatever D2MOO's prototype says.
/// A duplicate string is traced and dropped, but still consumes an index.
export fn FOG_AddRecordToLinkingTable(linker: ?*Linker, str: ?[*:0]const u8) callconv(.winapi) void {
    trace("FOG_AddRecordToLinkingTable @10216");
    const l = linker orelse return;
    const node: *StrNode = @ptrCast(@alignCast(heapZeroed(@sizeOf(StrNode)) orelse return));
    foldKey(&node.key, str);
    node.index = l.size;
    l.size += 1;

    var slot = &l.str;
    while (slot.*) |n| {
        const order = std.mem.order(u8, std.mem.sliceTo(&node.key, 0), std.mem.sliceTo(&n.key, 0));
        switch (order) {
            .lt => slot = &n.left,
            .gt => slot = &n.right,
            .eq => {
                sayFmt("  link: duplicate record \"{s}\"", .{cstr(str)});
                heapFree(node);
                return;
            },
        }
    }
    slot.* = node;
}

export fn FOG_GetRowFromTxt(linker: ?*Linker, text: ?[*:0]const u8, log_error: i32) callconv(.winapi) i32 {
    trace("FOG_GetRowFromTxt @10217");
    const l = linker orelse return -1;
    var key: [0x20]u8 = undefined;
    foldKey(&key, text);
    const want = std.mem.sliceTo(&key, 0);
    var node = l.str;
    while (node) |n| {
        switch (std.mem.order(u8, want, std.mem.sliceTo(&n.key, 0))) {
            .lt => node = n.left,
            .gt => node = n.right,
            .eq => return n.index,
        }
    }
    if (log_error != 0 and want.len != 0 and !std.mem.eql(u8, want, "*")) {
        sayFmt("  link: row \"{s}\" not found", .{cstr(text)});
    }
    return -1;
}

/// The reverse of 10217 by shape — `char* (pLinker, nIndex, ...)` in the linker's address range.
/// Not in the spec table, so it is inferred: walk the tree for the node holding `index`.
fn findByIndex(node: ?*StrNode, index: i32) ?*StrNode {
    const n = node orelse return null;
    if (n.index == index) return n;
    return findByIndex(n.left, index) orelse findByIndex(n.right, index);
}

export fn FOG_10255(linker: ?*Linker, index: i32, unused: i32) callconv(.winapi) ?[*]u8 {
    _ = unused;
    trace("FOG_10255 (string from row, inferred)");
    const l = linker orelse return null;
    const n = findByIndex(l.str, index) orelse return null;
    return &n.key;
}

// ── calc expressions ─────────────────────────────────────────────────────────
//
// Both stdcall with six arguments. Compiling to nothing means every formula evaluates to 0, which
// is wrong but visible; the real parser lives in libd2 and lands here as a body change.

export fn DATATBLS_CalcEvaluateExpression(
    ast: ?*anyopaque,
    ast_size: i32,
    param_cb: ?*anyopaque,
    table: ?*anyopaque,
    table_size: i32,
    user: ?*anyopaque,
) callconv(.winapi) i32 {
    _ = ast;
    _ = ast_size;
    _ = param_cb;
    _ = table;
    _ = table_size;
    _ = user;
    trace("DATATBLS_CalcEvaluateExpression @10253");
    return 0;
}

export fn DATATBLS_CompileExpression(
    formula: ?[*:0]const u8,
    ast_out: ?*anyopaque,
    ast_size: i32,
    name_to_id: ?*anyopaque,
    param_count: ?*anyopaque,
    link_parse: ?*anyopaque,
) callconv(.winapi) i32 {
    _ = ast_out;
    _ = ast_size;
    _ = name_to_id;
    _ = param_count;
    _ = link_parse;
    trace("DATATBLS_CompileExpression @10254");
    sayFmt("  formula: {s}", .{cstr(formula)});
    return 0;
}

pub fn DllMain(inst: ?*anyopaque, reason: u32, reserved: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL {
    _ = inst;
    _ = reserved;
    if (reason == 1) say("fog: our Fog.dll attached");
    return .TRUE;
}

/// mingw auto-exports every `export fn` again under its decorated name, numbered from just above
/// the highest ordinal in the .def. Unpinned they land on 10259+, and real 1.10f Fog exports up to
/// 10264 — so 10259-10264 would resolve to an alias instead of failing, which is a silently wrong
/// call rather than a load error. This sentinel puts them out of reach of any real Fog ordinal.
export fn FOG_ordinal_ceiling() callconv(.winapi) u32 {
    return 0;
}
