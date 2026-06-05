//! Hook Fog::ErrorManager::ERROR_UnrecoverableInternalError_Halt @0x00408a60 to
//! log the asserting caller (return address) + line before the process exits.
//! Diagnostic only — maps engine asserts back to a function in Ghidra.

const patch = @import("patch.zig");
const log = @import("../log.zig");

const HALT_ADDR: usize = 0x00408a60;

extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

fn logHalt(retaddr: usize, nLine: usize) callconv(.c) void {
    log.hex("halt: assert caller=0x", retaddr);
    log.hex("halt: nLine=0x", nLine);
}

fn finish() callconv(.c) noreturn {
    ExitProcess(0xFFFF_FFFF);
}

// On entry to Halt: [esp]=caller return addr, [esp+4]=msg, [esp+8]=addr, [esp+0xc]=nLine.
fn handler() callconv(.naked) void {
    asm volatile (
        \\mov (%%esp), %%eax
        \\mov 0xc(%%esp), %%edx
        \\push %%edx
        \\push %%eax
        \\call %[f:P]
        \\add $8, %%esp
        \\call %[fin:P]
        :
        : [f] "X" (&logHalt),
          [fin] "X" (&finish),
    );
}

pub fn install() void {
    _ = patch.writeJump(HALT_ADDR, @intFromPtr(&handler));
}
