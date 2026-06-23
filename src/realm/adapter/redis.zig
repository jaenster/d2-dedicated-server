//! Redis persistence backend. Speaks RESP straight over a raw TCP socket — no
//! hiredis, no C client, nothing beyond the libc-backed net helpers in net.zig.
//! RESP is dead simple to drive by hand: a command is an array of bulk strings
//! (`*<n>\r\n` then `$<len>\r\n<bytes>\r\n` per arg) and replies are one of a
//! handful of typed lines (`+`, `-`, `:`, `$`, `*`). We encode commands with a
//! tiny `command()` and decode with a reader that is careful to treat bulk
//! strings as BINARY-SAFE: d2s saves contain NULs and stray \n, so we read
//! exactly <len> bytes rather than scanning for a newline.
//!
//! Concurrency: realmd opens a connection thread per peer, but Redis ops here
//! are infrequent (game/session create + join). So we keep a single persistent
//! connection, lazily connected on first use and torn down + reconnected on any
//! IO error, guarded by one spinlock that serialises whole command/reply cycles.
//!
//! DDD role: this is one concrete backend, not an adapter layer. The facade
//! (store.zig) picks exactly one of {fs, redis, pg} and calls it directly; each
//! backend exposes the identical public surface (see persist_fs.zig) so the
//! facade can switch among them with zero glue. Keys live under a "realmd:"
//! prefix; the schema mirrors the fs backend's records (chars durable; sessions
//! and games ephemeral with PX TTL and reverse indexes by gameid and by gs).
const std = @import("std");
const net = @import("realm_infra").net;
const Spinlock = @import("realm_infra").lock.Spinlock;
const types = @import("realm_infra").types;
const fs = @import("fs.zig");

const Name = types.Name;
const GameRec = types.GameRec;
const Route = types.Route;
const TokenRoute = types.TokenRoute;

const prefix = "realmd:";

// Accounts are durable, low-volume and simple — route them to the always-present
// filesystem backend rather than carry a parallel RESP schema.
pub fn createAccount(name: []const u8, pwhash: ?[20]u8) bool {
    return fs.createAccount(name, pwhash);
}
pub fn accountExists(name: []const u8) bool {
    return fs.accountExists(name);
}
pub fn accountPwHash(name: []const u8, out: *[20]u8) ?bool {
    return fs.accountPwHash(name, out);
}

// ── connection state ─────────────────────────────────────────────────────────

var host_buf: [256]u8 = undefined;
var host_z: [:0]const u8 = "127.0.0.1"; // sentinel-terminated host for net.connectTcp
var port: u16 = 6379;

var conn: ?net.Socket = null;
var conn_lock: Spinlock = .{};

/// `addr` is "host:port" (DNS name ok), e.g. "realmd-redis:6379"; port defaults
/// to 6379 when absent. We copy the host into a process-global NUL-terminated
/// buffer so connectTcp (which needs a [:0]const u8) can reuse it on reconnect.
pub fn init(addr: []const u8) void {
    var host = addr;
    if (std.mem.lastIndexOfScalar(u8, addr, ':')) |i| {
        host = addr[0..i];
        port = std.fmt.parseInt(u16, addr[i + 1 ..], 10) catch 6379;
    }
    if (host.len == 0 or host.len >= host_buf.len) host = "127.0.0.1";
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    host_z = host_buf[0..host.len :0];
}

/// Ensure we have a live connection, opening one if needed. Caller holds conn_lock.
fn ensureConn() ?net.Socket {
    if (conn) |fd| return fd;
    const fd = net.connectTcp(host_z, port) catch return null;
    conn = fd;
    return fd;
}

/// Drop the connection after an IO error so the next op reconnects. Caller holds lock.
fn dropConn() void {
    if (conn) |fd| net.closeSocket(fd);
    conn = null;
}

// ── RESP encode + reply read ─────────────────────────────────────────────────

/// Per-command read buffer + cursor. Bulk-string reads append straight into
/// `buf`; `pos`/`fill` track the consumed/available window of socket bytes.
const Reader = struct {
    fd: net.Socket,
    buf: [9216]u8 = undefined, // ≥8KB for char bytes plus RESP framing slack
    pos: usize = 0,
    fill: usize = 0,

    /// Pull at least one more byte from the socket into the buffer. False on EOF/error.
    fn fillMore(r: *Reader) bool {
        if (r.fill == r.buf.len) return false; // line/value longer than our buffer
        const n = net.readSome(r.fd, r.buf[r.fill..]);
        if (n == 0) return false;
        r.fill += n;
        return true;
    }

    /// Read one CRLF-terminated line, returning it WITHOUT the trailing \r\n.
    /// Lines here are always short (type bytes, lengths, simple strings).
    fn line(r: *Reader) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, r.buf[0..r.fill], r.pos, '\n')) |nl| {
                const end = if (nl > r.pos and r.buf[nl - 1] == '\r') nl - 1 else nl;
                const out = r.buf[r.pos..end];
                r.pos = nl + 1;
                return out;
            }
            if (!r.fillMore()) return null;
        }
    }

    /// Read exactly `n` payload bytes followed by the bulk-string CRLF. Binary-safe:
    /// we never stop on a newline inside the payload. Returns a slice into `buf`.
    fn bytes(r: *Reader, n: usize) ?[]const u8 {
        const need = n + 2; // payload + trailing \r\n
        while (r.fill - r.pos < need) {
            if (!r.fillMore()) return null;
        }
        const out = r.buf[r.pos .. r.pos + n];
        r.pos += need;
        return out;
    }
};

const Reply = union(enum) {
    status: []const u8, // +OK style (slice into reader buf)
    int: i64,
    bulk: ?[]const u8, // $-1 → null
    array_len: i64, // header only; caller reads elements
    err,
};

/// Read and classify one RESP reply line. Bulk/array payloads stay in `r.buf`.
fn readReply(r: *Reader) ?Reply {
    const ln = r.line() orelse return null;
    if (ln.len == 0) return null;
    return switch (ln[0]) {
        '+' => .{ .status = ln[1..] },
        '-' => .err,
        ':' => .{ .int = std.fmt.parseInt(i64, ln[1..], 10) catch return null },
        '$' => blk: {
            const len = std.fmt.parseInt(i64, ln[1..], 10) catch return null;
            if (len < 0) break :blk Reply{ .bulk = null };
            const b = r.bytes(@intCast(len)) orelse return null;
            break :blk Reply{ .bulk = b };
        },
        '*' => .{ .array_len = std.fmt.parseInt(i64, ln[1..], 10) catch return null },
        else => null,
    };
}

/// Encode `args` as a RESP array of bulk strings and write it to the socket.
/// Caller holds conn_lock and passes a live fd. False on write error.
fn sendCommand(fd: net.Socket, args: []const []const u8) bool {
    var hdr: [16]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "*{d}\r\n", .{args.len}) catch return false;
    if (!net.writeAll(fd, h)) return false;
    for (args) |a| {
        var lb: [16]u8 = undefined;
        const l = std.fmt.bufPrint(&lb, "${d}\r\n", .{a.len}) catch return false;
        if (!net.writeAll(fd, l)) return false;
        if (!net.writeAll(fd, a)) return false;
        if (!net.writeAll(fd, "\r\n")) return false;
    }
    return true;
}

/// Run `args` and return the (lazy) reader positioned right after the reply
/// header, with the parsed Reply. On any IO error the connection is dropped and
/// null returned; caller re-locks and may retry on the fresh connection if it
/// wants, but our ops simply treat a null as failure. Caller holds conn_lock.
fn command(r: *Reader, args: []const []const u8) ?Reply {
    const fd = ensureConn() orelse return null;
    r.* = .{ .fd = fd };
    if (!sendCommand(fd, args)) {
        dropConn();
        return null;
    }
    const rep = readReply(r) orelse {
        dropConn();
        return null;
    };
    return rep;
}

// ── name sanitising (matches persist_fs.sanitize) ────────────────────────────

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

// ── characters (durable) ─────────────────────────────────────────────────────

pub fn saveCharD2s(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "char:{s}:{s}", .{ a, c }) catch return false;
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, prefix ++ "chars:{s}", .{a}) catch return false;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    // SET the raw d2s bytes.
    switch (command(&r, &.{ "SET", key, bytes }) orelse return false) {
        .status, .bulk, .int => {},
        .array_len, .err => return false,
    }
    // SADD the charname into the account's char set so listChars can SMEMBERS.
    _ = command(&r, &.{ "SADD", setkey, c });
    return true;
}

pub fn getCharD2s(account: []const u8, charname: []const u8, out: []u8) usize {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const c = sanitize(charname, &cb) orelse return 0;
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "char:{s}:{s}", .{ a, c }) catch return 0;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "GET", key }) orelse return 0;
    const bulk = switch (rep) {
        .bulk => |b| b orelse return 0,
        else => return 0,
    };
    const n = @min(bulk.len, out.len);
    @memcpy(out[0..n], bulk[0..n]);
    return n;
}

pub fn deleteCharD2s(account: []const u8, charname: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "char:{s}:{s}", .{ a, c }) catch return false;
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, prefix ++ "chars:{s}", .{a}) catch return false;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    // Drop the save blob and remove the name from the account's char set. Mirror of
    // saveCharD2s (SET + SADD); idempotent — a missing key is fine.
    _ = command(&r, &.{ "DEL", key });
    _ = command(&r, &.{ "SREM", setkey, c });
    return true;
}

pub fn listChars(account: []const u8, names: []Name) usize {
    var ab: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, prefix ++ "chars:{s}", .{a}) catch return 0;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "SMEMBERS", setkey }) orelse return 0;
    const count = switch (rep) {
        .array_len => |n| if (n <= 0) return 0 else @as(usize, @intCast(n)),
        else => return 0,
    };
    var filled: usize = 0;
    for (0..count) |_| {
        const er = readReply(&r) orelse break;
        const member = switch (er) {
            .bulk => |b| b orelse continue,
            else => break,
        };
        if (filled >= names.len) continue; // still drain the rest of the reply
        if (member.len == 0 or member.len > names[filled].buf.len) continue;
        @memcpy(names[filled].buf[0..member.len], member);
        names[filled].len = @intCast(member.len);
        filled += 1;
    }
    return filled;
}

// ── sessions (ephemeral, PX TTL) ─────────────────────────────────────────────

pub fn saveSession(id: u64, account: []const u8, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return false;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(&r, &.{ "SET", key, account, "PX", px });
    } else command(&r, &.{ "SET", key, account });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn accountForSession(id: u64, out: []u8) ?[]const u8 {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return null;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "GET", key }) orelse return null;
    const bulk = switch (rep) {
        .bulk => |b| b orelse return null, // nil → missing or expired
        else => return null,
    };
    const n = @min(bulk.len, out.len);
    @memcpy(out[0..n], bulk[0..n]);
    return out[0..n];
}

pub fn expireSession(id: u64) void {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    _ = command(&r, &.{ "DEL", key });
}

// ── games (ephemeral, PX TTL, reverse indexed by id and by gs) ───────────────

pub fn registerGame(name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32, password: []const u8, ttl_s: u32) bool {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return false;

    var gk: [128]u8 = undefined;
    const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{safe}) catch return false;
    var vb: [96]u8 = undefined;
    // Trailing " <password>" (empty -> trailing space -> empty 5th token in parseGame).
    const body = std.fmt.bufPrint(&vb, "{d} {d}.{d}.{d}.{d} {d} {d} {s}", .{ gameid, gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3], gs_port, gsid, password }) catch return false;
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{gameid}) catch return false;
    var gb: [64]u8 = undefined;
    const gskey = std.fmt.bufPrint(&gb, prefix ++ "game:bygs:{x}", .{gsid}) catch return false;

    var pb: [16]u8 = undefined;
    const has_ttl = ttl_s > 0;
    const px = if (has_ttl) (std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false) else "";

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    // game:<name> = body (with PX ttl)
    const set_game = if (has_ttl)
        command(&r, &.{ "SET", gamekey, body, "PX", px })
    else
        command(&r, &.{ "SET", gamekey, body });
    switch (set_game orelse return false) {
        .status, .bulk, .int => {},
        .array_len, .err => return false,
    }
    // reverse index by id: game:byid:<gameid> = name (same PX ttl)
    if (has_ttl)
        _ = command(&r, &.{ "SET", idkey, safe, "PX", px })
    else
        _ = command(&r, &.{ "SET", idkey, safe });
    // reverse index by gs: SADD name into game:bygs:<gsid>
    _ = command(&r, &.{ "SADD", gskey, safe });
    // global index of all game names so /admin/games can enumerate (snapshotGames).
    _ = command(&r, &.{ "SADD", prefix ++ "games", safe });
    return true;
}

/// Enumerate active games for /admin/games: read the global name set, fetch each record.
/// Members whose record has TTL-expired are lazily SREM'd from the index.
pub fn snapshotGames(out: []types.NamedGame) usize {
    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "SMEMBERS", prefix ++ "games" }) orelse return 0;
    const count = switch (rep) {
        .array_len => |nn| if (nn <= 0) return 0 else @as(usize, @intCast(nn)),
        else => return 0,
    };
    // Drain the member names first (can't issue GETs mid-reply), then resolve each.
    var names: [256][48]u8 = undefined;
    var nlen: [256]u8 = undefined;
    var got: usize = 0;
    for (0..count) |_| {
        const er = readReply(&r) orelse break;
        const member = switch (er) {
            .bulk => |b| b orelse continue,
            else => break,
        };
        if (got >= names.len) continue;
        const ln: u8 = @intCast(@min(member.len, 48));
        @memcpy(names[got][0..ln], member[0..ln]);
        nlen[got] = ln;
        got += 1;
    }
    var n: usize = 0;
    for (0..got) |i| {
        if (n >= out.len) break;
        const gname = names[i][0..nlen[i]];
        var gk: [128]u8 = undefined;
        const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{gname}) catch continue;
        const grep = command(&r, &.{ "GET", gamekey }) orelse continue;
        const val = switch (grep) {
            .bulk => |b| b orelse {
                _ = command(&r, &.{ "SREM", prefix ++ "games", gname }); // expired → drop from index
                continue;
            },
            else => continue,
        };
        const rec = parseGame(val) orelse continue;
        var ng = types.NamedGame{ .gameid = rec.gameid, .gs_ip = rec.gs_ip, .gs_port = rec.gs_port, .gsid = rec.gsid };
        const cl: u8 = @intCast(@min(gname.len, ng.name.len));
        @memcpy(ng.name[0..cl], gname[0..cl]);
        ng.name_len = cl;
        out[n] = ng;
        n += 1;
    }
    return n;
}

pub fn findGame(name: []const u8) ?GameRec {
    var nb: [64]u8 = undefined;
    const safe = sanitize(name, &nb) orelse return null;
    var gk: [128]u8 = undefined;
    const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{safe}) catch return null;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "GET", gamekey }) orelse return null;
    const val = switch (rep) {
        .bulk => |b| b orelse return null,
        else => return null,
    };
    return parseGame(val);
}

/// Decode the space-separated game record text (same format persist_fs writes).
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

/// Look up the game name for an engine gameid via the byid index, then delete the
/// game record and that index entry.
pub fn removeGameById(gameid: u32) void {
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{gameid}) catch return;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "GET", idkey }) orelse return;
    const name = switch (rep) {
        .bulk => |b| b orelse return,
        else => return,
    };
    // Copy the name out of the reader buffer before issuing further commands.
    var ncopy: [64]u8 = undefined;
    if (name.len == 0 or name.len > ncopy.len) return;
    @memcpy(ncopy[0..name.len], name);
    var gk: [128]u8 = undefined;
    const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{ncopy[0..name.len]}) catch return;
    _ = command(&r, &.{ "DEL", gamekey });
    _ = command(&r, &.{ "DEL", idkey });
    _ = command(&r, &.{ "SREM", prefix ++ "games", ncopy[0..name.len] });
}

/// Expire every game hosted by a GS that disconnected, via its bygs set.
pub fn expireGamesByGs(gsid: u32) void {
    var gb: [64]u8 = undefined;
    const gskey = std.fmt.bufPrint(&gb, prefix ++ "game:bygs:{x}", .{gsid}) catch return;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "SMEMBERS", gskey }) orelse return;
    const count = switch (rep) {
        .array_len => |n| if (n <= 0) {
            _ = command(&r, &.{ "DEL", gskey });
            return;
        } else @as(usize, @intCast(n)),
        else => return,
    };
    // Drain the set members into a local buffer (can't issue DELs mid-reply).
    var pending: [64][48]u8 = undefined;
    var plen: [64]u8 = undefined;
    var got: usize = 0;
    for (0..count) |_| {
        const er = readReply(&r) orelse break;
        const member = switch (er) {
            .bulk => |b| b orelse continue,
            else => break,
        };
        if (got >= pending.len) continue;
        const ln: u8 = @intCast(@min(member.len, 48));
        @memcpy(pending[got][0..ln], member[0..ln]);
        plen[got] = ln;
        got += 1;
    }
    for (0..got) |i| {
        const gname = pending[i][0..plen[i]];
        var gk: [128]u8 = undefined;
        const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{gname}) catch continue;
        // Look up the game record to recover its gameid so we can also drop the
        // byid reverse-index key. If the record is already gone, skip the byid del.
        const grep = command(&r, &.{ "GET", gamekey }) orelse continue;
        if (switch (grep) {
            .bulk => |b| b,
            else => null,
        }) |val| {
            if (parseGame(val)) |rec| {
                var ik: [64]u8 = undefined;
                const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{rec.gameid}) catch null;
                if (idkey) |k| _ = command(&r, &.{ "DEL", k });
            }
        }
        _ = command(&r, &.{ "DEL", gamekey });
    }
    _ = command(&r, &.{ "DEL", gskey });
}

// ── routes (ephemeral, PX TTL) — keyed by client source IP ───────────────────

fn routeKey(buf: []u8, client_ip: [4]u8) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "route:{d}.{d}.{d}.{d}", .{ client_ip[0], client_ip[1], client_ip[2], client_ip[3] }) catch unreachable;
}

pub fn recordRoute(client_ip: [4]u8, gs_ip: [4]u8, gs_port: u16, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = routeKey(&kb, client_ip);
    var vb: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&vb, "{d}.{d}.{d}.{d} {d}", .{ gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3], gs_port }) catch return false;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(&r, &.{ "SET", key, body, "PX", px });
    } else command(&r, &.{ "SET", key, body });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn lookupRoute(client_ip: [4]u8) ?Route {
    var kb: [64]u8 = undefined;
    const key = routeKey(&kb, client_ip);

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "GET", key }) orelse return null;
    const val = switch (rep) {
        .bulk => |b| b orelse return null,
        else => return null,
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

// ── token routes (ephemeral, PX TTL) — keyed by realm-global token ───────────

fn tokenRouteKey(buf: []u8, token: u16) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "troute:{x}", .{token}) catch unreachable;
}

pub fn recordTokenRoute(token: u16, gs_ip: [4]u8, gs_port: u16, real_gameid: u32, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = tokenRouteKey(&kb, token);
    // Packed binary route: ip[4] ++ port(u16 LE) ++ gameid(u32 LE) = 10 bytes. Redis is
    // binary-safe, so the qqserver reads these 10 bytes directly — no string parsing.
    var vb: [10]u8 = undefined;
    @memcpy(vb[0..4], &gs_ip);
    std.mem.writeInt(u16, vb[4..6], gs_port, .little);
    std.mem.writeInt(u32, vb[6..10], real_gameid, .little);
    const body: []const u8 = &vb;

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(&r, &.{ "SET", key, body, "PX", px });
    } else command(&r, &.{ "SET", key, body });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn lookupTokenRoute(token: u16) ?TokenRoute {
    var kb: [64]u8 = undefined;
    const key = tokenRouteKey(&kb, token);

    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{ "GET", key }) orelse return null;
    const val = switch (rep) {
        .bulk => |b| b orelse return null,
        else => return null,
    };
    if (val.len < 10) return null; // packed: ip[4] ++ port(u16 LE) ++ gameid(u32 LE)
    return .{
        .gs_ip = val[0..4].*,
        .gs_port = std.mem.readInt(u16, val[4..6], .little),
        .gameid = std.mem.readInt(u32, val[6..10], .little),
    };
}

// ── housekeeping ─────────────────────────────────────────────────────────────

pub fn healthy() bool {
    conn_lock.lock();
    defer conn_lock.unlock();
    var r: Reader = undefined;
    const rep = command(&r, &.{"PING"}) orelse return false;
    return switch (rep) {
        .status => |s| std.mem.eql(u8, s, "PONG"),
        else => false,
    };
}
