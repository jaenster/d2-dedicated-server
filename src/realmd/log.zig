//! Tiny thread-safe logger for realmd. Writes to stderr (k8s captures it). A
//! spinlock serialises lines so concurrent connection threads don't interleave.
//! (std.Thread.Mutex moved in 0.16's Io migration; a flag spinlock has no such
//! dependency and is fine for log contention.)
const std = @import("std");

var held = std.atomic.Value(bool).init(false);

fn lock() void {
    while (held.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn unlock() void {
    held.store(false, .release);
}

/// `[tag] <formatted line>`.
pub fn line(tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    lock();
    defer unlock();
    std.debug.print("[{s}] ", .{tag});
    std.debug.print(fmt ++ "\n", args);
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
