//! Deferred injection of blizzhackers D2BS.dll (kolbot's bot engine). Enabled by `--d2bs <winpath>`.
//!
//! D2BS's own loader expects an ALREADY-RUNNING D2 with a valid window (its startup thread calls
//! FindWindowW and reads engine globals at once). LoadLibrary at DLL_PROCESS_ATTACH (before the
//! window exists) throws an uncaught C++ exception (0xe06d7363) and kills Game.exe. So mirror the
//! loader: poll FindWindowA(NULL, "Diablo II") on a thread and LoadLibrary only once it's up.

const std = @import("std");
const log = @import("../log.zig");

const DWORD = u32;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateThread(
    a: ?*anyopaque,
    st: usize,
    f: *const fn (?*anyopaque) callconv(.winapi) DWORD,
    p: ?*anyopaque,
    fl: DWORD,
    id: ?*DWORD,
) callconv(.winapi) ?*anyopaque;
extern "user32" fn FindWindowA(class: ?[*:0]const u8, title: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;

// The DLL path (ANSI, null-terminated) copied out of the command line at install.
var dll_path: [512]u8 = undefined;
var dll_len: usize = 0;

fn loaderThread(_: ?*anyopaque) callconv(.winapi) DWORD {
    // Wait for the D2 game window. Both the class and the title are "Diablo II"
    // in 1.14d; match by title (class alone is unreliable across builds).
    var waited: u32 = 0;
    while (FindWindowA(null, "Diablo II") == null) {
        Sleep(200);
        waited +%= 200;
        // Cap the wait so a mis-titled/headless build doesn't spin forever; after the
        // cap, inject anyway (a headed client always has the window by then).
        if (waited >= 60_000) {
            log.print("d2bs: window not seen in 60s — injecting anyway");
            break;
        }
    }
    // Give the engine a moment past window-create so its globals are populated
    // (D2BS reads them in its startup thread the instant it attaches).
    Sleep(1500);

    const path: [*:0]const u8 = @ptrCast(&dll_path);
    if (LoadLibraryA(path) == null) {
        log.hex("d2bs: LoadLibrary failed, err=0x", GetLastError());
    } else {
        log.print("d2bs: D2BS.dll injected (post-window)");
    }
    return 0;
}

/// Arm the deferred D2BS injector with the ANSI Windows path to D2BS.dll.
pub fn install(win_path: []const u8) void {
    const n = @min(win_path.len, dll_path.len - 1);
    @memcpy(dll_path[0..n], win_path[0..n]);
    dll_path[n] = 0;
    dll_len = n;
    _ = CreateThread(null, 0, loaderThread, null, 0, null);
    log.print("d2bs: deferred injector armed (waits for game window)");
}
