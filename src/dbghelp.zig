//! dbghelp.dll proxy — the injection foothold.
//!
//! Game.exe loads `dbghelp.dll` dynamically for its crash handler. With
//! `WINEDLLOVERRIDES="dbghelp=n"` (or this DLL sitting next to Game.exe on real
//! Windows), our build loads instead of the system one. On attach we:
//!   1. resolve the real system dbghelp and forward the handful of exports the
//!      game's crash handler calls (each exported name tail-jumps to the real fn),
//!   2. parse `--loaddll <winpath>` from the command line and LoadLibrary each —
//!      this is how `d2gs.dll` (and any extra mod DLLs) get into the process.
//!
//! Builds to `dbghelp.dll` (see build.zig). No external dependencies.

const std = @import("std");
const win = std.os.windows;
const log = @import("log.zig");

const HMODULE = win.HINSTANCE;
const BOOL = win.BOOL;
const LPCSTR = [*:0]const u8;
const LPCWSTR = [*:0]const u16;
const LPWSTR = [*:0]u16;
const FARPROC = *const fn () callconv(.winapi) isize;
const MAX_PATH = 260;

extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryW(name: LPCWSTR) callconv(.winapi) ?HMODULE;
extern "kernel32" fn FreeLibrary(h: HMODULE) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcAddress(h: HMODULE, name: LPCSTR) callconv(.winapi) ?FARPROC;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;
extern "kernel32" fn DisableThreadLibraryCalls(h: HMODULE) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "shell32" fn CommandLineToArgvW(cmd: LPWSTR, pNumArgs: *c_int) callconv(.winapi) ?[*]LPWSTR;

// dbghelp exports the game's crash handler resolves via GetProcAddress.
const forwarded_names = [_][:0]const u8{
    "StackWalk",
    "SymCleanup",
    "SymFunctionTableAccess",
    "SymGetModuleBase",
    "SymGetSymFromAddr",
    "SymInitialize",
    "SymSetOptions",
    "UnDecorateSymbolName",
    "MiniDumpWriteDump",
};

var real_dbghelp: ?HMODULE = null;
var resolved: [forwarded_names.len]usize = .{0} ** forwarded_names.len;

fn loadRealDbgHelp() ?HMODULE {
    if (real_dbghelp) |h| return h;
    var dir: [MAX_PATH]u16 = undefined;
    const len = GetSystemDirectoryW(&dir, MAX_PATH);
    if (len == 0) return null;
    var path: [MAX_PATH]u16 = undefined;
    var i: usize = 0;
    for (dir[0..len]) |c| {
        path[i] = c;
        i += 1;
    }
    const suffix = comptime std.unicode.utf8ToUtf16LeStringLiteral("\\dbghelp.dll");
    for (suffix) |c| {
        path[i] = c;
        i += 1;
    }
    path[i] = 0;
    real_dbghelp = LoadLibraryW(@ptrCast(&path));
    return real_dbghelp;
}

fn resolveForwarders() void {
    const h = loadRealDbgHelp() orelse return;
    inline for (forwarded_names, 0..) |name, i| {
        if (GetProcAddress(h, name.ptr)) |proc| resolved[i] = @intFromPtr(proc);
    }
}

/// One naked tail-jump per forwarded export. `jmp *resolved[idx]` reads the
/// resolved real pointer from memory and jumps — no compiler-inserted code, so
/// it's safe in a naked function.
fn Forwarder(comptime idx: usize) type {
    return struct {
        fn jump() callconv(.naked) void {
            asm volatile ("jmp *%[p]"
                :
                : [p] "m" (resolved[idx]),
            );
        }
    };
}

comptime {
    for (forwarded_names, 0..) |name, i| {
        @export(&Forwarder(i).jump, .{ .name = name, .linkage = .strong });
    }
}

fn eqlW(a: [*:0]const u16, comptime lit: []const u8) bool {
    const b = comptime std.unicode.utf8ToUtf16LeStringLiteral(lit);
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = if (a[i] >= 'A' and a[i] <= 'Z') a[i] + 32 else a[i];
        const cb = b[i]; // lit is already lowercase
        if (ca != cb) return false;
        if (cb == 0) return true;
    }
}

fn loadInjectedDlls() void {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return;
    defer _ = LocalFree(@ptrCast(argv));
    var i: usize = 0;
    while (i + 1 < @as(usize, @intCast(argc))) : (i += 1) {
        if (eqlW(argv[i], "--loaddll")) {
            if (LoadLibraryW(argv[i + 1]) == null) {
                log.hex("dbghelp_proxy: LoadLibrary failed, err=0x", GetLastError());
            } else {
                log.print("dbghelp_proxy: injected DLL loaded");
            }
            i += 1;
        }
    }
}

pub export fn DllMain(hModule: HMODULE, reason: u32, _: ?*anyopaque) callconv(.winapi) BOOL {
    if (reason == 1) { // DLL_PROCESS_ATTACH
        _ = DisableThreadLibraryCalls(hModule);
        log.initConsole();
        log.print("dbghelp_proxy: attach");
        resolveForwarders();
        log.print("dbghelp_proxy: forwarders resolved");
        loadInjectedDlls();
        log.print("dbghelp_proxy: injected DLLs processed");
    } else if (reason == 0) { // DLL_PROCESS_DETACH
        if (real_dbghelp) |h| {
            _ = FreeLibrary(h);
            real_dbghelp = null;
        }
    }
    return win.BOOL.TRUE;
}
