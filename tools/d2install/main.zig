//! Install a Diablo II payload from its Installer Tome, without running Installer.exe.
//!
//! The Tome is a standard MPQ. Inside it sits the install script the real installer follows,
//! `InstallCD\InstallerFileList\InstallerFileList.xml`: a list of operations under `<if>` guards
//! for platform and language. The ones that produce the game are `repack` elements inside a
//! `repack_into type="file"` — each names a member of the Tome and where it goes.
//!
//! What this does NOT do: `repack_into type="mpq"` adds members to an archive that is being
//! installed, which needs an MPQ writer; registry keys, shortcuts, uninstall entries and the
//! DirectX bundle are Windows installer concerns with no meaning here. All of them are counted
//! and listed rather than silently dropped.

const std = @import("std");
const mpq = @import("libd2").formats.mpq;
const installer = @import("libd2").formats.installer;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const usage =
    \\d2install — build the game directory from an Installer Tome
    \\
    \\  d2install <Installer Tome.mpq> <outdir> [options]
    \\
    \\  --platform win32|macos   which branch to follow (default win32)
    \\  --lang <name>            English German French Spanish Italian Polish
    \\                           Korean SimplifiedChinese TraditionalChinese
    \\  --list                   say what would be written, write nothing
    \\
;

fn readFile(gpa: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = open(path, @bitCast(std.posix.O{ .ACCMODE = .RDONLY }));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [1 << 20]u8 = undefined;
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
    var at: usize = 0;
    while (at < data.len) {
        const n = write(fd, data.ptr + at, data.len - at);
        if (n <= 0) return error.WriteFailed;
        at += @intCast(n);
    }
}

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

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const argv_z = try init.minimal.args.toSlice(gpa);
    var argv_list: std.ArrayList([]const u8) = .empty;
    for (argv_z) |a| try argv_list.append(gpa, std.mem.sliceTo(a, 0));
    const argv = argv_list.items;
    if (argv.len < 3) {
        std.debug.print(usage, .{});
        return error.Usage;
    }

    var platform: []const u8 = "win32";
    var lang: []const u8 = "English";
    var list_only = false;
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--platform") and i + 1 < argv.len) {
            i += 1;
            platform = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--lang") and i + 1 < argv.len) {
            i += 1;
            lang = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--list")) {
            list_only = true;
        }
    }

    const tome_path = try gpa.dupeZ(u8, argv[1]);
    const bytes = try readFile(gpa, tome_path.ptr);
    var archive = try mpq.Archive.open(gpa, bytes);
    defer archive.deinit(gpa);

    const manifest = try archive.read(gpa, installer.manifest_path);
    // The expansion's script deletes from wherever the base game already sits, which for us is
    // the directory being installed into.
    const original = try std.fmt.allocPrint(gpa, "{s}/", .{argv[2]});
    const plan = try installer.parse(gpa, manifest, .{
        .platform = if (std.mem.eql(u8, platform, "macos")) .macos else .win32,
        .language = lang,
        .symbols = &.{.{ .name = "OriginalInstallPath", .value = original }},
    });
    std.debug.print("manifest {d} bytes, platform {s}, language {s}, {d} operations\n\n", .{
        manifest.len, platform, lang, plan.ops.len,
    });

    if (!list_only) try mkdirs(gpa, argv[2]);

    // Members bound for an archive are collected and added in one pass per archive at the end:
    // each pass rewrites the archive, so doing it per member would rewrite it 25 times.
    var pending: std.ArrayList(@TypeOf(@as(installer.Op, undefined).add_to_archive)) = .empty;

    var written: usize = 0;
    var total: u64 = 0;
    var deferred: usize = 0;
    var host_only: usize = 0;
    var unresolved: usize = 0;
    var removed: usize = 0;

    for (plan.ops) |op| switch (op) {
        .extract => |f| {
            const from = f.from orelse {
                unresolved += 1;
                std.debug.print("  skip  no source in the archive: {s}\n", .{f.to});
                continue;
            };
            const data = archive.read(gpa, from) catch {
                unresolved += 1;
                std.debug.print("  MISS  {s}\n", .{from});
                continue;
            };
            defer gpa.free(data);
            if (f.size) |want| if (want != data.len)
                std.debug.print("  warn  {s}: script says {d}, archive has {d}\n", .{ f.to, want, data.len });

            const rel = try gpa.dupe(u8, f.to);
            defer gpa.free(rel);
            for (rel) |*ch| if (ch.* == '\\') { ch.* = '/'; };

            std.debug.print("  {s:<6} {d:>12}  {s}\n", .{ if (list_only) "would" else "write", data.len, rel });
            written += 1;
            total += data.len;
            if (list_only) continue;

            const full = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ argv[2], rel }, 0);
            defer gpa.free(full);
            if (std.mem.lastIndexOfScalar(u8, full, '/')) |cut| try mkdirs(gpa, full[0..cut]);
            try writeFile(full.ptr, data);
        },
        .add_to_archive => |a| {
            deferred += 1;
            if (!list_only) try pending.append(gpa, a);
        },
        .encrypt => |e| {
            host_only += 1;
            std.debug.print("  skip  encrypt {s} into {s}\n", .{ e.object, e.into });
        },
        .delete => |path| {
            // Replacing a file the previous install left behind. Confined to the target
            // directory the caller named, and reported rather than done quietly.
            const rel = try gpa.dupe(u8, path);
            defer gpa.free(rel);
            for (rel) |*c| if (c.* == '\\') { c.* = '/'; };
            std.debug.print("  delete {s}\n", .{rel});
            removed += 1;
            if (list_only) continue;
            const full = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ argv[2], rel }, 0);
            defer gpa.free(full);
            _ = unlink(full.ptr);
        },
        .create_folder, .registry, .shortcut, .directx, .add_remove_programs => {
            host_only += 1;
        },
    };

    // One rewrite per archive, with every member destined for it.
    var repacked: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (pending.items) |a| {
        if (seen.contains(a.container)) continue;
        try seen.put(gpa, a.container, {});

        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ argv[2], a.container }, 0);
        defer gpa.free(path);
        const before = readFile(gpa, path.ptr) catch {
            std.debug.print("  warn  {s} is not here to add members to\n", .{a.container});
            continue;
        };
        defer gpa.free(before);

        var add: std.ArrayList(mpq.NewFile) = .empty;
        defer add.deinit(gpa);
        for (pending.items) |b| {
            if (!std.mem.eql(u8, b.container, a.container)) continue;
            const from = b.file.from orelse continue;
            const data = archive.read(gpa, from) catch {
                std.debug.print("  MISS  {s}\n", .{from});
                continue;
            };
            try add.append(gpa, .{ .name = b.file.to, .data = data });
        }

        const grown = mpq.append(gpa, before, add.items) catch |e| {
            std.debug.print("  warn  {s}: {t}\n", .{ a.container, e });
            continue;
        };
        defer gpa.free(grown);
        try writeFile(path.ptr, grown);
        repacked += add.items.len;
        std.debug.print("  repack {d} members into {s}\n", .{ add.items.len, a.container });
    }

    std.debug.print(
        \\
        \\{d} files, {d} bytes{s}
        \\{d} members added to installed archives
        \\{d} host-only steps (folders, registry, shortcuts, DirectX, key encoding)
        \\{d} unresolved, {d} deleted
        \\
    , .{ written, total, if (list_only) " (nothing written)" else "", if (list_only) deferred else repacked, host_only, unresolved, removed });
}
