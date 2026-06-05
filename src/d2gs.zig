//! d2gs.dll — injected payload that boots 1.14d Game.exe as a headless dedicated
//! game server by driving the engine's built-in QServer/D2Game code.
//!
//! Loaded into the live Game.exe process by a dbghelp.dll proxy that
//! LoadLibrary's it via `--loaddll <winpath>`. Flags:
//!   --d2gs        attach + log (safe; proves injection)
//!   --d2gs-boot   ALSO run the engine bootstrap + tick loop (calls into the
//!                 real engine — only safe once init timing is confirmed; this
//!                 is intentionally separate so the injection test can't crash
//!                 the host)
//!
//! Run with `--headless` so no renderer/window is created.

const std = @import("std");
const win = std.os.windows;
const server = @import("engine/server.zig");
const command = @import("engine/command.zig");
const realm = @import("engine/realm.zig");
const d2cs = @import("realm/d2cs.zig");
const d2dbs = @import("realm/d2dbs.zig");
const headless = @import("runtime/headless.zig");
const crash = @import("runtime/crash.zig");
const halt_hook = @import("runtime/halt_hook.zig");
const log = @import("log.zig");

var use_realm: bool = false;
var d2cs_host: [64]u8 = undefined; // null-terminated IPv4
var d2cs_port: u16 = 0;
var d2cs_enabled: bool = false;
var d2dbs_host: [64]u8 = undefined;
var d2dbs_port: u16 = 0;
var d2dbs_enabled: bool = false;
var fetch_acct: [32]u8 = undefined;
var fetch_char: [32]u8 = undefined;
var fetch_enabled: bool = false;

const BOOL = win.BOOL; // enum(c_int){ FALSE, TRUE } in zig 0.16
const HMODULE = win.HINSTANCE;
const DWORD = win.DWORD;

extern "kernel32" fn DisableThreadLibraryCalls(h: HMODULE) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]const u8;
extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateThread(
    attrs: ?*anyopaque,
    stack: usize,
    start: *const fn (?*anyopaque) callconv(.winapi) DWORD,
    param: ?*anyopaque,
    flags: DWORD,
    id: ?*DWORD,
) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

/// Matches `--flag` anywhere in the command line (token-aware).
fn hasFlag(comptime flag: []const u8) bool {
    const needle = "--" ++ flag;
    const cmd: [*:0]const u8 = GetCommandLineA();
    var i: usize = 0;
    outer: while (cmd[i] != 0) : (i += 1) {
        if (cmd[i] != '-' or cmd[i + 1] != '-') continue;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (cmd[i + j] != needle[j]) continue :outer;
        }
        const after = cmd[i + needle.len];
        if (after == 0 or after == ' ' or after == '\t') return true;
    }
    return false;
}

/// Copy the whitespace-delimited token after `--<flag> ` into `out` (null-term).
/// Returns its length, or null if the flag is absent.
fn flagToken(comptime flag: []const u8, out: []u8) ?usize {
    const needle = "--" ++ flag ++ " ";
    const cmd: [*:0]const u8 = GetCommandLineA();
    var i: usize = 0;
    var start: ?usize = null;
    outer: while (cmd[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (cmd[i + j] != needle[j]) continue :outer;
        }
        start = i + needle.len;
        break;
    }
    const s = start orelse return null;
    var k = s;
    var n: usize = 0;
    while (cmd[k] != 0 and cmd[k] != ' ' and cmd[k] != '\t') : (k += 1) {
        if (n + 1 < out.len) {
            out[n] = cmd[k];
            n += 1;
        }
    }
    out[n] = 0;
    return n;
}

/// Split "host:port" (or "a:b") into `left` (null-term) + parsed `right` number.
fn splitColon(tok: []const u8, left: []u8, right: *u16) bool {
    var ci: ?usize = null;
    for (tok, 0..) |c, idx| {
        if (c == ':') {
            ci = idx;
            break;
        }
    }
    const c = ci orelse return false;
    const llen = @min(c, left.len - 1);
    @memcpy(left[0..llen], tok[0..llen]);
    left[llen] = 0;
    var n: u16 = 0;
    for (tok[c + 1 ..]) |ch| {
        if (ch >= '0' and ch <= '9') n = n *% 10 +% (ch - '0');
    }
    right.* = n;
    return llen > 0 and n != 0;
}

/// Split "account:charname" into the two name buffers (both null-terminated).
fn splitNames(tok: []const u8, a: []u8, b: []u8) bool {
    var ci: ?usize = null;
    for (tok, 0..) |c, idx| {
        if (c == ':') {
            ci = idx;
            break;
        }
    }
    const c = ci orelse return false;
    const alen = @min(c, a.len - 1);
    @memcpy(a[0..alen], tok[0..alen]);
    a[alen] = 0;
    const blen = @min(tok.len - c - 1, b.len - 1);
    @memcpy(b[0..blen], tok[c + 1 ..][0..blen]);
    b[blen] = 0;
    return alen > 0 and blen > 0;
}

fn parseEndpoints() void {
    var tmp: [96]u8 = undefined;
    if (flagToken("d2cs", &tmp)) |len| {
        var port: u16 = 0;
        if (splitColon(tmp[0..len], &d2cs_host, &port)) {
            d2cs_port = port;
            d2cs_enabled = true;
        }
    }
    if (flagToken("d2dbs", &tmp)) |len| {
        var port: u16 = 0;
        if (splitColon(tmp[0..len], &d2dbs_host, &port)) {
            d2dbs_port = port;
            d2dbs_enabled = true;
        }
    }
    if (flagToken("fetch-char", &tmp)) |len| {
        fetch_enabled = splitNames(tmp[0..len], &fetch_acct, &fetch_char);
    }
}

/// One-shot D2DBS character fetch (test/demo for `--fetch-char`).
fn fetchCharThread(_: ?*anyopaque) callconv(.winapi) DWORD {
    if (!d2dbs.connectTo(@ptrCast(&d2dbs_host), d2dbs_port)) return 0;
    const acct = std.mem.sliceTo(&fetch_acct, 0);
    const name = std.mem.sliceTo(&fetch_char, 0);
    log.print("d2dbs: fetching character...");
    var save: [8192]u8 = undefined;
    const got = d2dbs.fetchCharSave(acct, name, &save);
    if (got > 0) {
        log.hex("d2dbs: CHAR FETCHED ok, save bytes=0x", got);
    } else {
        log.print("d2dbs: char fetch returned no data");
    }
    return 0;
}

/// Server thread: bring the QServer up in dedicated mode, then pump forever.
/// Runs on its own thread so DllMain returns promptly and the host finishes its
/// (headless) init before we touch engine globals.
fn serverThread(_: ?*anyopaque) callconv(.winapi) DWORD {
    // Let the host reach a stable post-init state. TODO: replace this fixed
    // delay with a hook on the engine's init-complete point (VERIFY.md #4).
    log.print("d2gs: server thread up; waiting for engine init...");
    Sleep(3000);

    // Full dedicated-realm bootstrap (mirrors NET_QServer_StartServer's host tail
    // minus the host-as-player-1 connect, plus SetupAsBnetServer). With --realm
    // we register the (currently all-null, safe) realm table to enable realm mode;
    // otherwise we run open (no D2CS), which the POC already proved listens on :4000.
    if (use_realm) {
        log.print("d2gs: bootstrap (realm mode, IsBattleNetServer=1)");
        server.bootstrapRealmServer(&realm.table);
    } else {
        log.print("d2gs: bootstrap (open mode, no realm)");
        server.bootstrapRealmServer(null);
    }
    // Load the D2Common data tables (items/monsters/skills/levels/…) that game
    // creation needs. The client app-mode entry normally does this; our server
    // boot must do it explicitly. Only when game creation is enabled.
    if (command.allow_create) {
        log.print("d2gs: loading data tables (TXT_InitTxtFiles)...");
        server.TXT_InitTxtFiles(0, 0, 1);
        log.print("d2gs: data tables loaded");
    }

    log.print("d2gs: entering tick loop (listening on :4000)");

    // Connect to PvPGN's D2CS so it can dispatch game create/join to us.
    if (d2cs_enabled) d2cs.start(@ptrCast(&d2cs_host), d2cs_port);

    // One-shot D2DBS character fetch demo (--d2dbs <ip:port> --fetch-char acct:char).
    if (d2dbs_enabled and fetch_enabled) {
        _ = CreateThread(null, 0, fetchCharThread, null, 0, null);
    }

    while (true) {
        command.pump(); // run queued engine commands (create game, …) on this thread
        server.tick();
        Sleep(10); // ~100 Hz; D2 logic runs at 25 fps, tune later
    }
}

pub export fn DllMain(hModule: HMODULE, reason: DWORD, _: ?*anyopaque) callconv(.winapi) BOOL {
    if (reason == 1) { // DLL_PROCESS_ATTACH
        _ = DisableThreadLibraryCalls(hModule);
        if (hasFlag("d2gs")) {
            log.print("d2gs: DLL_PROCESS_ATTACH (--d2gs)");
            log.hex("d2gs: Game.exe base=0x", @intFromPtr(GetModuleHandleA(null)));
            // Patch the host to survive with no display so our server can run.
            // Applied here (process-attach, before client code executes).
            if (hasFlag("headless")) {
                headless.apply();
            }
            crash.install(); // log faulting addresses of engine access violations
            halt_hook.install(); // log engine assert sites before exit
            if (hasFlag("d2gs-boot")) {
                use_realm = hasFlag("realm");
                command.allow_create = hasFlag("create-games");
                parseEndpoints();
                log.print("d2gs: --d2gs-boot set, spawning server thread");
                _ = CreateThread(null, 0, serverThread, null, 0, null);
            } else {
                log.print("d2gs: injection OK (no --d2gs-boot, engine untouched)");
            }
        }
    }
    return win.BOOL.TRUE;
}
