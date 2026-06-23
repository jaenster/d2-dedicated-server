//! Headless survival patches for retail 1.14d Game.exe. Lets the host run with no
//! display/sprites so the server thread can drive the engine. Addresses absolute
//! @ base 0x00400000.
//!
//! `apply()` = safety patches (always) + rendering/media stubs (headless). Call
//! once from DllMain, before the client code runs.
const std = @import("std");
const win = std.os.windows;
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?win.HINSTANCE;
extern "kernel32" fn GetProcAddress(h: win.HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const MemoryPatch = patch.MemoryPatch; // Charon-style fluent patch builder

pub fn install() void {
    applySafety();
    applyHeadlessRendering();
    log.print("headless: patches applied");
}

fn applySafety() void {
    // DC6 null safety: CELCMP_FixupPointersAndPrepare — repoint the jz operand at 0x00601349.
    _ = MemoryPatch(0x00601349).jumpEq(@intFromPtr(&celcmpNullHandler)).commit();
    // IMAGE_GetFramesCount null guard — jmp our guard + 1 NOP pad.
    _ = MemoryPatch(0x006019F0).jump(@intFromPtr(&imageGetFramesCountGuard)).nops(1).commit();
    // BNGatewayAccess::Load — halts if Realms.bin missing → ret 4.
    _ = MemoryPatch(0x005186d0).retImm(4).commit();
    // CLIENT_ConnectToBattleNet → xor eax,eax; ret.
    _ = MemoryPatch(0x0043BF60).xorEaxEax().ret().commit();

    hookExitProcess();
}

fn applyHeadlessRendering() void {
    // Hide the game window — NOP the ShowWindow call (9 bytes).
    _ = MemoryPatch(0x004F585A).nops(9).commit();

    // Renderers: nothing draws.
    _ = MemoryPatch(0x004F98E0).ret().commit(); // RENDERER_DrawOutOfGameScene
    _ = MemoryPatch(0x0044C990).retImm(4).commit(); // InGameDraw stdcall 1 arg

    // Char select without DC6 sprites.
    _ = MemoryPatch(0x005066C0).xorEaxEax().retImm(0x10).commit(); // AllocCharSelectComponent → NULL
    _ = MemoryPatch(0x00438D8B).jump(@intFromPtr(&parseSaveSkipAnimHandler)).commit();
    _ = MemoryPatch(0x005041BC).bytes(&[_]u8{ 0x5E, 0x59, 0x5D, 0xC2, 0x08, 0x00 }).commit(); // D2COMP_DestroyCompositeUnit NULL → pop esi/ecx/ebp; ret 8
    _ = MemoryPatch(0x00438560).ret().commit(); // DRAW_LocalCharsInSelectionScreen0
    _ = MemoryPatch(0x00439210).xorEaxEax().ret().commit(); // CHARSEL_UpdateSelectedCharDisplay

    _ = MemoryPatch(0x004565E0).ret().commit(); // Draw_UI_LoadGame
    _ = MemoryPatch(0x0044F017).nops(6).commit(); // CurrentDrawFunction call in CLIENT_GameLoopFrame
    _ = MemoryPatch(0x0044F28B).nops(6).commit();

    // Missing media files.
    _ = MemoryPatch(0x004FB1E0).xorEaxEax().retImm(8).commit(); // D2WINPAL_LoadPaletteFiles
    _ = MemoryPatch(0x00609AA0).ret().commit(); // TILECMP_Generate25SubTiles
    _ = MemoryPatch(0x00505550).ret().commit(); // D2COMP_LoadAllItemPalettes
    _ = MemoryPatch(0x00600B80).ret().commit(); // PALETTE_InitItemPalettes
    _ = MemoryPatch(0x005137E0).retImm(4).commit(); // BINK
    _ = MemoryPatch(0x005136F0).ret().commit();
}

// ── ExitProcess interceptor: log where the host tried to die ─────────────────
// Set true by the d2gs server thread once it reaches its tick loop. Until then a
// host exit(0) is PREMATURE — the headless engine-init returned before the server
// came up. We turn that silent success-exit into a loud non-zero failure so an
// orchestrator (k8s) treats the restart as meaningful instead of a quiet 0-exit loop.
pub var server_ready: bool = false;
// Sentinel exit code for a premature pre-server exit (ASCII 'E').
pub const premature_exit_code: u32 = 0x45;

var exit_process_addr: usize = 0;
var exit_process_original: [5]u8 = undefined;

fn hookExitProcess() void {
    const kernel32 = GetModuleHandleA("kernel32.dll") orelse return;
    const proc = GetProcAddress(kernel32, "ExitProcess") orelse return;
    exit_process_addr = @intFromPtr(proc);
    const src: [*]const u8 = @ptrFromInt(exit_process_addr);
    @memcpy(&exit_process_original, src[0..5]);
    _ = MemoryPatch(exit_process_addr).jump(@intFromPtr(&exitProcessInterceptor)).commit();
}

fn exitProcessInterceptor(exit_code: u32) callconv(.winapi) noreturn {
    var code = exit_code;
    if (!server_ready and exit_code == 0) {
        log.print("headless: FATAL — host exited before the d2gs server was ready (premature engine-init exit)");
        code = premature_exit_code; // fail loud so the orchestrator restarts on a real error
    }
    log.print("headless: ExitProcess called");
    log.hex("headless: exit code 0x", code);
    // restore original prologue and call through
    var ob: [5]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) ob[i] = exit_process_original[i];
    _ = MemoryPatch(exit_process_addr).bytes(&ob).commit();
    const realExit: *const fn (u32) callconv(.winapi) noreturn = @ptrFromInt(exit_process_addr);
    realExit(code);
}

// ── naked handlers (AT&T, absolute targets) ──────────────────────────────────
fn celcmpNullHandler() callconv(.naked) void {
    asm volatile (
        \\mov 0x0C(%%ebp), %%eax
        \\movl $0, (%%eax)
        \\pop %%esi
        \\pop %%ebp
        \\ret $0x18
    );
}

fn imageGetFramesCountGuard() callconv(.naked) void {
    asm volatile (
        \\push %%ebp
        \\mov %%esp, %%ebp
        \\mov 0x08(%%ebp), %%eax
        \\test %%eax, %%eax
        \\jnz 1f
        \\xor %%eax, %%eax
        \\pop %%ebp
        \\ret $0x04
        \\1:
        \\push $0x006019F6
        \\ret
    );
}

fn parseSaveSkipAnimHandler() callconv(.naked) void {
    asm volatile (
        \\test %%eax, %%eax
        \\jnz 1f
        \\push $0x00438DD6
        \\ret
        \\1:
        \\push $0x00438DAC
        \\ret
    );
}
