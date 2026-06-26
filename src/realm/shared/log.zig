//! Tiny thread-safe logger for realmd. Writes to stderr (k8s captures it). A
//! spinlock serialises lines so concurrent connection threads don't interleave.
//! (std.Thread.Mutex moved in 0.16's Io migration; a flag spinlock has no such
//! dependency and is fine for log contention.)
const std = @import("std");
const obs = @import("obs.zig"); // per-thread trace/span/account context, stamped on every JSON line

extern "c" fn time(t: ?*c_long) c_long; // unix seconds (std.time.timestamp went through Io in 0.16)

var held = std.atomic.Value(bool).init(false);

/// Emit structured JSON lines (`{"ts","tag","msg"}`) instead of `[tag] msg` when
/// set (REALMD_LOG_JSON) — for log collectors that parse JSON. Set by main().
pub var json: bool = false;

fn lock() void {
    while (held.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn unlock() void {
    held.store(false, .release);
}

/// `[tag] <formatted line>`, or a JSON object when `json` is set.
pub fn line(tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    lock();
    defer unlock();
    if (json) {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        std.debug.print("{{\"ts\":{d},\"tag\":\"{s}\",\"msg\":\"", .{ time(null), tag });
        for (msg) |c| switch (c) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\t' => std.debug.print("\\t", .{}),
            else => std.debug.print("{c}", .{c}),
        };
        std.debug.print("\"", .{});
        // ambient per-thread trace/span + the user this connection is acting for
        const c = obs.current();
        if (c.hasTrace()) {
            var th: [32]u8 = undefined;
            std.debug.print(",\"trace\":\"{s}\",\"span\":{d}", .{ obs.traceHex(&th, c.trace_hi, c.trace_lo), c.span });
            if (c.parent != 0) std.debug.print(",\"parent\":{d}", .{c.parent});
        }
        if (c.acct_len != 0) std.debug.print(",\"acct\":\"{s}\"", .{c.account()});
        if (c.token != 0) std.debug.print(",\"token\":{d}", .{c.token});
        std.debug.print("}}\n", .{});
    } else {
        std.debug.print("[{s}] ", .{tag});
        std.debug.print(fmt ++ "\n", args);
    }
}

/// Hex+ASCII dump of a byte slice (protocol discovery / capture mode).
pub fn hexdump(tag: []const u8, data: []const u8) void {
    lock();
    defer unlock();
    std.debug.print("[{s}] {d} bytes:\n", .{ tag, data.len });
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const row = data[i..@min(i + 16, data.len)];
        std.debug.print("  {x:0>4}  ", .{i});
        for (0..16) |j| {
            if (j < row.len) std.debug.print("{x:0>2} ", .{row[j]}) else std.debug.print("   ", .{});
        }
        std.debug.print(" |", .{});
        for (row) |b| std.debug.print("{c}", .{if (b >= 0x20 and b < 0x7f) b else '.'});
        std.debug.print("|\n", .{});
    }
}
