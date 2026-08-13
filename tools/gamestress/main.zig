//! Stress driver for the empty-game reaper fix: log into the live realm and create N games
//! back-to-back (the client never enters them, so each is empty immediately). Without the
//! reaper patch these pile up past FOG's 8 pool managers and the GS dies with 0xe0000001;
//! with it, the engine reaps each after the (patched) idle window and creation keeps working.
const std = @import("std");
const rc = @import("realmclient");
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn main() !void {
    // GS_ACCT lets several copies run concurrently as different users (multi-client
    // trace-isolation test); GS_HOLD_MS holds the connection open so they overlap.
    const acct: []const u8 = if (getenv("GS_ACCT")) |a| std.mem.span(a) else "StressGuy";
    const hold: c_uint = if (getenv("GS_HOLD_MS")) |h| (std.fmt.parseInt(c_uint, std.mem.span(h), 10) catch 0) else 0;

    // Same escape hatch the e2e harness has: without it this connects to whatever is on 6112,
    // which on a dev box is usually someone's live realm rather than the one under test.
    if (getenv("E2E_PORT_BASE")) |b| {
        const base = std.fmt.parseInt(u16, std.mem.span(b), 10) catch 0;
        if (base != 0) rc.setPortBase(base);
    }

    var c = rc.RealmClient{};
    defer c.close();
    try c.connectBnet();
    try c.auth();
    _ = c.createAccount(acct, "x") catch 0; // idempotent (no-op if already created)
    if ((try c.loginPwResult(acct, "x")) != 0) return error.LogonFailed;
    try c.enterRealm();
    std.debug.print("client {s}: logged in + entered realm\n", .{acct});
    if (hold > 0) {
        _ = usleep(hold * 1000); // overlap with other concurrent clients
        return; // login-only mode (no GS needed): exercises realmd per-connection traces
    }
    try c.connectD2cs();
    _ = c.startup() catch 0;

    // Smoke: create a game and JOIN it — exercises the GS idle→busy gate (create
    // bumps d2cs's live count) and the create→join path that a join-based count
    // would deadlock.
    const cg = try c.createGame("smoke", "d");
    std.debug.print("create 'smoke' -> token={d} result={d}\n", .{ cg.token, cg.result });
    const jg = try c.joinGame("smoke");
    std.debug.print("join   'smoke' -> token={d} result={d} gs={d}.{d}.{d}.{d}\n", .{ jg.token, jg.result, jg.ip[0], jg.ip[1], jg.ip[2], jg.ip[3] });

    // GS_GAMES / GS_DELAY_MS: five creates 1.5s apart keeps the 5s reaper in the loop, which is
    // the reaper regression. Testing the pool ceiling wants the opposite — more games than the
    // engine's seven, created faster than any reap window — so both are tunable.
    const n: usize = if (getenv("GS_GAMES")) |g| (std.fmt.parseInt(usize, std.mem.span(g), 10) catch 5) else 5;
    const delay_ms: c_uint = if (getenv("GS_DELAY_MS")) |d| (std.fmt.parseInt(c_uint, std.mem.span(d), 10) catch 1500) else 1500;
    var ok: usize = 0;
    var fail: usize = 0;
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < n) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "stress{d}", .{i}) catch unreachable;
        if (c.createGame(name, "d")) |r| {
            std.debug.print("[{d}/{d}] create {s} -> token={d} result={d}\n", .{ i + 1, n, name, r.token, r.result });
            if (r.result == 0) ok += 1 else fail += 1;
        } else |e| {
            std.debug.print("[{d}/{d}] create {s} -> ERROR {s}\n", .{ i + 1, n, name, @errorName(e) });
            fail += 1;
        }
        _ = usleep(delay_ms * 1000);
    }
    std.debug.print("\nstress done: {d} created ok, {d} failed (of {d})\n", .{ ok, fail, n });
}
