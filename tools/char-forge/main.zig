//! char-forge <name> <class> <level> <out.d2s> --experience <experience.txt> --charstats <charstats.txt>
//!            [--hardcore] [--classic]
//!
//! Writes a save of that class at that level (see forge.zig). The two tables are the game's own, extracted from the
//! 1.14d MPQs (`mpqcat Patch_D2.mpq 'data\global\excel\experience.txt' experience.txt`, same for charstats.txt).
//! The save is an expansion character unless `--classic`. Prints what it wrote.
const std = @import("std");
const forge = @import("forge.zig");

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fwrite(buf: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn time(t: ?*i64) i64;

const gpa = std.heap.c_allocator;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    say(fmt ++ "\n", args);
    std.process.exit(1);
}

fn readFile(path: []const u8) ![]u8 {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    const f = fopen(z, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    var pos: [4][]const u8 = undefined;
    var npos: usize = 0;
    var experience_path: ?[]const u8 = null;
    var charstats_path: ?[]const u8 = null;
    var hardcore = false;
    var expansion = true;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--hardcore")) {
            hardcore = true;
        } else if (std.mem.eql(u8, a, "--classic")) {
            expansion = false;
        } else if (std.mem.eql(u8, a, "--experience")) {
            experience_path = args.next();
        } else if (std.mem.eql(u8, a, "--charstats")) {
            charstats_path = args.next();
        } else if (npos < pos.len) {
            pos[npos] = a;
            npos += 1;
        }
    }
    if (npos != 4 or experience_path == null or charstats_path == null)
        fatal("usage: char-forge <name> <class> <level> <out.d2s> --experience <experience.txt> --charstats <charstats.txt> [--hardcore] [--classic]", .{});

    var class: ?u8 = null;
    for (forge.class_names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, pos[1])) class = @intCast(i);
    }
    const level = std.fmt.parseInt(u8, pos[2], 10) catch fatal("bad level {s}", .{pos[2]});
    const experience = readFile(experience_path.?) catch fatal("cannot read {s}", .{experience_path.?});
    const charstats = readFile(charstats_path.?) catch fatal("cannot read {s}", .{charstats_path.?});

    var buf: [4096]u8 = undefined;
    const out = forge.forge(&buf, experience, charstats, .{
        .name = pos[0],
        .class = class orelse fatal("unknown class {s}", .{pos[1]}),
        .level = level,
        .hardcore = hardcore,
        .expansion = expansion,
        .created = @intCast(time(null)),
    }) catch |e| fatal("cannot forge: {s}", .{@errorName(e)});

    const z = try gpa.dupeZ(u8, pos[3]);
    const f = fopen(z, "wb") orelse fatal("cannot write {s}", .{pos[3]});
    _ = fwrite(out.ptr, 1, out.len, f);
    _ = fclose(f);
    say("{s}: {s} level {d}, {d} bytes\n", .{ pos[0], forge.class_names[class.?], level, out.len });
}
