//! Stress driver for the empty-game reaper fix: log into the live realm and create N games
//! back-to-back (the client never enters them, so each is empty immediately). Without the
//! reaper patch these pile up past FOG's 8 pool managers and the GS dies with 0xe0000001;
//! with it, the engine reaps each after the (patched) idle window and creation keeps working.
const std = @import("std");
const rc = @import("realmclient");
extern "c" fn usleep(usec: c_uint) c_int;

pub fn main() !void {
    const n: usize = 15;
    var c = rc.RealmClient{};
    defer c.close();
    try c.connectBnet();
    try c.auth();
    try c.login("StressGuy");
    try c.enterRealm();
    try c.connectD2cs();
    _ = c.startup() catch 0;

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
