//! Multi-instance patch (d2bs's `Multi`). D2GFX_CreateWindow @0x4F5610 calls
//! FindWindowA @0x4F5623 to detect an already-running copy and, if found, shows
//! "Only one copy of Diablo II may run at a time." and bails. Running the
//! headless GS + the client at once trips it. d2bs PatchCall's that call
//! (D2Gfx.DLL+0xF5623, len 6); we replace it with a stub that returns 0 ("no
//! other window") so the check always passes — both copies run.
//!
//! FindWindowA is __stdcall(lpClassName, lpWindowName) — 2 args pushed before the
//! call (8 bytes), so the stub must `ret 8` to keep the stack balanced.
const patch = @import("patch.zig");
const log = @import("../log.zig");

const FINDWINDOW_CALL: usize = 0x004F5623; // call dword [FindWindowA]

fn multiStub() callconv(.naked) void {
    asm volatile (
        \\xor %%eax, %%eax
        \\ret $8
    );
}

pub fn apply() void {
    if (patch.writeCall(FINDWINDOW_CALL, @intFromPtr(&multiStub))) {
        _ = patch.writeNops(FINDWINDOW_CALL + 5, 1); // pad the 6-byte call site
        log.print("multi: single-instance check bypassed (FindWindowA -> 0)");
    } else {
        log.print("multi: FAILED to patch single-instance check");
    }
}
