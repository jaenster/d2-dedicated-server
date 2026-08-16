//! In-process HTTP observability endpoint for the headless GS.
//!
//! A tiny winsock listener on its own thread, routed by path:
//!   /          — the original single-answer endpoint (200 ok / 503 down); the shipped k8s chart
//!                probes it, so renaming breaks every running pod on the next config reload.
//!   /healthz   — liveness, from the engine heartbeat ONLY: a wedged engine still accepts sockets
//!                and replies 200, which is the failure this must catch (see run-stress.sh).
//!   /readyz    — published into the realm's shared store; a live-but-unpublished GS is not ready.
//!   /stats     — counters as JSON (runtime/feature/stats.zig); /metrics is the same in Prometheus.
//!
//! Liveness = `beat` advancing (tick loop calls tick() every frame); stale too long -> fail.
//! Rendering uses this thread's own buffer, so a stalled HTTP client costs the tick loop nothing.
const std = @import("std");
const win = std.os.windows;
const log = @import("../../log.zig");
const headless = @import("headless.zig");
const stats = @import("stats.zig");
const d2cs = @import("../../realmclient/d2cs.zig");

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
const notready_resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 10\r\nConnection: close\r\n\r\nnot ready\n";

/// The request path, as a slice of `req`. Anything we can't parse reads as "/" so a
/// malformed request gets the historical answer rather than an error.
fn pathOf(req: []const u8) []const u8 {
    var i: usize = 0;
    while (i < req.len and req[i] != ' ') : (i += 1) {} // skip the method
    i += 1;
    if (i >= req.len) return "/";
    var j = i;
    while (j < req.len and req[j] != ' ' and req[j] != '?' and req[j] != '\r' and req[j] != '\n') : (j += 1) {}
    if (j == i) return "/";
    return req[i..j];
}

/// Body big enough for 32 games plus the per-code table; sits on the health thread's
/// stack, so it never competes with the engine for the FOG pools.
const body_cap = 32 * 1024;

fn sendBody(cs: SOCKET, content_type: []const u8, body: []const u8) void {
    var head: [160]u8 = undefined;
    const h = std.fmt.bufPrint(
        &head,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ content_type, body.len },
    ) catch return;
    _ = send(cs, h.ptr, @intCast(h.len), 0);
    if (body.len > 0) _ = send(cs, body.ptr, @intCast(body.len), 0);
}

fn sendText(cs: SOCKET, resp: []const u8) void {
    _ = send(cs, resp.ptr, @intCast(resp.len), 0);
}

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
    var body: [body_cap]u8 = undefined;
    while (true) {
        const cs = accept(ls, null, null);
        if (cs == INVALID_SOCKET) continue;
        var req: [512]u8 = undefined;
        const got = recv(cs, &req, req.len, 0);
        const path = if (got > 0) pathOf(req[0..@intCast(got)]) else "/";
        const now = GetTickCount();
        const cur = beat;
        if (cur != last_beat) {
            last_beat = cur;
            last_ms = now; // tick advanced — refresh liveness
        }
        // The one question every probe reduces to: is the ENGINE still stepping? Measured
        // from the tick loop's heartbeat, so a process that is up while its server thread
        // is dead answers 503 — which is the whole point of having this endpoint at all.
        const alive = headless.server_ready and (now -% last_ms) < stale_ms;
        if (std.mem.eql(u8, path, "/stats")) {
            sendBody(cs, "application/json", stats.writeJson(&body));
        } else if (std.mem.eql(u8, path, "/metrics")) {
            sendBody(cs, "text/plain; version=0.0.4", stats.writeMetrics(&body));
        } else if (std.mem.eql(u8, path, "/readyz")) {
            // Ready is strictly narrower than alive: the engine must be stepping AND the
            // realm must know about us, or a game routed here has nowhere to land.
            sendText(cs, if (alive and d2cs.registered) ok_resp else notready_resp);
        } else {
            // "/", "/healthz", and anything else: the original liveness answer.
            sendText(cs, if (alive) ok_resp else bad_resp);
        }
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
