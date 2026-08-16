//! mpqmin — rebuild an MPQ with only the members a headless game server reads.
//!
//! A retail d2data.mpq is ~256 MB and a server touches ~4 MB of it: the excel tables, the level
//! tiles it needs for collision, the COF animation data, the string tables. Everything else is
//! art (.dc6/.dcc), sound (.wav) and light tables (.pl2) — pixels for a client that isn't there.
//! Filtering by extension is what separates the two, and it is exact: applied to a retail archive
//! it reproduces this repo's shipped minimal d2data.mpq and d2exp.mpq member-for-member.
//!
//! The same rule holds for the macOS archives, because they are the same archives: "Diablo II
//! Expansion Data" is byte-identical to d2exp.mpq, and "Diablo II Game Data" is d2data.mpq plus a
//! handful of Mac-only members — among them Data\Local\MacUI\<lang>\D2Resources.rsrc, which
//! PreInitApplication extracts and which the `.rsrc` entry in the keep-list is there to save.
//!
//! Usage:
//!   mpqmin [--ui] <src> <dst>   rebuild <src> into <dst>, keeping only what the rule keeps
//!   mpqmin --list <src>         one line per member: flags size csize offset locale name
//!   mpqmin --keep <list> <src> <dst>   keep exactly the members named in <list>, one per line
//!
//! `--list` doubles as the offset map for read tracing: the host's file shim logs archive reads as
//! (offset, length), and a read inside [offset, offset+csize) is a read of that member.
//!
//! Build (mirrors tools/mpqcat):
//!   SL=/opt/homebrew/opt/stormlib
//!   zig build-exe mpqmin.zig -O ReleaseSafe -lc -lstorm -lz -lbz2 -I"$SL/include" -L"$SL/lib"
const std = @import("std");

const HANDLE = ?*anyopaque;
const max_path = 1024; // StormPort.h defines MAX_PATH as 1024 off Windows, and SFILE_FIND_DATA embeds it.

const FindData = extern struct {
    name: [max_path]u8,
    plain: ?[*:0]u8,
    hash_index: u32,
    block_index: u32,
    size: u32,
    flags: u32,
    comp_size: u32,
    time_lo: u32,
    time_hi: u32,
    locale: u32,
};

extern fn SFileOpenArchive(name: [*:0]const u8, priority: u32, flags: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileCloseArchive(mpq: HANDLE) callconv(.c) bool;
extern fn SFileCreateArchive(name: [*:0]const u8, flags: u32, max_files: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileOpenFileEx(mpq: HANDLE, name: [*:0]const u8, scope: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileGetFileSize(file: HANDLE, high: ?*u32) callconv(.c) u32;
extern fn SFileReadFile(file: HANDLE, buf: [*]u8, to_read: u32, read: *u32, ov: ?*anyopaque) callconv(.c) bool;
extern fn SFileCloseFile(file: HANDLE) callconv(.c) bool;
extern fn SFileGetFileInfo(h: HANDLE, class: u32, out: *anyopaque, len: u32, need: ?*u32) callconv(.c) bool;
extern fn SFileSetLocale(locale: u32) callconv(.c) u32;
extern fn SFileFindFirstFile(mpq: HANDLE, mask: [*:0]const u8, data: *FindData, listfile: ?[*:0]const u8) callconv(.c) HANDLE;
extern fn SFileFindNextFile(find: HANDLE, data: *FindData) callconv(.c) bool;
extern fn SFileFindClose(find: HANDLE) callconv(.c) bool;
extern fn SFileCreateFile(mpq: HANDLE, name: [*:0]const u8, time: u64, size: u32, locale: u32, flags: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileWriteFile(file: HANDLE, data: [*]const u8, size: u32, compression: u32) callconv(.c) bool;
extern fn SFileFinishFile(file: HANDLE) callconv(.c) bool;

/// StormLib reports failures the POSIX way off Windows: its `SetLastError` writes `errno`.
fn lastError() i32 {
    return std.c._errno().*;
}

const info_byte_offset: u32 = 49;

const create_listfile: u32 = 0x0010_0000;
const file_implode: u32 = 0x0000_0100;
const file_compress: u32 = 0x0000_0200;
const file_encrypted: u32 = 0x0001_0000;
const file_fix_key: u32 = 0x0002_0000;
const file_single_unit: u32 = 0x0100_0000;
const file_exists: u32 = 0x8000_0000;
/// What may be carried over from the source entry. `MPQ_FILE_SECTOR_CRC` is deliberately not here:
/// the sector checksums are re-derived on write, and asking for them costs size for nothing.
const carry_flags: u32 = file_implode | file_compress | file_encrypted | file_fix_key | file_single_unit;

const compression_zlib: u32 = 0x02;
const compression_pkware: u32 = 0x08;

const gpa = std.heap.c_allocator;

/// The keep rule. Extensions rather than paths because the split is by KIND, not by location:
/// tables, tiles, animation data and string tables live scattered under data\global and data\local,
/// and every one of them is a small format the server parses itself.
///
///   txt tbl        excel tables, string tables, font metrics
///   dat d2         palettes, palshift, AnimData.D2, the compiled COF archives
///   ds1 dt1 dn1    level presets and tiles — the collision map is built from these
///   key map ico    keybinds, font map, the window icon the client build wants
///   bin rsrc       realms.bin and the Mac resource fork PreInitApplication explodes out
///   scc            three stray SourceSafe files; kept only so this matches the shipped archives
///   (none)         data\local\use, an extensionless marker file
const keep_ext = [_][]const u8{ "txt", "tbl", "dat", "d2", "ds1", "dt1", "dn1", "key", "map", "ico", "bin", "rsrc", "scc" };

/// Directories whose sprites a client-mode boot loads before any game starts: the font glyphs, the
/// cursor, and the monster-health indicator. `--ui` keeps their DC6s and the PL2 colour tables.
const ui_dirs = [_][]const u8{ "data\\local\\font\\", "data\\global\\ui\\cursor\\", "data\\global\\ui\\font\\" };

/// `--ui`: also keep what a boot that runs the client's UI init reads. The Windows build has a
/// dedicated-server application mode and never touches any of this; the macOS build has none
/// compiled in, so its host boots the client with the renderer patched out and the palette and font
/// load still run. Measured, not guessed: without `data\global\palette\ACT1\Pal.PL2` that boot
/// segfaults immediately after reading the act's `pal.dat`.
var keep_ui = false;

fn keeps(name: []const u8) bool {
    const cut = std.mem.lastIndexOfAny(u8, name, "\\/");
    const leaf = if (cut) |c| name[c + 1 ..] else name;
    const dot = std.mem.lastIndexOfScalar(u8, leaf, '.') orelse return true;
    const ext = leaf[dot + 1 ..];
    for (keep_ext) |k| {
        if (ext.len == k.len and std.ascii.eqlIgnoreCase(ext, k)) return true;
    }
    if (!keep_ui) return false;
    if (std.ascii.eqlIgnoreCase(ext, "pl2")) return true;
    if (!std.ascii.eqlIgnoreCase(ext, "dc6")) return false;
    const dir = lowered(name[0 .. (cut orelse return false) + 1]);
    for (ui_dirs) |d| {
        if (std.mem.startsWith(u8, dir, d)) return true;
    }
    return false;
}

fn span(name: *const [max_path]u8) []const u8 {
    return std.mem.sliceTo(name, 0);
}

/// Read a whole member into an allocated buffer (caller frees). null if missing or unreadable.
fn readMember(mpq: HANDLE, name: [*:0]const u8, locale: u32) ?[]u8 {
    _ = SFileSetLocale(locale);
    var fh: HANDLE = null;
    if (!SFileOpenFileEx(mpq, name, 0, &fh)) return null;
    defer _ = SFileCloseFile(fh);
    const size = SFileGetFileSize(fh, null);
    if (size == 0xFFFF_FFFF) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    if (size == 0) return buf;
    var got: u32 = 0;
    if (!SFileReadFile(fh, buf.ptr, size, &got, null)) {
        gpa.free(buf);
        return null;
    }
    return buf[0..got];
}

fn list(mpq: HANDLE) u8 {
    var d: FindData = undefined;
    const find = SFileFindFirstFile(mpq, "*", &d, null) orelse {
        std.debug.print("cannot enumerate the archive (no (listfile)?)\n", .{});
        return 1;
    };
    defer _ = SFileFindClose(find);
    while (true) {
        var offset: u64 = 0;
        var fh: HANDLE = null;
        _ = SFileSetLocale(d.locale);
        const cname = gpa.dupeZ(u8, span(&d.name)) catch return 1;
        defer gpa.free(cname);
        if (SFileOpenFileEx(mpq, cname.ptr, 0, &fh)) {
            _ = SFileGetFileInfo(fh, info_byte_offset, &offset, @sizeOf(u64), null);
            _ = SFileCloseFile(fh);
        }
        std.debug.print("{x:0>8}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{ d.flags, d.size, d.comp_size, offset, d.locale, span(&d.name) });
        if (!SFileFindNextFile(find, &d)) break;
    }
    return 0;
}

/// The member names to copy, in archive order. `wanted` null means "apply the keep rule".
fn plan(mpq: HANDLE, wanted: ?*const std.StringHashMap(void)) !std.ArrayList(FindData) {
    var out: std.ArrayList(FindData) = .empty;
    var d: FindData = undefined;
    const find = SFileFindFirstFile(mpq, "*", &d, null) orelse return error.NoListfile;
    defer _ = SFileFindClose(find);
    while (true) {
        const name = span(&d.name);
        // The internal files are rebuilt by the writer, never copied.
        const internal = name.len != 0 and name[0] == '(';
        const take = if (wanted) |w| w.contains(lowered(name)) else keeps(name);
        if (!internal and take) try out.append(gpa, d);
        if (!SFileFindNextFile(find, &d)) break;
    }
    return out;
}

/// A DT1 is a header, a table of 96-byte tile records, and then the graphics blocks those records
/// point at. The server reads the records — the per-subtile collision flags are in them — and never
/// the blocks, which is where all the bytes are: 243 KB of tileset becomes 1.9 KB. Truncating after
/// the records and clearing each record's block pointer/size/count leaves a file the tile loader
/// walks to the same collision result and finds nothing to draw. Returns the kept length.
fn stripDt1(data: []u8) usize {
    if (data.len < dt1_header) return data.len;
    const count = std.mem.readInt(u32, data[268..272], .little);
    const start = std.mem.readInt(u32, data[272..276], .little);
    const end = @as(u64, start) + @as(u64, count) * dt1_record;
    if (start < dt1_header or end > data.len) return data.len;
    var at: usize = start;
    while (at + dt1_record <= end) : (at += dt1_record) @memset(data[at + 72 ..][0..12], 0);
    return @intCast(end);
}

const dt1_header = 276;
const dt1_record = 96;

var lower_buf: [max_path]u8 = undefined;

/// Members are matched case- and separator-insensitively: an MPQ name is `data\global\...` but a
/// keep-list written by hand or by a trace mapper may use either slash and any case.
fn lowered(name: []const u8) []const u8 {
    for (name, 0..) |c, i| lower_buf[i] = if (c == '/') '\\' else std.ascii.toLower(c);
    return lower_buf[0..name.len];
}

fn pack(src: HANDLE, dst_path: [*:0]const u8, wanted: ?*const std.StringHashMap(void)) !u8 {
    var members = try plan(src, wanted);
    defer members.deinit(gpa);

    var dst: HANDLE = null;
    if (!SFileCreateArchive(dst_path, create_listfile, @intCast(members.items.len + 16), &dst)) {
        std.debug.print("cannot create {s} (error {d}) — remove it first if it exists\n", .{ dst_path, lastError() });
        return 1;
    }
    defer _ = SFileCloseArchive(dst);

    var written: usize = 0;
    var bytes: u64 = 0;
    for (members.items) |m| {
        const name = span(&m.name);
        const cname = try gpa.dupeZ(u8, name);
        defer gpa.free(cname);
        const whole = readMember(src, cname.ptr, m.locale) orelse {
            std.debug.print("skipped (unreadable): {s}\n", .{name});
            continue;
        };
        defer gpa.free(whole);
        const data = if (std.ascii.endsWithIgnoreCase(name, ".dt1")) whole[0..stripDt1(whole)] else whole;

        // Keep the source's own storage decisions. A member the game reads with an explode call is
        // one the game expects to be imploded, and re-compressing it as zlib would be a guess.
        const flags = (m.flags & carry_flags) | file_exists;
        const compression: u32 = if (m.flags & file_implode != 0) compression_pkware else compression_zlib;

        var fh: HANDLE = null;
        if (!SFileCreateFile(dst, cname.ptr, @as(u64, m.time_hi) << 32 | m.time_lo, @intCast(data.len), m.locale, flags, &fh)) {
            std.debug.print("cannot add {s} (error {d})\n", .{ name, lastError() });
            return 1;
        }
        if (data.len != 0 and !SFileWriteFile(fh, data.ptr, @intCast(data.len), compression)) {
            std.debug.print("cannot write {s} (error {d})\n", .{ name, lastError() });
            return 1;
        }
        if (!SFileFinishFile(fh)) {
            std.debug.print("cannot finish {s} (error {d})\n", .{ name, lastError() });
            return 1;
        }
        written += 1;
        bytes += data.len;
    }
    std.debug.print("{s}: {d} members, {d} KiB uncompressed\n", .{ dst_path, written, bytes / 1024 });
    return 0;
}

fn readKeepList(path: [*:0]const u8) !std.StringHashMap(void) {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.ReadFailed;
    const text = try gpa.alloc(u8, @intCast(end));
    var done: usize = 0;
    while (done < text.len) {
        const n = std.c.pread(fd, text.ptr + done, text.len - done, @intCast(done));
        if (n <= 0) break;
        done += @intCast(n);
    }
    var set: std.StringHashMap(void) = .init(gpa);
    var lines = std.mem.tokenizeAny(u8, text[0..done], "\r\n");
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t");
        if (name.len == 0) continue;
        try set.put(try gpa.dupe(u8, lowered(name)), {});
    }
    return set;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    var first = it.next() orelse return usage();

    var keep_list: ?std.StringHashMap(void) = null;
    if (std.mem.eql(u8, first, "--ui")) {
        keep_ui = true;
        first = it.next() orelse return usage();
    }
    if (std.mem.eql(u8, first, "--keep")) {
        const p = it.next() orelse return usage();
        keep_list = readKeepList(p.ptr) catch |e| {
            std.debug.print("cannot read keep-list {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        first = it.next() orelse return usage();
    }
    const listing = std.mem.eql(u8, first, "--list");
    const src_path = if (listing) (it.next() orelse return usage()) else first;
    const dst_path = if (listing) null else it.next();
    if (!listing and dst_path == null) return usage();

    var src: HANDLE = null;
    if (!SFileOpenArchive(src_path.ptr, 0, 0, &src)) {
        std.debug.print("failed to open archive {s}\n", .{src_path});
        return 1;
    }
    defer _ = SFileCloseArchive(src);

    if (listing) return list(src);
    return pack(src, dst_path.?.ptr, if (keep_list) |*k| k else null) catch |e| {
        std.debug.print("pack failed: {s}\n", .{@errorName(e)});
        return 1;
    };
}

fn usage() u8 {
    std.debug.print(
        \\usage: mpqmin [--ui] <src.mpq> <dst.mpq>     rebuild with only what a server reads
        \\       mpqmin --list <src.mpq>               flags size csize offset locale name
        \\       mpqmin --keep <list> <src> <dst>      keep exactly the named members
        \\
        \\  --ui  also keep the palette/font/cursor files a client-mode boot loads (macOS build)
        \\
    , .{});
    return 2;
}
