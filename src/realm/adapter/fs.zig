//! Filesystem persistence backend. The zero-dependency default: one file per record
//! under a (possibly shared, RWX) data dir. Hardened over the naive version:
//!
//!   * atomic writes — write `<path>.tmp.<n>` then rename, so a reader never sees a
//!     half-written save and a crash mid-write can't corrupt an existing record.
//!   * TTL — sessions/games carry an `exp <unix>` first line; reads treat an expired
//!     record as missing and a sweeper thread reclaims the files.
//!   * reverse indexes — games are also indexed by engine gameid and by hosting GS id,
//!     so removeGameById / expireGamesByGs work without scanning every game.
//!
//! 0.16's filesystem goes through std.Io; we hold a process-global Io (set by init)
//! and serialise fs ops behind one spinlock — these are infrequent and it keeps the
//! shared Io single-op-at-a-time, which is simplest and safe.
const std = @import("std");
const Spinlock = @import("realm_infra").lock.Spinlock;
const types = @import("realm_infra").types;

const Dir = std.Io.Dir;
const Name = types.Name;
const GameRec = types.GameRec;
const Route = types.Route;
const TokenRoute = types.TokenRoute;

extern "c" fn time(t: ?*c_long) c_long;

var data_dir: []const u8 = "realmd-data";
var io: std.Io = undefined;
var fs_lock: Spinlock = .{};
var write_ctr = std.atomic.Value(u32).init(0);

pub fn init(io_: std.Io, dir: []const u8) void {
    io = io_;
    data_dir = dir;
}

// ── name sanitising + path building ──────────────────────────────────────────

fn sanitize(name: []const u8, out: []u8) ?[]const u8 {
    if (name.len == 0 or name.len >= out.len) return null;
    for (name, 0..) |c, i| {
        const okc = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!okc) return null;
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

// ── atomic primitives ────────────────────────────────────────────────────────

/// Write `data` to `path` atomically: a unique temp sibling then rename over it.
/// Caller holds fs_lock. `path` must be under an already-created directory.
fn atomicWrite(path: []const u8, data: []const u8) bool {
    var tb: [600]u8 = undefined;
    const n = write_ctr.fetchAdd(1, .monotonic);
    const tmp = std.fmt.bufPrint(&tb, "{s}.tmp.{d}", .{ path, n }) catch return false;
    Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data }) catch return false;
    Dir.cwd().rename(tmp, Dir.cwd(), path, io) catch {
        Dir.cwd().deleteFile(io, tmp) catch {};
        return false;
    };
    return true;
}

fn ensureDir(sub: []const u8) bool {
    var dbuf: [320]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ data_dir, sub }) catch return false;
    Dir.cwd().createDirPath(io, dir) catch return false;
    return true;
}

fn writeSmall(subdir: []const u8, key: []const u8, bytes: []const u8) bool {
    if (!ensureDir(subdir)) return false;
    var pbuf: [400]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ data_dir, subdir, key }) catch return false;
    return atomicWrite(path, bytes);
}

fn readSmall(subdir: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var pbuf: [400]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ data_dir, subdir, key }) catch return null;
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, out, 0) catch return null;
    return out[0..n];
}

fn deleteSmall(subdir: []const u8, key: []const u8) void {
    var pbuf: [400]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ data_dir, subdir, key }) catch return;
    Dir.cwd().deleteFile(io, path) catch {};
}

/// Records with a TTL are stored as "exp <unix>\n<payload>". Returns the payload if
/// unexpired (and copies it down to out[0..]), else null. `raw` is the file content.
fn unexpiredPayload(raw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, raw, "exp ")) return raw; // no TTL header → never expires
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    const exp = std.fmt.parseInt(i64, raw[4..nl], 10) catch return null;
    if (exp != 0 and time(null) >= exp) return null;
    return raw[nl + 1 ..];
}

fn ttlHeader(buf: []u8, ttl_s: u32) usize {
    if (ttl_s == 0) return 0;
    const exp = time(null) + @as(i64, ttl_s);
    const s = std.fmt.bufPrint(buf, "exp {d}\n", .{exp}) catch return 0;
    return s.len;
}

// ── characters (durable) ─────────────────────────────────────────────────────

pub fn saveCharD2s(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    fs_lock.lock();
    defer fs_lock.unlock();
    var dbuf: [512]u8 = undefined;
    const dir = dirPath(&dbuf, account) orelse return false;
    Dir.cwd().createDirPath(io, dir) catch return false;
    var pbuf: [512]u8 = undefined;
    const path = charPath(&pbuf, account, charname) orelse return false;
    return atomicWrite(path, bytes);
}

pub fn getCharD2s(account: []const u8, charname: []const u8, out: []u8) usize {
    fs_lock.lock();
    defer fs_lock.unlock();
    var pbuf: [512]u8 = undefined;
    const path = charPath(&pbuf, account, charname) orelse return 0;
    const f = Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    return f.readPositionalAll(io, out, 0) catch 0;
}

/// Delete a character's .d2s. True if the file existed and is now gone (idempotent:
/// a missing file is also reported as success so a double-delete doesn't error).
pub fn deleteCharD2s(account: []const u8, charname: []const u8) bool {
    fs_lock.lock();
    defer fs_lock.unlock();
    var pbuf: [512]u8 = undefined;
    const path = charPath(&pbuf, account, charname) orelse return false;
    Dir.cwd().deleteFile(io, path) catch |e| return e == error.FileNotFound;
    return true;
}

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
        if (!std.mem.endsWith(u8, entry.name, ".d2s")) continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        if (stem.len == 0 or stem.len > names[count].buf.len) continue;
        @memcpy(names[count].buf[0..stem.len], stem);
        names[count].len = @intCast(stem.len);
        count += 1;
    }
    return count;
}

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

// ── accounts (durable) ───────────────────────────────────────────────────────
// One file per account at accounts/<name>: 21 bytes = has_password(1) ++ pwhash(20).

pub fn createAccount(name: []const u8, pwhash: ?[20]u8) bool {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return false;
    fs_lock.lock();
    defer fs_lock.unlock();
    // Reject if the account already exists.
    var eb: [32]u8 = undefined;
    if (readSmall("accounts", safe, &eb) != null) return false;
    var rec: [21]u8 = [_]u8{0} ** 21;
    if (pwhash) |h| {
        rec[0] = 1;
        @memcpy(rec[1..21], &h);
    }
    return writeSmall("accounts", safe, &rec);
}

pub fn accountExists(name: []const u8) bool {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return false;
    fs_lock.lock();
    defer fs_lock.unlock();
    var rb: [32]u8 = undefined;
    return readSmall("accounts", safe, &rb) != null;
}

/// Returns whether the account has a password (filling `out` when true), or null
/// if no such account exists.
pub fn accountPwHash(name: []const u8, out: *[20]u8) ?bool {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return null;
    fs_lock.lock();
    defer fs_lock.unlock();
    var rb: [32]u8 = undefined;
    const raw = readSmall("accounts", safe, &rb) orelse return null;
    if (raw.len < 21 or raw[0] == 0) return false;
    @memcpy(out, raw[1..21]);
    return true;
}

/// List account names (one file per account under accounts/). Fills `names`,
/// returns the count (capped at names.len).
pub fn listAccounts(names: [][32]u8) usize {
    fs_lock.lock();
    defer fs_lock.unlock();
    var dbuf: [320]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/accounts", .{data_dir}) catch return 0;
    var d = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var it = d.iterate();
    var count: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (count >= names.len) break;
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.name, ".tmp.") != null) continue; // skip atomic temps
        if (entry.name.len == 0 or entry.name.len > 32) continue;
        @memset(&names[count], 0);
        @memcpy(names[count][0..entry.name.len], entry.name);
        count += 1;
    }
    return count;
}

// ── sessions (ephemeral, TTL) ────────────────────────────────────────────────

pub fn saveSession(id: u64, account: []const u8, ttl_s: u32) bool {
    var kb: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{x}", .{id}) catch return false;
    var vb: [128]u8 = undefined;
    const hlen = ttlHeader(&vb, ttl_s);
    if (hlen + account.len > vb.len) return false;
    @memcpy(vb[hlen..][0..account.len], account);
    fs_lock.lock();
    defer fs_lock.unlock();
    return writeSmall("sessions", key, vb[0 .. hlen + account.len]);
}

pub fn accountForSession(id: u64, out: []u8) ?[]const u8 {
    var kb: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{x}", .{id}) catch return null;
    fs_lock.lock();
    defer fs_lock.unlock();
    var rb: [128]u8 = undefined;
    const raw = readSmall("sessions", key, &rb) orelse return null;
    const payload = unexpiredPayload(raw) orelse {
        deleteSmall("sessions", key);
        return null;
    };
    const n = @min(payload.len, out.len);
    @memcpy(out[0..n], payload[0..n]);
    return out[0..n];
}

pub fn expireSession(id: u64) void {
    var kb: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{x}", .{id}) catch return;
    fs_lock.lock();
    defer fs_lock.unlock();
    deleteSmall("sessions", key);
}

// ── games (ephemeral, TTL, reverse indexed by id and by gs) ──────────────────

pub fn registerGame(name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32, password: []const u8, ttl_s: u32) bool {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return false;
    var vb: [160]u8 = undefined;
    const hlen = ttlHeader(&vb, ttl_s);
    // Trailing " <password>" (empty password -> trailing space -> empty 5th token).
    const body = std.fmt.bufPrint(vb[hlen..], "{d} {d}.{d}.{d}.{d} {d} {d} {s}", .{ gameid, gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3], gs_port, gsid, password }) catch return false;
    fs_lock.lock();
    defer fs_lock.unlock();
    if (!writeSmall("games", safe, vb[0 .. hlen + body.len])) return false;
    // reverse indexes: gameid -> name, and per-gs marker -> name
    var idkey: [16]u8 = undefined;
    const ik = std.fmt.bufPrint(&idkey, "{x}", .{gameid}) catch return true;
    _ = writeSmall("games-byid", ik, safe);
    var gsdir: [32]u8 = undefined;
    const gd = std.fmt.bufPrint(&gsdir, "games-bygs/{x}", .{gsid}) catch return true;
    _ = writeSmall(gd, safe, safe);
    return true;
}

pub fn findGame(name: []const u8) ?GameRec {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return null;
    fs_lock.lock();
    defer fs_lock.unlock();
    var vb: [128]u8 = undefined;
    const raw = readSmall("games", safe, &vb) orelse return null;
    const val = unexpiredPayload(raw) orelse {
        deleteSmall("games", safe);
        return null;
    };
    return parseGame(val);
}

fn parseGame(val: []const u8) ?GameRec {
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
    const gs_port: u16 = if (it.next()) |t| (std.fmt.parseInt(u16, t, 10) catch 4000) else 4000;
    const gsid: u32 = if (it.next()) |t| (std.fmt.parseInt(u32, t, 10) catch 0) else 0;
    var rec = GameRec{ .gameid = gameid, .gs_ip = ip, .gs_port = gs_port, .gsid = gsid };
    if (it.next()) |p| rec.setPw(p); // 5th token = join password (may be empty)
    return rec;
}

/// Enumerate live games from the games dir for shared-mode /admin/games. Skips records
/// whose TTL has lapsed (a sweeper reclaims the files separately).
pub fn snapshotGames(out: []types.NamedGame) usize {
    fs_lock.lock();
    defer fs_lock.unlock();
    var dpath: [320]u8 = undefined;
    const dir = std.fmt.bufPrint(&dpath, "{s}/games", .{data_dir}) catch return 0;
    var d = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (n >= out.len) break;
        if (entry.kind != .file) continue;
        var vb: [128]u8 = undefined;
        const raw = readSmall("games", entry.name, &vb) orelse continue;
        const val = unexpiredPayload(raw) orelse continue; // expired → skip
        const rec = parseGame(val) orelse continue;
        var ng = types.NamedGame{ .gameid = rec.gameid, .gs_ip = rec.gs_ip, .gs_port = rec.gs_port, .gsid = rec.gsid };
        const ln: u8 = @intCast(@min(entry.name.len, ng.name.len));
        @memcpy(ng.name[0..ln], entry.name[0..ln]);
        ng.name_len = ln;
        out[n] = ng;
        n += 1;
    }
    return n;
}

pub fn removeGameById(gameid: u32) void {
    var idkey: [16]u8 = undefined;
    const ik = std.fmt.bufPrint(&idkey, "{x}", .{gameid}) catch return;
    fs_lock.lock();
    defer fs_lock.unlock();
    var nb: [64]u8 = undefined;
    const name = readSmall("games-byid", ik, &nb) orelse return;
    var namecopy: [64]u8 = undefined;
    @memcpy(namecopy[0..name.len], name);
    const nm = namecopy[0..name.len];
    deleteSmall("games", nm);
    deleteSmall("games-byid", ik);
}

/// Expire every game hosted by a GS that disconnected, via its games-bygs index.
pub fn expireGamesByGs(gsid: u32) void {
    fs_lock.lock();
    defer fs_lock.unlock();
    var gsdir: [64]u8 = undefined;
    const sub = std.fmt.bufPrint(&gsdir, "games-bygs/{x}", .{gsid}) catch return;
    var dpath: [320]u8 = undefined;
    const dir = std.fmt.bufPrint(&dpath, "{s}/{s}", .{ data_dir, sub }) catch return;
    var d = Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    var it = d.iterate();
    var pending: [64][48]u8 = undefined;
    var plen: [64]u8 = undefined;
    var count: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (count >= pending.len) break;
        if (entry.kind != .file) continue;
        const ln: u8 = @intCast(@min(entry.name.len, 48));
        @memcpy(pending[count][0..ln], entry.name[0..ln]);
        plen[count] = ln;
        count += 1;
    }
    d.close(io);
    // Delete each game record + its by-id index + the per-gs marker.
    for (0..count) |i| {
        const gname = pending[i][0..plen[i]];
        var vb: [128]u8 = undefined;
        if (readSmall("games", gname, &vb)) |raw| {
            const val = if (std.mem.startsWith(u8, raw, "exp "))
                raw[(std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len - 1) + 1 ..]
            else
                raw;
            if (parseGame(val)) |rec| {
                var idkey: [16]u8 = undefined;
                const ik = std.fmt.bufPrint(&idkey, "{x}", .{rec.gameid}) catch unreachable;
                deleteSmall("games-byid", ik);
            }
        }
        deleteSmall("games", gname);
        deleteSmall(sub, gname);
    }
    Dir.cwd().deleteDir(io, dir) catch {};
}

// ── routes (ephemeral, TTL) ──────────────────────────────────────────────────
// Keyed by the client's source IP (hex octets) → "a.b.c.d port". The qqserver
// looks this up by the connecting socket's peer IP to pick the backend GS.

fn routeKey(buf: []u8, client_ip: [4]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ client_ip[0], client_ip[1], client_ip[2], client_ip[3] }) catch unreachable;
}

pub fn recordRoute(client_ip: [4]u8, gs_ip: [4]u8, gs_port: u16, ttl_s: u32) bool {
    var kb: [16]u8 = undefined;
    const key = routeKey(&kb, client_ip);
    var vb: [128]u8 = undefined;
    const hlen = ttlHeader(&vb, ttl_s);
    const body = std.fmt.bufPrint(vb[hlen..], "{d}.{d}.{d}.{d} {d}", .{ gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3], gs_port }) catch return false;
    fs_lock.lock();
    defer fs_lock.unlock();
    return writeSmall("routes", key, vb[0 .. hlen + body.len]);
}

pub fn lookupRoute(client_ip: [4]u8) ?Route {
    var kb: [16]u8 = undefined;
    const key = routeKey(&kb, client_ip);
    fs_lock.lock();
    defer fs_lock.unlock();
    var vb: [128]u8 = undefined;
    const raw = readSmall("routes", key, &vb) orelse return null;
    const val = unexpiredPayload(raw) orelse {
        deleteSmall("routes", key);
        return null;
    };
    var it = std.mem.splitScalar(u8, val, ' ');
    const iptxt = it.next() orelse return null;
    var ip: [4]u8 = undefined;
    var ipit = std.mem.splitScalar(u8, iptxt, '.');
    var i: usize = 0;
    while (ipit.next()) |o| : (i += 1) {
        if (i >= 4) return null;
        ip[i] = std.fmt.parseInt(u8, o, 10) catch return null;
    }
    if (i != 4) return null;
    const gs_port: u16 = if (it.next()) |t| (std.fmt.parseInt(u16, t, 10) catch 4000) else 4000;
    return .{ .gs_ip = ip, .gs_port = gs_port };
}

// ── token routes (ephemeral, TTL) ────────────────────────────────────────────
// Keyed by the realm-global token (hex) → "a.b.c.d port gameid". The qqserver reads
// the token from the client's first GAMELOGON packet, looks this up, and splices to
// the GS — rewriting the in-packet token to `gameid` first. NAT-proof: globally unique
// tokens never collide for two clients sharing a public IP.

fn tokenRouteKey(buf: []u8, token: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>4}", .{token}) catch unreachable;
}

pub fn recordTokenRoute(token: u16, gs_ip: [4]u8, gs_port: u16, real_gameid: u32, ttl_s: u32) bool {
    var kb: [16]u8 = undefined;
    const key = tokenRouteKey(&kb, token);
    var vb: [128]u8 = undefined;
    const hlen = ttlHeader(&vb, ttl_s);
    const body = std.fmt.bufPrint(vb[hlen..], "{d}.{d}.{d}.{d} {d} {d}", .{ gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3], gs_port, real_gameid }) catch return false;
    fs_lock.lock();
    defer fs_lock.unlock();
    return writeSmall("troutes", key, vb[0 .. hlen + body.len]);
}

pub fn lookupTokenRoute(token: u16) ?TokenRoute {
    var kb: [16]u8 = undefined;
    const key = tokenRouteKey(&kb, token);
    fs_lock.lock();
    defer fs_lock.unlock();
    var vb: [128]u8 = undefined;
    const raw = readSmall("troutes", key, &vb) orelse return null;
    const val = unexpiredPayload(raw) orelse {
        deleteSmall("troutes", key);
        return null;
    };
    var it = std.mem.splitScalar(u8, val, ' ');
    const iptxt = it.next() orelse return null;
    var ip: [4]u8 = undefined;
    var ipit = std.mem.splitScalar(u8, iptxt, '.');
    var i: usize = 0;
    while (ipit.next()) |o| : (i += 1) {
        if (i >= 4) return null;
        ip[i] = std.fmt.parseInt(u8, o, 10) catch return null;
    }
    if (i != 4) return null;
    const gs_port: u16 = if (it.next()) |t| (std.fmt.parseInt(u16, t, 10) catch 4000) else 4000;
    const gameid: u32 = if (it.next()) |t| (std.fmt.parseInt(u32, t, 10) catch return null) else return null;
    return .{ .gs_ip = ip, .gs_port = gs_port, .gameid = gameid };
}

// ── housekeeping ─────────────────────────────────────────────────────────────

pub fn healthy() bool {
    fs_lock.lock();
    defer fs_lock.unlock();
    var d = Dir.cwd().openDir(io, data_dir, .{}) catch {
        Dir.cwd().createDirPath(io, data_dir) catch return false;
        return true;
    };
    d.close(io);
    return true;
}
