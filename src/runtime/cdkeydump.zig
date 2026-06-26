//! Dump the client's decoded CD-key strings (debug/verification only, gated by
//! --dump-cdkeys). The game's DecodeAndLoadKeys (@0x5234d0) decodes the obfuscated
//! key files into the globals D2Client::_CdKey::KeyClassic (@0x882744) and
//! KeyExpansion (@0x88274c) — pointers to plaintext key strings, populated during
//! the Battle.net connect. We poll until they're set and log them, so we can feed
//! the SAME keys to src/realm/shared/cdkey.zig and verify our clientless decode
//! against the AUTH_CHECK the game actually sends. See [[d2-cdkey-extraction]].
const std = @import("std");
const log = @import("../log.zig");

extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const KeyClassic: *const ?[*:0]const u8 = @ptrFromInt(0x882744); // 0x400000 + RVA 0x482744
const KeyExpansion: *const ?[*:0]const u8 = @ptrFromInt(0x88274c);
// D2Client::_net_sid::DecodeAndLoadKeys — __stdcall, no args (no-arg stdcall == cdecl at the
// call site). Decodes the obfuscated key files into the globals. NOT auto-called in our flow,
// so we force it like D2Launcher's DumpCdKeys. It ERROR_Halts if keys are already loaded, so
// only call it while KeyClassic is null.
const DecodeAndLoadKeys: *const fn () callconv(.c) void = @ptrFromInt(0x5234D0);

fn thread(_: ?*anyopaque) callconv(.winapi) u32 {
    Sleep(6000); // let the game init Storm/MPQ first (D2Launcher uses WaitForInputIdle)
    if (KeyClassic.* == null) {
        log.print("cdkeydump: forcing DecodeAndLoadKeys()");
        DecodeAndLoadKeys();
        Sleep(500);
    }
    if (KeyClassic.*) |kc| {
        log.cstr("cdkeydump: classic=", @intFromPtr(kc));
        if (KeyExpansion.*) |ke| log.cstr("cdkeydump: expansion=", @intFromPtr(ke));
    } else {
        log.print("cdkeydump: KeyClassic still null after DecodeAndLoadKeys");
    }
    return 0;
}

pub fn install() void {
    _ = CreateThread(null, 0, thread, null, 0, null);
    log.print("cdkeydump: watching for decoded CD keys");
}
