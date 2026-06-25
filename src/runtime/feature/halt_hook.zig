//! Hook Fog::ErrorManager::ERROR_UnrecoverableInternalError_Halt @0x00408a60 to
//! log the asserting caller (return address) + line before the process exits.
//! Diagnostic only — maps engine asserts back to a function in Ghidra.

const patch = @import("../patch.zig");
const log = @import("../../log.zig");

const HALT_ADDR: usize = 0x00408a60;

// FOG top-level unhandled-exception filter (the SetUnhandledExceptionFilter target) —
// the function that shows the "application encountered an unexpected error" Blizzard
// dialog on a hard crash (access violation etc.). We replace its entry so an unhandled
// crash exits SILENTLY instead of popping the dialog. Always on, no flag.
const EXC_FILTER_ADDR: usize = 0x00403e90;

extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

/// When true, asserts are SWALLOWED (Halt returns to its caller) instead of
/// exiting — lets the engine continue past a recoverable assert (e.g. the
/// version-check download state machine). Set via enableSuppress().
var suppress: bool = false;
pub fn enableSuppress() void {
    suppress = true;
    log.print("halt: suppress mode ON (asserts will be swallowed)");
}

fn logHalt(retaddr: usize, nLine: usize) callconv(.c) void {
    log.hex("halt: assert caller=0x", retaddr);
    log.hex("halt: nLine=0x", nLine);
}

fn finish() callconv(.c) noreturn {
    ExitProcess(0xFFFF_FFFF);
}

/// Replaces the engine's crash-dialog filter: log the crash and exit silently, so the
/// Blizzard "unexpected error" popup never appears (vectored crash.zig already logged
/// the faulting address). Runs for every unhandled crash; no flag.
fn noCrashDialog() callconv(.c) noreturn {
    log.print("crash: Blizzard error dialog suppressed — exiting silently");
    ExitProcess(0xC0000005);
}

// On entry to Halt: [esp]=caller return addr, [esp+4]=msg, [esp+8]=addr, [esp+0xc]=nLine.
// ERROR_Halt is cdecl (caller cleans args), so swallowing = a plain `ret`.
fn handler() callconv(.naked) void {
    asm volatile (
        \\mov (%%esp), %%eax
        \\mov 0xc(%%esp), %%edx
        \\push %%edx
        \\push %%eax
        \\call %[f:P]
        \\add $8, %%esp
        \\mov %[flag], %%eax
        \\movb (%%eax), %%al
        \\testb %%al, %%al
        \\jnz 1f
        \\call %[fin:P]
        \\1:
        \\ret
        :
        : [f] "X" (&logHalt),
          [fin] "X" (&finish),
          [flag] "X" (&suppress),
    );
}

pub fn install() void {
    _ = patch.MemoryPatch(HALT_ADDR).jump(@intFromPtr(&handler)).commit();
    // Override the engine's crash-dialog filter so the Blizzard "unexpected error"
    // popup never appears — an unhandled crash exits silently after we've logged it.
    _ = patch.MemoryPatch(EXC_FILTER_ADDR).jump(@intFromPtr(&noCrashDialog)).commit();
    log.print("halt: crash dialog suppressed (no Blizzard error popup)");
}
