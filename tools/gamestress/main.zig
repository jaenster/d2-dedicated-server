//! Stress driver for the empty-game reaper fix: log into the live realm and create N games
//! back-to-back (the client never enters them, so each is empty immediately). Without the
//! reaper patch these pile up past FOG's 8 pool managers and the GS dies with 0xe0000001;
//! with it, the engine reaps each after the (patched) idle window and creation keeps working.
const std = @import("std");
const rc = @import("realmclient");
extern "c" fn usleep(usec: c_uint) c_int;

pub fn main() !void {
    const n: usize = 5;
    var c = rc.RealmClient{};
    defer c.close();
    try c.connectBnet();
    try c.auth();
    _ = c.createAccount("StressGuy", "x") catch 0; // idempotent (no-op if already created)
    if ((try c.loginPwResult("StressGuy", "x")) != 0) return error.LogonFailed;
    try c.enterRealm();
    try c.connectD2cs();
    _ = c.startup() catch 0;

    // Smoke: create a game and JOIN it — exercises the GS idle→busy gate (create
    // bumps d2cs's live count) and the create→join path that a join-based count
    // would deadlock.
    const cg = try c.createGame("smoke", "d");
    std.debug.print("create 'smoke' -> token={d} result={d}\n", .{ cg.token, cg.result });
    const jg = try c.joinGame("smoke");
    std.debug.print("join   'smoke' -> token={d} result={d} gs={d}.{d}.{d}.{d}\n", .{ jg.token, jg.result, jg.ip[0], jg.ip[1], jg.ip[2], jg.ip[3] });

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
        _ = usleep(1_500_000); // 1.5s between creates so the 5s reaper keeps up
    }
    std.debug.print("\nstress done: {d} created ok, {d} failed (of {d})\n", .{ ok, fail, n });
}
