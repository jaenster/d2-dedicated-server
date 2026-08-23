//! d2host's HTTP observability endpoint.
//!
//! Every engine before 1.14d runs under this host, and until now none of them could be asked
//! anything: the only surface in the fleet was the one `d2gs.dll` carries, which exists only in
//! the 1.14d image. So a pre-1.14 pod was probed on a bare TCP connect, and a listening socket is
//! answered by the OS — it says the port is open, not that the engine is stepping, and certainly
//! not that the realm knows about this server. A pod could read Ready for hours while no game
//! could be placed on it.
//!
//! The listener is winsock on its own thread, the same as the 1.14d one, because this is a
//! Windows image running under wine. What it SAYS is `gs_health`, shared with every other server
//! so one probe and one dashboard cover the whole realm.
//!
//! Rendering happens on this thread into this thread's buffer, so a stalled HTTP client costs the
//! tick loop nothing.
const std = @import("std");
const gs_health = @import("gs_health");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const INADDR_ANY: u32 = 0;

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16, // network order
    addr: u32 = INADDR_ANY,
    zero: [8]u8 = .{0} ** 8,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, t: i32, proto: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr_in, addrlen: ?*i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn htons(v: u16) callconv(.winapi) u16;
extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateThread(a: ?*anyopaque, b: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, p: ?*anyopaque, f: u32, id: ?*u32) callconv(.winapi) ?win.HANDLE;
const win = std.os.windows;

/// Written on the tick thread, read on the health thread. Plain aligned words, so a reader sees
/// one value or the other and never a torn one; nothing here is worth a lock on a 40 ms budget.
pub var ticks: u32 = 0;
pub var games_live: u32 = 0;
pub var games_max: u32 = 0;
pub var game_frames: u32 = 0;
pub var games_created: u32 = 0;
pub var games_destroyed: u32 = 0;
pub var players_joined: u32 = 0;
pub var published = false;
pub var gsid: u32 = 0;
/// The engine tag as the fleet publishes it. Set before `start`.
pub var engine: []const u8 = "";

var boot_ms: u32 = 0;
var health_port: u16 = 8086;

/// The tick loop must advance this within the window or the server counts as wedged. Long enough
/// that a slow frame is not a restart, short enough that a hang is caught before the fleet record
/// expires at 90 seconds.
const stale_ms: u32 = 15000;

pub inline fn tick() void {
    ticks +%= 1;
}

fn healthThread(_: ?*anyopaque) callconv(.winapi) u32 {
    var wsa: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsa); // refcounted — the host already started winsock
    const ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls == INVALID_SOCKET) return 1;
    const sa = sockaddr_in{ .port = htons(health_port) };
    if (bind(ls, &sa, @sizeOf(sockaddr_in)) != 0 or listen(ls, 8) != 0) {
        _ = closesocket(ls);
        return 1;
    }
    var last_ticks: u32 = ticks;
    var last_ms: u32 = GetTickCount();
    var rate_ticks: u32 = ticks;
    var rate_ms: u32 = last_ms;
    var rate_x100: u32 = 0;
    var body: [16 * 1024]u8 = undefined;
    var headbuf: [160]u8 = undefined;
    while (true) {
        const cs = accept(ls, null, null);
        if (cs == INVALID_SOCKET) continue;
        var req: [512]u8 = undefined;
        const got = recv(cs, &req, req.len, 0);
        const path = if (got > 0) gs_health.pathOf(req[0..@intCast(got)]) else "/";

        const now = GetTickCount();
        const cur = ticks;
        if (cur != last_ticks) {
            last_ticks = cur;
            last_ms = now; // the loop moved — refresh liveness
        }
        // Sampled off the probe rather than on a timer: something asks at least every ten seconds
        // (that is what the probes are), and a rate needs a window, not a thread of its own.
        if (now -% rate_ms >= 1000) {
            rate_x100 = gs_health.tickRateX100(cur -% rate_ticks, now -% rate_ms);
            rate_ticks = cur;
            rate_ms = now;
        }

        const snap = gs_health.Snapshot{
            .alive = (now -% last_ms) < stale_ms,
            .published = published,
            .engine = engine,
            .gsid = gsid,
            .uptime_s = (now -% boot_ms) / 1000,
            .ticks = cur,
            .tick_rate_x100 = rate_x100,
            .games_live = games_live,
            .games_max = games_max,
            .game_frames = game_frames,
            .games_created = games_created,
            .games_destroyed = games_destroyed,
            .players_joined = players_joined,
        };
        const answer = gs_health.route(path, snap, &body);
        const h = gs_health.head(answer, &headbuf);
        _ = send(cs, h.ptr, @intCast(h.len), 0);
        if (answer.body.len > 0) _ = send(cs, answer.body.ptr, @intCast(answer.body.len), 0);
        _ = closesocket(cs);
    }
}

/// Spawn the listener. Port from D2GS_HEALTH_PORT, default 8086 — the same port and the same
/// answers as the 1.14d server, so one set of probes covers the fleet.
///
/// Safe to call before the engine is up: it answers 503 until the tick loop starts.
pub fn start() void {
    boot_ms = GetTickCount();
    var buf: [16]u8 = undefined;
    const n = GetEnvironmentVariableA("D2GS_HEALTH_PORT", &buf, buf.len);
    if (n > 0 and n < buf.len) {
        var p: u16 = 0;
        for (buf[0..n]) |c| {
            if (c >= '0' and c <= '9') p = p *% 10 +% (c - '0');
        }
        if (p != 0) health_port = p;
    }
    _ = CreateThread(null, 0, healthThread, null, 0, null);
}
