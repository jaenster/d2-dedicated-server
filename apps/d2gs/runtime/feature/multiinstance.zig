//! Multi-instance patch (d2bs's `Multi`). D2GFX_CreateWindow @0x4F5610 calls FindWindowA
//! @0x4F5623 to detect an already-running copy and bails with "Only one copy..." — trips
//! when GS + client run together. Like d2bs, we PatchCall (D2Gfx.DLL+0xF5623, len 6) with
//! a stub returning 0 ("no other window"). FindWindowA is __stdcall(2 args, 8 bytes), so
//! the stub must `ret 8` to keep the stack balanced.
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

const FINDWINDOW_CALL: usize = 0x004F5623; // call dword [FindWindowA]

fn multiStub() callconv(.naked) void {
    asm volatile (
        \\xor %%eax, %%eax
        \\ret $8
    );
}

pub fn install() void {
    // call our stub + 1 NOP to pad the original 6-byte call site.
    if (patch.MemoryPatch(FINDWINDOW_CALL).call(@intFromPtr(&multiStub)).nops(1).commit()) {
        log.print("multi: single-instance check bypassed (FindWindowA -> 0)");
    } else {
        log.print("multi: FAILED to patch single-instance check");
    }
}
