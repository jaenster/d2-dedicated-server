//! Minimal HTTP health endpoint for k8s probes. The game protocols are raw TCP, so
//! we expose liveness/readiness over a tiny separate HTTP listener instead.
//!
//!   GET /healthz  -> 200 once the listeners are up (liveness: don't restart me)
//!   GET /readyz   -> 200 only when this pod can actually serve a client right now:
//!                    started AND not draining AND the store backend is reachable
//!                    AND (if REALMD_REQUIRE_GS) at least one game server registered.
//!                    503 otherwise, so k8s keeps it out of the Service endpoints.
//!
//! Readiness reflects real dependencies (store + GS), not just "process alive", so a
//! pod that can't reach its database or has no game server is not sent traffic.
const std = @import("std");
const net = @import("net.zig");
const gslink = @import("gslink.zig");
const store = @import("store.zig");
const shutdown = @import("shutdown.zig");

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
    if (require_gs and !gslink.ready()) return "no game server";
    return null; // ready
}

pub fn handle(fd: net.Socket, tag: []const u8) void {
    _ = tag;
    var buf: [1024]u8 = undefined;
    const n = net.readSome(fd, &buf);
    if (n == 0) return;
    const path = parsePath(buf[0..n]);

    if (std.mem.eql(u8, path, "/healthz")) {
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
    } else {
        respond(fd, not_found, "not found\n");
    }
}
