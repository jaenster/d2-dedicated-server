//! This server's HTTP observability endpoint.
//!
//! Same port, same paths and the same answers as every other server in the fleet — the vocabulary
//! is `gs_health`, shared, so one probe and one dashboard panel cover a realm running five eras.
//! Only the transport is local: this image is a static Linux binary and reaches the network
//! through libc, where the Windows servers reach it through winsock.
//!
//! It matters more here than anywhere else that liveness is measured from the tick loop and not
//! from the listener. This process is a Mach-O image loaded into a host, and a fault inside the
//! engine leaves the host's threads running: the socket would still be accepted and still answer
//! 200 long after the last game stopped advancing.
const std = @import("std");
const gs_health = @import("gs_health");

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, val: *const anyopaque, len: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const sockaddr_in = extern struct {
    family: u16 = 2, // AF_INET
    port: u16, // network order
    addr: u32 = 0, // INADDR_ANY
    zero: [8]u8 = .{0} ** 8,
};

/// Written on the tick thread, read on this one. Plain aligned words: a reader sees one value or
/// the other, never a torn one, and nothing here is worth a lock on the engine's frame budget.
pub var ticks: u32 = 0;
pub var games_live: u32 = 0;
pub var games_max: u32 = 0;
pub var published = false;
pub var gsid: u32 = 0;

var boot_ms: i64 = 0;
var health_port: u16 = 8086;

/// The tick loop must advance within the window or the engine counts as wedged. The loop sleeps
/// 10-30 ms a pass, so fifteen seconds is hundreds of missed frames — a slow pass is not a
/// restart, and a stop is caught well before the 90-second fleet record expires.
const stale_ms: i64 = 15000;

pub inline fn tick() void {
    ticks +%= 1;
}

/// Monotonic, the same clock `realm.zig` paces its tick on — a wall clock that steps backwards
/// would read as an engine that stopped.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) *% 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn healthThread() void {
    const ls = socket(2, 1, 0); // AF_INET, SOCK_STREAM
    if (ls < 0) return;
    const one: c_int = 1;
    _ = setsockopt(ls, 1, 2, &one, @sizeOf(c_int)); // SOL_SOCKET, SO_REUSEADDR
    const sa = sockaddr_in{ .port = std.mem.nativeToBig(u16, health_port) };
    if (bind(ls, &sa, @sizeOf(sockaddr_in)) != 0 or listen(ls, 8) != 0) {
        _ = close(ls);
        return;
    }
    var last_ticks: u32 = ticks;
    var last_ms: i64 = nowMs();
    var rate_ticks: u32 = ticks;
    var rate_ms: i64 = last_ms;
    var rate_x100: u32 = 0;
    var body: [16 * 1024]u8 = undefined;
    var headbuf: [160]u8 = undefined;
    while (true) {
        const cs = accept(ls, null, null);
        if (cs < 0) continue;
        var req: [512]u8 = undefined;
        const got = recv(cs, &req, req.len, 0);
        const path = if (got > 0) gs_health.pathOf(req[0..@intCast(got)]) else "/";

        const now = nowMs();
        const cur = ticks;
        if (cur != last_ticks) {
            last_ticks = cur;
            last_ms = now; // the loop moved — refresh liveness
        }
        // Sampled off the probe, not on a timer: something asks at least every ten seconds, which
        // is what the probes are, and a rate needs a window rather than a thread of its own.
        if (now - rate_ms >= 1000) {
            rate_x100 = gs_health.tickRateX100(cur -% rate_ticks, @intCast(now - rate_ms));
            rate_ticks = cur;
            rate_ms = now;
        }

        const snap = gs_health.Snapshot{
            .alive = (now - last_ms) < stale_ms,
            .published = published,
            // The ENGINE, not the runtime. `d2gs:1.14d-native` already says which host this is to
            // a human, and a client only ever cares that the game is 1.14d.
            .engine = "1.14d",
            .gsid = gsid,
            .uptime_s = @intCast(@divTrunc(now - boot_ms, 1000)),
            .ticks = cur,
            .tick_rate_x100 = rate_x100,
            .games_live = games_live,
            .games_max = games_max,
        };
        const answer = gs_health.route(path, snap, &body);
        const h = gs_health.head(answer, &headbuf);
        _ = send(cs, h.ptr, h.len, 0);
        if (answer.body.len > 0) _ = send(cs, answer.body.ptr, answer.body.len, 0);
        _ = close(cs);
    }
}

/// Spawn the listener. Port from D2GS_HEALTH_PORT, default 8086 — the same port and answers as
/// every other server, so one set of probes covers the fleet.
///
/// Safe to call before the engine is up: it answers 503 until the tick loop starts.
pub fn start() void {
    boot_ms = nowMs();
    if (getenv("D2GS_HEALTH_PORT")) |v| {
        var p: u16 = 0;
        var i: usize = 0;
        while (v[i] != 0) : (i += 1) {
            if (v[i] >= '0' and v[i] <= '9') p = p *% 10 +% (v[i] - '0');
        }
        if (p != 0) health_port = p;
    }
    _ = std.Thread.spawn(.{}, healthThread, .{}) catch return;
}
