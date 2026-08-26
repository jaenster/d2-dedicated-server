//! Read an MPQ: one member by name, or the whole archive against a listfile.
//!
//! Member names are hashed, not stored, so an archive cannot be listed — only asked. Two ways
//! around that, both here. A listfile turns the hashes back into names, which is how a Blizzard
//! installer archive gets read at all; `SetupDat\Files100\D2Client.dll` is a name nothing in the
//! archive spells out. And a member whose name is in no listfile can still be recovered, because
//! its encrypted sector table starts with its own length — enough known plaintext to solve for the
//! key. That is what gets the beta discs open, where the shipped trees do not apply.

const std = @import("std");
const mpq = @import("libd2").formats.mpq;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

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

/// Create every directory on the way to `path`, ignoring the ones already there.
fn mkdirs(gpa: std.mem.Allocator, path: []const u8) !void {
    const buf = try gpa.dupeZ(u8, path);
    defer gpa.free(buf);
    var i: usize = 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] != '/') continue;
        buf[i] = 0;
        _ = mkdir(buf.ptr, 0o755);
        buf[i] = '/';
    }
    _ = mkdir(buf.ptr, 0o755);
}

/// A member's name, and the block it resolved to.
const Named = struct { name: []const u8, index: u32 };

/// Every line of every listfile, plus — with `cross` — every leaf tried under every directory
/// seen. A beta build shipped a tree no released listfile knows, but it is made of the same
/// filenames sitting in a differently-named folder, so the cross product finds them.
fn candidates(gpa: std.mem.Allocator, files: []const []const u8, cross: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    var leaves: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (files) |text| {
        var it = std.mem.splitAny(u8, text, "\r\n");
        while (it.next()) |line| {
            const name = std.mem.trim(u8, line, " \t");
            if (name.len == 0) continue;
            try out.append(gpa, name);
            if (std.mem.lastIndexOfScalar(u8, name, '\\')) |at| {
                try dirs.put(gpa, name[0..at], {});
                try leaves.put(gpa, name[at + 1 ..], {});
            } else {
                try leaves.put(gpa, name, {});
            }
        }
    }
    if (cross) {
        for (dirs.keys()) |d| {
            for (leaves.keys()) |l| {
                try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ d, l }));
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Which block each candidate name resolves to. First name wins a block; the rest are aliases.
fn resolve(gpa: std.mem.Allocator, archive: mpq.Archive, names: []const []const u8) ![]?Named {
    const by_block = try gpa.alloc(?Named, archive.blocks.len);
    @memset(by_block, null);
    for (names) |name| {
        const index = archive.lookup(name) orelse continue;
        if (index >= by_block.len) continue;
        if (by_block[index] == null) by_block[index] = .{ .name = name, .index = index };
    }
    return by_block;
}

fn printRow(name: []const u8, blk: mpq.BlockEntry, note: []const u8) void {
    std.debug.print("{s:<52} {d:>10}  {d:>10}  {x:0>8}  {s}\n", .{
        name, blk.unpacked_size, blk.packed_size, blk.flags, note,
    });
}

fn cmdList(gpa: std.mem.Allocator, archive: mpq.Archive, names: []const []const u8) !void {
    const by_block = try resolve(gpa, archive, names);
    var named: usize = 0;
    std.debug.print("{s:<52} {s:>10}  {s:>10}  {s:<8}  {s}\n", .{ "name", "size", "packed", "flags", "" });
    for (archive.blocks, 0..) |blk, i| {
        if (blk.flags & mpq.Flags.exists == 0) continue;
        if (by_block[i]) |n| {
            named += 1;
            printRow(n.name, blk, "");
        }
    }
    var nameless: usize = 0;
    for (archive.blocks, 0..) |blk, i| {
        if (blk.flags & mpq.Flags.exists == 0) continue;
        if (by_block[i] != null) continue;
        nameless += 1;
        const key = archive.recoverKey(gpa, @intCast(i)) catch null;
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "<block {d}>", .{i}) catch "<block>";
        printRow(label, blk, if (key != null) "key recovered" else "NO NAME, NO KEY");
    }
    std.debug.print("\n{d} blocks: {d} named, {d} nameless\n", .{ archive.blocks.len, named, nameless });
}

fn cmdExtract(gpa: std.mem.Allocator, archive: mpq.Archive, names: []const []const u8, outdir: []const u8) !void {
    const by_block = try resolve(gpa, archive, names);
    var ok: usize = 0;
    var failed: usize = 0;
    for (archive.blocks, 0..) |blk, i| {
        if (blk.flags & mpq.Flags.exists == 0) continue;
        const index: u32 = @intCast(i);

        // A named member decrypts from its name; a nameless one from its own sector table.
        var rel: []const u8 = undefined;
        var data: []u8 = undefined;
        if (by_block[i]) |n| {
            rel = try gpa.dupe(u8, n.name);
            data = archive.read(gpa, n.name) catch |e| {
                std.debug.print("  FAIL {s}: {t}\n", .{ n.name, e });
                failed += 1;
                continue;
            };
        } else {
            rel = try std.fmt.allocPrint(gpa, "_unnamed\\block{d:0>4}.bin", .{i});
            const key: ?u32 = if (blk.flags & mpq.Flags.encrypted != 0)
                (archive.recoverKey(gpa, index) catch null) orelse {
                    std.debug.print("  FAIL block {d}: no name and no recoverable key\n", .{i});
                    failed += 1;
                    continue;
                }
            else
                null;
            data = archive.readBlock(gpa, index, key) catch |e| {
                std.debug.print("  FAIL block {d}: {t}\n", .{ i, e });
                failed += 1;
                continue;
            };
        }

        const path = try gpa.alloc(u8, outdir.len + 1 + rel.len);
        @memcpy(path[0..outdir.len], outdir);
        path[outdir.len] = '/';
        for (rel, 0..) |c, j| path[outdir.len + 1 + j] = if (c == '\\') '/' else c;
        const at = std.mem.lastIndexOfScalar(u8, path, '/').?;
        try mkdirs(gpa, path[0..at]);
        const zpath = try gpa.dupeZ(u8, path);
        try writeFile(zpath.ptr, data);
        ok += 1;
    }
    std.debug.print("{d} written, {d} failed -> {s}\n", .{ ok, failed, outdir });
}

const usage =
    \\usage:
    \\  mpqcat <archive> <member> [out]                     one member, by name
    \\  mpqcat list <archive> [listfile...] [--cross]       what is in it
    \\  mpqcat extract <archive> <outdir> [listfile...] [--cross]
    \\  mpqcat carve <stub> <out.mpq>                       lift the appended archive out
    \\
    \\  mpqcat d2exp.mpq 'data\global\excel\skills.bin' skills.bin
    \\  mpqcat list SETUP.EXE Diablo2UberListfile.txt --cross
    \\
    \\The archive may be appended to a stub, as an installer's is — the header is found by scan.
    \\Members with no name in any listfile are still extracted, under _unnamed/, whenever their
    \\key can be solved for. --cross also tries every listed filename under every listed folder,
    \\which is what reaches a build whose tree no listfile describes.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 3) {
        std.debug.print(usage, .{});
        return error.Usage;
    }
    const verb = std.mem.sliceTo(argv[1], 0);
    const listing = std.mem.eql(u8, verb, "list");
    const extracting = std.mem.eql(u8, verb, "extract");
    const carving = std.mem.eql(u8, verb, "carve");

    if (carving) {
        if (argv.len < 4) {
            std.debug.print(usage, .{});
            return error.Usage;
        }
        const bytes = try readFile(gpa, argv[2]);
        const archive = try mpq.Archive.open(gpa, bytes);
        const end = @min(bytes.len, @as(usize, archive.base) + archive.header.archive_size);
        try writeFile(argv[3], bytes[archive.base..end]);
        std.debug.print("{s}: archive at 0x{x}, {d} bytes -> {s}\n", .{
            std.mem.sliceTo(argv[2], 0), archive.base, end - archive.base, argv[3],
        });
        return;
    }

    if (!listing and !extracting) {
        const bytes = try readFile(gpa, argv[1]);
        var archive = try mpq.Archive.open(gpa, bytes);
        const member = std.mem.sliceTo(argv[2], 0);
        const data = archive.read(gpa, member) catch {
            std.debug.print("not in archive: {s}\n", .{member});
            return error.NotFound;
        };
        if (argv.len >= 4) {
            try writeFile(argv[3], data);
            std.debug.print("{s}: {d} bytes -> {s}\n", .{ member, data.len, argv[3] });
        } else {
            std.debug.print("{s}: {d} bytes\n", .{ member, data.len });
        }
        return;
    }

    const bytes = try readFile(gpa, argv[2]);
    const archive = try mpq.Archive.open(gpa, bytes);

    var rest_at: usize = 3;
    var outdir: []const u8 = "";
    if (extracting) {
        if (argv.len < 4) {
            std.debug.print(usage, .{});
            return error.Usage;
        }
        outdir = std.mem.sliceTo(argv[3], 0);
        rest_at = 4;
    }

    var cross = false;
    var texts: std.ArrayList([]const u8) = .empty;
    for (argv[rest_at..]) |a| {
        const arg = std.mem.sliceTo(a, 0);
        if (std.mem.eql(u8, arg, "--cross")) {
            cross = true;
        } else {
            try texts.append(gpa, try readFile(gpa, a));
        }
    }
    // An archive that carries its own `(listfile)` needs nothing from the caller. Blizzard's
    // installer archives do not have one, which is what the external listfiles are for.
    if (archive.lookup("(listfile)") != null) {
        if (archive.read(gpa, "(listfile)")) |own| {
            try texts.append(gpa, own);
            std.debug.print("using the archive's own (listfile)\n", .{});
        } else |_| {}
    }
    const names = try candidates(gpa, texts.items, cross);
    std.debug.print("{d} candidate names\n", .{names.len});

    if (listing) return cmdList(gpa, archive, names);
    return cmdExtract(gpa, archive, names, outdir);
}
