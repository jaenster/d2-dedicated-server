//! Tiny thread-safe logger for realmd and the gateway: one line, one write(2).
//!
//! Not std.debug.print: it takes std's stderr mutex and flushes its own 64-byte buffer per
//! call, so a JSON line built a character at a time cost a syscall per character, all of it
//! under this file's lock. Building the line in one buffer holds the lock for one write.
//!
//! stderr because k8s captures it; one write per line is what stops concurrent threads
//! interleaving halves of each other's output.
const std = @import("std");
const obs = @import("obs"); // per-thread trace/span/account context, stamped on every JSON line
const Lock = @import("lock.zig").Lock;

extern "c" fn time(t: ?*c_long) c_long; // unix seconds (std.time.timestamp went through Io in 0.16)
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

const STDERR: c_int = 2;

/// A longer line is truncated rather than split across writes: a clipped line reads better
/// than two interleaved halves.
const LINE_MAX = 4096;

var out_lock: Lock = .{};

/// Emit structured JSON lines (`{"ts","tag","msg"}`) instead of `[tag] msg` when
/// set (REALMD_LOG_JSON) — for log collectors that parse JSON. Set by main().
pub var json: bool = false;

/// A fixed line buffer whose appends are all bounded, so a runaway format argument clips the
/// line instead of smearing over the stack.
const Line = struct {
    buf: [LINE_MAX]u8 = undefined,
    len: usize = 0,

    fn add(self: *Line, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch {
            self.len = self.buf.len; // no room left; further appends are no-ops
            return;
        };
        self.len += written.len;
    }

    fn addStr(self: *Line, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn addByte(self: *Line, c: u8) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = c;
        self.len += 1;
    }

    /// Append `s` with the escapes a JSON string value requires.
    fn addJsonStr(self: *Line, s: []const u8) void {
        for (s) |c| switch (c) {
            '"' => self.addStr("\\\""),
            '\\' => self.addStr("\\\\"),
            '\n' => self.addStr("\\n"),
            '\t' => self.addStr("\\t"),
            else => self.addByte(c),
        };
    }

    fn flush(self: *Line) void {
        emit(self.buf[0..self.len]);
        self.len = 0;
    }

    fn room(self: *Line) usize {
        return self.buf.len - self.len;
    }
};

/// One write, under the lock so lines don't interleave. A short write is looped; a failing
/// write drops the line — blocking a connection handler on a wedged stderr is worse.
fn emit(buf: []const u8) void {
    if (buf.len == 0) return;
    out_lock.lock();
    defer out_lock.unlock();
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(STDERR, buf.ptr + off, buf.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// `[tag] <formatted line>`, or a JSON object when `json` is set.
pub fn line(tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    var out: Line = .{};
    if (json) {
        out.add("{{\"ts\":{d},\"tag\":\"{s}\",\"msg\":\"", .{ time(null), tag });
        // Format the message on its own first so it can be escaped as a JSON string value.
        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch msg_buf[0..0];
        out.addJsonStr(msg);
        out.addByte('"');
        // ambient per-thread trace/span + the user this connection is acting for
        const c = obs.current();
        if (c.hasTrace()) {
            var th: [32]u8 = undefined;
            out.add(",\"trace\":\"{s}\",\"span\":{d}", .{ obs.traceHex(&th, c.trace_hi, c.trace_lo), c.span });
            if (c.parent != 0) out.add(",\"parent\":{d}", .{c.parent});
        }
        if (c.acct_len != 0) out.add(",\"acct\":\"{s}\"", .{c.account()});
        if (c.token != 0) out.add(",\"token\":{d}", .{c.token});
        out.addStr("}\n");
    } else {
        out.add("[{s}] ", .{tag});
        out.add(fmt ++ "\n", args);
    }
    out.flush();
}

/// Hex+ASCII dump of a byte slice (protocol discovery / capture mode). Rows accumulate into
/// the line buffer and go out in whole-buffer writes.
pub fn hexdump(tag: []const u8, data: []const u8) void {
    // 16 bytes render as "  0000  " + 16*3 + " |" + 16 + "|\n" = 78 columns.
    const ROW_MAX = 80;
    var out: Line = .{};
    out.add("[{s}] {d} bytes:\n", .{ tag, data.len });
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        if (out.room() < ROW_MAX) out.flush();
        const row = data[i..@min(i + 16, data.len)];
        out.add("  {x:0>4}  ", .{i});
        for (0..16) |j| {
            if (j < row.len) out.add("{x:0>2} ", .{row[j]}) else out.addStr("   ");
        }
        out.addStr(" |");
        for (row) |b| out.addByte(if (b >= 0x20 and b < 0x7f) b else '.');
        out.addStr("|\n");
    }
    out.flush();
}

test "a plain line is tagged and newline-terminated" {
    var out: Line = .{};
    out.add("[{s}] ", .{"bnet"});
    out.add("games={d}\n", .{3});
    try std.testing.expectEqualStrings("[bnet] games=3\n", out.buf[0..out.len]);
}

test "json string values are escaped" {
    var out: Line = .{};
    out.addJsonStr("say \"hi\"\tnow\\then\n");
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\tnow\\\\then\\n", out.buf[0..out.len]);
}

test "an oversized append truncates instead of overflowing" {
    var out: Line = .{};
    const big = [_]u8{'x'} ** (LINE_MAX + 100);
    out.addStr(&big);
    try std.testing.expectEqual(@as(usize, LINE_MAX), out.len);
    out.addByte('!'); // no room left: a no-op, not a write past the end
    try std.testing.expectEqual(@as(usize, LINE_MAX), out.len);
}
