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
extern "c" var environ: [*:null]const ?[*:0]const u8;

fn envOr(name: [*:0]const u8, default: [:0]const u8) [:0]const u8 {
    if (getenv(name)) |v| return std.mem.span(v);
    return default;
}

const Status = enum { pass, fail, skip };
const Result = struct { name: []const u8, status: Status, msg: []const u8 };

const alloc = std.heap.c_allocator;

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
    _ = mkdir(data_dir, 0o755); // ignore EEXIST; realmd creates subdirs itself
    _ = setenv("REALMD_DATA_DIR", data_dir, 1);
    _ = setenv("REALMD_HEALTH_PORT", health, 1);
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

pub fn main() !void {
    const child = try maybeStartRealmd();

    const results = [_]Result{
        scLogin(),
        scCharListStatstring(),
        scCreateJoinGame(),
        scFleetCapacity(),
        skip("create_account_real_auth", "SKIP: not implemented yet — bnetd accepts any password (no real credential verification)"),
        skip("delete_char", "SKIP: not implemented yet — MCP_DELETECHARACTER (0x0a) has no handler in d2cs.zig"),
        skip("lobby_chat_a_to_b", "SKIP: not implemented yet — realm lobby is intentionally not a chat channel; no A->B message relay exists"),
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
