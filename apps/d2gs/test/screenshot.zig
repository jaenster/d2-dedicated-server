//! Periodic screenshot capture via the game's own D2WIN_TakeScreenshot @0x4FA7A0,
//! which writes Screenshot%03d.jpg to the game CWD. Lets us SEE the client's
//! screen (login form, errors, realm/char screens) for debugging. Found in d2bs
//! (D2WIN_TakeScreenshot, 1.14d). See [[d2-ui-controls]].
const std = @import("std");
const log = @import("../log.zig");

extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

// void __fastcall D2WIN_TakeScreenshot(void) — no args, so a plain call is fine.
const TakeScreenshot: *const fn () callconv(.c) void = @ptrFromInt(0x004FA7A0);

fn thread(_: ?*anyopaque) callconv(.winapi) u32 {
    while (true) {
        Sleep(3000);
        TakeScreenshot();
        log.print("screenshot: captured (Screenshot###.jpg in game dir)");
    }
}

pub fn install() void {
    _ = CreateThread(null, 0, thread, null, 0, null);
    log.print("screenshot: capture thread started (every 3s)");
}
