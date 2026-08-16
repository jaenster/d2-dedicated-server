//! Little-endian byte reader/writer shared by all three protocols (BNCS / MCP /
//! d2gs / d2dbs differ only in their framing header, not their field encoding).
//! Bounds are checked: a malformed packet yields zeros/empties and sets `.bad`
//! rather than panicking a connection thread — a server must not crash on input.
const std = @import("std");

/// Bounds-checked packet builder. Every write is capacity-checked and a write that would not fit
/// is DROPPED, latching `overflowed`, instead of the old unchecked `@memcpy` (an OOB slice panic
/// in a safe build, taking down the connection thread or process on ordinary input like an
/// oversized friends list or userdata read). Truncating silently is also not fine — callers that
/// can produce unbounded output should check `overflowed`; the guarantee is a bad reply, not a
/// dead server.
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,
    /// Set once a write did not fit. Never cleared.
    overflowed: bool = false,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// Reserve `n` bytes, or record the overflow and refuse. Returns the slice to fill.
    fn take(w: *Writer, n: usize) ?[]u8 {
        if (w.pos + n > w.buf.len) {
            w.overflowed = true;
            return null;
        }
        const s = w.buf[w.pos..][0..n];
        w.pos += n;
        return s;
    }

    /// Bytes still available.
    pub fn room(w: *const Writer) usize {
        return w.buf.len - w.pos;
    }

    pub fn putU8(w: *Writer, v: u8) void {
        const s = w.take(1) orelse return;
        s[0] = v;
    }
    pub fn putU16(w: *Writer, v: u16) void {
        const s = w.take(2) orelse return;
        std.mem.writeInt(u16, s[0..2], v, .little);
    }
    pub fn putU32(w: *Writer, v: u32) void {
        const s = w.take(4) orelse return;
        std.mem.writeInt(u32, s[0..4], v, .little);
    }
    pub fn putU64(w: *Writer, v: u64) void {
        const s = w.take(8) orelse return;
        std.mem.writeInt(u64, s[0..8], v, .little);
    }
    pub fn putBytes(w: *Writer, b: []const u8) void {
        const s = w.take(b.len) orelse return;
        @memcpy(s, b);
    }
    /// Null-terminated string. All-or-nothing: a string that does not fit with its
    /// terminator is not written at half length.
    pub fn putStr(w: *Writer, s: []const u8) void {
        if (w.pos + s.len + 1 > w.buf.len) {
            w.overflowed = true;
            return;
        }
        w.putBytes(s);
        w.putU8(0);
    }
    pub fn zeros(w: *Writer, n: usize) void {
        const s = w.take(n) orelse return;
        @memset(s, 0);
    }
    /// Overwrite a u16 already written at `at` (length back-patching).
    pub fn patchU16(w: *Writer, at: usize, v: u16) void {
        if (at + 2 > w.buf.len) return;
        std.mem.writeInt(u16, w.buf[at..][0..2], v, .little);
    }
    /// Overwrite a u32 already written at `at` (length back-patching).
    pub fn patchU32(w: *Writer, at: usize, v: u32) void {
        if (at + 4 > w.buf.len) return;
        std.mem.writeInt(u32, w.buf[at..][0..4], v, .little);
    }
    pub fn slice(w: *Writer) []u8 {
        return w.buf[0..w.pos];
    }
};

test "a writer refuses to run past its buffer instead of panicking" {
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    w.putU32(0x11223344);
    try std.testing.expect(!w.overflowed);
    w.putBytes("abcdefghij"); // 10 into the 4 that remain
    try std.testing.expect(w.overflowed);
    try std.testing.expectEqual(@as(usize, 4), w.pos); // the oversized write was dropped whole
}

test "a string that does not fit with its terminator is not half-written" {
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    w.putBytes("abcd");
    w.putStr("efgh"); // 4 bytes + NUL = 5, only 4 left
    try std.testing.expect(w.overflowed);
    try std.testing.expectEqual(@as(usize, 4), w.pos);
    w.putStr("xyz"); // 3 + NUL = 4, exactly fits
    try std.testing.expectEqual(@as(usize, 8), w.pos);
    try std.testing.expectEqualSlices(u8, "abcdxyz\x00", buf[0..8]);
}

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    bad: bool = false,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }
    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.pos + n > r.buf.len) {
            r.bad = true;
            return null;
        }
        const s = r.buf[r.pos..][0..n];
        r.pos += n;
        return s;
    }
    pub fn getU8(r: *Reader) u8 {
        const s = r.take(1) orelse return 0;
        return s[0];
    }
    pub fn getU16(r: *Reader) u16 {
        const s = r.take(2) orelse return 0;
        return std.mem.readInt(u16, s[0..2], .little);
    }
    pub fn getU32(r: *Reader) u32 {
        const s = r.take(4) orelse return 0;
        return std.mem.readInt(u32, s[0..4], .little);
    }
    pub fn getU64(r: *Reader) u64 {
        const s = r.take(8) orelse return 0;
        return std.mem.readInt(u64, s[0..8], .little);
    }
    pub fn skip(r: *Reader, n: usize) void {
        _ = r.take(n);
    }
    /// Read exactly 20 bytes (a hash); zeros on underflow (sets .bad).
    pub fn take20(r: *Reader) *const [20]u8 {
        const zero = &[_]u8{0} ** 20;
        const s = r.take(20) orelse return zero;
        return s[0..20];
    }
    /// Read a null-terminated string (slice excludes the null; advances past it).
    pub fn getStr(r: *Reader) []const u8 {
        const start = r.pos;
        while (r.pos < r.buf.len) : (r.pos += 1) {
            if (r.buf[r.pos] == 0) {
                const s = r.buf[start..r.pos];
                r.pos += 1; // consume null
                return s;
            }
        }
        r.bad = true;
        return r.buf[start..r.pos];
    }
    pub fn remaining(r: *Reader) usize {
        return r.buf.len - r.pos;
    }
};
