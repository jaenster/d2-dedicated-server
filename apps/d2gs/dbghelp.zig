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
const realmgw = @import("runtime/realmgw.zig");

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
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn FindWindowW(class: ?LPCWSTR, title: ?LPCWSTR) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, prot: u32, old: *u32) callconv(.winapi) BOOL;
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
    // Additional exports blizzhackers D2BS.dll resolves for its own crash reporter
    // (were "not found in dbghelp.dll" when D2BS side-loads through this proxy).
    "SymGetLineFromAddr",
    "SymGetModuleInfo",
    "SymGetOptions",
    "SymLoadModule",
    "SymUnloadModule",
    "SymGetSearchPath",
    "SymSetSearchPath",
    "SymFromAddr",
    "SymGetLineFromAddr64",
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

// Deferred D2BS injection (--d2bs <winpath>). D2BS's DllMain startup thread calls
// FindWindow and reads engine globals the instant it attaches, so LoadLibrary'ing it
// pre-WinMain (via --loaddll, before the window exists) makes it throw 0xe06d7363 and
// kill Game.exe. We mirror D2BS's own `--inject <pid>` loader: a thread waits for the
// game window, THEN LoadLibrary's it. This lets a STOCK client run kolbot with only
// D2BS.dll injected — no d2gs.dll (its gateway/checkrev/no-compress patches aren't
// needed: point the client at realmd via the registry gateway; realmd passes checkrev
// natively and the client obeys the server's 0xAF greeting for compression).
var d2bs_path: [512]u16 = undefined;

fn d2bsLoaderThread(_: ?*anyopaque) callconv(.winapi) u32 {
    const title = comptime std.unicode.utf8ToUtf16LeStringLiteral("Diablo II");
    var waited: u32 = 0;
    while (FindWindowW(null, title) == null) {
        Sleep(200);
        waited +%= 200;
        if (waited >= 60_000) {
            log.print("dbghelp_proxy: d2bs window not seen in 60s — injecting anyway");
            break;
        }
    }
    Sleep(1500); // let the engine populate its globals past window-create
    if (LoadLibraryW(@ptrCast(&d2bs_path)) == null) {
        log.hex("dbghelp_proxy: D2BS LoadLibrary failed, err=0x", GetLastError());
    } else {
        log.print("dbghelp_proxy: D2BS.dll injected (post-window)");
    }
    return 0;
}

fn armD2bs(win_path: LPCWSTR) void {
    var i: usize = 0;
    while (win_path[i] != 0 and i < d2bs_path.len - 1) : (i += 1) d2bs_path[i] = win_path[i];
    d2bs_path[i] = 0;
    _ = CreateThread(null, 0, d2bsLoaderThread, null, 0, null);
    log.print("dbghelp_proxy: deferred D2BS injector armed (waits for game window)");
}

// Work around WineHQ bug 44360: D2 1.14 hits Fog's unrecoverable-internal-error Halt
// (@0x408a60) right after Battle.net login (realm/char-select transition) under wine —
// reproduces against real Battle.net too, so it's a wine bug in D2's post-login path, not
// the server. ERROR_Halt is cdecl (caller cleans args), so overwriting its entry with a
// bare RET (0xC3) makes every assert a no-op return and lets the engine continue — the same
// survive-the-assert behaviour d2gs.dll's halt_hook provides. Opt-in via --suppress-halt so
// a stock client needs NO d2gs.dll. (The Game.exe image is mapped by the time dbghelp
// attaches, so patching its code here is safe.)
const HALT_ADDR: usize = 0x00408a60;

/// Overwrite `bytes` at code address `addr` (RWX during the write, restored after).
/// Game.exe's image is mapped by the time dbghelp attaches, so this is safe here.
fn patchBytes(addr: usize, bytes: []const u8) bool {
    const p: *anyopaque = @ptrFromInt(addr);
    var old: u32 = 0;
    if (VirtualProtect(p, bytes.len, 0x40, &old) == win.BOOL.FALSE) return false; // PAGE_EXECUTE_READWRITE
    const dst: [*]volatile u8 = @ptrFromInt(addr);
    for (bytes, 0..) |b, i| dst[i] = b;
    _ = VirtualProtect(p, bytes.len, old, &old);
    return true;
}

fn suppressHalt() void {
    if (patchBytes(HALT_ADDR, &[_]u8{0xC3})) { // RET — cdecl Halt, caller cleans args
        log.print("dbghelp_proxy: D2 Halt suppressed (wine bug 44360 workaround)");
    } else {
        log.print("dbghelp_proxy: suppress-halt VirtualProtect FAILED");
    }
}

// Client-side CheckRevision bypass — the real WineHQ bug 44360 workaround. D2's version-check
// path (BNDOWNLOAD @0x51xxxx) does a patch-download that DIVIDES BY ZERO on wine's size-0 reply,
// halting right after Battle.net login. Ported verbatim from d2gs.dll's checkrev_patch feature:
// (1) stub BNDOWNLOAD_PerformCheckRevision @0x51e6d0 to write dummy version/checksum + return
//     success (realmd accepts any SID_AUTH_CHECK), so the real MPQ computation never runs;
// (2) force BNDOWNLOAD_GetProgress @0x51ea70 -> 0x66 ("no patch needed") so the launcher proceeds
//     into the game instead of starting the divide-by-zero patch download.
const CHECKREV_ADDR: usize = 0x0051e6d0;
const GETPROGRESS_ADDR: usize = 0x0051ea70;
const checkrev_stub = [_]u8{
    0x85, 0xC9, 0x74, 0x06, 0xC7, 0x01, 0x01, 0x00, 0x00, 0x01, // test ecx / jz / mov [ecx],0x01000001
    0x85, 0xD2, 0x74, 0x06, 0xC7, 0x02, 0xEF, 0xBE, 0xAD, 0xDE, // test edx / jz / mov [edx],0xDEADBEEF
    0x8B, 0x44, 0x24, 0x04, 0x85, 0xC0, 0x74, 0x03, 0xC6, 0x00, 0x00, // exeInfoOut[0]=0
    0xB8, 0x01, 0x00, 0x00, 0x00, 0xC2, 0x04, 0x00, // mov eax,1 ; ret 4
};
const getprogress_ret66 = [_]u8{ 0xB8, 0x66, 0x00, 0x00, 0x00, 0xC3 }; // mov eax,0x66 ; ret

fn bypassCheckrev() void {
    const a = patchBytes(CHECKREV_ADDR, &checkrev_stub);
    const b = patchBytes(GETPROGRESS_ADDR, &getprogress_ret66);
    if (a and b) {
        log.print("dbghelp_proxy: CheckRevision bypassed (wine bug 44360 — skips size-0 patch divide-by-zero)");
    } else {
        log.print("dbghelp_proxy: checkrev bypass FAILED to patch");
    }
}

// --realm-gw <ip>: the actual WineHQ-bug-44360 workaround for a stock realm client. D2's
// BNGatewayAccess::Load @0x5186d0 HALTS when GetGatewayList's registry read comes back empty
// (which it does under wine). realmgw detours GetGatewayList to supply the gateway list from
// memory (every realm -> <ip>), so the load never touches the registry and never halts. This
// is the single client patch a stock D2+D2BS realm client needs on wine.
var gw_ip: [64]u8 = undefined;

fn applyRealmGw(win_ip: LPCWSTR) void {
    var i: usize = 0;
    while (win_ip[i] != 0 and i < gw_ip.len - 1) : (i += 1) gw_ip[i] = @truncate(win_ip[i]);
    realmgw.apply(gw_ip[0..i]);
}

fn loadInjectedDlls() void {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return;
    defer _ = LocalFree(@ptrCast(argv));
    const n: usize = @intCast(argc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (eqlW(argv[i], "--suppress-halt")) {
            suppressHalt();
        } else if (eqlW(argv[i], "--bypass-checkrev")) {
            bypassCheckrev();
        } else if (i + 1 < n and eqlW(argv[i], "--realm-gw")) {
            applyRealmGw(argv[i + 1]);
            i += 1;
        } else if (i + 1 < n and eqlW(argv[i], "--loaddll")) {
            if (LoadLibraryW(argv[i + 1]) == null) {
                log.hex("dbghelp_proxy: LoadLibrary failed, err=0x", GetLastError());
            } else {
                log.print("dbghelp_proxy: injected DLL loaded");
            }
            i += 1;
        } else if (i + 1 < n and eqlW(argv[i], "--d2bs")) {
            armD2bs(argv[i + 1]);
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
