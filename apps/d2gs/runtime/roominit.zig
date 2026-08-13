//! Server RoomInit driver — fans out the per-game `roomInit` hook with a real
//! per-game GameCtx (the game's own FOG pool). Ported from Charon's RoomInit.cpp.
//!
//! Hooks SUNITINACTIVE_RoomInit @0x542b40 (__fastcall(D2GameStrc* ECX,
//! D2RoomStrc* EDX), verified in recon session 9df5e900). We JMP the entry to our
//! hook; the hook runs the original via a relocated-prologue stub, then fans out.
//! The original's first 6 bytes are position-independent:
//!   55        push ebp
//!   8b ec     mov ebp, esp
//!   83 ec 18  sub esp, 0x18
//! so the relocated stub just re-emits them and continues the original at +6.
//!
//! This is a driver (like runtime/gameloop.zig), not a registry feature. It fires
//! in-game on the server, so it's installed from the GS boot path.
const patch = @import("patch.zig");
const log = @import("../log.zig");
const feature = @import("../engine/feature.zig");
const d2types = @import("../engine/d2types.zig");

const ROOMINIT: usize = 0x00542b40;
const ROOMINIT_REJOIN: usize = 0x00542b46; // original entry + 6 (after the relocated prologue)

/// Relocated original prologue, then continue the original at +6. Calling this is
/// equivalent to invoking the original RoomInit (ECX/EDX still hold pGame/pRoom).
fn roomInitRelocated() callconv(.naked) void {
    asm volatile (
        \\push %ebp
        \\mov %esp, %ebp
        \\sub $0x18, %esp
        \\push $0x00542b46
        \\ret
    );
}

/// Entry hook (reached via JMP, so ECX=pGame, EDX=pRoom): run the original, then
/// call our cdecl handler with (pGame, pRoom), then return to the caller.
fn roomInitHook() callconv(.naked) void {
    asm volatile (
        \\push %ecx
        \\push %edx
        \\call %[reloc:P]
        \\pop %edx
        \\pop %ecx
        \\push %edx
        \\push %ecx
        \\call %[handler:P]
        \\add $8, %esp
        \\ret
        :
        : [reloc] "X" (&roomInitRelocated),
          [handler] "X" (&roomInitHandler),
    );
}

fn roomInitHandler(pGame: *d2types.D2GameStrc, pRoom: *d2types.D2RoomStrc) callconv(.c) void {
    const pool = pGame.pMemoryPool orelse return; // no pool → can't build a game ctx
    const ctx = feature.gameCtx(pGame, pool);
    feature.fanRoomInit(&ctx, @ptrCast(pRoom));
}

pub fn install() void {
    comptime {
        if (ROOMINIT_REJOIN != ROOMINIT + 6) @compileError("rejoin must be entry+6 (prologue length)");
    }
    if (patch.MemoryPatch(ROOMINIT).jump(@intFromPtr(&roomInitHook)).nops(1).commit()) {
        log.print("roominit: SUNITINACTIVE_RoomInit hooked (fans out roomInit)");
    } else {
        log.print("roominit: FAILED to hook RoomInit");
    }
}
