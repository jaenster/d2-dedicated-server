//! Vectored exception handler — logs the faulting address of access violations
//! so engine crashes can be mapped back to a function in Ghidra. Runs before the
//! game's own SEH, and continues the search (we only observe, don't swallow).

const std = @import("std");
const win = std.os.windows;
const log = @import("../log.zig");

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
    }
    return 0; // EXCEPTION_CONTINUE_SEARCH
}

pub fn install() void {
    _ = AddVectoredExceptionHandler(1, handler);
}
