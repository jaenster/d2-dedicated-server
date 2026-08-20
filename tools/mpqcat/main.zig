//! Read one member out of an MPQ, by name.
//!
//! Member names are hashed, not stored, so an archive cannot be listed — only asked. This exists
//! to answer one question exactly: does a table this project generated match the one the game
//! shipped, byte for byte? Sizes agreeing is suggestive; the bytes are the proof.

const std = @import("std");
const mpq = @import("libd2").formats.mpq;

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 3) {
        std.debug.print(
            \\usage: mpqcat <archive.mpq> <member> [out]
            \\
            \\  mpqcat d2exp.mpq 'data\global\excel\skills.bin' skills.bin
            \\
            \\Without <out>, prints the member's size only.
            \\
        , .{});
        return error.Usage;
    }
    const bytes = try readFile(gpa, argv[1]);
    var archive = try mpq.Archive.open(gpa, bytes);
    const data = archive.read(gpa, std.mem.sliceTo(argv[2], 0)) catch {
        std.debug.print("not in archive: {s}\n", .{argv[2]});
        return error.NotFound;
    };
    if (argv.len >= 4) {
        try writeFile(argv[3], data);
        std.debug.print("{s}: {d} bytes -> {s}\n", .{ argv[2], data.len, argv[3] });
    } else {
        std.debug.print("{s}: {d} bytes\n", .{ argv[2], data.len });
    }
}
