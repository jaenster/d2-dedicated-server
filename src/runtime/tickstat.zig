//! What one server tick costs, against how many games are live.
//!
//! `QSERVER_TickAllGames` steps EVERY game on this process on ONE thread, and D2 logic runs at
//! 25 fps — so the budget for a whole tick is 40 ms no matter how many games share it. That
//! makes CPU, not memory, the thing most likely to cap games per process: raising Fog's
//! eight-manager ceiling buys nothing if seven games already eat the frame.
//!
//! So measure before cutting into the allocator. This reports average and worst tick time per
//! game count, which extrapolates directly: if N games cost T ms, the ceiling is where T hits
//! 40 ms.

const std = @import("std");
const log = @import("../log.zig");
const memstat = @import("memstat.zig");

extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;

var freq: i64 = 0;
var start: i64 = 0;

// Accumulated per games-live bucket, so a busy server reports cost against load rather than one
// meaningless average over every mix it has seen.
const MAX_BUCKET = 16;
var ticks: [MAX_BUCKET]u32 = .{0} ** MAX_BUCKET;
var total_us: [MAX_BUCKET]u64 = .{0} ** MAX_BUCKET;
var worst_us: [MAX_BUCKET]u64 = .{0} ** MAX_BUCKET;
var since_report: u32 = 0;

pub fn begin() void {
    if (freq == 0) _ = QueryPerformanceFrequency(&freq);
    _ = QueryPerformanceCounter(&start);
}

/// Close the tick and attribute it to `games`. Reports every 500 ticks (~5 s at 100 Hz).
pub fn end(games: u32) void {
    if (freq == 0) return;
    var now: i64 = 0;
    _ = QueryPerformanceCounter(&now);
    const us: u64 = @intCast(@divTrunc((now - start) * 1_000_000, freq));
    const b = @min(games, MAX_BUCKET - 1);
    ticks[b] +%= 1;
    total_us[b] +%= us;
    if (us > worst_us[b]) worst_us[b] = us;

    since_report +%= 1;
    if (!memstat.diag_enabled) return; // measuring is opt-in; the counters keep accumulating
    if (since_report < 500) return;
    since_report = 0;
    var i: usize = 0;
    while (i < MAX_BUCKET) : (i += 1) {
        if (ticks[i] == 0) continue;
        // games, average microseconds, worst microseconds — 40000 us is the 25 fps budget.
        const avg: usize = @intCast(total_us[i] / ticks[i]);
        const worst: usize = @intCast(worst_us[i]);
        log.hex3("tick: games / avg us / worst us:", i, avg, worst);
    }
}
