//! D2 GameCrashFix — the well-known d2bs stability patch.
//!
//! At D2CMP.dll+0x2091E5 (= 0x006091E5 in 1.14d's statically-linked Game.exe) the
//! engine does `MOV [ECX+0x10], EDX` where ECX can be null → access violation,
//! which pops the modal "unexpected error" dialog. d2bs PatchCall's it with an
//! intercept that guards the deref:
//!   CMP ECX,0 / JE skip / MOV [ECX+0x10],EDX / skip: MOV [EAX+0xC],0 / RET
//! so the game keeps running instead of crashing into the UI.
const patch = @import("patch.zig");
const log = @import("../log.zig");

const PATCH_ADDR: usize = 0x006091E5;

fn intercept() callconv(.naked) void {
    asm volatile (
        \\test %%ecx, %%ecx
        \\je 1f
        \\mov %%edx, 0x10(%%ecx)
        \\1:
        \\movl $0, 0xc(%%eax)
        \\ret
    );
}

pub fn apply() void {
    if (patch.writeCall(PATCH_ADDR, @intFromPtr(&intercept))) {
        _ = patch.writeNops(PATCH_ADDR + 5, 5); // d2bs uses a 10-byte patch region
        log.print("gamecrashfix: D2CMP null-deref guard installed @0x6091E5");
    } else {
        log.print("gamecrashfix: FAILED to patch @0x6091E5");
    }
}
