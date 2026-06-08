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
const d2cs = @import("realm/client/d2cs.zig");
const d2dbs = @import("realm/client/d2dbs.zig");
const feature = @import("engine/feature.zig");
const halt_hook = @import("runtime/feature/halt_hook.zig"); // for enableSuppress (sub-mode, not a toggle)
const gsport = @import("runtime/gsport.zig");
const roominit = @import("runtime/roominit.zig");
const joindiag = @import("runtime/joindiag.zig");
const pkttrace = @import("runtime/pkttrace.zig");
const realmgw = @import("runtime/realmgw.zig");
const drawing = @import("runtime/drawing.zig");
const autoenter = @import("test/autoenter.zig");
const autologin = @import("test/autologin.zig");
const screenshot = @import("test/screenshot.zig");
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
// Public game address clients dial (self-reported to D2CS) + advertised capacity +
// this GS's stable fleet id. Set from --gs-addr/--max-games (or env) in parseEndpoints.
var gs_public_ip: [4]u8 = .{ 0, 0, 0, 0 };
var gs_public_port: u16 = 4000;
var gs_max_games: u32 = 100;
var gsid: u32 = 0;

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
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetComputerNameA(buf: [*]u8, size: *DWORD) callconv(.winapi) BOOL;

/// Copy the value of env var `name` into `out` (null-terminated). Length, or null
/// if unset / too large. Lets k8s configure the GS via env in addition to flags.
fn envToken(name: [*:0]const u8, out: []u8) ?usize {
    const n = GetEnvironmentVariableA(name, out.ptr, @intCast(out.len));
    if (n == 0 or n >= out.len) return null;
    return n;
}

/// Parse a dotted-quad "a.b.c.d" into network-order octets. Null if malformed.
fn parseDottedQuad(s: []const u8) ?[4]u8 {
    var oct: [4]u8 = undefined;
    var idx: usize = 0;
    var cur: u16 = 0;
    var seen = false;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            cur = cur * 10 + (c - '0');
            if (cur > 255) return null;
            seen = true;
        } else if (c == '.') {
            if (!seen or idx >= 3) return null;
            oct[idx] = @intCast(cur);
            idx += 1;
            cur = 0;
            seen = false;
        } else return null;
    }
    if (!seen or idx != 3) return null;
    oct[3] = @intCast(cur);
    return oct;
}

fn fnv1a(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

/// A stable per-GS id for the fleet: hash of the pod/host name (unique per k8s pod),
/// falling back to the public ip:port if the name is unavailable.
fn computeGsId() u32 {
    var buf: [256]u8 = undefined;
    var sz: DWORD = @intCast(buf.len);
    if (GetComputerNameA(&buf, &sz).toBool() and sz > 0) return fnv1a(buf[0..sz]);
    var fb: [6]u8 = undefined;
    fb[0..4].* = gs_public_ip;
    std.mem.writeInt(u16, fb[4..6], gs_public_port, .little);
    return fnv1a(&fb);
}

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

/// Copy a host string into a fixed null-terminated buffer.
fn setHost(dst: []u8, host: []const u8) void {
    const n = @min(host.len, dst.len - 1);
    @memcpy(dst[0..n], host[0..n]);
    dst[n] = 0;
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

    // Single-host convenience: `--realmd <host>` (or REALMD_HOST) points the GS at one
    // realm server, deriving the gslink control port (6115) and d2dbs port (6114).
    // Explicit --d2cs/--d2dbs above still win. `<host>` may be a DNS name (resolved at
    // connect) — e.g. a k8s Service like realmd.realmd.svc.cluster.local.
    {
        var hbuf: [80]u8 = undefined;
        const got = flagToken("realmd", &hbuf) orelse envToken("REALMD_HOST", &hbuf);
        if (got) |len| {
            const host = hbuf[0..len];
            if (!d2cs_enabled) {
                setHost(&d2cs_host, host);
                d2cs_port = 6115;
                d2cs_enabled = true;
            }
            if (!d2dbs_enabled) {
                setHost(&d2dbs_host, host);
                d2dbs_port = 6114;
                d2dbs_enabled = true;
            }
        }
    }

    // Public game address clients dial — flag, then env (k8s passes it via env).
    {
        const got = flagToken("gs-addr", &tmp) orelse envToken("D2GS_GS_ADDR", &tmp);
        if (got) |len| {
            var port: u16 = 0;
            var ipbuf: [64]u8 = undefined;
            if (splitColon(tmp[0..len], &ipbuf, &port)) {
                if (parseDottedQuad(std.mem.sliceTo(&ipbuf, 0))) |oct| {
                    gs_public_ip = oct;
                    gs_public_port = port;
                }
            }
        }
    }
    // Advertised capacity — flag, then env.
    {
        const got = flagToken("max-games", &tmp) orelse envToken("D2GS_MAX_GAMES", &tmp);
        if (got) |len| {
            var v: u32 = 0;
            var any = false;
            for (tmp[0..len]) |c| {
                if (c >= '0' and c <= '9') {
                    v = v * 10 + (c - '0');
                    any = true;
                }
            }
            if (any and v > 0) gs_max_games = v;
        }
    }
    gsid = computeGsId();
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
    // Move the engine's QServer off :4000 to the port we advertise (gs_public_port), so the
    // qqserver can own the client-facing :4000 and splice through to us. Must precede the
    // QSERVER_CreateAndInit inside bootstrapRealmServer. No-op when gs_public_port == 4000.
    gsport.apply(gs_public_port);
    // Per-game server hook surface: hook RoomInit to fan out roomInit() with a real
    // per-game GameCtx (the game's own FOG pool). Opt-in via a consumer flag so the
    // default server path stays byte-identical.
    if (hasFlag("srvdiag")) roominit.install();
    if (use_realm) {
        if (d2dbs_enabled) realm.setDatabaseSource(@ptrCast(&d2dbs_host), d2dbs_port);
        joindiag.install(); // log nReason when the engine refuses a join
        if (hasFlag("pkttrace")) pkttrace.install(); // verbose :4000 packet trace
        realm.init(); // populate the callback table before SetupAsBnetServer
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
    if (d2cs_enabled) d2cs.start(@ptrCast(&d2cs_host), d2cs_port, gs_public_ip, gs_public_port, gs_max_games, gsid);

    // One-shot D2DBS character fetch demo (--d2dbs <ip:port> --fetch-char acct:char).
    if (d2dbs_enabled and fetch_enabled) {
        _ = CreateThread(null, 0, fetchCharThread, null, 0, null);
    }

    while (true) {
        command.pump(); // run queued engine commands (create game, …) on this thread
        if (use_realm) realm.pumpDelivery(); // deliver fetched char outside the join stack
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
            // Feature registry (engine/feature.zig): map command-line flags onto
            // per-feature enable bits, then install every enabled feature. Covers
            // the attach-time patches that used to be a manual sequence here —
            // crash/halt_hook/gamecrashfix/multiinstance are default-on; headless,
            // checkrev (--bypass-checkrev), nocompress (--no-compress) and clientdiag
            // are gated by their flags. The single config table is in feature.zig.
            feature.applyFlags(hasFlag);
            feature.installAll();
            if (hasFlag("mapunits") or hasFlag("mapreveal")) drawing.install();
            if (hasFlag("screenshot")) screenshot.install();
            if (hasFlag("suppress-halts")) halt_hook.enableSuppress(); // sub-mode, not a toggle
            // Install the Battle.net gateway list in-process so the client always has a
            // valid gateway and never hits the crashing default-ini path (lets clients
            // share one wineprefix). --realm <ip> sets the realm IP (default 127.0.0.1).
            {
                var tmp: [64]u8 = undefined;
                if (flagToken("realm-gw", &tmp)) |len| {
                    realmgw.apply(if (len > 0) tmp[0..len] else "127.0.0.1");
                } else if (flagToken("realm", &tmp)) |len| {
                    // Bare `--realm` (GS boot, followed by another flag) must NOT be read as
                    // an IP — only treat the token as the realm IP when it looks numeric.
                    if (len > 0 and tmp[0] >= '0' and tmp[0] <= '9') realmgw.apply(tmp[0..len]);
                } else if (hasFlag("realm-gw")) {
                    realmgw.apply("127.0.0.1");
                }
            }
            // Drive the bnet login form: --auto-login <account>:<password>.
            {
                var tmp: [160]u8 = undefined;
                if (flagToken("auto-login", &tmp)) |len| {
                    var acct: [64]u8 = undefined;
                    var pass: [64]u8 = undefined;
                    if (splitNames(tmp[0..len], &acct, &pass)) {
                        autologin.install(std.mem.sliceTo(&acct, 0), std.mem.sliceTo(&pass, 0));
                    }
                } else if (flagToken("auto-join", &tmp)) |len| {
                    // acct:pass:gamename
                    var acct: [64]u8 = undefined;
                    var rest: [96]u8 = undefined;
                    if (splitNames(tmp[0..len], &acct, &rest)) {
                        var pass: [64]u8 = undefined;
                        var game: [64]u8 = undefined;
                        if (splitNames(std.mem.sliceTo(&rest, 0), &pass, &game)) {
                            autologin.installJoin(std.mem.sliceTo(&acct, 0), std.mem.sliceTo(&pass, 0), std.mem.sliceTo(&game, 0));
                        }
                    }
                }
            }
            if (hasFlag("test-enter")) {
                // Drive the real client through the menus into a game with a
                // character and verify it loads (no server bootstrap).
                autoenter.install();
            } else if (hasFlag("d2gs-boot")) {
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
