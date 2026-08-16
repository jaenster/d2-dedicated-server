//! The Mac File Manager, backed by ordinary Linux files.
//!
//! HFS addresses a file as (volume, directory id, leaf name), not by path, so the shim owns that
//! mapping: one volume rooted at the process working directory, directory id = index into a table
//! of absolute paths. `FSSpec` is read field-by-field by Storm into parameter blocks, so it keeps
//! Carbon's 68k packing exactly; `FSRef` is opaque by contract, so it's just a magic word + the
//! same table index.
//!
//! `CFURLCreateFromFSRef`/`GetFileSystemRepresentation` are the FSRef-to-path leg of that lookup
//! (unrelated to Core Foundation otherwise). Resource Manager entries exist because a resource
//! fork doesn't exist on Linux: a resource file is a plain file, a resource refnum is a file refnum.

const std = @import("std");

pub const OSErr = i16;

pub const noErr: OSErr = 0;
pub const nsvErr: OSErr = -35;
pub const eofErr: OSErr = -39;
pub const fnfErr: OSErr = -43;
pub const dupFNErr: OSErr = -48;
pub const paramErr: OSErr = -50;

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "FSMakeFSSpec", &fsMakeFSSpec },
        .{ "FSpMakeFSRef", &fspMakeFSRef },
        .{ "FSGetCatalogInfo", &fsGetCatalogInfo },
        .{ "FSRefMakePath", &fsRefMakePath },
        .{ "FSpCreate", &fspCreate },
        .{ "FSpDirCreate", &fspDirCreate },
        .{ "FSpDelete", &fspDelete },
        .{ "FSpRstFLock", &fspRstFLock },
        .{ "FSpOpenDF", &fspOpenDF },
        .{ "FSpOpenRF", &fspOpenRF },
        .{ "FSClose", &fsClose },
        .{ "FSWrite", &fsWrite },
        .{ "GetEOF", &getEOF },
        .{ "SetEOF", &setEOF },
        .{ "GetFPos", &getFPos },
        .{ "SetFPos", &setFPos },
        .{ "FSGetForkPosition", &fsGetForkPosition },
        .{ "FSSetForkPosition", &fsSetForkPosition },
        .{ "FindFolder", &findFolder },
        .{ "FSFindFolder", &fsFindFolder },
        .{ "FlushVol", &flushVol },
        .{ "ResolveAliasFileWithMountFlags", &resolveAliasFileWithMountFlags },
        .{ "PBHGetVInfoSync", &pbhGetVInfoSync },
        .{ "PBHGetVolParmsSync", &pbhGetVolParmsSync },
        .{ "PBGetCatInfoSync", &pbGetCatInfoSync },
        .{ "PBSetCatInfoSync", &pbSetCatInfoSync },
        .{ "PBReadSync", &pbReadSync },
        .{ "PBReadAsync", &pbReadSync },
        .{ "PBFlushFileSync", &pbFlushFileSync },
        .{ "FSpCreateResFile", &fspCreateResFile },
        .{ "FSpOpenResFile", &fspOpenResFile },
        .{ "CloseResFile", &closeResFile },
        .{ "ResError", &resError },
        .{ "CopyCStringToPascal", &copyCStringToPascal },
        .{ "CopyPascalStringToC", &copyPascalStringToC },
        .{ "EqualString", &equalString },
        .{ "CFURLCreateFromFSRef", &cfURLCreateFromFSRef },
        .{ "CFURLGetFileSystemRepresentation", &cfURLGetFileSystemRepresentation },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

// the volume

/// One volume, and a negative reference number because that is what a real one has: positive values
/// are working-directory references, which this shim never hands out.
pub const vol_ref: i16 = -1;

/// Never a name any of the game's archives is labelled with. `MAC_FindVolume` walks the mounted
/// volumes looking for "Diablo II Game Data" and friends, and a volume that answered to one of those
/// would send it down the CD path instead of letting it fall through to the working directory.
pub const volume_name = "Macintosh HD";

/// Classic HFS reserves directory id 2 for a volume's root and 1 for the root's notional parent.
pub const root_dir_id: i32 = 2;
pub const root_par_id: i32 = 1;

/// Ids the shim allocates start well clear of the reserved pair, so a caller passing a raw 1 or 2
/// through cannot land on a real entry.
const dir_base: i32 = 1000;

const path_max = 1024;
const max_nodes = 512;

const Node = struct {
    len: usize = 0,
    path: [path_max]u8 = @splat(0),
};

/// Both directory ids and FSRefs index this. A path appears once however many times it is asked for,
/// so the table size bounds the distinct directories the game touches, not the calls it makes.
var nodes: [max_nodes]Node = @splat(.{});
var node_count: usize = 0;

/// Storm's async I/O worker opens and reads archives on its own pthread while the main thread is
/// still walking the same tables, so "scan for a free entry, then claim it" needs to be one step.
/// Critical sections are a memcpy or a single syscall, which is what makes a spin cheaper than a
/// mutex that would itself have to be initialised before any of this ran.
const Spin = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Spin) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Spin) void {
        self.held.store(false, .release);
    }
};

var table_lock: Spin = .{};

/// The volume root. Darwin answers this from the application bundle's own location; there is no
/// bundle here, and the working directory is the same fact — the loader is started in the directory
/// holding the game's data, and `FLAMINGLOGO_SetWorkingDirectory` chdir's back to it.
var root_path: [path_max]u8 = @splat(0);
var root_len: usize = 0;

pub fn setRoot(path: []const u8) void {
    const n = @min(path.len, path_max - 1);
    @memcpy(root_path[0..n], path[0..n]);
    root_path[n] = 0;
    root_len = n;
}

fn root() []const u8 {
    if (root_len == 0) {
        var buf: [path_max]u8 = undefined;
        if (std.c.getcwd(&buf, buf.len)) |p| setRoot(std.mem.span(@as([*:0]u8, @ptrCast(p)))) else setRoot(".");
    }
    return root_path[0..root_len];
}

/// Index of `path` in the node table, adding it if it is new. -1 when the table is full, which the
/// callers turn into a File Manager error rather than a wrong answer.
fn intern(path: []const u8) i32 {
    table_lock.lock();
    defer table_lock.unlock();
    for (nodes[0..node_count], 0..) |*n, i| {
        if (std.mem.eql(u8, n.path[0..n.len], path)) return @intCast(i);
    }
    if (node_count == max_nodes) return -1;
    const n = &nodes[node_count];
    const len = @min(path.len, path_max - 1);
    @memcpy(n.path[0..len], path[0..len]);
    n.path[len] = 0;
    n.len = len;
    node_count += 1;
    return @intCast(node_count - 1);
}

fn nodePath(slot: i32) ?[]const u8 {
    table_lock.lock();
    defer table_lock.unlock();
    if (slot < 0 or slot >= node_count) return null;
    const n = &nodes[@intCast(slot)];
    return n.path[0..n.len];
}

/// The absolute path a directory id names. Reserved ids and ids the shim never handed out resolve to
/// the volume root, which is where a caller that made one up meant to be anyway.
pub fn dirPath(id: i32) []const u8 {
    if (id < dir_base) return root();
    return nodePath(id - dir_base) orelse root();
}

fn dirId(path: []const u8) i32 {
    if (std.mem.eql(u8, path, root())) return root_dir_id;
    const slot = intern(path);
    return if (slot < 0) root_dir_id else slot + dir_base;
}

/// Splits an absolute path into the directory holding it and its leaf. The volume root is named
/// after its volume and its parent is the reserved id 1, which is where an upward walk terminates.
fn splitPath(path: []const u8) struct { par: i32, leaf: []const u8 } {
    if (path.len == 0 or std.mem.eql(u8, path, root())) return .{ .par = root_par_id, .leaf = volume_name };
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .par = root_dir_id, .leaf = path };
    const dir = if (cut == 0) "/" else path[0..cut];
    return .{ .par = dirId(dir), .leaf = path[cut + 1 ..] };
}

// Pascal strings

fn pascalRead(p: [*]const u8) []const u8 {
    return p[1..][0..p[0]];
}

/// The toolbox's own conversions, here because a Pascal string is the File Manager's name type and
/// Storm converts in both directions on every path it builds. Getting either wrong produces an empty
/// leaf name rather than a crash, which then reads as "the archive does not exist".
fn copyCStringToPascal(src: ?[*:0]const u8, dst: ?[*]u8) callconv(.c) void {
    const s = src orelse return;
    const d = dst orelse return;
    var n: usize = 0;
    while (s[n] != 0 and n < 255) : (n += 1) d[1 + n] = s[n];
    d[0] = @intCast(n);
}

fn copyPascalStringToC(src: ?[*]const u8, dst: ?[*]u8) callconv(.c) void {
    const s = src orelse return;
    const d = dst orelse return;
    const n = s[0];
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[1 + i];
    d[n] = 0;
}

/// Pascal-string comparison. `MAC_FindVolume` scans mounted volumes with this, and `ARCHIVE_LoadMPQ`
/// checks each candidate against the archives it already has open — an answer that is always "not
/// equal" spins that scan rather than ending it.
fn equalString(str1: ?[*]const u8, str2: ?[*]const u8, caseSensitive: u8, diacSensitive: u8) callconv(.c) u8 {
    _ = diacSensitive; // Nothing the game names has a diacritic to fold.
    const a = pascalRead(str1 orelse return 0);
    const b = pascalRead(str2 orelse return 0);
    if (a.len != b.len) return 0;
    if (caseSensitive != 0) return @intFromBool(std.mem.eql(u8, a, b));
    return @intFromBool(std.ascii.eqlIgnoreCase(a, b));
}

fn pascalWrite(out: []u8, text: []const u8) void {
    const n = @min(text.len, out.len - 1);
    out[0] = @intCast(n);
    @memcpy(out[1..][0..n], text[0..n]);
}

// FSSpec and FSRef

/// Carbon's `#pragma options align=mac68k` puts `parID` on an odd two-byte boundary, so every field
/// carries its own alignment: 70 bytes, not the 72 a naturally-aligned struct would be. The game
/// copies these into parameter blocks whole, so the packing is not negotiable.
pub const FSSpec = extern struct {
    vRefNum: i16 align(1),
    parID: i32 align(1),
    name: [64]u8 align(1),
};

comptime {
    std.debug.assert(@sizeOf(FSSpec) == 70);
    std.debug.assert(@offsetOf(FSSpec, "parID") == 2);
    std.debug.assert(@offsetOf(FSSpec, "name") == 6);
}

const fsref_magic: u32 = 0x4432_4d41;

/// An FSRef is 80 opaque bytes by contract. Only the first eight mean anything here.
pub const FSRef = extern struct {
    magic: u32,
    slot: i32,
    rest: [72]u8,
};

fn writeRef(out: ?*anyopaque, slot: i32) void {
    const r: *FSRef = @ptrCast(@alignCast(out orelse return));
    r.magic = fsref_magic;
    r.slot = slot;
}

fn readRef(p: ?*const anyopaque) ?[]const u8 {
    const r: *const FSRef = @ptrCast(@alignCast(p orelse return null));
    if (r.magic != fsref_magic) return null;
    return nodePath(r.slot);
}

/// The absolute path an FSSpec names. An empty leaf means the directory `parID` itself, which is how
/// `FLAMINGLOGO_SetWorkingDirectory` asks for the folder holding the application.
pub fn specPath(spec: *const FSSpec, out: []u8) ?[]const u8 {
    // The reserved parent id is the volume root's own parent, and the root is the only thing under
    // it — so a spec that names it is the root, whatever leaf it carries.
    if (spec.parID == root_par_id) {
        const r = root();
        if (r.len > out.len) return null;
        @memcpy(out[0..r.len], r);
        return out[0..r.len];
    }
    const dir = dirPath(spec.parID);
    const leaf = pascalRead(&spec.name);
    if (leaf.len == 0) {
        if (dir.len > out.len) return null;
        @memcpy(out[0..dir.len], dir);
        return out[0..dir.len];
    }
    return join(out, dir, leaf);
}

fn join(out: []u8, dir: []const u8, leaf: []const u8) ?[]const u8 {
    if (dir.len + 1 + leaf.len > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 ..][0..leaf.len], leaf);
    return out[0 .. dir.len + 1 + leaf.len];
}

/// Fills `spec` so it names `path`.
pub fn specForPath(spec: *FSSpec, path: []const u8) void {
    const parts = splitPath(path);
    spec.vRefNum = vol_ref;
    spec.parID = parts.par;
    pascalWrite(&spec.name, parts.leaf);
}

/// Fills `out` with a reference to `path`. The Process Manager hands one of these back for the
/// application's own location, which is the only producer of an FSRef outside this file.
pub fn refForPath(out: *FSRef, path: []const u8) OSErr {
    const slot = intern(path);
    if (slot < 0) return paramErr;
    writeRef(out, slot);
    return noErr;
}

/// The `FSSpec` half of a catalog lookup, which is the only half anything on the boot path reads.
pub fn getCatalogSpec(ref: *const FSRef, out: *FSSpec) OSErr {
    const path = readRef(ref) orelse return paramErr;
    specForPath(out, path);
    return noErr;
}

// path resolution

const f_ok: c_uint = 0;

fn exists(path: []const u8) bool {
    var z: [path_max]u8 = undefined;
    const p = terminate(&z, path) orelse return false;
    return std.c.access(p, f_ok) == 0;
}

/// Opening with O_DIRECTORY rather than stat'ing: `struct stat` is one of the few layouts that
/// differs between this host and the target, and the open either succeeds or it does not.
fn isDir(path: []const u8) bool {
    var z: [path_max]u8 = undefined;
    const p = terminate(&z, path) orelse return false;
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

fn terminate(buf: *[path_max]u8, path: []const u8) ?[:0]const u8 {
    if (path.len >= path_max) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Resolves an HFS name against a starting directory. The name may be a bare leaf, or a path whose
/// components are separated by colons — Storm builds those by rewriting the backslashes in a Windows
/// path — and it may lead with the volume name, in which case it starts at the root instead.
const Resolved = struct { dir: []const u8, leaf: []const u8 };

fn resolveName(start: []const u8, name: []const u8, dir_buf: []u8, leaf_buf: []u8) ?Resolved {
    var rest = name;
    var dir_len: usize = undefined;
    if (rest.len > 0 and rest[0] == ':') {
        // A leading colon is HFS's "relative to the directory I gave you".
        rest = rest[1..];
        @memcpy(dir_buf[0..start.len], start);
        dir_len = start.len;
    } else if (std.mem.indexOfScalar(u8, rest, ':')) |cut| {
        if (std.ascii.eqlIgnoreCase(rest[0..cut], volume_name)) {
            rest = rest[cut + 1 ..];
            @memcpy(dir_buf[0..root().len], root());
            dir_len = root().len;
        } else {
            @memcpy(dir_buf[0..start.len], start);
            dir_len = start.len;
        }
    } else {
        @memcpy(dir_buf[0..start.len], start);
        dir_len = start.len;
    }

    var it = std.mem.splitScalar(u8, rest, ':');
    var leaf: []const u8 = "";
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (leaf.len != 0) {
            var step: [path_max]u8 = undefined;
            const next = join(&step, dir_buf[0..dir_len], leaf) orelse return null;
            if (next.len > dir_buf.len) return null;
            // `join` wrote into its own buffer, so the copy back cannot overlap.
            @memcpy(dir_buf[0..next.len], next);
            dir_len = next.len;
        }
        leaf = part;
    }
    if (leaf.len > leaf_buf.len) return null;
    @memcpy(leaf_buf[0..leaf.len], leaf);
    return .{ .dir = dir_buf[0..dir_len], .leaf = leaf_buf[0..leaf.len] };
}

// open files

const max_files = 64;

const OpenFile = struct {
    used: bool = false,
    fd: std.c.fd_t = -1,
    /// Tracked here rather than in the kernel's file offset: the classic calls seek and read as two
    /// steps, and a 32-bit `lseek` on this target is one of the easiest ABI mismatches to get wrong.
    /// `pread`/`pwrite` take the offset explicitly and cannot be got wrong.
    pos: u64 = 0,
    /// Leaf name, kept only so a traced read can say which archive it came out of.
    leaf: [name_max]u8 = @splat(0),
    leaf_len: u8 = 0,
};

const name_max = 40;

var files: [max_files]OpenFile = @splat(.{});

fn claim(fd: std.c.fd_t, path: []const u8) ?i16 {
    const leaf = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
    const n = @min(leaf.len, name_max);
    table_lock.lock();
    defer table_lock.unlock();
    for (&files, 0..) |*f, i| {
        if (f.used) continue;
        f.* = .{ .used = true, .fd = fd, .pos = 0, .leaf_len = @intCast(n) };
        @memcpy(f.leaf[0..n], leaf[0..n]);
        return @intCast(i + 1);
    }
    return null;
}

fn fileOf(refNum: i16) ?*OpenFile {
    if (refNum < 1 or refNum > max_files) return null;
    const f = &files[@intCast(refNum - 1)];
    return if (f.used) f else null;
}

fn release(refNum: i16) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(refNum) orelse return paramErr;
    _ = std.c.close(f.fd);
    f.used = false;
    return noErr;
}

fn openPath(path: []const u8, writable: bool, refNum: ?*i16) OSErr {
    var z: [path_max]u8 = undefined;
    const p = terminate(&z, path) orelse return paramErr;
    const flags: std.c.O = if (writable) .{ .ACCMODE = .RDWR } else .{ .ACCMODE = .RDONLY };
    const fd = std.c.open(p, flags);
    if (fd < 0) return fnfErr;
    const ref = claim(fd, path) orelse {
        _ = std.c.close(fd);
        return paramErr;
    };
    if (refNum) |r| r.* = ref;
    return noErr;
}

/// `lseek` to the end rather than `fstat`: the position is restored by every caller anyway, since
/// this shim keeps its own, and it avoids depending on a `struct stat` layout.
fn sizeOf(f: *OpenFile) u64 {
    const end = std.c.lseek(f.fd, 0, std.c.SEEK.END);
    return if (end < 0) 0 else @intCast(end);
}

// File Manager

/// Builds an `FSSpec` from a directory and a name. Reporting `fnfErr` for a name that does not exist
/// yet is not a failure: the spec is filled either way, and that is exactly how every create call
/// gets the spec it then creates.
fn fsMakeFSSpec(vRefNum: i16, dirID: i32, name: ?[*]const u8, out: ?*FSSpec) callconv(.c) OSErr {
    _ = vRefNum; // One volume, so there is nothing to select.
    const spec = out orelse return paramErr;
    const start = dirPath(dirID);

    const raw = if (name) |p| pascalRead(p) else "";
    if (raw.len == 0) {
        // The directory itself, named the way its own parent names it.
        specForPath(spec, start);
        return noErr;
    }

    var dir_buf: [path_max]u8 = undefined;
    var leaf_buf: [64]u8 = undefined;
    const r = resolveName(start, raw, &dir_buf, &leaf_buf) orelse return paramErr;

    spec.vRefNum = vol_ref;
    spec.parID = dirId(r.dir);
    pascalWrite(&spec.name, r.leaf);
    var full: [path_max]u8 = undefined;
    const found = join(&full, r.dir, r.leaf) orelse return paramErr;
    return if (exists(found)) noErr else fnfErr;
}

fn fspMakeFSRef(spec: ?*const FSSpec, out: ?*FSRef) callconv(.c) OSErr {
    const s = spec orelse return paramErr;
    var buf: [path_max]u8 = undefined;
    const p = specPath(s, &buf) orelse return paramErr;
    const slot = intern(p);
    if (slot < 0) return paramErr;
    writeRef(out, slot);
    return noErr;
}

/// Only the `FSSpec` output is answered. The catalog record proper carries Finder metadata a Linux
/// file does not have, and every caller on the boot path asks for the spec and nothing else.
fn fsGetCatalogInfo(
    ref: ?*const FSRef,
    whichInfo: u32,
    catalogInfo: ?*anyopaque,
    outName: ?[*]u8,
    fsSpec: ?*FSSpec,
    parentRef: ?*FSRef,
) callconv(.c) OSErr {
    _ = .{ whichInfo, catalogInfo };
    const path = readRef(ref) orelse return paramErr;
    const parts = splitPath(path);
    if (fsSpec) |s| _ = getCatalogSpec(ref.?, s);
    if (outName) |n| pascalWrite(n[0..64], parts.leaf);
    if (parentRef) |p| {
        const slot = intern(dirPath(parts.par));
        if (slot < 0) return paramErr;
        writeRef(p, slot);
    }
    return noErr;
}

fn fsRefMakePath(ref: ?*const FSRef, path: ?[*]u8, maxLen: u32) callconv(.c) OSErr {
    const src = readRef(ref) orelse return paramErr;
    const out = path orelse return paramErr;
    if (maxLen == 0 or src.len + 1 > maxLen) return paramErr;
    @memcpy(out[0..src.len], src);
    out[src.len] = 0;
    return noErr;
}

fn fspCreate(spec: ?*const FSSpec, creator: u32, fileType: u32, scriptTag: i16) callconv(.c) OSErr {
    _ = .{ creator, fileType, scriptTag }; // Finder types; nothing on Linux records them.
    const s = spec orelse return paramErr;
    var buf: [path_max]u8 = undefined;
    const p = specPath(s, &buf) orelse return paramErr;
    if (exists(p)) return dupFNErr;
    var z: [path_max]u8 = undefined;
    const zp = terminate(&z, p) orelse return paramErr;
    const fd = std.c.open(zp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o666));
    if (fd < 0) return paramErr;
    _ = std.c.close(fd);
    return noErr;
}

/// Creates the leading components as well as the leaf. A parID names a directory in the shim's own
/// table, and nothing put that directory on disk, so by the time a create arrives any number of
/// levels above it may still be missing — which is the "the save folder was never made" failure
/// rather than a real `FSpDirCreate` restriction worth preserving.
fn fspDirCreate(spec: ?*const FSSpec, scriptTag: i16, createdDirID: ?*i32) callconv(.c) OSErr {
    _ = scriptTag;
    const s = spec orelse return paramErr;
    var buf: [path_max]u8 = undefined;
    const p = specPath(s, &buf) orelse return paramErr;
    var z: [path_max]u8 = undefined;
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (i != p.len and p[i] != '/') continue;
        const zp = terminate(&z, p[0..i]) orelse return paramErr;
        _ = std.c.mkdir(zp, 0o777);
    }
    if (!isDir(p)) return paramErr;
    if (createdDirID) |id| id.* = dirId(p);
    return noErr;
}

fn fspDelete(spec: ?*const FSSpec) callconv(.c) OSErr {
    const s = spec orelse return paramErr;
    var buf: [path_max]u8 = undefined;
    const p = specPath(s, &buf) orelse return paramErr;
    var z: [path_max]u8 = undefined;
    const zp = terminate(&z, p) orelse return paramErr;
    return if (std.c.unlink(zp) == 0) noErr else fnfErr;
}

/// Clearing a file's lock bit. Nothing here sets one.
fn fspRstFLock(spec: ?*const FSSpec) callconv(.c) OSErr {
    _ = spec;
    return noErr;
}

/// `permission` is fsRdPerm 1, fsWrPerm 2, fsRdWrPerm 3. Anything but read-only gets a writable
/// descriptor, since a caller that asked to write and got a read-only file fails much later.
fn fspOpenDF(spec: ?*const FSSpec, permission: i8, refNum: ?*i16) callconv(.c) OSErr {
    const s = spec orelse return paramErr;
    var buf: [path_max]u8 = undefined;
    const p = specPath(s, &buf) orelse return paramErr;
    return openPath(p, permission != 1, refNum);
}

/// There is no resource fork on this filesystem, so a resource fork is the file. The one caller that
/// matters writes a resource file it created a moment earlier and reads it straight back.
fn fspOpenRF(spec: ?*const FSSpec, permission: i8, refNum: ?*i16) callconv(.c) OSErr {
    return fspOpenDF(spec, permission, refNum);
}

fn fsClose(refNum: i16) callconv(.c) OSErr {
    return release(refNum);
}

/// `count` is in-out: the caller asks for a byte count and reads back the count actually written.
/// `PreInitApplication` compares the two, so a short write has to be reported as one.
fn fsWrite(refNum: i16, count: ?*i32, buffer: ?[*]const u8) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(refNum) orelse return paramErr;
    const c = count orelse return paramErr;
    const buf = buffer orelse return paramErr;
    const want: usize = @intCast(@max(c.*, 0));
    var done: usize = 0;
    while (done < want) {
        const n = std.c.pwrite(f.fd, buf + done, want - done, @intCast(f.pos + done));
        if (n <= 0) break;
        done += @intCast(n);
    }
    f.pos += done;
    c.* = @intCast(done);
    return if (done < want) eofErr else noErr;
}

fn getEOF(refNum: i16, logEOF: ?*i32) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(refNum) orelse return paramErr;
    if (logEOF) |p| p.* = @intCast(sizeOf(f));
    return noErr;
}

fn setEOF(refNum: i16, logEOF: i32) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(refNum) orelse return paramErr;
    return if (std.c.ftruncate(f.fd, @max(logEOF, 0)) == 0) noErr else paramErr;
}

fn getFPos(refNum: i16, filePos: ?*i32) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(refNum) orelse return paramErr;
    if (filePos) |p| p.* = @intCast(f.pos);
    return noErr;
}

/// fsAtMark 0, fsFromStart 1, fsFromLEOF 2, fsFromMark 3. Only the low two bits select the base; the
/// rest carry newline-scan options nothing here uses.
fn seek(f: *OpenFile, posMode: i16, posOff: i64) OSErr {
    const base: i64 = switch (posMode & 3) {
        1 => 0,
        2 => @intCast(sizeOf(f)),
        3 => @intCast(f.pos),
        else => return noErr,
    };
    const target = base + posOff;
    if (target < 0) return paramErr;
    f.pos = @intCast(target);
    return if (target > sizeOf(f)) eofErr else noErr;
}

fn setFPos(refNum: i16, posMode: i16, posOff: i32) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(refNum) orelse return paramErr;
    return seek(f, posMode, posOff);
}

fn fsGetForkPosition(forkRefNum: i16, position: ?*i64) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(forkRefNum) orelse return paramErr;
    if (position) |p| p.* = @intCast(f.pos);
    return noErr;
}

fn fsSetForkPosition(forkRefNum: i16, positionMode: i16, positionOffset: i64) callconv(.c) OSErr {
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(forkRefNum) orelse return paramErr;
    return seek(f, positionMode, positionOffset);
}

/// `kTemporaryFolderType`. The only folder the game asks for, and `/tmp` is what it means.
const temporary_folder: u32 = 0x666c_6e74; // 'flnt'

fn folderPath(folderType: u32) ?[]const u8 {
    return switch (folderType) {
        temporary_folder => "/tmp",
        else => null,
    };
}

/// `kCreateFolder` is not advice. The game passes it, and the only reason it does is that it is
/// about to create a file in there — so answering "found" for a directory that is not on disk is a
/// success that the very next call turns into `paramErr`. It cost a boot: the deploy image is built
/// `FROM scratch` and has no `/tmp`, so `FSpCreateResFile` failed, `ResError` reported -50 and
/// PreInitApplication put up "critical error and cannot start. (6, -50)".
fn ensureFolder(path: []const u8, createFolder: u8) OSErr {
    if (isDir(path)) return noErr;
    if (createFolder == 0) return fnfErr;
    var z: [path_max]u8 = undefined;
    const zp = terminate(&z, path) orelse return paramErr;
    _ = std.c.mkdir(zp, 0o777);
    return if (isDir(path)) noErr else fnfErr;
}

fn findFolder(
    vRefNum: i16,
    folderType: u32,
    createFolder: u8,
    foundVRefNum: ?*i16,
    foundDirID: ?*i32,
) callconv(.c) OSErr {
    _ = vRefNum;
    const p = folderPath(folderType) orelse return fnfErr;
    const err = ensureFolder(p, createFolder);
    if (err != noErr) return err;
    if (foundVRefNum) |v| v.* = vol_ref;
    if (foundDirID) |d| d.* = dirId(p);
    return noErr;
}

fn fsFindFolder(vRefNum: i16, folderType: u32, createFolder: u8, foundRef: ?*FSRef) callconv(.c) OSErr {
    _ = vRefNum;
    const p = folderPath(folderType) orelse return fnfErr;
    const err = ensureFolder(p, createFolder);
    if (err != noErr) return err;
    const slot = intern(p);
    if (slot < 0) return paramErr;
    writeRef(foundRef, slot);
    return noErr;
}

/// Writing back a volume's cached directory blocks. The kernel owns that here.
fn flushVol(volName: ?[*]const u8, vRefNum: i16) callconv(.c) OSErr {
    _ = .{ volName, vRefNum };
    return noErr;
}

/// Nothing in a plain data directory is an alias, so the spec already names its own target.
fn resolveAliasFileWithMountFlags(
    theSpec: ?*FSSpec,
    resolveAliasChains: u8,
    targetIsFolder: ?*u8,
    wasAliased: ?*u8,
    mountFlags: u32,
) callconv(.c) OSErr {
    _ = .{ resolveAliasChains, mountFlags };
    const s = theSpec orelse return paramErr;
    var buf: [path_max]u8 = undefined;
    const p = specPath(s, &buf) orelse return paramErr;
    if (targetIsFolder) |t| t.* = @intFromBool(isDir(p));
    if (wasAliased) |w| w.* = 0;
    return if (exists(p)) noErr else fnfErr;
}

// parameter blocks

/// `ParamBlockRec` keeps 68k packing, so four-byte fields sit on odd two-byte boundaries and the
/// variants overlay each other. Addressing by explicit offset rather than through a struct is what
/// stops a silent alignment disagreement from quietly corrupting a read.
const pb = struct {
    const result = 16;
    const name_ptr = 18;
    const v_ref_num = 22;
    const ref_num = 24;
    /// `ioMisc` in IOParam, `ioVolIndex` in HVolumeParam: the same bytes, two meanings.
    const vol_index = 28;
    const buffer = 32;
    const req_count = 36;
    const act_count = 40;
    const pos_mode = 44;
    const pos_offset = 46;

    /// HVolumeParam. `ioVNmAlBlks` and `ioVFrBlk` are 16-bit, so the block size has to be chosen to
    /// let a real volume's size fit in them.
    const v_nm_al_blks = 46;
    const v_al_blk_siz = 48;
    const v_fr_blk = 62;

    /// HFileInfo / DirInfo, the two CInfoPBRec variants.
    const fdir_index = 28;
    const fl_attrib = 30;
    const dir_id = 48;
    const dr_par_id = 100;
    const fl_lg_len = 54;
    const fl_py_len = 58;
};

fn get16(p: [*]u8, off: usize) i16 {
    return std.mem.readInt(i16, p[off..][0..2], .little);
}

fn get32(p: [*]u8, off: usize) i32 {
    return std.mem.readInt(i32, p[off..][0..4], .little);
}

fn put16(p: [*]u8, off: usize, v: i16) void {
    std.mem.writeInt(i16, p[off..][0..2], v, .little);
}

fn put32(p: [*]u8, off: usize, v: i32) void {
    std.mem.writeInt(i32, p[off..][0..4], v, .little);
}

fn getPtr(p: [*]u8, off: usize) ?[*]u8 {
    const raw = std.mem.readInt(u32, p[off..][0..4], .little);
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// `MAC_FindVolume` walks `ioVolIndex` = 1, 2, 3, ... looking for a volume whose name matches an
/// archive's CD label, and it stops only when a call comes back non-zero. There is one volume, so it
/// is answered at index 1 — and at index 0, which selects by `ioVRefNum` instead and -1 is the only
/// one there is — and `nsvErr` for everything past that. Without that refusal the walk never sees a
/// failure and re-queries an index that keeps succeeding, forever.
fn pbhGetVInfoSync(paramBlock: ?[*]u8) callconv(.c) OSErr {
    const p = paramBlock orelse return paramErr;
    if (get16(p, pb.vol_index) >= 2) {
        put16(p, pb.result, nsvErr);
        return nsvErr;
    }
    put16(p, pb.v_ref_num, vol_ref);
    if (getPtr(p, pb.name_ptr)) |name| pascalWrite(name[0..64], volume_name);
    fillVolumeSize(p);
    put16(p, pb.result, noErr);
    return noErr;
}

/// What the volume reports as its size. Neither Zig's standard library nor this shim has a `statfs`
/// on this target, and the real number is not a fact the boot path needs — it becomes one at
/// character create, where `MAC_GetDiskFreeSpaceEx` reads these fields and a zero produces "not
/// enough room on your Hard Disk". A gigabyte is stated rather than measured, and this is the note
/// that says so.
const reported_volume_bytes: u64 = 1 << 30;

/// A block size is picked so the total fits the 16-bit block counts, and free is derived with the
/// same size so a caller multiplying either count by `ioVAlBlkSiz` agrees with the other.
fn fillVolumeSize(p: [*]u8) void {
    const total: u64 = reported_volume_bytes;
    const free: u64 = reported_volume_bytes;
    const max_blocks: u64 = 0xffff;
    const block_size = @max((total + max_blocks - 1) / max_blocks, 512);
    const total_blocks = @min(total / block_size, max_blocks);
    const free_blocks = @min(free / block_size, total_blocks);
    put16(p, pb.v_nm_al_blks, @bitCast(@as(u16, @intCast(total_blocks))));
    put32(p, pb.v_al_blk_siz, @intCast(block_size));
    put16(p, pb.v_fr_blk, @bitCast(@as(u16, @intCast(free_blocks))));
}

/// Volume capability bits. Zero says "a plain local volume with no special attributes", which is
/// what this is.
fn pbhGetVolParmsSync(paramBlock: ?[*]u8) callconv(.c) OSErr {
    const p = paramBlock orelse return paramErr;
    if (getPtr(p, pb.buffer)) |buf| {
        const len: usize = @intCast(@max(get32(p, pb.req_count), 0));
        @memset(buf[0..@min(len, 128)], 0);
    }
    put16(p, pb.result, noErr);
    return noErr;
}

/// Catalog lookup: a stat by name, or — with a negative `ioFDirIndex` — a description of the
/// directory `ioDrDirID` names, which is how a caller walks back up the tree.
fn pbGetCatInfoSync(paramBlock: ?[*]u8) callconv(.c) OSErr {
    const p = paramBlock orelse return paramErr;
    if (get16(p, pb.fdir_index) < 0) {
        const id = get32(p, pb.dir_id);
        const path = dirPath(id);
        const parts = splitPath(path);
        if (getPtr(p, pb.name_ptr)) |name| pascalWrite(name[0..64], parts.leaf);
        put32(p, pb.dr_par_id, parts.par);
        put16(p, pb.result, noErr);
        return noErr;
    }

    const name = getPtr(p, pb.name_ptr) orelse {
        put16(p, pb.result, fnfErr);
        return fnfErr;
    };
    var dir_buf: [path_max]u8 = undefined;
    var leaf_buf: [64]u8 = undefined;
    const start = dirPath(get32(p, pb.dir_id));
    const r = resolveName(start, pascalRead(name), &dir_buf, &leaf_buf) orelse {
        put16(p, pb.result, fnfErr);
        return fnfErr;
    };
    var full: [path_max]u8 = undefined;
    const path = join(&full, r.dir, r.leaf) orelse {
        put16(p, pb.result, fnfErr);
        return fnfErr;
    };
    // ioFlAttrib bit 4 is "this is a directory"; DirInfo overlays HFileInfo, so a directory answer
    // fills the id where a file answer fills the two lengths.
    if (isDir(path)) {
        put16(p, pb.fl_attrib, 0x10);
        put32(p, pb.dir_id, dirId(path));
        put16(p, pb.result, noErr);
        return noErr;
    }
    const size = pathSize(path) orelse {
        put16(p, pb.result, fnfErr);
        return fnfErr;
    };
    put16(p, pb.fl_attrib, 0);
    put32(p, pb.fl_lg_len, @intCast(size));
    put32(p, pb.fl_py_len, @intCast(size));
    put16(p, pb.result, noErr);
    return noErr;
}

/// Size of a file by path, or null when it cannot be opened.
fn pathSize(path: []const u8) ?i64 {
    var z: [path_max]u8 = undefined;
    const p = terminate(&z, path) orelse return null;
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    return std.c.lseek(fd, 0, std.c.SEEK.END);
}

/// Writing Finder metadata back. There is none to write.
fn pbSetCatInfoSync(paramBlock: ?[*]u8) callconv(.c) OSErr {
    const p = paramBlock orelse return paramErr;
    put16(p, pb.result, noErr);
    return noErr;
}

/// Storm's archive reads. The async entry point resolves to this too: the work is a single `pread`,
/// so completing it before returning is both correct and what every caller here waits for anyway.
fn pbReadSync(paramBlock: ?[*]u8) callconv(.c) OSErr {
    const p = paramBlock orelse return paramErr;
    table_lock.lock();
    defer table_lock.unlock();
    const f = fileOf(get16(p, pb.ref_num)) orelse {
        put16(p, pb.result, paramErr);
        return paramErr;
    };
    const err = seek(f, get16(p, pb.pos_mode), get32(p, pb.pos_offset));
    if (err != noErr and err != eofErr) {
        put16(p, pb.result, err);
        return err;
    }
    const want: usize = @intCast(@max(get32(p, pb.req_count), 0));
    const buf = getPtr(p, pb.buffer) orelse {
        put16(p, pb.result, paramErr);
        return paramErr;
    };
    var done: usize = 0;
    while (done < want) {
        const n = std.c.pread(f.fd, buf + done, want - done, @intCast(f.pos + done));
        if (n <= 0) break;
        done += @intCast(n);
    }
    trace(f, f.pos, done);
    f.pos += done;
    put32(p, pb.act_count, @intCast(done));
    put32(p, pb.pos_offset, @intCast(f.pos));
    const result: OSErr = if (done < want) eofErr else noErr;
    put16(p, pb.result, result);
    return result;
}

/// Which archive members the game actually reads, answered without an engine hook. Storm's member
/// lookup is internal to the image and cannot be intercepted from here, but every byte it reads
/// arrives through this one call — so a (file, offset, length) log plus the archive's own block
/// offsets (`tools/mpqmin --list`) names the member exactly. Off unless `D2MAC_TRACE_IO=1`, and
/// unbuffered so a crash cannot swallow the tail of the run.
var trace_on: ?bool = null;

fn trace(f: *const OpenFile, at: u64, len: usize) void {
    const on = trace_on orelse blk: {
        const v = std.c.getenv("D2MAC_TRACE_IO");
        const on = v != null and v.?[0] == '1';
        trace_on = on;
        break :blk on;
    };
    if (!on or len == 0) return;
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "io {s} {d} {d}\n", .{ f.leaf[0..f.leaf_len], at, len }) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

fn pbFlushFileSync(paramBlock: ?[*]u8) callconv(.c) OSErr {
    const p = paramBlock orelse return paramErr;
    table_lock.lock();
    defer table_lock.unlock();
    if (fileOf(get16(p, pb.ref_num))) |f| _ = std.c.fsync(f.fd);
    put16(p, pb.result, noErr);
    return noErr;
}

// Resource Manager

/// The Resource Manager reports through a separate call rather than a return value, so the last
/// result has to be kept. `PreInitApplication` checks it straight after creating its resource file
/// and gives up on anything but zero.
var last_res_error: OSErr = noErr;

fn resError() callconv(.c) OSErr {
    return last_res_error;
}

/// A resource file with no resources in it is an empty file, and that is what the caller goes on to
/// fill by writing the fork directly. Re-creating an existing one is `dupFNErr`, which the caller
/// tolerates — the delete just before it is what normally makes that moot.
fn fspCreateResFile(spec: ?*const FSSpec, creator: u32, fileType: u32, scriptTag: i16) callconv(.c) void {
    last_res_error = fspCreate(spec, creator, fileType, scriptTag);
}

/// The refnum only has to be something `CloseResFile` accepts and something that is not -1, which is
/// the Resource Manager's "no such file". Backing it with the open file keeps that honest.
fn fspOpenResFile(spec: ?*const FSSpec, permission: i8) callconv(.c) i16 {
    var ref: i16 = -1;
    last_res_error = fspOpenDF(spec, permission, &ref);
    if (last_res_error != noErr) return -1;
    return ref;
}

fn closeResFile(refNum: i16) callconv(.c) void {
    last_res_error = release(refNum);
}

// the FSRef-to-path leg of Core Foundation

const cfurl_magic: u32 = 0x4432_5552;

/// A CFURL as far as this process is concerned: a tagged path. Nothing here implements Core
/// Foundation, and nothing needs to — the game creates these from an FSRef and immediately asks for
/// the file system representation back.
const CFURL = extern struct {
    magic: u32,
    slot: i32,
};

var urls: [max_nodes]CFURL = @splat(.{ .magic = 0, .slot = 0 });
var url_count: usize = 0;

fn cfURLCreateFromFSRef(allocator: ?*anyopaque, ref: ?*const FSRef) callconv(.c) ?*CFURL {
    _ = allocator;
    const r: *const FSRef = @ptrCast(@alignCast(ref orelse return null));
    if (r.magic != fsref_magic) return null;
    table_lock.lock();
    defer table_lock.unlock();
    if (url_count == urls.len) return null;
    const u = &urls[url_count];
    u.* = .{ .magic = cfurl_magic, .slot = r.slot };
    url_count += 1;
    return u;
}

fn cfURLGetFileSystemRepresentation(
    url: ?*const CFURL,
    resolveAgainstBase: u8,
    buffer: ?[*]u8,
    maxBufLen: i32,
) callconv(.c) u8 {
    _ = resolveAgainstBase; // Every URL here is already absolute.
    const u = url orelse return 0;
    if (u.magic != cfurl_magic) return 0;
    const path = nodePath(u.slot) orelse return 0;
    const out = buffer orelse return 0;
    if (maxBufLen <= 0 or path.len + 1 > @as(usize, @intCast(maxBufLen))) return 0;
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return 1;
}

const testing = std.testing;

/// Every test runs against a fixed root so a real working directory cannot change the answers.
fn withRoot(path: []const u8) void {
    setRoot(path);
    node_count = 0;
    url_count = 0;
    last_res_error = noErr;
}

test "an FSSpec keeps Carbon's 68k packing" {
    try testing.expectEqual(@as(usize, 70), @sizeOf(FSSpec));
    try testing.expectEqual(@as(usize, 2), @offsetOf(FSSpec, "parID"));
    try testing.expectEqual(@as(usize, 6), @offsetOf(FSSpec, "name"));
    try testing.expectEqual(@as(usize, 80), @sizeOf(FSRef));
}

test "the error codes are the ones the game compares against" {
    // PreInitApplication switches on ResError() + 0x31, so these values are load-bearing arithmetic,
    // not decoration.
    try testing.expectEqual(@as(OSErr, 0), noErr);
    try testing.expectEqual(@as(OSErr, -35), nsvErr);
    try testing.expectEqual(@as(OSErr, -39), eofErr);
    try testing.expectEqual(@as(OSErr, -43), fnfErr);
    try testing.expectEqual(@as(OSErr, -48), dupFNErr);
    try testing.expectEqual(@as(OSErr, -50), paramErr);
}

test "a directory id round-trips to the path it names" {
    withRoot("/game");
    try testing.expectEqualStrings("/game", dirPath(root_dir_id));
    // Ids that were never handed out are the root, not a wild pointer into the table.
    try testing.expectEqualStrings("/game", dirPath(0));
    try testing.expectEqualStrings("/game", dirPath(root_par_id));

    const save = dirId("/game/Save");
    try testing.expect(save >= dir_base);
    try testing.expectEqualStrings("/game/Save", dirPath(save));
    // Interning is by path, so the same directory is always the same id.
    try testing.expectEqual(save, dirId("/game/Save"));
    try testing.expectEqual(root_dir_id, dirId("/game"));
}

test "a spec resolves to a path, and an empty leaf means the directory itself" {
    withRoot("/game");
    var spec: FSSpec = undefined;
    var buf: [path_max]u8 = undefined;

    spec = .{ .vRefNum = vol_ref, .parID = root_dir_id, .name = undefined };
    pascalWrite(&spec.name, "d2data.mpq");
    try testing.expectEqualStrings("/game/d2data.mpq", specPath(&spec, &buf).?);

    // This is the shape FLAMINGLOGO_SetWorkingDirectory asks for: the folder holding the app.
    pascalWrite(&spec.name, "");
    try testing.expectEqualStrings("/game", specPath(&spec, &buf).?);
}

test "the spec for a path names it from its parent, and the root is named after the volume" {
    withRoot("/game");
    var spec: FSSpec = undefined;

    specForPath(&spec, "/game/Save/char.d2s");
    try testing.expectEqual(vol_ref, spec.vRefNum);
    try testing.expectEqualStrings("/game/Save", dirPath(spec.parID));
    try testing.expectEqualStrings("char.d2s", pascalRead(&spec.name));

    // HFS names a volume's root directory after the volume, and its parent is the reserved id.
    specForPath(&spec, "/game");
    try testing.expectEqual(root_par_id, spec.parID);
    try testing.expectEqualStrings(volume_name, pascalRead(&spec.name));

    // And it has to resolve back to the root, not to a "Macintosh HD" inside it. This is the exact
    // spec FLAMINGLOGO_SetWorkingDirectory chdir's to, so getting it wrong moves the whole game.
    var buf: [path_max]u8 = undefined;
    try testing.expectEqualStrings("/game", specPath(&spec, &buf).?);
}

test "an empty name asks for the directory itself, which is what the working-directory lookup does" {
    withRoot("/game");
    var spec: FSSpec = undefined;
    var buf: [path_max]u8 = undefined;

    // FSMakeFSSpec(vRefNum, dirID, "") -> the folder `dirID` names.
    try testing.expectEqual(noErr, fsMakeFSSpec(vol_ref, root_dir_id, null, &spec));
    try testing.expectEqualStrings("/game", specPath(&spec, &buf).?);

    const save = dirId("/game/Save");
    try testing.expectEqual(noErr, fsMakeFSSpec(vol_ref, save, null, &spec));
    try testing.expectEqualStrings("/game/Save", specPath(&spec, &buf).?);
}

test "an HFS name resolves relative to its directory, absolutely, or with colons for separators" {
    withRoot("/game");
    var dir_buf: [path_max]u8 = undefined;
    var leaf_buf: [64]u8 = undefined;

    // A bare leaf.
    var r = resolveName("/game", "d2data.mpq", &dir_buf, &leaf_buf).?;
    try testing.expectEqualStrings("/game", r.dir);
    try testing.expectEqualStrings("d2data.mpq", r.leaf);

    // A leading colon is HFS's "relative to here"; the components in between are directories.
    r = resolveName("/game", ":Data:Local:D2Resources.rsrc", &dir_buf, &leaf_buf).?;
    try testing.expectEqualStrings("/game/Data/Local", r.dir);
    try testing.expectEqualStrings("D2Resources.rsrc", r.leaf);

    // Leading with the volume name starts at the root, whatever directory was passed in.
    r = resolveName("/game/Save", volume_name ++ ":Data:file.txt", &dir_buf, &leaf_buf).?;
    try testing.expectEqualStrings("/game/Data", r.dir);
    try testing.expectEqualStrings("file.txt", r.leaf);
}

test "a resource file reports its own last error" {
    withRoot("/game");
    try testing.expectEqual(noErr, resError());
    // A spec no path can be built for fails, and the failure is what ResError has to report.
    _ = fspOpenResFile(null, 1);
    try testing.expectEqual(paramErr, resError());
}

test "a folder the caller asked to have created is on disk before it is reported found" {
    withRoot("/game");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [path_max]u8 = undefined;
    const missing = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/Temporary Items", .{tmp.sub_path});

    // Without the flag the answer is the truth about the file system, not a directory id.
    try testing.expectEqual(fnfErr, ensureFolder(missing, 0));
    try testing.expectEqual(noErr, ensureFolder(missing, 1));
    try testing.expect(isDir(missing));
    // Already there is still found, not dupFNErr — FindFolder has no such failure.
    try testing.expectEqual(noErr, ensureFolder(missing, 1));
}

test "the file table hands out refnums from one and refuses an unknown one" {
    withRoot("/game");
    for (&files) |*f| f.used = false;
    try testing.expectEqual(paramErr, release(1));
    try testing.expectEqual(paramErr, fsClose(0));
    try testing.expectEqual(paramErr, fsClose(max_files + 1));
}

test "the volume answers once and then refuses, or MAC_FindVolume never stops walking" {
    withRoot("/game");
    // ioNamePtr stays null: a parameter block holds 32-bit pointers, which a 64-bit test host cannot
    // supply. The name itself is covered by the Pascal-string test.
    var block: [128]u8 = @splat(0);

    for ([_]i16{ 0, 1 }) |index| {
        put16(&block, pb.vol_index, index);
        try testing.expectEqual(noErr, pbhGetVInfoSync(&block));
        try testing.expectEqual(vol_ref, get16(&block, pb.v_ref_num));
        try testing.expectEqual(noErr, get16(&block, pb.result));
    }
    put16(&block, pb.vol_index, 2);
    try testing.expectEqual(nsvErr, pbhGetVInfoSync(&block));
    try testing.expectEqual(nsvErr, get16(&block, pb.result));

    // Total and free have to stay consistent with the block size, whichever pair a caller multiplies.
    put16(&block, pb.vol_index, 1);
    _ = pbhGetVInfoSync(&block);
    const blocks: u64 = @as(u16, @bitCast(get16(&block, pb.v_nm_al_blks)));
    const free: u64 = @as(u16, @bitCast(get16(&block, pb.v_fr_blk)));
    const size: u64 = @intCast(get32(&block, pb.v_al_blk_siz));
    try testing.expect(blocks != 0 and free != 0);
    try testing.expect(free <= blocks);
    try testing.expect(blocks * size <= reported_volume_bytes);
}

test "a Pascal string is a length byte and its characters, and it cannot outgrow a Str63" {
    var buf: [64]u8 = @splat(0xaa);
    pascalWrite(&buf, "d2data.mpq");
    try testing.expectEqual(@as(u8, 10), buf[0]);
    try testing.expectEqualStrings("d2data.mpq", pascalRead(&buf));

    pascalWrite(&buf, "x" ** 200);
    try testing.expectEqual(@as(u8, 63), buf[0]);
    try testing.expectEqual(@as(usize, 63), pascalRead(&buf).len);

    pascalWrite(&buf, "");
    try testing.expectEqual(@as(usize, 0), pascalRead(&buf).len);
}

test "an FSRef only answers to a reference this shim wrote" {
    withRoot("/game");
    var ref: FSRef = undefined;
    writeRef(&ref, intern("/game/Save"));
    try testing.expectEqualStrings("/game/Save", readRef(&ref).?);

    var junk: FSRef = std.mem.zeroes(FSRef);
    try testing.expectEqual(@as(?[]const u8, null), readRef(&junk));
    try testing.expectEqual(@as(?[]const u8, null), readRef(null));
}

test "a CFURL made from an FSRef gives the path back and nothing else does" {
    withRoot("/game");
    var ref: FSRef = undefined;
    writeRef(&ref, intern("/game"));
    const url = cfURLCreateFromFSRef(null, &ref).?;

    var buf: [path_max]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), cfURLGetFileSystemRepresentation(url, 1, &buf, buf.len));
    try testing.expectEqualStrings("/game", std.mem.sliceTo(&buf, 0));

    // Too small a buffer is a refusal, not a truncated path.
    try testing.expectEqual(@as(u8, 0), cfURLGetFileSystemRepresentation(url, 1, &buf, 3));
    const alien: CFURL = .{ .magic = 0, .slot = 0 };
    try testing.expectEqual(@as(u8, 0), cfURLGetFileSystemRepresentation(&alien, 1, &buf, buf.len));
}

test "the import names this package answers to are the ones it implements" {
    try testing.expect(address("FSMakeFSSpec") != null);
    try testing.expect(address("PBHGetVInfoSync") != null);
    try testing.expect(address("ResError") != null);
    // The asynchronous read shares the synchronous entry point rather than getting a thunk.
    try testing.expectEqual(address("PBReadSync"), address("PBReadAsync"));
    // Nothing that needs a real resource fork is claimed here.
    try testing.expectEqual(@as(?usize, null), address("GetResource"));
    try testing.expectEqual(@as(?usize, null), address("Get1NamedResource"));
    try testing.expectEqual(@as(?usize, null), address("DetachResource"));
}
