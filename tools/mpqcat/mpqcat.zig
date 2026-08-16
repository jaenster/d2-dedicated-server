//! mpqcat — list / inspect files inside an MPQ via StormLib (handles encrypted (listfile)
//! and compression that pure-Zig/mpyq readers can't).
//! Usage: mpqcat <archive.mpq> [member [outfile]] — no member lists (listfile) and flags
//! Mach-O/PE/fat-binary members with architecture; member extracts it (outfile writes it).
//! Build (mirrors tools/vermpq/build.sh): SL=/opt/homebrew/opt/stormlib; zig build-exe
//! mpqcat.zig -O ReleaseSafe -lc -lstorm -lz -lbz2 -I"$SL/include" -L"$SL/lib"
const std = @import("std");

const HANDLE = ?*anyopaque;
extern fn SFileOpenArchive(name: [*:0]const u8, priority: u32, flags: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileCloseArchive(mpq: HANDLE) callconv(.c) bool;
extern fn SFileOpenFileEx(mpq: HANDLE, name: [*:0]const u8, scope: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileGetFileSize(file: HANDLE, high: ?*u32) callconv(.c) u32;
extern fn SFileReadFile(file: HANDLE, buf: [*]u8, to_read: u32, read: *u32, ov: ?*anyopaque) callconv(.c) bool;
extern fn SFileCloseFile(file: HANDLE) callconv(.c) bool;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const gpa = std.heap.c_allocator;

fn writeFile(path: [*:0]const u8, data: []const u8) bool {
    const flags: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    const fd = open(path, flags, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer _ = close(fd);
    return write(fd, data.ptr, data.len) == @as(isize, @intCast(data.len));
}

/// Read a whole member into an allocated buffer (caller frees). null if missing.
fn readMember(mpq: HANDLE, name: [*:0]const u8) ?[]u8 {
    var fh: HANDLE = null;
    if (!SFileOpenFileEx(mpq, name, 0, &fh)) return null;
    defer _ = SFileCloseFile(fh);
    const size = SFileGetFileSize(fh, null);
    if (size == 0 or size == 0xFFFF_FFFF) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    var got: u32 = 0;
    if (!SFileReadFile(fh, buf.ptr, size, &got, null)) {
        gpa.free(buf);
        return null;
    }
    return buf[0..got];
}

fn archOf(d: []const u8) []const u8 {
    if (d.len < 8) return "";
    const m = std.mem.readInt(u32, d[0..4], .little);
    return switch (m) {
        0xFEEDFACE => "Mach-O 32-bit",
        0xFEEDFACF => "Mach-O 64-bit",
        // fat/universal header is BIG-endian; cputype of first slice @ +4 (BE).
        0xBEBAFECA => blk: {
            const cputype = std.mem.readInt(u32, d[8..12], .big);
            break :blk if (cputype & 0x0100_0000 != 0) "fat/universal (contains 64-bit)" else "fat/universal (32-bit)";
        },
        0xCAFEBABE => "fat/universal", // (same magic LE-read)
        else => if (d[0] == 'M' and d[1] == 'Z') "PE/MZ (Windows)" else "",
    };
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const arch_path = it.next() orelse {
        std.debug.print("usage: mpqcat <archive.mpq> [member [outfile]]\n", .{});
        return 2;
    };
    const member = it.next();
    const outfile = it.next();

    var mpq: HANDLE = null;
    if (!SFileOpenArchive(arch_path.ptr, 0, 0, &mpq)) {
        std.debug.print("failed to open archive {s}\n", .{arch_path});
        return 1;
    }
    defer _ = SFileCloseArchive(mpq);

    if (member) |m| {
        const data = readMember(mpq, m.ptr) orelse {
            std.debug.print("member not found / unreadable: {s}\n", .{m});
            return 1;
        };
        std.debug.print("{s}: {d} bytes  {s}\n", .{ m, data.len, archOf(data) });
        if (outfile) |o| {
            if (!writeFile(o.ptr, data)) return 1;
            std.debug.print("wrote -> {s}\n", .{o});
        }
        return 0;
    }

    // List the (listfile) and flag executables with their architecture.
    const lf = readMember(mpq, "(listfile)") orelse {
        std.debug.print("no readable (listfile) in archive\n", .{});
        return 1;
    };
    var n: usize = 0;
    var lines = std.mem.tokenizeAny(u8, lf, "\r\n");
    while (lines.next()) |name| {
        n += 1;
        const cname = gpa.dupeZ(u8, name) catch continue;
        defer gpa.free(cname);
        var hdr: [64]u8 = undefined;
        var fh: HANDLE = null;
        var tag: []const u8 = "";
        var sz: u32 = 0;
        if (SFileOpenFileEx(mpq, cname.ptr, 0, &fh)) {
            sz = SFileGetFileSize(fh, null);
            var got: u32 = 0;
            if (SFileReadFile(fh, &hdr, hdr.len, &got, null)) tag = archOf(hdr[0..got]);
            _ = SFileCloseFile(fh);
        }
        if (tag.len > 0)
            std.debug.print("  {s}  ({d} bytes)  <-- {s}\n", .{ name, sz, tag })
        else
            std.debug.print("  {s}  ({d} bytes)\n", .{ name, sz });
    }
    std.debug.print("=== {d} files ===\n", .{n});
    return 0;
}
