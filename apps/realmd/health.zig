//! Minimal HTTP health endpoint for k8s probes. The game protocols are raw TCP, so this exposes
//! liveness/readiness over a tiny separate HTTP listener instead.
//!
//!   GET /healthz -> 200 once the listeners are up (liveness: don't restart me)
//!   GET /readyz  -> 200 only if started AND not draining AND store reachable AND (if
//!                   REALMD_REQUIRE_GS) a game server is registered; 503 otherwise so k8s
//!                   keeps the pod out of Service endpoints.
const std = @import("std");
const net = @import("realm_infra").net;
const fleet = @import("fleet.zig");
const store = @import("store.zig");
const shutdown = @import("shutdown.zig");
const admin = @import("admin.zig");
const webui = @import("webui.zig");

/// When set (REALMD_REQUIRE_GS), /readyz only goes green once ≥1 GS is registered —
/// so the pod isn't routed client traffic before it can actually host games.
pub var require_gs: bool = false;
/// Flipped true by main() once all listeners are bound and serving. Until then both
/// probes report not-up, so k8s waits for a clean start.
var started = std.atomic.Value(bool).init(false);

pub fn markStarted() void {
    started.store(true, .release);
}

const Status = struct { code: u16, text: []const u8 };
const ok: Status = .{ .code = 200, .text = "200 OK" };
const unavailable: Status = .{ .code = 503, .text = "503 Service Unavailable" };
const not_found: Status = .{ .code = 404, .text = "404 Not Found" };

fn parsePath(req: []const u8) []const u8 {
    const sp1 = std.mem.indexOfScalar(u8, req, ' ') orelse return "";
    const rest = req[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return rest;
    return rest[0..sp2];
}

/// The HTTP method (the token before the first space on the request line).
fn parseMethod(req: []const u8) []const u8 {
    const sp1 = std.mem.indexOfScalar(u8, req, ' ') orelse return "";
    return req[0..sp1];
}

fn respond(fd: net.Socket, status: Status, body: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status.text, body.len, body }) catch return;
    _ = net.writeAll(fd, msg);
}

/// Why readiness is/ isn't green — returned in the body so probes are debuggable.
fn readyReason() ?[]const u8 {
    if (!started.load(.acquire)) return "starting";
    if (shutdown.draining.load(.acquire)) return "draining";
    if (!store.healthy()) return "store unreachable";
    if (require_gs and !fleet.ready()) return "no game server";
    return null; // ready
}

/// Case-insensitive scan of the header block for `Content-Length`, returns its value (0 if absent).
fn contentLength(headers: []const u8) usize {
    var i: usize = 0;
    while (i + 15 <= headers.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(headers[i .. i + 15], "content-length:")) {
            var j = i + 15;
            while (j < headers.len and (headers[j] == ' ' or headers[j] == '\t')) j += 1;
            var v: usize = 0;
            while (j < headers.len and headers[j] >= '0' and headers[j] <= '9') : (j += 1) v = v * 10 + (headers[j] - '0');
            return v;
        }
    }
    return 0;
}

/// Read a full HTTP request: loop until we have the header terminator (\r\n\r\n) plus
/// the Content-Length body bytes. A single readSome can return just the head (the body
/// arrives in a later TCP segment) — which silently truncated POST bodies before.
fn readRequest(fd: net.Socket, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = net.readSome(fd, buf[total..]);
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |hdr_end| {
            const body_start = hdr_end + 4;
            if (total - body_start >= contentLength(buf[0..hdr_end])) break;
        }
    }
    return total;
}

pub fn handle(fd: net.Socket, tag: []const u8) void {
    _ = tag;
    var buf: [2048]u8 = undefined;
    const n = readRequest(fd, &buf);
    if (n == 0) return;
    const req = buf[0..n];
    const path = parsePath(req);

    if (std.mem.startsWith(u8, path, "/admin/")) {
        // Admin API: token-gated, JSON. Health probes stay unauthenticated above.
        admin.handle(fd, parseMethod(req), path, req);
    } else if (std.mem.eql(u8, path, "/healthz")) {
        // Liveness: alive once we've started; the process answering at all is the
        // signal. We never go un-live on drain (that's readiness' job, not restart's).
        if (started.load(.acquire)) respond(fd, ok, "ok\n") else respond(fd, unavailable, "starting\n");
    } else if (std.mem.eql(u8, path, "/readyz")) {
        if (readyReason()) |why| {
            var b: [64]u8 = undefined;
            respond(fd, unavailable, std.fmt.bufPrint(&b, "not ready: {s}\n", .{why}) catch "not ready\n");
        } else {
            respond(fd, ok, "ready\n");
        }
    } else if (std.mem.eql(u8, parseMethod(req), "GET")) {
        // Everything else is the admin web UI (a single-page app). Only GET; other
        // methods on unknown paths stay a 404.
        webui.handle(fd, path);
    } else {
        respond(fd, not_found, "not found\n");
    }
}
