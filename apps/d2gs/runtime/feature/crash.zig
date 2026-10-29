//! Vectored exception handler — logs the faulting address of access violations
//! so engine crashes can be mapped back to a function in Ghidra. Runs before the
//! game's own SEH, and continues the search (we only observe, don't swallow).

const std = @import("std");
const win = std.os.windows;
const log = @import("../../log.zig");
const srvtrace = @import("srvtrace.zig");

const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: ?*anyopaque,
    ExceptionAddress: usize,
    NumberParameters: u32,
    ExceptionInformation: [15]usize,
};
const EXCEPTION_POINTERS = extern struct {
    ExceptionRecord: *EXCEPTION_RECORD,
    ContextRecord: ?*anyopaque,
};

// x86 CONTEXT field offsets (ContextFlags@0, FloatSave@0x1c..0x8c, ints after).
const CTX_EDI = 0x9c;
const CTX_ESI = 0xa0;
const CTX_EBX = 0xa4;
const CTX_EDX = 0xa8;
const CTX_ECX = 0xac;
const CTX_EAX = 0xb0;
const CTX_EBP = 0xb4;
const CTX_EIP = 0xb8;
const CTX_ESP = 0xc4;

fn ctxU32(ctx: usize, off: usize) usize {
    return @as(*const u32, @ptrFromInt(ctx + off)).*;
}

extern "kernel32" fn AddVectoredExceptionHandler(
    first: u32,
    handler: *const fn (*EXCEPTION_POINTERS) callconv(.winapi) i32,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn IsBadReadPtr(p: ?*const anyopaque, n: usize) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleExA(flags: u32, addr: usize, out: *?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameA(m: ?*anyopaque, buf: [*]u8, n: u32) callconv(.winapi) u32;

/// Names the module an address lies in and its load base, so the fault maps to a symbol offset.
fn logModule(prefix: []const u8, addr: usize) void {
    var m: ?*anyopaque = null;
    if (GetModuleHandleExA(0x4 | 0x2, addr, &m) == 0 or m == null) {
        log.hex(prefix, 0);
        return;
    }
    var buf: [260]u8 = undefined;
    const n = GetModuleFileNameA(m, &buf, buf.len);
    log.hex(prefix, @intFromPtr(m.?));
    if (n > 0) log.print(buf[0..n]);
}

pub fn readable(addr: usize, n: usize) bool {
    return addr >= 0x10000 and IsBadReadPtr(@ptrFromInt(addr), n) == 0;
}

/// Where the engine was when it died, as addresses to look up in Ghidra: the saved-EBP chain (return addresses of the
/// frames that kept EBP) and the code addresses found on the stack above ESP (the frames that did not). Game.exe's
/// code is 0x401000-0x6EFFFF; anything else on the stack is data. Nothing here may fault: every read is probed.
pub fn stackTrace(tag: []const u8, esp: usize, ebp: usize) void {
    var prefix: [32]u8 = undefined;
    var ebp_walk = ebp;
    var frames: u32 = 0;
    while (frames < 24 and ebp_walk & 3 == 0 and readable(ebp_walk, 8)) : (frames += 1) {
        const next = @as(*const u32, @ptrFromInt(ebp_walk)).*;
        const ret = @as(*const u32, @ptrFromInt(ebp_walk + 4)).*;
        log.hex(std.mem.print(&prefix, "{s}: ebp frame ret=0x", .{tag}) catch tag, ret);
        if (next <= ebp_walk) break;
        ebp_walk = next;
    }
    var found: u32 = 0;
    var off: usize = 0;
    while (off < 4 * 256 and found < 24 and readable(esp + off, 4)) : (off += 4) {
        const v = @as(*const u32, @ptrFromInt(esp + off)).*;
        if (v >= 0x401000 and v < 0x6F0000) {
            log.hex(std.mem.print(&prefix, "{s}: stack code=0x", .{tag}) catch tag, v);
            found += 1;
        }
    }
}

/// The oracle's position (srvtrace.where): which seed, act, level and room the engine was building.
pub fn logWhere(tag: []const u8) void {
    const w = srvtrace.where;
    if (w.phase == 0) return;
    var buf: [200]u8 = undefined;
    log.print(std.mem.print(&buf, "{s}: map oracle at seed {d} difficulty {d} act {d} level {d} room {d},{d} phase {d}", .{ tag, w.seed, w.diff, w.act, w.level, w.room_x, w.room_y, w.phase }) catch tag);
}

fn handler(info: *EXCEPTION_POINTERS) callconv(.winapi) i32 {
    const rec = info.ExceptionRecord;
    // Only fatal exceptions (>= 0xC0000000): access violations, etc. Skip the
    // benign SEH/RPC codes wine and the game raise internally.
    if (rec.ExceptionCode >= 0xC000_0000) {
        log.hex("crash: code=0x", rec.ExceptionCode);
        log.hex("crash: fault addr=0x", rec.ExceptionAddress);
        if (rec.NumberParameters >= 2) {
            log.hex("crash: access type=0x", rec.ExceptionInformation[0]);
            log.hex("crash: target addr=0x", rec.ExceptionInformation[1]);
        }
        // On a null-pointer CALL the EIP is 0; [ESP] holds the return address
        // (the instruction right after the faulting CALL) — i.e. the caller.
        if (info.ContextRecord) |c| {
            const ctx = @intFromPtr(c);
            const esp = ctxU32(ctx, CTX_ESP);
            log.hex("crash: eip=0x", ctxU32(ctx, CTX_EIP));
            logModule("crash: eip module base=0x", ctxU32(ctx, CTX_EIP));
            log.hex("crash: esp=0x", esp);
            log.hex("crash: ebp=0x", ctxU32(ctx, CTX_EBP));
            log.hex("crash: eax=0x", ctxU32(ctx, CTX_EAX));
            log.hex("crash: ecx=0x", ctxU32(ctx, CTX_ECX));
            if (esp != 0) log.hex("crash: [esp]=ret=0x", @as(*const u32, @ptrFromInt(esp)).*);
            logWhere("crash");
            stackTrace("crash", esp, ctxU32(ctx, CTX_EBP));
        }
    }
    return 0; // EXCEPTION_CONTINUE_SEARCH
}

pub fn install() void {
    _ = AddVectoredExceptionHandler(1, handler);
}
