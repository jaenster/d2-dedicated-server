//! Graceful shutdown for k8s. On SIGTERM/SIGINT we flip `draining`, which makes the
//! health endpoint report /readyz as 503 so the cluster removes this pod from the
//! Service endpoints (stops sending it new connections). After a grace period — long
//! enough for the load balancer to converge and in-flight requests to finish — the
//! process exits 0. GS control links simply drop on exit; each GS reconnects to a
//! surviving realmd.
//!
//! The signal handler does only an async-signal-safe atomic store; a monitor thread
//! observes the flag and performs the (sleep + exit) drain off the signal context.
const std = @import("std");
const log = @import("realm_infra").log;

extern "c" fn usleep(usec: c_uint) c_int; // std.Thread.sleep went through Io in 0.16

pub var draining = std.atomic.Value(bool).init(false);
var grace_ms: u32 = 5000;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    draining.store(true, .release);
}

/// Sleep `ms` in ≤1s chunks (keeps the usleep argument well within c_uint).
fn sleepMs(ms: u32) void {
    var left = ms;
    while (left > 0) {
        const chunk: u32 = @min(left, 1000); // explicit u32: @min narrows the type otherwise
        _ = usleep(chunk * 1000);
        left -= chunk;
    }
}

fn monitor() void {
    while (!draining.load(.acquire)) sleepMs(100);
    log.line("realmd", "SIGTERM/SIGINT received — draining ({d}ms; /readyz now 503)", .{grace_ms});
    sleepMs(grace_ms);
    log.line("realmd", "drain complete — exiting 0", .{});
    std.process.exit(0);
}

/// Install SIGTERM/SIGINT handlers and start the drain monitor. `grace` is how long
/// to keep serving (reporting not-ready) after a signal before exiting.
pub fn install(grace: u32) void {
    grace_ms = grace;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
    const t = std.Thread.spawn(.{}, monitor, .{}) catch {
        log.line("realmd", "WARNING could not start shutdown monitor thread", .{});
        return;
    };
    t.detach();
}
