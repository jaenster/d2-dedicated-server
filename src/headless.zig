//! Headless survival patches for retail 1.14d Game.exe. Lets the host run with no
//! display/sprites so the server thread can drive the engine. Addresses absolute
//! @ base 0x00400000.
//!
//! `apply()` = safety patches (always) + rendering/media stubs (headless). Call
//! once from DllMain, before the client code runs.
const std = @import("std");
const win = std.os.windows;
const patch = @import("patch.zig");
const log = @import("log.zig");

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?win.HINSTANCE;
extern "kernel32" fn GetProcAddress(h: win.HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

pub fn apply() void {
    applySafety();
    applyHeadlessRendering();
    log.print("headless: patches applied");
}

fn applySafety() void {
    // DC6 null safety: CELCMP_FixupPointersAndPrepare (0x00601340)
    const jz_addr: usize = 0x00601349;
    const rel = patch.calcRelAddr(jz_addr, @intFromPtr(&celcmpNullHandler), 6);
    const rel_bytes: [4]u8 = @bitCast(rel);
    _ = patch.writeBytes(jz_addr + 2, &rel_bytes);

    // IMAGE_GetFramesCount null guard (0x006019F0)
    const gf = patch.calcRelAddr(0x006019F0, @intFromPtr(&imageGetFramesCountGuard), 5);
    const gfb: [4]u8 = @bitCast(gf);
    _ = patch.writeBytes(0x006019F0, &[_]u8{ 0xE9, gfb[0], gfb[1], gfb[2], gfb[3], 0x90 });

    // BNGatewayAccess::Load (0x005186d0) — halts if Realms.bin missing → ret
    _ = patch.writeBytes(0x005186d0, &[_]u8{ 0xC2, 0x04, 0x00 });
    // CLIENT_ConnectToBattleNet (0x0043BF60) → xor eax,eax; ret
    _ = patch.writeBytes(0x0043BF60, &[_]u8{ 0x31, 0xC0, 0xC3 });

    hookExitProcess();
}

fn applyHeadlessRendering() void {
    // Hide the game window — NOP the ShowWindow call at 0x004F585A (9 bytes)
    _ = patch.writeNops(0x004F585A, 9);

    // Renderers: nothing draws
    _ = patch.writeBytes(0x004F98E0, &[_]u8{0xC3}); // RENDERER_DrawOutOfGameScene
    _ = patch.writeBytes(0x0044C990, &[_]u8{ 0xC2, 0x04, 0x00 }); // InGameDraw stdcall 1 arg

    // Char select without DC6 sprites
    _ = patch.writeBytes(0x005066C0, &[_]u8{ 0x31, 0xC0, 0xC2, 0x10, 0x00 }); // AllocCharSelectComponent → NULL
    const skip = patch.calcRelAddr(0x00438D8B, @intFromPtr(&parseSaveSkipAnimHandler), 5);
    const skb: [4]u8 = @bitCast(skip);
    _ = patch.writeBytes(0x00438D8B, &[_]u8{ 0xE9, skb[0], skb[1], skb[2], skb[3] });
    _ = patch.writeBytes(0x005041BC, &[_]u8{ 0x5E, 0x59, 0x5D, 0xC2, 0x08, 0x00 }); // D2COMP_DestroyCompositeUnit NULL → ret 8
    _ = patch.writeBytes(0x00438560, &[_]u8{0xC3}); // DRAW_LocalCharsInSelectionScreen0
    _ = patch.writeBytes(0x00439210, &[_]u8{ 0x31, 0xC0, 0xC3 }); // CHARSEL_UpdateSelectedCharDisplay

    _ = patch.writeBytes(0x004565E0, &[_]u8{0xC3}); // Draw_UI_LoadGame
    _ = patch.writeNops(0x0044F017, 6); // CurrentDrawFunction call in CLIENT_GameLoopFrame
    _ = patch.writeNops(0x0044F28B, 6);

    // Missing media files
    _ = patch.writeBytes(0x004FB1E0, &[_]u8{ 0x31, 0xC0, 0xC2, 0x08, 0x00 }); // D2WINPAL_LoadPaletteFiles
    _ = patch.writeBytes(0x00609AA0, &[_]u8{0xC3}); // TILECMP_Generate25SubTiles
    _ = patch.writeBytes(0x00505550, &[_]u8{0xC3}); // D2COMP_LoadAllItemPalettes
    _ = patch.writeBytes(0x00600B80, &[_]u8{0xC3}); // PALETTE_InitItemPalettes
    _ = patch.writeBytes(0x005137E0, &[_]u8{ 0xC2, 0x04, 0x00 }); // BINK
    _ = patch.writeBytes(0x005136F0, &[_]u8{0xC3});
}

// ── ExitProcess interceptor: log where the host tried to die ─────────────────
var exit_process_addr: usize = 0;
var exit_process_original: [5]u8 = undefined;

fn hookExitProcess() void {
    const kernel32 = GetModuleHandleA("kernel32.dll") orelse return;
    const proc = GetProcAddress(kernel32, "ExitProcess") orelse return;
    exit_process_addr = @intFromPtr(proc);
    const src: [*]const u8 = @ptrFromInt(exit_process_addr);
    @memcpy(&exit_process_original, src[0..5]);
    _ = patch.writeJump(exit_process_addr, @intFromPtr(&exitProcessInterceptor));
}

fn exitProcessInterceptor(exit_code: u32) callconv(.winapi) noreturn {
    log.print("headless: ExitProcess called");
    log.hex("headless: exit code 0x", exit_code);
    // restore original prologue and call through
    var ob: [5]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) ob[i] = exit_process_original[i];
    _ = patch.writeBytes(exit_process_addr, &ob);
    const realExit: *const fn (u32) callconv(.winapi) noreturn = @ptrFromInt(exit_process_addr);
    realExit(exit_code);
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
