//! Hacky in-process HTTP health endpoint for the headless GS.
//!
//! A tiny winsock listener on its own thread answers ANY HTTP request with `200 ok`
//! once the server thread is actually ticking, else `503 down`. This lets k8s probe the
//! real engine (is the tick loop advancing?) instead of just "is wine alive" — a wedged
//! tick loop stops bumping the heartbeat and the probe goes 503, so the pod restarts.
//!
//! Liveness = `beat` advancing. The server tick loop calls tick() every frame; the
//! responder remembers when beat last changed and fails if it's been stale too long.
const std = @import("std");
const win = std.os.windows;
const log = @import("../../log.zig");
const headless = @import("headless.zig");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const INADDR_ANY: u32 = 0;

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16, // network order
    addr: u32 = INADDR_ANY, // network order
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

/// Bumped every server tick. Liveness = this advancing.
pub var beat: u32 = 0;
pub inline fn tick() void {
    beat +%= 1;
}

var health_port: u16 = 8086;
const stale_ms: u32 = 15000; // tick must advance within this window to count as live

const ok_resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n";
const bad_resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\ndown\n";

fn healthThread(_: ?*anyopaque) callconv(.winapi) u32 {
    var wsa: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsa); // refcounted — the host already started winsock
    const ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls == INVALID_SOCKET) {
        log.print("health: socket() failed");
        return 1;
    }
    const sa = sockaddr_in{ .port = htons(health_port) };
    if (bind(ls, &sa, @sizeOf(sockaddr_in)) != 0) {
        log.print("health: bind failed");
        _ = closesocket(ls);
        return 1;
    }
    if (listen(ls, 8) != 0) {
        log.print("health: listen failed");
        _ = closesocket(ls);
        return 1;
    }
    log.hex("health: HTTP endpoint up on port 0x", health_port);
    var last_beat: u32 = beat;
    var last_ms: u32 = GetTickCount();
    while (true) {
        const cs = accept(ls, null, null);
        if (cs == INVALID_SOCKET) continue;
        var dump: [512]u8 = undefined;
        _ = recv(cs, &dump, dump.len, 0); // drain + ignore the request line
        const now = GetTickCount();
        const cur = beat;
        if (cur != last_beat) {
            last_beat = cur;
            last_ms = now; // tick advanced — refresh liveness
        }
        const healthy = headless.server_ready and (now -% last_ms) < stale_ms;
        const resp = if (healthy) ok_resp else bad_resp;
        _ = send(cs, resp.ptr, @intCast(resp.len), 0);
        _ = closesocket(cs);
    }
}

/// Spawn the health listener. Port from D2GS_HEALTH_PORT (default 8086). Safe to call
/// before the server is ready — it just answers 503 until the tick loop starts beating.
pub fn start() void {
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
