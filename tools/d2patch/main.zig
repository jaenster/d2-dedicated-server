//! Blizzard PrePatch delta applier — turns a D2 patch-installer record back into a real file.
//!
//! Every member of a `D2Patch_*.exe` / `LODPatch_*.exe` archive is a 24-byte record plus payload,
//! and before 1.11b the payload is a binary delta against the retail install rather than the file
//! itself. This reverses `Ptc.cpp` out of BNUpdate.exe (applier @0x404fee, stream-A @0x4051e9,
//! stream-B @0x4053a3, varints @0x40532a signed / @0x40545d unsigned) so a version can be
//! reconstructed offline instead of by running the installer.
//!
//!   d2patch carve <installer.exe> <out.mpq>       find the MPQ appended after the stub
//!   d2patch info  <record>                        print a record header
//!   d2patch apply <record> <source> <out>         apply a record to its source file
//!
//! Members come out of the archive with `tools/mpqcat` (they are encrypted with FIX_KEY, so
//! extraction needs the real name); this tool takes it from there.

const std = @import("std");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

fn readFile(gpa: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = open(path, @bitCast(std.posix.O{ .ACCMODE = .RDONLY }));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(gpa);
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const flags: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    const fd = open(path, flags, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var sent: usize = 0;
    while (sent < data.len) {
        const n = write(fd, data.ptr + sent, data.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

/// The record that fronts every archive member.
pub const Record = struct {
    header_size: u16,
    kind: u16,
    src_crc32: u32,
    src_size: u32,
    tgt_size: u32,
    tgt_filetime: u64,
    payload: []const u8,

    /// A full file is stored verbatim; anything else is a delta needing the source.
    pub fn isFull(self: Record) bool {
        return self.kind >> 8 == 1;
    }

    pub fn parse(bytes: []const u8) !Record {
        // BNUpdate.exe + D2VidTst.exe ship unwrapped, so a leading MZ is the file itself.
        if (bytes.len >= 2 and bytes[0] == 'M' and bytes[1] == 'Z') return .{
            .header_size = 0,
            .kind = 0x0100,
            .src_crc32 = 0,
            .src_size = 0,
            .tgt_size = @intCast(bytes.len),
            .tgt_filetime = 0,
            .payload = bytes,
        };
        if (bytes.len < 0x18) return error.Truncated;
        const hs = std.mem.readInt(u16, bytes[0..2], .little);
        if (hs != 0x18) return error.BadHeaderSize;
        return .{
            .header_size = hs,
            .kind = std.mem.readInt(u16, bytes[2..4], .little),
            .src_crc32 = std.mem.readInt(u32, bytes[4..8], .little),
            .src_size = std.mem.readInt(u32, bytes[8..12], .little),
            .tgt_size = std.mem.readInt(u32, bytes[12..16], .little),
            .tgt_filetime = std.mem.readInt(u64, bytes[16..24], .little),
            .payload = bytes[hs..],
        };
    }
};

/// The 1/2/3/4-byte varint both streams are coded with. `signed` sign-extends to the width the
/// length actually carries, which is what separates the stream-A reader from the stream-B one.
const Varint = struct {
    value: i32,
    next: usize,

    fn read(b: []const u8, pos: usize, signed: bool) !Varint {
        if (pos >= b.len) return error.Truncated;
        const f = b[pos];
        var v: u32 = undefined;
        var n: usize = undefined;
        var bits: u5 = undefined;
        if (f & 0x80 == 0) {
            v = f & 0x7F;
            n = 1;
            bits = 7;
        } else if (f & 0x40 == 0) {
            v = (f & 0x3F) | (@as(u32, b[pos + 1]) << 6);
            n = 2;
            bits = 14;
        } else if (f & 0x20 == 0) {
            v = (f & 0x1F) | (@as(u32, b[pos + 1]) << 5) | (@as(u32, b[pos + 2]) << 13);
            n = 3;
            bits = 21;
        } else {
            v = (f & 0x1F) | (@as(u32, b[pos + 1]) << 5) | (@as(u32, b[pos + 2]) << 13) |
                (@as(u32, b[pos + 3]) << 21);
            n = 4;
            bits = 29;
        }
        if (pos + n > b.len) return error.Truncated;
        var out: i32 = @bitCast(v);
        if (signed and v & (@as(u32, 1) << (bits - 1)) != 0) {
            out = @bitCast(v -% (@as(u32, 1) << bits));
        }
        return .{ .value = out, .next = pos + n };
    }
};

fn u16At(b: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, b[i..][0..2], .little);
}

fn setU16(b: []u8, i: usize, v: u16) void {
    std.mem.writeInt(u16, b[i..][0..2], v, .little);
}

/// Apply `rec` to `src`, returning the reconstructed file. Caller owns the result.
pub fn apply(gpa: std.mem.Allocator, rec: Record, src: []const u8) ![]u8 {
    if (rec.isFull()) return gpa.dupe(u8, rec.payload[0..rec.tgt_size]);
    if (src.len != rec.src_size) return error.SourceSizeMismatch;
    if (rec.payload.len < 8) return error.Truncated;

    const size_a = std.mem.readInt(u32, rec.payload[0..4], .little);
    const size_b = std.mem.readInt(u32, rec.payload[4..8], .little);
    if (8 + size_a + size_b > rec.payload.len) return error.Truncated;
    const a = rec.payload[8..][0..size_a];
    const b = rec.payload[8 + size_a ..][0..size_b];

    // The source is first-differenced over u16 lanes, high to low, so that code which only moved
    // by a constant differences to a constant and codes almost to nothing.
    const diffed = try gpa.dupe(u8, src);
    defer gpa.free(diffed);
    var i: usize = if (rec.src_size >= 2) rec.src_size - 2 else 0;
    while (i >= 2) : (i -= 2) {
        setU16(diffed, i, u16At(diffed, i) -% u16At(diffed, i - 2));
    }

    const out = try gpa.alloc(u8, rec.tgt_size + 1);
    errdefer gpa.free(out);
    @memset(out, 0);

    var pa: usize = 0;
    var op: usize = 0;
    var sp: usize = 0;
    while (pa < size_a) {
        if (pa + 2 > size_a) return error.Truncated;
        const tok = u16At(a, pa);
        pa += 2;
        const code = tok & 0xC000;
        const len: usize = tok & 0x3FFF;
        if (code == 0x4000 or code == 0x8000) {
            const v = try Varint.read(a, pa, true);
            pa = v.next;
            sp = @intCast(@as(i64, @intCast(sp)) + v.value);
        }
        switch (code) {
            0x0000 => { // literal bytes carried in stream A
                @memcpy(out[op..][0..len], a[pa..][0..len]);
                sp += len;
                op += len;
                pa += len;
            },
            0x4000 => { // verbatim run from the untouched source
                @memcpy(out[op..][0..len], src[sp..][0..len]);
                op += len;
                sp += len;
            },
            0x8000 => { // running sum against the differenced source
                var n = len / 2;
                while (n > 0) : (n -= 1) {
                    const prev: u16 = if (op >= 2) u16At(out, op - 2) else 0;
                    setU16(out, op, u16At(diffed, sp) +% prev);
                    op += 2;
                    sp += 2;
                }
            },
            else => { // 0xC000: zero fill
                @memset(out[op..][0..len], 0);
                op += len;
                sp += len;
            },
        }
    }

    // Stream B re-applies the absolute-address fixups: groups of (accumulated value, then a
    // delta-coded list of offsets to add it at). A zero ends a list; a zero value ends the stream.
    var pb: usize = 0;
    var acc: i64 = 0;
    while (pb < size_b) {
        const dv = try Varint.read(b, pb, false);
        pb = dv.next;
        if (dv.value == 0) break;
        acc += dv.value;
        const first = try Varint.read(b, pb, false);
        pb = first.next;
        var off: i64 = first.value;
        setU16(out, @intCast(off), u16At(out, @intCast(off)) +% @as(u16, @truncate(@as(u64, @bitCast(acc)))));
        while (pb < size_b) {
            const step = try Varint.read(b, pb, false);
            pb = step.next;
            if (step.value == 0) break;
            off += step.value;
            setU16(out, @intCast(off), u16At(out, @intCast(off)) +% @as(u16, @truncate(@as(u64, @bitCast(acc)))));
        }
    }

    return gpa.realloc(out, rec.tgt_size);
}

/// Locate the MPQ the installer stub carries after itself. The offset moved between versions
/// (0x22000, 0x23000, 0x29000 are all in use), so scan rather than assume.
pub fn carve(bytes: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 32 <= bytes.len) : (i += 1) {
        if (!std.mem.eql(u8, bytes[i..][0..4], "MPQ\x1a")) continue;
        const hs = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        const asz = std.mem.readInt(u32, bytes[i + 8 ..][0..4], .little);
        if (hs == 32 and asz > 0 and asz <= bytes.len - i) return bytes[i..][0..asz];
    }
    return null;
}

test "varint widths and sign extension" {
    // one byte, 7-bit
    try std.testing.expectEqual(@as(i32, 0x41), (try Varint.read(&[_]u8{0x41}, 0, false)).value);
    try std.testing.expectEqual(@as(usize, 1), (try Varint.read(&[_]u8{0x41}, 0, false)).next);
    // one byte, sign-extended from 7 bits
    try std.testing.expectEqual(@as(i32, -1), (try Varint.read(&[_]u8{0x7F}, 0, true)).value);
    try std.testing.expectEqual(@as(i32, 0x7F), (try Varint.read(&[_]u8{0x7F}, 0, false)).value);
    // two bytes: low 6 bits then the next byte at <<6
    try std.testing.expectEqual(@as(i32, 0x01 | (0x02 << 6)), (try Varint.read(&[_]u8{ 0x81, 0x02 }, 0, false)).value);
    try std.testing.expectEqual(@as(usize, 2), (try Varint.read(&[_]u8{ 0x81, 0x02 }, 0, false)).next);
    // three bytes: 5 bits, then <<5, then <<13
    const three = [_]u8{ 0xC1, 0x02, 0x03 };
    try std.testing.expectEqual(@as(i32, 0x01 | (0x02 << 5) | (0x03 << 13)), (try Varint.read(&three, 0, false)).value);
    try std.testing.expectEqual(@as(usize, 3), (try Varint.read(&three, 0, false)).next);
    // four bytes are selected by the 0x20 bit of the first byte
    const four = [_]u8{ 0xE1, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(
        @as(i32, 0x01 | (0x02 << 5) | (0x03 << 13) | (0x04 << 21)),
        (try Varint.read(&four, 0, false)).value,
    );
    try std.testing.expectEqual(@as(usize, 4), (try Varint.read(&four, 0, false)).next);
}

test "record parse: delta, full, and an unwrapped PE" {
    var delta: [0x18]u8 = @splat(0);
    std.mem.writeInt(u16, delta[0..2], 0x18, .little);
    std.mem.writeInt(u16, delta[2..4], 0x0004, .little);
    std.mem.writeInt(u32, delta[4..8], 0xdeadbeef, .little);
    std.mem.writeInt(u32, delta[8..12], 802816, .little);
    std.mem.writeInt(u32, delta[12..16], 831541, .little);
    const d = try Record.parse(&delta);
    try std.testing.expect(!d.isFull());
    try std.testing.expectEqual(@as(u32, 802816), d.src_size);
    try std.testing.expectEqual(@as(u32, 831541), d.tgt_size);

    std.mem.writeInt(u16, delta[2..4], 0x0104, .little);
    std.mem.writeInt(u32, delta[8..12], 0, .little);
    try std.testing.expect((try Record.parse(&delta)).isFull());

    // BNUpdate.exe and D2VidTst.exe are stored with no record at all.
    const raw = [_]u8{ 'M', 'Z', 0x90, 0x00 };
    const r = try Record.parse(&raw);
    try std.testing.expect(r.isFull());
    try std.testing.expectEqual(@as(u32, 4), r.tgt_size);
}

test "apply: full records copy through verbatim" {
    const gpa = std.testing.allocator;
    var rec: [0x18 + 5]u8 = @splat(0);
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0104, .little);
    std.mem.writeInt(u32, rec[12..16], 5, .little);
    @memcpy(rec[0x18..], "hello");
    const out = try apply(gpa, try Record.parse(&rec), &[_]u8{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "apply: every stream-A opcode against a known source" {
    const gpa = std.testing.allocator;
    const src = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };

    // one 0x4000 token: copy 4 bytes from the source, preceded by a zero source-skip varint.
    var a: [7]u8 = undefined;
    std.mem.writeInt(u16, a[0..2], 0x4000 | 4, .little);
    a[2] = 0; // varint 0
    var payload: [8 + 3]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 3, .little); // sizeA
    std.mem.writeInt(u32, payload[4..8], 0, .little); // sizeB
    @memcpy(payload[8..], a[0..3]);

    var rec: [0x18 + payload.len]u8 = @splat(0);
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0004, .little);
    std.mem.writeInt(u32, rec[8..12], src.len, .little);
    std.mem.writeInt(u32, rec[12..16], 4, .little);
    @memcpy(rec[0x18..], &payload);

    const out = try apply(gpa, try Record.parse(&rec), &src);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &src, out);
}

test "apply: refuses a source of the wrong size" {
    const gpa = std.testing.allocator;
    var rec: [0x18]u8 = @splat(0);
    std.mem.writeInt(u16, rec[0..2], 0x18, .little);
    std.mem.writeInt(u16, rec[2..4], 0x0004, .little);
    std.mem.writeInt(u32, rec[8..12], 802816, .little);
    try std.testing.expectError(error.SourceSizeMismatch, apply(gpa, try Record.parse(&rec), &[_]u8{ 1, 2, 3 }));
}

test "carve finds an MPQ at an arbitrary offset" {
    var buf: [128]u8 = @splat(0);
    @memcpy(buf[64..68], "MPQ\x1a");
    std.mem.writeInt(u32, buf[68..72], 32, .little); // headerSize
    std.mem.writeInt(u32, buf[72..76], 64, .little); // archiveSize
    const got = carve(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 64), got.len);
    try std.testing.expect(carve(buf[0..32]) == null);
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  d2patch carve <installer.exe> <out.mpq>     carve the appended MPQ out of a patch stub
        \\  d2patch info  <record>                      print a patch record header
        \\  d2patch apply <record> <source> <out>       rebuild a file from its record + source
        \\
        \\Records come from the archive via tools/mpqcat (members are FIX_KEY encrypted, so
        \\extraction needs the real filename).
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 3) {
        usage();
        return error.Usage;
    }
    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "carve")) {
        if (argv.len < 4) return error.Usage;
        const bytes = try readFile(gpa, argv[2]);
        const mpq = carve(bytes) orelse {
            std.debug.print("no appended MPQ found\n", .{});
            return error.NotFound;
        };
        try writeFile(argv[3], mpq);
        std.debug.print("MPQ @0x{x} ({d} bytes) -> {s}\n", .{ bytes.len - mpq.len, mpq.len, argv[3] });
        return;
    }

    const rec = try Record.parse(try readFile(gpa, argv[2]));
    if (std.mem.eql(u8, cmd, "info")) {
        std.debug.print("kind      0x{x:0>4} ({s})\n", .{ rec.kind, if (rec.isFull()) "full file" else "delta" });
        std.debug.print("srcCRC32  0x{x:0>8}\n", .{rec.src_crc32});
        std.debug.print("srcSize   {d}\n", .{rec.src_size});
        std.debug.print("tgtSize   {d}\n", .{rec.tgt_size});
        std.debug.print("payload   {d}\n", .{rec.payload.len});
        return;
    }

    if (!std.mem.eql(u8, cmd, "apply")) {
        usage();
        return error.Usage;
    }
    if (argv.len < 5) return error.Usage;
    const src = if (rec.isFull()) &[_]u8{} else try readFile(gpa, argv[3]);
    const out = apply(gpa, rec, src) catch |e| {
        if (e == error.SourceSizeMismatch) {
            std.debug.print("source is {d} bytes, this record patches a {d}-byte file\n", .{ src.len, rec.src_size });
        }
        return e;
    };
    try writeFile(argv[4], out);
    const pe = out.len >= 2 and out[0] == 'M' and out[1] == 'Z';
    std.debug.print("wrote {s}: {d} bytes{s}\n", .{ argv[4], out.len, if (pe) " (PE)" else "" });
}
