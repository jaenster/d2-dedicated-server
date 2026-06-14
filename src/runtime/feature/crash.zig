//! Vectored exception handler — logs the faulting address of access violations
//! so engine crashes can be mapped back to a function in Ghidra. Runs before the
//! game's own SEH, and continues the search (we only observe, don't swallow).

const std = @import("std");
const win = std.os.windows;
const log = @import("../../log.zig");

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
            log.hex("crash: esp=0x", esp);
            log.hex("crash: ebp=0x", ctxU32(ctx, CTX_EBP));
            log.hex("crash: eax=0x", ctxU32(ctx, CTX_EAX));
            log.hex("crash: ecx=0x", ctxU32(ctx, CTX_ECX));
            if (esp != 0) log.hex("crash: [esp]=ret=0x", @as(*const u32, @ptrFromInt(esp)).*);
        }
    }
    return 0; // EXCEPTION_CONTINUE_SEARCH
}

pub fn install() void {
    _ = AddVectoredExceptionHandler(1, handler);
}
