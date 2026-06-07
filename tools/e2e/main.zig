//! Clientless E2E test runner for realmd. Optionally auto-starts its own realmd
//! (REALMD_BIN, default ./zig-out/bin/realmd) with a temp data dir + health port
//! 18080, runs the named scenarios, prints [PASS]/[FAIL]/[SKIP] + a summary, and
//! exits non-zero on any failure. Ported from tools/e2e/{run,scenarios}.py.
const std = @import("std");
const net = @import("net.zig");
const rc = @import("realmclient.zig");
const FakeGS = @import("fakegs.zig").FakeGS;

// libc process control. The 0.16 std.process.spawn API requires an Io instance
// + Environ.Map; we call fork/execve/kill/waitpid directly instead — same
// "talk to libc, skip the churny std wrappers" approach net.zig takes for
// sockets. getenv mirrors src/realm/server/config.zig.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn fork() c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

// libc socket bits for the echo server (mirrors net.zig's approach). We bind to an
// ephemeral port (port 0) and read it back with getsockname so the FakeGS can advertise it.
const posix = std.posix;
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *c_uint) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
const cclose = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "close" });

fn envOr(name: [*:0]const u8, default: [:0]const u8) [:0]const u8 {
    if (getenv(name)) |v| return std.mem.span(v);
    return default;
}

const Status = enum { pass, fail, skip };
const Result = struct { name: []const u8, status: Status, msg: []const u8 };

const alloc = std.heap.c_allocator;

// Admin API bearer token the harness starts realmd with (REALMD_ADMIN_TOKEN).
const ADMIN_TOKEN = "testtoken";
const HEALTH_PORT: u16 = 18080;

fn msg(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch "(alloc failed)";
}

// --- crafts: minimal_d2s ---
const D2S_SIGNATURE: u32 = 0xAA55AA55;

/// Minimal .d2s: sig@0, expansion bit@0x24, class@0x28, level@0x2b, pad to 0x40.
fn minimalD2s(buf: *[0x40]u8, name: []const u8, class_id: u8, level: u8) []const u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], D2S_SIGNATURE, .little);
    const n = @min(name.len, @as(usize, 15));
    @memcpy(buf[0x14..][0..n], name[0..n]);
    buf[0x24] = 0x20; // expansion
    buf[0x28] = class_id;
    buf[0x2b] = level;
    return buf[0..];
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

fn scLogin() Result {
    const name = "login";
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    c.auth() catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    c.login("LoginGuy") catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    c.enterRealm() catch |e| return .{ .name = name, .status = .fail, .msg = msg("{s}", .{@errorName(e)}) };
    if (c.status != 0) return .{ .name = name, .status = .fail, .msg = msg("realm status={d}", .{c.status}) };
    if (c.sessionId() < 1) return .{ .name = name, .status = .fail, .msg = msg("session id not minted ({d})", .{c.sessionId()}) };
    return .{ .name = name, .status = .pass, .msg = msg("session minted id={d} cookie=0x{x}", .{ c.sessionId(), c.cookie }) };
}

fn scCharListStatstring() Result {
    const name = "char_list_statstring";
    const acct = "EpicAma";
    const char = "StatSorc";
    var d2s: [0x40]u8 = undefined;
    const blob = minimalD2s(&d2s, char, 1, 42); // 1 = Sorceress
    const sr = rc.d2dbsSave(acct, char, blob) catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (sr != 0) return fail(name, "d2dbs save result={d}", .{sr});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login(acct) catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const su = c.startup() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (su != 0) return fail(name, "d2cs startup result=0x{x}", .{su});

    var entries: [64]rc.CharEntry = undefined;
    var dst: [4096]u8 = undefined;
    const cl = c.charList(&entries, &dst) catch |e| return fail(name, "{s}", .{@errorName(e)});
    var found: ?rc.CharEntry = null;
    for (entries[0..cl.count]) |e| {
        if (std.mem.eql(u8, e.name, char)) found = e;
    }
    const ch = found orelse return fail(name, "char {s} not in list", .{char});
    const cls = if (ch.class_id >= 0 and ch.class_id < rc.CLASS_NAMES.len)
        rc.CLASS_NAMES[@intCast(ch.class_id)]
    else
        "?";
    if (!std.mem.eql(u8, cls, "Sorceress")) return fail(name, "decoded class={s} (id={d}), want Sorceress", .{ cls, ch.class_id });
    if (ch.level != 42) return fail(name, "decoded level={d}, want 42", .{ch.level});
    return .{ .name = name, .status = .pass, .msg = msg("listed {s}: class={s} level={d} flags={d} (total={d})", .{ char, cls, ch.level, ch.flags, cl.total }) };
}

fn scCreateJoinGame() Result {
    const name = "create_join_game";
    var gs = FakeGS{ .gsid = 0xABCD, .ip = .{ 127, 0, 0, 1 }, .maxgame = 100, .gameid = 42 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register over gs-link", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("GameGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const cg = c.createGame("mygame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    if (cg.token != 42) return fail(name, "create token={d} want 42", .{cg.token});

    const jg = c.joinGame("mygame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});
    if (jg.token != 42) return fail(name, "join token={d} want 42", .{jg.token});
    if (!(jg.ip[0] == 127 and jg.ip[1] == 0 and jg.ip[2] == 0 and jg.ip[3] == 1))
        return fail(name, "join gs_ip={d}.{d}.{d}.{d} want 127.0.0.1", .{ jg.ip[0], jg.ip[1], jg.ip[2], jg.ip[3] });
    if (gs.creates != 1 or gs.joins != 1) return fail(name, "FakeGS saw creates={d} joins={d}, want 1/1", .{ gs.creates, gs.joins });
    return .{ .name = name, .status = .pass, .msg = msg("create+join ok token={d} gs_ip=127.0.0.1 (creates={d} joins={d})", .{ cg.token, gs.creates, gs.joins }) };
}

fn scFleetCapacity() Result {
    const name = "fleet_capacity";
    var gs_a = FakeGS{ .gsid = 0xAAA, .ip = .{ 127, 0, 0, 2 }, .maxgame = 1, .next_gameid = 100 };
    var gs_b = FakeGS{ .gsid = 0xBBB, .ip = .{ 127, 0, 0, 3 }, .maxgame = 1, .next_gameid = 200 };
    gs_a.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_a.stop();
    gs_b.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs_b.stop();
    if (!gs_a.isRegistered() or !gs_b.isRegistered()) return fail(name, "both FakeGS must register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("FleetGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const r1 = (c.createGame("game1", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    const r2 = (c.createGame("game2", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    if (r1 != 0 or r2 != 0) return fail(name, "first two creates must pass (r1={d} r2={d})", .{ r1, r2 });
    if (gs_a.creates != 1 or gs_b.creates != 1) return fail(name, "creates must spread one-each (a={d} b={d})", .{ gs_a.creates, gs_b.creates });

    const r3 = (c.createGame("game3", "d") catch |e| return fail(name, "{s}", .{@errorName(e)})).result;
    if (r3 == 0) return fail(name, "third create must fail (fleet full)", .{});
    if (gs_a.creates != 1 or gs_b.creates != 1) return fail(name, "no extra creates sent when full", .{});
    return .{ .name = name, .status = .pass, .msg = msg("spread a={d} b={d}, 3rd rejected (result={d})", .{ gs_a.creates, gs_b.creates, r3 }) };
}

fn scLobbyChatAtoB() Result {
    const name = "lobby_chat_a_to_b";
    const acct_a = "ChatAlice";
    const acct_b = "ChatBob";
    const channel = "Diablo II";

    var a = rc.RealmClient{};
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login(acct_a) catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterChat() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.joinChannel(channel) catch |e| return fail(name, "A {s}", .{@errorName(e)});

    var b = rc.RealmClient{};
    defer b.close();
    b.connectBnet() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.auth() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.login(acct_b) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.enterChat() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.joinChannel(channel) catch |e| return fail(name, "B {s}", .{@errorName(e)});
    b.setBnetTimeout(2000); // never block forever on a missing event

    // Let B's join propagate before A talks, so A already sees B in-channel.
    _ = net.usleep(100_000);
    a.chatCommand("hello B") catch |e| return fail(name, "A {s}", .{@errorName(e)});

    // B reads events, skipping the CHANNEL/SHOWUSER/JOIN noise, until the TALK.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ev = b.readChatEvent() catch |e| return fail(name, "B no TALK event ({s})", .{@errorName(e)});
        if (ev.eid != rc.EID_TALK) continue;
        if (!std.mem.eql(u8, ev.username, acct_a))
            return fail(name, "TALK from {s}, want {s}", .{ ev.username, acct_a });
        if (!std.mem.eql(u8, ev.text, "hello B"))
            return fail(name, "TALK text '{s}', want 'hello B'", .{ev.text});
        return .{ .name = name, .status = .pass, .msg = msg("B received TALK from {s}: '{s}'", .{ ev.username, ev.text }) };
    }
    return fail(name, "no EID_TALK among first 8 events B received", .{});
}

// Real Battle.net OLS account creation + password verification (xSHA-1):
//   1. CREATEACCOUNT2 "AuthUser"/"secret"  -> result 0 (created)
//   2. CREATEACCOUNT2 "AuthUser" again     -> non-zero (name taken)
//   3. login "AuthUser"/"secret"           -> 0 (success)
//   4. login "AuthUser"/"wrongpw"          -> non-zero (rejected)
fn scCreateAccountRealAuth() Result {
    const name = "create_account_real_auth";
    const acct = "AuthUser";

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});

    const r1 = c.createAccount(acct, "secret") catch |e| return fail(name, "create1 {s}", .{@errorName(e)});
    if (r1 != 0) return fail(name, "first create result={d}, want 0 (created)", .{r1});

    const r2 = c.createAccount(acct, "secret") catch |e| return fail(name, "create2 {s}", .{@errorName(e)});
    if (r2 == 0) return fail(name, "dup create result=0, want non-zero (name taken)", .{});

    const r3 = c.loginPwResult(acct, "secret") catch |e| return fail(name, "login-good {s}", .{@errorName(e)});
    if (r3 != 0) return fail(name, "correct-password login result={d}, want 0", .{r3});

    // Fresh connection: a new per-connection server_token, but the stored hash
    // means the wrong password must still be rejected.
    var c2 = rc.RealmClient{};
    defer c2.close();
    c2.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c2.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const r4 = c2.loginPwResult(acct, "wrongpw") catch |e| return fail(name, "login-bad {s}", .{@errorName(e)});
    if (r4 == 0) return fail(name, "wrong-password login result=0, want non-zero (rejected)", .{});

    return .{ .name = name, .status = .pass, .msg = msg("create=0 dup={d} good-login=0 bad-login={d}", .{ r2, r4 }) };
}

// HTTP admin API on the health port: bearer-token auth, GS fleet listing,
// account creation that a real realm login then accepts.
//   1. a FakeGS registers (non-empty fleet)
//   2. GET /admin/gameservers + token -> 200, contains the FakeGS gsid
//   3. GET /admin/gameservers WITHOUT token -> 401
//   4. POST /admin/accounts {name,password} -> 200 created
//   5. realm loginPw(AdminMade, pw) -> success (admin-created account works)
//   6. GET /admin/status -> 200, gameservers >= 1
fn scAdminApi() Result {
    const name = "admin_api";
    var rxbuf: [8192]u8 = undefined;

    var gs = FakeGS{ .gsid = 0x5151, .ip = .{ 127, 0, 0, 1 }, .maxgame = 50, .gameid = 7 };
    gs.start(3000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    // 2. listing with the token contains the gsid (formatted lowercase hex "0x5151").
    const r1 = net.httpRequest(HEALTH_PORT, "GET", "/admin/gameservers", ADMIN_TOKEN, "", &rxbuf) catch |e| return fail(name, "gameservers {s}", .{@errorName(e)});
    if (r1.status != 200) return fail(name, "gameservers status={d} want 200", .{r1.status});
    if (std.mem.indexOf(u8, r1.body, "0x5151") == null) return fail(name, "gameservers body missing gsid 0x5151: {s}", .{r1.body});

    // 3. same request without the token -> 401.
    var rx2: [1024]u8 = undefined;
    const r2 = net.httpRequest(HEALTH_PORT, "GET", "/admin/gameservers", "", "", &rx2) catch |e| return fail(name, "noauth {s}", .{@errorName(e)});
    if (r2.status != 401) return fail(name, "no-token status={d} want 401", .{r2.status});

    // 4. create an account via the admin API.
    var rx3: [1024]u8 = undefined;
    const r3 = net.httpRequest(HEALTH_PORT, "POST", "/admin/accounts", ADMIN_TOKEN, "{\"name\":\"AdminMade\",\"password\":\"pw\"}", &rx3) catch |e| return fail(name, "create {s}", .{@errorName(e)});
    if (r3.status != 200) return fail(name, "create status={d} body={s}", .{ r3.status, r3.body });

    // 5. that account must log in over the real realm protocol.
    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    const lr = c.loginPwResult("AdminMade", "pw") catch |e| return fail(name, "login {s}", .{@errorName(e)});
    if (lr != 0) return fail(name, "admin-created login result={d} want 0", .{lr});

    // 6. status reflects the registered fleet.
    var rx4: [1024]u8 = undefined;
    const r4 = net.httpRequest(HEALTH_PORT, "GET", "/admin/status", ADMIN_TOKEN, "", &rx4) catch |e| return fail(name, "status {s}", .{@errorName(e)});
    if (r4.status != 200) return fail(name, "status status={d} want 200", .{r4.status});
    if (std.mem.indexOf(u8, r4.body, "\"gameservers\":0") != null) return fail(name, "status reports gameservers=0: {s}", .{r4.body});
    if (std.mem.indexOf(u8, r4.body, "\"gameservers\"") == null) return fail(name, "status missing gameservers: {s}", .{r4.body});

    return .{ .name = name, .status = .pass, .msg = msg("gameservers listed gsid=0x5151, no-token=401, account created+logged-in, status ok", .{}) };
}

fn fail(name: []const u8, comptime fmt: []const u8, args: anytype) Result {
    return .{ .name = name, .status = .fail, .msg = msg(fmt, args) };
}

fn skip(name: []const u8, m: []const u8) Result {
    return .{ .name = name, .status = .skip, .msg = m };
}

// ---------------------------------------------------------------------------
// realmd child management
// ---------------------------------------------------------------------------
fn waitPort(port: u16, deadline_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < deadline_ms) : (waited += 100) {
        if (net.portOpen(port)) return true;
        _ = net.usleep(100_000);
    }
    return false;
}

/// A single REALMD_* env override (name/value) applied before fork+execve.
const EnvVar = struct { name: [*:0]const u8, value: [*:0]const u8 };

/// fork+execve a realmd child, applying `envs` to our environ first (the child
/// inherits the augmented environ). Returns the child pid. Waits up to 10s for
/// `wait_port` to listen; exits the harness if it never comes up.
fn spawnRealmd(bin: [:0]const u8, envs: []const EnvVar, wait_port: u16) !c_int {
    for (envs) |e| _ = setenv(e.name, e.value, 1);
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{bin.ptr};
        _ = execve(bin.ptr, &argv, environ);
        std.process.exit(127); // execve only returns on failure
    }
    if (!waitPort(wait_port, 10_000)) {
        _ = kill(pid, 9);
        std.debug.print("ERROR: realmd did not start listening on {d} in time.\n", .{wait_port});
        std.process.exit(2);
    }
    return pid;
}

/// fork+execve realmd with REALMD_DATA_DIR/REALMD_HEALTH_PORT set in our env
/// (inherited by the child). Returns the child pid, or null on existing realmd.
fn maybeStartRealmd() !?c_int {
    if (net.portOpen(rc.HOST_BNET)) {
        std.debug.print("using existing realmd on 127.0.0.1:{d}\n", .{rc.HOST_BNET});
        return null;
    }
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");
    const data_dir = envOr("REALMD_DATA_DIR", "/tmp/e2e-realmd");
    const health = envOr("REALMD_HEALTH_PORT", "18080");
    // Fresh data dir each run — accounts/chars/games persist otherwise and break
    // isolation (e.g. a re-created account would already exist on the 2nd run).
    var rmbuf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&rmbuf, "rm -rf {s}", .{data_dir})) |cmd| {
        _ = system(cmd.ptr);
    } else |_| {}
    _ = mkdir(data_dir, 0o755); // ignore EEXIST; realmd creates subdirs itself
    _ = setenv("REALMD_DATA_DIR", data_dir, 1);
    _ = setenv("REALMD_HEALTH_PORT", health, 1);
    _ = setenv("REALMD_ADMIN_TOKEN", ADMIN_TOKEN, 1); // enable the admin API (admin_api scenario)
    std.debug.print("starting realmd: {s} (data_dir={s}, health={s})\n", .{ bin, data_dir, health });

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // child: exec realmd, inheriting our (now-augmented) environ.
        const argv = [_:null]?[*:0]const u8{bin.ptr};
        _ = execve(bin.ptr, &argv, environ);
        std.process.exit(127); // execve only returns on failure
    }
    if (!waitPort(rc.HOST_BNET, 10_000)) {
        _ = kill(pid, 9);
        std.debug.print("ERROR: realmd did not start listening in time.\n", .{});
        std.process.exit(2);
    }
    return pid;
}

// Verify ONE GS hosts MULTIPLE concurrent games: a single FakeGS accepts 3 creates
// and realmd tracks all 3 against that one gsid. This is the realmd side of the
// multi-game-per-GS model (capacity, routing, tracking); the engine actually ticking
// N real games needs the GS under wine and is out of scope for the clientless harness.
fn scMultiGameOneGs() Result {
    const name = "multi_game_one_gs";
    var gs = FakeGS{ .gsid = 0xD2D2, .ip = .{ 127, 0, 0, 1 }, .maxgame = 10, .next_gameid = 500 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("MultiGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const names3 = [_][]const u8{ "mg_one", "mg_two", "mg_three" };
    for (names3) |gn| {
        const cg = c.createGame(gn, "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
        if (cg.result != 0) return fail(name, "create {s} result={d}", .{ gn, cg.result });
    }
    if (gs.creates != 3) return fail(name, "one GS must host 3 games, saw creates={d}", .{gs.creates});

    // realmd tracks all 3 under the one gsid — confirm via the admin API.
    var rxbuf: [4096]u8 = undefined;
    const r = net.httpRequest(HEALTH_PORT, "GET", "/admin/games", ADMIN_TOKEN, "", &rxbuf) catch |e| return fail(name, "admin games {s}", .{@errorName(e)});
    if (r.status != 200) return fail(name, "admin games status={d}", .{r.status});
    for (names3) |gn| {
        if (std.mem.indexOf(u8, r.body, gn) == null) return fail(name, "game {s} not in /admin/games", .{gn});
    }
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, r.body, idx, "0xd2d2")) |p| : (idx = p + 1) count += 1;
    if (count < 3) return fail(name, "expected 3 games on gsid 0xd2d2, found {d}", .{count});
    return .{ .name = name, .status = .pass, .msg = msg("one GS hosts 3 games (creates={d}), all tracked under gsid 0xd2d2", .{gs.creates}) };
}

// Two realmd instances (A, B) sharing one data dir (REALMD_SHARED) keep sessions
// in a shared store: a session minted on A's bnetd must resolve on B's d2cs.
// Instance A: bnet 16112 / d2cs 16113 / d2dbs 16114 / gs 16115 / health 16118.
// Instance B: 17112 / 17113 / 17114 / 17115 / 17118, SAME data dir, instance "B".
fn scMultiInstance() Result {
    const name = "multi_instance";
    const bin = envOr("REALMD_BIN", "./zig-out/bin/realmd");

    // Shared data dir, fresh each run (isolation: accounts/sessions persist on fs).
    const data_dir = "/tmp/e2e-realmd-shared";
    var rmbuf: [256]u8 = undefined;
    if (std.fmt.bufPrintZ(&rmbuf, "rm -rf {s}", .{data_dir})) |cmd| {
        _ = system(cmd.ptr);
    } else |_| {}
    _ = mkdir(data_dir, 0o755);

    const envs_a = [_]EnvVar{
        .{ .name = "REALMD_SHARED", .value = "1" },
        .{ .name = "REALMD_INSTANCE", .value = "A" },
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_BNET_PORT", .value = "16112" },
        .{ .name = "REALMD_D2CS_PORT", .value = "16113" },
        .{ .name = "REALMD_D2DBS_PORT", .value = "16114" },
        .{ .name = "REALMD_GS_PORT", .value = "16115" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "16118" },
    };
    const a_pid = spawnRealmd(bin, &envs_a, 16112) catch |e| return fail(name, "spawn A {s}", .{@errorName(e)});

    const envs_b = [_]EnvVar{
        .{ .name = "REALMD_SHARED", .value = "1" },
        .{ .name = "REALMD_INSTANCE", .value = "B" },
        .{ .name = "REALMD_DATA_DIR", .value = data_dir },
        .{ .name = "REALMD_BNET_PORT", .value = "17112" },
        .{ .name = "REALMD_D2CS_PORT", .value = "17113" },
        .{ .name = "REALMD_D2DBS_PORT", .value = "17114" },
        .{ .name = "REALMD_GS_PORT", .value = "17115" },
        .{ .name = "REALMD_HEALTH_PORT", .value = "17118" },
    };
    const b_pid = spawnRealmd(bin, &envs_b, 17112) catch |e| {
        _ = kill(a_pid, 15);
        _ = waitpid(a_pid, null, 0);
        return fail(name, "spawn B {s}", .{@errorName(e)});
    };
    defer {
        _ = kill(a_pid, 15);
        _ = kill(b_pid, 15);
        _ = waitpid(a_pid, null, 0);
        _ = waitpid(b_pid, null, 0);
    }

    // Mint a session on instance A (bnetd 16112 -> d2cs handoff lives in shared store).
    var a = rc.RealmClient{ .bnet_port = 16112, .d2cs_port = 16113 };
    defer a.close();
    a.connectBnet() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.auth() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.login("MultiInst") catch |e| return fail(name, "A {s}", .{@errorName(e)});
    a.enterRealm() catch |e| return fail(name, "A {s}", .{@errorName(e)});
    if (a.sessionId() < 1) return fail(name, "A minted no session", .{});

    // Resolve A's session on instance B's d2cs (17113). Copy A's session fields
    // into B's client so its STARTUP carries A's cookie/status/lo/hi/account.
    var b = rc.RealmClient{ .bnet_port = 17112, .d2cs_port = 17113 };
    defer b.close();
    b.cookie = a.cookie;
    b.status = a.status;
    b.lo = a.lo;
    b.hi = a.hi;
    b.account = a.account;
    b.connectD2cs() catch |e| return fail(name, "B {s}", .{@errorName(e)});
    const su = b.startup() catch |e| return fail(name, "B startup {s}", .{@errorName(e)});
    if (su != 0) return fail(name, "B failed to resolve A's session (startup result=0x{x})", .{su});

    return .{ .name = name, .status = .pass, .msg = msg("session id={d} minted on A resolved on B's d2cs (startup=0)", .{a.sessionId()}) };
}

// A tiny echo TCP server standing in for a real backend GS :4000 game port. Binds an
// ephemeral port (read back via getsockname) and accepts connections in a loop, each on
// its own thread, echoing whatever it reads. Looping (not one-shot) matters: the qqserver
// port-probe opens a throwaway connection that the qqserver splices through to us, so the
// real test connection must still get its own accept. `got`/`got_len` capture the first
// non-empty payload so the scenario can assert bytes reached the backend.
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
const c_write = @extern(*const fn (c_int, [*]const u8, usize) callconv(.c) isize, .{ .name = "write" });

const EchoServer = struct {
    listen_fd: c_int = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    got: [256]u8 = undefined,
    got_len: usize = 0,

    fn start(self: *EchoServer) !void {
        const fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        const one: c_int = 1;
        _ = setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one, @sizeOf(c_int));
        var addr = std.mem.zeroes(posix.sockaddr.in);
        addr.family = posix.AF.INET;
        addr.port = 0; // ephemeral
        addr.addr = std.mem.nativeToBig(u32, 0x7f00_0001); // 127.0.0.1
        if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);
        if (bind(fd, &addr, @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
        if (listen(fd, 8) != 0) return error.ListenFailed;
        var sn = std.mem.zeroes(posix.sockaddr.in);
        var l: c_uint = @sizeOf(posix.sockaddr.in);
        if (getsockname(fd, &sn, &l) != 0) return error.SockNameFailed;
        self.listen_fd = fd;
        self.port = std.mem.bigToNative(u16, sn.port);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    // Accept forever; each connection echoed on a detached thread. The loop ends when
    // stop() closes the listen fd and accept() errors.
    fn acceptLoop(self: *EchoServer) void {
        while (true) {
            const cfd = accept(self.listen_fd, null, null);
            if (cfd < 0) return;
            const t = std.Thread.spawn(.{}, echoConn, .{ self, cfd }) catch {
                _ = cclose(cfd);
                continue;
            };
            t.detach();
        }
    }

    fn echoConn(self: *EchoServer, cfd: c_int) void {
        defer _ = cclose(cfd);
        var buf: [256]u8 = undefined;
        while (true) {
            const n = c_read(cfd, &buf, buf.len);
            if (n <= 0) return;
            const un: usize = @intCast(n);
            if (@atomicLoad(usize, &self.got_len, .seq_cst) == 0) {
                @memcpy(self.got[0..un], buf[0..un]);
                @atomicStore(usize, &self.got_len, un, .seq_cst);
            }
            _ = c_write(cfd, &buf, un); // echo back
        }
    }

    fn received(self: *EchoServer) []const u8 {
        const n = @atomicLoad(usize, &self.got_len, .seq_cst);
        return self.got[0..n];
    }

    fn stop(self: *EchoServer) void {
        if (self.listen_fd >= 0) _ = cclose(self.listen_fd);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};

/// fork+execve the qqserver binary (REALMD_QQSERVER_BIN, default ./zig-out/bin/qqserver)
/// sharing the harness realmd's REALMD_DATA_DIR (so it reads the same fs route store) and
/// listening on REALMD_QQ_PORT. Waits up to 10s for the port; exits the harness if it
/// never comes up. Mirrors spawnRealmd.
fn spawnQqserver(qq_port: u16) !c_int {
    const bin = envOr("REALMD_QQSERVER_BIN", "./zig-out/bin/qqserver");
    const data_dir = envOr("REALMD_DATA_DIR", "/tmp/e2e-realmd");
    var pbuf: [8]u8 = undefined;
    const portz = std.fmt.bufPrintZ(&pbuf, "{d}", .{qq_port}) catch return error.BadPort;
    _ = setenv("REALMD_DATA_DIR", data_dir, 1);
    _ = setenv("REALMD_QQ_PORT", portz.ptr, 1);
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{bin.ptr};
        _ = execve(bin.ptr, &argv, environ);
        std.process.exit(127);
    }
    if (!waitPort(qq_port, 10_000)) {
        _ = kill(pid, 9);
        std.debug.print("ERROR: qqserver did not start listening on {d} in time.\n", .{qq_port});
        std.process.exit(2);
    }
    return pid;
}

// Prove the full gateway path: realmd records a route on JOINGAME and the qqserver
// splices the client's game connection to the right backend by source IP.
//   1. an echo server stands in for the backend GS game port (ephemeral port P)
//   2. a FakeGS registers with ip=127.0.0.1 / gs_port=P, so the game record points at P
//   3. a client create+joins from 127.0.0.1 — realmd recordRoute(127.0.0.1 -> 127.0.0.1:P)
//   4. spawn the qqserver on :14000 sharing the same fs data dir
//   5. connect to :14000, send "PING-QQ" — assert the echo server got it AND it comes back
fn scQqserverRouting() Result {
    const name = "qqserver_routing";
    const QQ_PORT: u16 = 14000;

    var echo = EchoServer{};
    echo.start() catch |e| return fail(name, "echo start {s}", .{@errorName(e)});
    defer echo.stop();

    var gs = FakeGS{ .gsid = 0x9999, .ip = .{ 127, 0, 0, 1 }, .gs_port = echo.port, .maxgame = 10, .gameid = 77 };
    gs.start(2000) catch |e| return fail(name, "{s}", .{@errorName(e)});
    defer gs.stop();
    if (!gs.isRegistered()) return fail(name, "FakeGS did not register", .{});

    var c = rc.RealmClient{};
    defer c.close();
    c.connectBnet() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.auth() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.login("QqGuy") catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.enterRealm() catch |e| return fail(name, "{s}", .{@errorName(e)});
    c.connectD2cs() catch |e| return fail(name, "{s}", .{@errorName(e)});
    if ((c.startup() catch 1) != 0) return fail(name, "d2cs startup failed", .{});

    const cg = c.createGame("qqgame", "d") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (cg.result != 0) return fail(name, "create result={d}", .{cg.result});
    // The join records the route {127.0.0.1 -> 127.0.0.1:echo.port}.
    const jg = c.joinGame("qqgame") catch |e| return fail(name, "{s}", .{@errorName(e)});
    if (jg.result != 0) return fail(name, "join result={d}", .{jg.result});

    const qq_pid = spawnQqserver(QQ_PORT) catch |e| return fail(name, "spawn qqserver {s}", .{@errorName(e)});
    defer {
        _ = kill(qq_pid, 15);
        _ = waitpid(qq_pid, null, 0);
    }

    // Connect to the qqserver as the client's game traffic; it routes by our source IP.
    const fd = net.connectLocal(QQ_PORT) catch |e| return fail(name, "connect qq {s}", .{@errorName(e)});
    defer net.closeSocket(fd);
    net.writeAll(fd, "PING-QQ") catch |e| return fail(name, "send {s}", .{@errorName(e)});

    var back: [16]u8 = undefined;
    net.readFull(fd, back[0..7]) catch |e| return fail(name, "no echo back through qq ({s})", .{@errorName(e)});
    if (!std.mem.eql(u8, back[0..7], "PING-QQ")) return fail(name, "echo mismatch '{s}'", .{back[0..7]});

    // Backend must have actually seen the bytes (proves the splice reached the GS port).
    var waited: u32 = 0;
    while (echo.received().len == 0 and waited < 1000) : (waited += 20) _ = net.usleep(20_000);
    const got = echo.received();
    if (!std.mem.eql(u8, got, "PING-QQ")) return fail(name, "backend GS saw '{s}', want 'PING-QQ'", .{got});

    return .{ .name = name, .status = .pass, .msg = msg("route recorded on join, qqserver spliced 127.0.0.1 -> backend :{d}, echo round-tripped", .{echo.port}) };
}

pub fn main() !void {
    const child = try maybeStartRealmd();

    const results = [_]Result{
        scLogin(),
        scCharListStatstring(),
        scCreateJoinGame(),
        scFleetCapacity(),
        scAdminApi(),
        scMultiGameOneGs(),
        scQqserverRouting(),
        scCreateAccountRealAuth(),
        skip("delete_char", "SKIP: not implemented yet — MCP_DELETECHARACTER (0x0a) has no handler in d2cs.zig"),
        scLobbyChatAtoB(),
        scMultiInstance(),
    };

    if (child) |pid| {
        _ = kill(pid, 15); // SIGTERM
        _ = waitpid(pid, null, 0);
    }

    var npass: u32 = 0;
    var nfail: u32 = 0;
    var nskip: u32 = 0;
    for (results) |r| {
        const tag = switch (r.status) {
            .pass => "PASS",
            .fail => "FAIL",
            .skip => "SKIP",
        };
        std.debug.print("[{s}] {s}: {s}\n", .{ tag, r.name, r.msg });
        switch (r.status) {
            .pass => npass += 1,
            .fail => nfail += 1,
            .skip => nskip += 1,
        }
    }
    std.debug.print("\nsummary: {d} passed, {d} failed, {d} skipped ({d} total)\n", .{ npass, nfail, nskip, results.len });
    if (nfail != 0) std.process.exit(1);
}
