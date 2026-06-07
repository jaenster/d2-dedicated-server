//! Little-endian byte reader/writer shared by all three protocols (BNCS / MCP /
//! d2gs / d2dbs differ only in their framing header, not their field encoding).
//! Bounds are checked: a malformed packet yields zeros/empties and sets `.bad`
//! rather than panicking a connection thread — a server must not crash on input.
const std = @import("std");

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }
    pub fn putU8(w: *Writer, v: u8) void {
        w.buf[w.pos] = v;
        w.pos += 1;
    }
    pub fn putU16(w: *Writer, v: u16) void {
        std.mem.writeInt(u16, w.buf[w.pos..][0..2], v, .little);
        w.pos += 2;
    }
    pub fn putU32(w: *Writer, v: u32) void {
        std.mem.writeInt(u32, w.buf[w.pos..][0..4], v, .little);
        w.pos += 4;
    }
    pub fn putU64(w: *Writer, v: u64) void {
        std.mem.writeInt(u64, w.buf[w.pos..][0..8], v, .little);
        w.pos += 8;
    }
    pub fn putBytes(w: *Writer, b: []const u8) void {
        @memcpy(w.buf[w.pos..][0..b.len], b);
        w.pos += b.len;
    }
    /// Null-terminated string.
    pub fn putStr(w: *Writer, s: []const u8) void {
        w.putBytes(s);
        w.putU8(0);
    }
    pub fn zeros(w: *Writer, n: usize) void {
        @memset(w.buf[w.pos..][0..n], 0);
        w.pos += n;
    }
    /// Overwrite a u16 already written at `at` (length back-patching).
    pub fn patchU16(w: *Writer, at: usize, v: u16) void {
        std.mem.writeInt(u16, w.buf[at..][0..2], v, .little);
    }
    /// Overwrite a u32 already written at `at` (length back-patching).
    pub fn patchU32(w: *Writer, at: usize, v: u32) void {
        std.mem.writeInt(u32, w.buf[at..][0..4], v, .little);
    }
    pub fn slice(w: *Writer) []u8 {
        return w.buf[0..w.pos];
    }
};

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
