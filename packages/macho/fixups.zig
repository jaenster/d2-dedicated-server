//! dyld's fixup streams, as bytecode.
//!
//! A Mach-O does not list "relocate this word" or "import this symbol" as records; it ships two
//! tiny programs whose state machines emit them. Rebase says where pointers live so the image can
//! be loaded anywhere; bind says which slot wants which name from which library.
//!
//! Both are visitor-driven, because the same walk answers two different questions: on a build host
//! it enumerates the imports so the shim table can be generated, and on the target it writes the
//! addresses in.

const std = @import("std");
const image = @import("image.zig");

pub const Error = error{ Truncated, BadOpcode, BadSegment };

/// i386. Every stride and slot in these streams is one pointer wide.
pub const ptr_size: u32 = 4;

// The ADD_ADDR opcodes take a ULEB that dyld adds with wraparound, so a backwards step is encoded
// as a huge unsigned value. Checked addition rejects the real streams.

pub const RebaseType = enum(u8) { pointer = 1, text_absolute32 = 2, text_pcrel32 = 3, _ };
pub const BindType = enum(u8) { pointer = 1, text_absolute32 = 2, text_pcrel32 = 3, _ };

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return Error.Truncated;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn uleb(self: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            shift = std.math.add(u6, shift, 7) catch return Error.BadOpcode;
        }
    }

    fn sleb(self: *Reader) Error!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(i64, b & 0x7f) << shift;
            shift = std.math.add(u6, shift, 7) catch return Error.BadOpcode;
            if (b & 0x80 == 0) {
                if (shift < 64 and b & 0x40 != 0) result |= @as(i64, -1) << shift;
                return result;
            }
        }
    }

    /// Symbol names sit inline in the bind stream, null-terminated. That is why binding needs no
    /// symbol table.
    fn cstr(self: *Reader) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and self.bytes[self.pos] != 0) self.pos += 1;
        if (self.pos >= self.bytes.len) return Error.Truncated;
        defer self.pos += 1;
        return self.bytes[start..self.pos];
    }
};

/// Where a fixup lands. Segment-relative rather than absolute, because the stream is written
/// before anyone knows where the image will be mapped.
pub const Site = struct {
    segment: usize,
    offset: u64,
};

/// `visitor` needs `fn rebase(self, Site, RebaseType) !void`.
pub fn walkRebase(bytes: []const u8, visitor: anytype) !void {
    var r: Reader = .{ .bytes = bytes };
    var kind: RebaseType = .pointer;
    var seg: usize = 0;
    var off: u64 = 0;

    while (r.pos < bytes.len) {
        const op = try r.byte();
        const imm: u8 = op & 0x0f;
        switch (op & 0xf0) {
            0x00 => return, // DONE
            0x10 => kind = @enumFromInt(imm),
            0x20 => {
                seg = imm;
                off = try r.uleb();
            },
            0x30 => off +%= try r.uleb(),
            0x40 => off += @as(u64, imm) * ptr_size,
            0x50 => for (0..imm) |_| {
                try visitor.rebase(.{ .segment = seg, .offset = off }, kind);
                off += ptr_size;
            },
            0x60 => {
                const count = try r.uleb();
                var i: u64 = 0;
                while (i < count) : (i += 1) {
                    try visitor.rebase(.{ .segment = seg, .offset = off }, kind);
                    off += ptr_size;
                }
            },
            0x70 => {
                try visitor.rebase(.{ .segment = seg, .offset = off }, kind);
                off +%= ptr_size +% try r.uleb();
            },
            0x80 => {
                const count = try r.uleb();
                const skip = try r.uleb();
                var i: u64 = 0;
                while (i < count) : (i += 1) {
                    try visitor.rebase(.{ .segment = seg, .offset = off }, kind);
                    off += ptr_size + skip;
                }
            },
            else => return Error.BadOpcode,
        }
    }
}

/// `visitor` needs `fn bind(self, Site, BindType, name: []const u8, addend: i64) !void`.
///
/// `stop_at_done` separates the two streams that share this bytecode: the eager stream ends at the
/// first DONE, while the lazy stream terminates every entry with one and keeps going. Reading the
/// lazy stream with eager rules finds exactly one import out of a thousand.
pub fn walkBind(bytes: []const u8, stop_at_done: bool, visitor: anytype) !void {
    var r: Reader = .{ .bytes = bytes };
    var kind: BindType = .pointer;
    var seg: usize = 0;
    var off: u64 = 0;
    var addend: i64 = 0;
    var name: []const u8 = "";

    while (r.pos < bytes.len) {
        const op = try r.byte();
        const imm: u8 = op & 0x0f;
        switch (op & 0xf0) {
            0x00 => if (stop_at_done) return,
            // Which dylib a name comes from. We resolve by name alone: the shim is one namespace,
            // and no symbol in this binary is ambiguous across the twenty frameworks it links.
            0x10 => {},
            0x20 => _ = try r.uleb(),
            0x30 => {},
            // The immediate carries weak/non-weak-definition flags. Nothing in this image is weak.
            0x40 => name = try r.cstr(),
            0x50 => kind = @enumFromInt(imm),
            0x60 => addend = try r.sleb(),
            0x70 => {
                seg = imm;
                off = try r.uleb();
            },
            0x80 => off +%= try r.uleb(),
            0x90 => {
                try visitor.bind(.{ .segment = seg, .offset = off }, kind, name, addend);
                off += ptr_size;
            },
            0xa0 => {
                try visitor.bind(.{ .segment = seg, .offset = off }, kind, name, addend);
                off +%= ptr_size +% try r.uleb();
            },
            0xb0 => {
                try visitor.bind(.{ .segment = seg, .offset = off }, kind, name, addend);
                off += ptr_size + @as(u64, imm) * ptr_size;
            },
            0xc0 => {
                const count = try r.uleb();
                const skip = try r.uleb();
                var i: u64 = 0;
                while (i < count) : (i += 1) {
                    try visitor.bind(.{ .segment = seg, .offset = off }, kind, name, addend);
                    off += ptr_size + skip;
                }
            },
            else => return Error.BadOpcode,
        }
    }
}

/// Absolute address of a fixup site once the image is mapped at `slide`.
pub fn resolve(img: *const image.Image, site: Site, slide: i64) Error!u32 {
    const segs = img.segments();
    if (site.segment >= segs.len) return Error.BadSegment;
    const s = segs[site.segment];
    if (site.offset > s.vmsize) return Error.BadSegment;
    const base: i64 = @as(i64, s.vmaddr) + slide;
    return @intCast(base + @as(i64, @intCast(site.offset)));
}
