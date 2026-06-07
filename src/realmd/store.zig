//! Store — durable character data. The first backend is the filesystem itself:
//! one save file per character at `<data_dir>/chars/<account>/<char>.d2s`. That
//! survives restarts for free, and on k8s a shared PVC (or later a shared object
//! store / DB behind this same API) makes it work across instances.
//!
//! This is the Store seam referenced by state.zig: protocol handlers call these
//! functions and never touch the filesystem directly, so the backend can change
//! without touching d2cs/d2dbs.
//!
//! 0.16's filesystem went through std.Io, so we hold a process-global Io (set by
//! main) and serialise all fs ops behind one spinlock — these are infrequent and
//! it keeps the shared Io single-op-at-a-time, which is simplest and safe.
const std = @import("std");
const Spinlock = @import("lock.zig").Spinlock;
const Dir = std.Io.Dir;

pub var data_dir: []const u8 = "realmd-data";
pub var io: std.Io = undefined; // set by main()
var fs_lock: Spinlock = .{};

pub const max_chars = 16;
pub const Name = struct {
    buf: [32]u8 = [_]u8{0} ** 32,
    len: u8 = 0,
    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Reject anything that could escape the data dir or isn't a plain identifier.
fn sanitize(name: []const u8, out: []u8) ?[]const u8 {
    if (name.len == 0 or name.len >= out.len) return null;
    for (name, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return null;
        out[i] = c;
    }
    return out[0..name.len];
}

fn dirPath(buf: []u8, account: []const u8) ?[]const u8 {
    var ab: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/chars/{s}", .{ data_dir, a }) catch null;
}

fn charPath(buf: []u8, account: []const u8, charname: []const u8) ?[]const u8 {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return null;
    const c = sanitize(charname, &cb) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/chars/{s}/{s}.d2s", .{ data_dir, a, c }) catch null;
}

/// Persist a character's save bytes. Returns false on bad name / IO error.
pub fn saveChar(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    fs_lock.lock();
    defer fs_lock.unlock();

    var dbuf: [512]u8 = undefined;
    const dir = dirPath(&dbuf, account) orelse return false;
    Dir.cwd().createDirPath(io, dir) catch return false;

    var pbuf: [512]u8 = undefined;
    const path = charPath(&pbuf, account, charname) orelse return false;
    Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch return false;
    return true;
}

/// Read a character's save bytes into `out`. Returns byte count (0 if missing).
pub fn getChar(account: []const u8, charname: []const u8, out: []u8) usize {
    fs_lock.lock();
    defer fs_lock.unlock();

    var pbuf: [512]u8 = undefined;
    const path = charPath(&pbuf, account, charname) orelse return 0;
    const f = Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    return f.readPositionalAll(io, out, 0) catch 0;
}

// ── shared session/game records (multi-instance mode) ────────────────────────
// Sessions and games live as small files under the (shared) data dir so any
// instance can resolve what another created. Same backend as chars; on k8s a
// ReadWriteMany PVC makes this multi-instance. Reusing the Store seam means no
// extra service (Redis/DB) is required for instances to run in tandem.

fn writeSmall(subdir: []const u8, key: []const u8, bytes: []const u8) bool {
    fs_lock.lock();
    defer fs_lock.unlock();
    var dbuf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ data_dir, subdir }) catch return false;
    Dir.cwd().createDirPath(io, dir) catch return false;
    var pbuf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ data_dir, subdir, key }) catch return false;
    Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch return false;
    return true;
}

fn readSmall(subdir: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    fs_lock.lock();
    defer fs_lock.unlock();
    var pbuf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ data_dir, subdir, key }) catch return null;
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, out, 0) catch return null;
    return out[0..n];
}

fn deleteSmall(subdir: []const u8, key: []const u8) void {
    fs_lock.lock();
    defer fs_lock.unlock();
    var pbuf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ data_dir, subdir, key }) catch return;
    Dir.cwd().deleteFile(io, path) catch {};
}

/// Session id -> account name, as a file (hex-named, no traversal risk).
pub fn putSession(id: u64, account: []const u8) bool {
    var kb: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{x}", .{id}) catch return false;
    return writeSmall("sessions", key, account);
}
pub fn getSession(id: u64, out: []u8) ?[]const u8 {
    var kb: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{x}", .{id}) catch return null;
    return readSmall("sessions", key, out);
}

/// Game record file: body is "<gameid> <a.b.c.d>". Returns true on success.
pub fn putGame(name: []const u8, gameid: u32, gs_ip: [4]u8) bool {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return false;
    var vb: [64]u8 = undefined;
    const val = std.fmt.bufPrint(&vb, "{d} {d}.{d}.{d}.{d}", .{ gameid, gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3] }) catch return false;
    return writeSmall("games", safe, val);
}
pub const GameRec = struct { gameid: u32, gs_ip: [4]u8 };
pub fn getGame(name: []const u8) ?GameRec {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return null;
    var vb: [64]u8 = undefined;
    const val = readSmall("games", safe, &vb) orelse return null;
    var it = std.mem.splitScalar(u8, val, ' ');
    const idtxt = it.next() orelse return null;
    const iptxt = it.next() orelse return null;
    const gameid = std.fmt.parseInt(u32, idtxt, 10) catch return null;
    var ip: [4]u8 = undefined;
    var ipit = std.mem.splitScalar(u8, iptxt, '.');
    var i: usize = 0;
    while (ipit.next()) |o| : (i += 1) {
        if (i >= 4) return null;
        ip[i] = std.fmt.parseInt(u8, o, 10) catch return null;
    }
    if (i != 4) return null;
    return .{ .gameid = gameid, .gs_ip = ip };
}
pub fn delGame(name: []const u8) void {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return;
    deleteSmall("games", safe);
}

/// Read a BNFTP-served file (version-check MPQ etc.) from <data_dir>/bnftp/.
/// Allows '.' and '-' in the name (real filenames) but rejects path escapes.
pub fn getBnftp(filename: []const u8, out: []u8) ?[]const u8 {
    if (filename.len == 0 or filename.len >= 128) return null;
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return null;
    if (std.mem.indexOfScalar(u8, filename, '\\') != null) return null;
    if (std.mem.indexOf(u8, filename, "..") != null) return null;
    fs_lock.lock();
    defer fs_lock.unlock();
    var pbuf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/bnftp/{s}", .{ data_dir, filename }) catch return null;
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, out, 0) catch return null;
    return out[0..n];
}

/// Fill `names` with the account's characters (".d2s" stripped). Returns count.
pub fn listChars(account: []const u8, names: []Name) usize {
    fs_lock.lock();
    defer fs_lock.unlock();

    var dbuf: [512]u8 = undefined;
    const dir = dirPath(&dbuf, account) orelse return 0;
    var d = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(io);

    var it = d.iterate();
    var count: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (count >= names.len) break;
        if (entry.kind != .file) continue;
        const is_d2s = std.mem.endsWith(u8, entry.name, ".d2s");
        const stem = if (is_d2s) entry.name[0 .. entry.name.len - 4] else entry.name;
        if (stem.len == 0 or stem.len > names[count].buf.len) continue;
        @memcpy(names[count].buf[0..stem.len], stem);
        names[count].len = @intCast(stem.len);
        count += 1;
    }
    return count;
}
