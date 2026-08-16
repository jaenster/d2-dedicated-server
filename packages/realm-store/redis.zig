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
//! IO error. A small POOL of them, because a connection is held for a whole
//! command/reply cycle: with one, thread-per-connection bought no concurrency
//! at all. A slot is held across a network round trip, so its lock must sleep
//! rather than spin (see infra lock.zig) — and anything that would take N round
//! trips is pipelined into one instead of looping `command`.
//!
//! Lock order: game_index_lock before a pool slot, never the reverse.
//!
//! DDD role: this is one concrete backend, not an adapter layer. The facade
//! (store.zig) picks exactly one of {fs, redis, pg} and calls it directly; each
//! backend exposes the identical public surface (see persist_fs.zig) so the
//! facade can switch among them with zero glue. Keys live under a "realmd:"
//! prefix; the schema mirrors the fs backend's records (chars durable; sessions
//! and games ephemeral with PX TTL and reverse indexes by gameid and by gs).
const std = @import("std");
const net = @import("realm_infra").net;
const Lock = @import("realm_infra").lock.Lock;
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

// A thread-local connection would be simpler, but realmd's threads are per-CLIENT and
// detached: redis would see connection churn proportional to player turnover and our fd count
// would track concurrent players. A fixed pool is bounded on both counts.
//
// Each slot carries its own lock, and holding that lock IS the checkout.
const POOL_N = 8;

const Slot = struct {
    lock: Lock = .{},
    fd: ?net.Socket = null,
};

var slots = [_]Slot{.{}} ** POOL_N;
var rotor = std.atomic.Value(u32).init(0);

/// Check out a connection. Always succeeds; the caller must release it.
fn acquire() *Slot {
    for (&slots) |*s| {
        if (s.lock.tryLock()) return s;
    }
    // All busy: queue on one slot rather than spinning over all of them, rotating the choice
    // so concurrent waiters spread out instead of piling onto slot zero.
    const i = rotor.fetchAdd(1, .monotonic) % POOL_N;
    slots[i].lock.lock();
    return &slots[i];
}

fn release(s: *Slot) void {
    s.lock.unlock();
}

/// Serialises every mutation of the GAME INDEX — the record plus its by-id and by-gs reverse
/// keys. Reads and every other key (sessions, routes, char blobs) stay fully concurrent.
///
/// Not just lost updates: the engine recycles game ids from a 1024-slot ring, and
/// `removeGameById` resolves a name by reading `byid:<id>`. A close interleaved with a create
/// that reused the id resolves the NEW game's name and deletes the record just written.
///
/// Held across IO, so it must be a sleeping lock. Always taken BEFORE a slot, never after, so
/// a waiter for the index can never be sitting on a connection somebody else needs.
///
/// Within-process only: two realmd instances on one redis still race here. The real cure is
/// for CLOSEGAME to carry the game NAME so a recycled id is unambiguous.
var game_index_lock: Lock = .{};

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

/// Ensure this slot has a live connection, opening one if needed. Caller holds the slot.
fn ensureConn(s: *Slot) ?net.Socket {
    if (s.fd) |fd| return fd;
    const fd = net.connectTcp(host_z, port) catch return null;
    s.fd = fd;
    return fd;
}

/// Drop this slot's connection after an IO error so its next op reconnects. Only this slot is
/// affected.
fn dropConn(s: *Slot) void {
    if (s.fd) |fd| net.closeSocket(fd);
    s.fd = null;
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
    ///
    /// Consumed bytes are compacted away first: without it a PIPELINE wedges once its replies
    /// total more than the buffer, even though no single one comes close. The cost is that
    /// slices handed out by `bytes` are only valid until the next read — copy before reading on.
    fn fillMore(r: *Reader) bool {
        if (r.pos > 0) {
            const keep = r.fill - r.pos;
            if (keep > 0) std.mem.copyForwards(u8, r.buf[0..keep], r.buf[r.pos..r.fill]);
            r.pos = 0;
            r.fill = keep;
        }
        if (r.fill == r.buf.len) return false; // a single line/value longer than our buffer
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

/// Accumulates one command — or a whole pipeline of them — and writes in whole-buffer chunks.
/// Encoding straight to the socket cost a write() per RESP token (seven for a two-argument GET).
const CmdBuf = struct {
    fd: net.Socket,
    buf: [8192]u8 = undefined,
    len: usize = 0,
    ok: bool = true,

    fn put(c: *CmdBuf, s: []const u8) void {
        if (!c.ok) return;
        // An argument bigger than the buffer (a d2s save) goes out on its own, so this buffer
        // need not be sized for the largest thing we store.
        if (s.len >= c.buf.len) {
            c.flush();
            if (c.ok and !net.writeAll(c.fd, s)) c.ok = false;
            return;
        }
        if (c.len + s.len > c.buf.len) c.flush();
        if (!c.ok) return;
        @memcpy(c.buf[c.len..][0..s.len], s);
        c.len += s.len;
    }

    fn print(c: *CmdBuf, comptime fmt: []const u8, args: anytype) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch {
            c.ok = false;
            return;
        };
        c.put(s);
    }

    /// Append one command as a RESP array of bulk strings.
    fn add(c: *CmdBuf, args: []const []const u8) void {
        c.print("*{d}\r\n", .{args.len});
        for (args) |a| {
            c.print("${d}\r\n", .{a.len});
            c.put(a);
            c.put("\r\n");
        }
    }

    fn flush(c: *CmdBuf) void {
        if (!c.ok or c.len == 0) return;
        if (!net.writeAll(c.fd, c.buf[0..c.len])) c.ok = false;
        c.len = 0;
    }
};

/// Encode `args` as a RESP array of bulk strings and write it to the socket.
/// Caller holds conn_lock and passes a live fd. False on write error.
fn sendCommand(fd: net.Socket, args: []const []const u8) bool {
    var c = CmdBuf{ .fd = fd };
    c.add(args);
    c.flush();
    return c.ok;
}

/// Run `args` and return the (lazy) reader positioned right after the reply
/// header, with the parsed Reply. On any IO error the connection is dropped and
/// null returned; caller re-locks and may retry on the fresh connection if it
/// wants, but our ops simply treat a null as failure. Caller holds the slot.
fn command(s: *Slot, r: *Reader, args: []const []const u8) ?Reply {
    const fd = ensureConn(s) orelse return null;
    r.* = .{ .fd = fd };
    if (!sendCommand(fd, args)) {
        dropConn(s);
        return null;
    }
    const rep = readReply(r) orelse {
        dropConn(s);
        return null;
    };
    return rep;
}

/// Send several commands as ONE round trip and drain their replies in order. For operations
/// that are a handful of independent writes which all have to land but whose replies carry no
/// value; callers that need a VALUE back still use `command`.
///
/// Every reply is consumed even on error — leaving any on the socket would desync the
/// connection and hand the next caller this call's leftovers. False if any reply was an error
/// or the connection failed.
fn pipeline(s: *Slot, r: *Reader, cmds: []const []const []const u8) bool {
    const fd = ensureConn(s) orelse return false;
    var c = CmdBuf{ .fd = fd };
    for (cmds) |args| c.add(args);
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return false;
    }
    r.* = .{ .fd = fd };
    var ok = true;
    for (cmds) |_| {
        const rep = readReply(r) orelse {
            dropConn(s);
            return false;
        };
        if (rep == .err) ok = false; // keep draining: the rest of the replies are still coming
    }
    return ok;
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

/// A game name reduced to the key it is stored under.
///
/// LOWERCASED, and that is the point. Battle.net treats game names case-insensitively — "Jan" and
/// "jan" are the same game to a player typing one into the join box — but a key that preserves
/// case makes them two rows. The failure that produces is genuinely baffling from the outside:
/// CREATEGAME matches one record and answers "a game already exists with that name", while
/// JOINGAME matches the other and routes to a game that is not the one on screen, so the client
/// says "game name and password don't match" about a game it can see in the list.
fn gameKey(name: []const u8, out: []u8) ?[]const u8 {
    const safe = sanitize(name, out) orelse return null;
    for (out[0..safe.len]) |*c| c.* = std.ascii.toLower(c.*);
    return out[0..safe.len];
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

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    // The save blob and the account's char-set membership in one round trip; listChars reads
    // that set, so neither write is optional.
    return pipeline(s, &r, &.{
        &.{ "SET", key, bytes },
        &.{ "SADD", setkey, c },
    });
}

pub fn getCharD2s(account: []const u8, charname: []const u8, out: []u8) usize {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const c = sanitize(charname, &cb) orelse return 0;
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "char:{s}:{s}", .{ a, c }) catch return 0;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return 0;
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

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    // Drop the save blob and remove the name from the account's char set. Mirror of
    // saveCharD2s (SET + SADD); idempotent — a missing key is fine.
    _ = pipeline(s, &r, &.{
        &.{ "DEL", key },
        &.{ "SREM", setkey, c },
    });
    return true;
}

pub fn listChars(account: []const u8, names: []Name) usize {
    var ab: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, prefix ++ "chars:{s}", .{a}) catch return 0;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SMEMBERS", setkey }) orelse return 0;
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

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(s, &r, &.{ "SET", key, account, "PX", px });
    } else command(s, &r, &.{ "SET", key, account });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn accountForSession(id: u64, out: []u8) ?[]const u8 {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return null;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return null;
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

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = command(s, &r, &.{ "DEL", key });
}

// ── games (ephemeral, PX TTL, reverse indexed by id and by gs) ───────────────

pub fn registerGame(name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32, players: u16, status: u8, difficulty: u8, password: []const u8, description: []const u8, ttl_s: u32) bool {
    var nb: [64]u8 = undefined;
    const safe = gameKey(name, &nb) orelse return false;

    var gk: [128]u8 = undefined;
    const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{safe}) catch return false;
    var vb: [256]u8 = undefined;
    // Fields: gameid ip port gsid players status difficulty <password> <description>. The password is a
    // single token (may be empty); the description absorbs the rest, since it may
    // contain spaces. Same encoding as the fs backend, so parseGame is shared in spirit.
    const body = std.fmt.bufPrint(&vb, "{d} {d}.{d}.{d}.{d} {d} {d} {d} {d} {d} {s} {s}", .{ gameid, gs_ip[0], gs_ip[1], gs_ip[2], gs_ip[3], gs_port, gsid, players, status, difficulty, password, description }) catch return false;
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{gameid}) catch return false;
    var gb: [64]u8 = undefined;
    const gskey = std.fmt.bufPrint(&gb, prefix ++ "game:bygs:{x}", .{gsid}) catch return false;

    var pb: [16]u8 = undefined;
    const has_ttl = ttl_s > 0;
    const px = if (has_ttl) (std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false) else "";

    // Writes the record + both reverse indexes; ordered against close/expire (see game_index_lock).
    game_index_lock.lock();
    defer game_index_lock.unlock();
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    // The record, both reverse indexes (by id, by gs) and the global name set snapshotGames
    // enumerates — four writes that all have to land for a game to be findable, in one trip.
    return if (has_ttl) pipeline(s, &r, &.{
        &.{ "SET", gamekey, body, "PX", px },
        &.{ "SET", idkey, safe, "PX", px },
        &.{ "SADD", gskey, safe },
        &.{ "SADD", prefix ++ "games", safe },
    }) else pipeline(s, &r, &.{
        &.{ "SET", gamekey, body },
        &.{ "SET", idkey, safe },
        &.{ "SADD", gskey, safe },
        &.{ "SADD", prefix ++ "games", safe },
    });
}

/// Enumerate active games for /admin/games: read the global name set, fetch each record.
/// Members whose record has TTL-expired are lazily SREM'd from the index.
pub fn snapshotGames(out: []types.NamedGame) usize {
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SMEMBERS", prefix ++ "games" }) orelse return 0;
    const count = switch (rep) {
        .array_len => |nn| if (nn <= 0) return 0 else @as(usize, @intCast(nn)),
        else => return 0,
    };
    // Drain the member names first (can't issue GETs mid-reply), then resolve each.
    var names: [256][48]u8 = undefined;
    var nlen: [256]u8 = undefined;
    var got: usize = 0;
    for (0..count) |_| {
        // Same rule as expireGamesByGs: never leave part of an array on the socket.
        const er = readReply(&r) orelse {
            dropConn(s);
            return 0;
        };
        const member = switch (er) {
            .bulk => |b| b orelse continue,
            else => {
                dropConn(s);
                return 0;
            },
        };
        if (got >= names.len) continue;
        const ln: u8 = @intCast(@min(member.len, 48));
        @memcpy(names[got][0..ln], member[0..ln]);
        nlen[got] = ln;
        got += 1;
    }
    if (got == 0) return 0;

    // Resolve every member in ONE round trip: a GET per game made opening the join screen cost
    // a redis wait per live game, with the connection held for all of them.
    const fd = s.fd orelse return 0;
    var c = CmdBuf{ .fd = fd };
    for (0..got) |i| {
        var gk: [128]u8 = undefined;
        const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{names[i][0..nlen[i]]}) catch {
            c.ok = false;
            break;
        };
        c.add(&.{ "GET", gamekey });
    }
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return 0;
    }

    // Every reply must be consumed even once `out` is full, or the connection desyncs.
    var expired = [_]bool{false} ** names.len;
    var any_expired = false;
    var synced = true;
    var n: usize = 0;
    for (0..got) |i| {
        const grep = readReply(&r) orelse {
            dropConn(s);
            synced = false;
            break;
        };
        const val = switch (grep) {
            .bulk => |b| b orelse {
                expired[i] = true; // the record TTL'd out; its index entry is stale
                any_expired = true;
                continue;
            },
            else => continue,
        };
        if (n >= out.len) continue;
        const rec = parseGame(val) orelse continue;
        var ng = types.NamedGame{ .gameid = rec.gameid, .gs_ip = rec.gs_ip, .gs_port = rec.gs_port, .gsid = rec.gsid, .players = rec.players, .status = rec.status };
        ng.setDesc(rec.desc());
        const gname = names[i][0..nlen[i]];
        const cl: u8 = @intCast(@min(gname.len, ng.name.len));
        @memcpy(ng.name[0..cl], gname[0..cl]);
        ng.name_len = cl;
        out[n] = ng;
        n += 1;
    }

    // One variadic SREM for every stale member. Skipped on a desynced connection — we no
    // longer know what we read.
    if (any_expired and synced) {
        var args: [names.len + 2][]const u8 = undefined;
        args[0] = "SREM";
        args[1] = prefix ++ "games";
        var na: usize = 2;
        for (0..got) |i| {
            if (!expired[i]) continue;
            args[na] = names[i][0..nlen[i]];
            na += 1;
        }
        var rr: Reader = undefined;
        _ = command(s, &rr, args[0..na]);
    }
    return n;
}

pub fn findGame(name: []const u8) ?GameRec {
    var nb: [64]u8 = undefined;
    const safe = gameKey(name, &nb) orelse return null;
    var gk: [128]u8 = undefined;
    const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{safe}) catch return null;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", gamekey }) orelse return null;
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
    rec.players = if (it.next()) |t| (std.fmt.parseInt(u16, t, 10) catch 0) else 0; // 5th
    rec.status = if (it.next()) |t| (std.fmt.parseInt(u8, t, 10) catch 0) else 0; // 6th
    rec.difficulty = if (it.next()) |t| (std.fmt.parseInt(u8, t, 10) catch 0) else 0; // 7th
    if (it.next()) |p| rec.setPw(p); // 8th token = join password (may be empty)
    rec.setDesc(it.rest()); // remainder = description (may contain spaces)
    return rec;
}

/// Overwrite a game's player count, found via the byid index. Rewrites the record with
/// `SET ... KEEPTTL` so the game keeps the lease it already had — a join or a leave says
/// nothing about how much longer the game should stay listed.
pub fn setGamePlayers(gameid: u32, players: u16) bool {
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{gameid}) catch return false;

    // A read-modify-write over the game index (GET the name, GET the record, SET it back).
    game_index_lock.lock();
    defer game_index_lock.unlock();
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const idrep = command(s, &r, &.{ "GET", idkey }) orelse return false;
    const name = switch (idrep) {
        .bulk => |b| b orelse return false,
        else => return false,
    };
    // Copy out of the reader buffer before issuing the next command overwrites it.
    var ncopy: [64]u8 = undefined;
    if (name.len == 0 or name.len > ncopy.len) return false;
    @memcpy(ncopy[0..name.len], name);
    var gk: [128]u8 = undefined;
    const gamekey = std.fmt.bufPrint(&gk, prefix ++ "game:{s}", .{ncopy[0..name.len]}) catch return false;

    const rep = command(s, &r, &.{ "GET", gamekey }) orelse return false;
    const val = switch (rep) {
        .bulk => |b| b orelse return false,
        else => return false,
    };
    const rec = parseGame(val) orelse return false;
    var vb: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&vb, "{d} {d}.{d}.{d}.{d} {d} {d} {d} {d} {d} {s} {s}", .{
        rec.gameid, rec.gs_ip[0], rec.gs_ip[1],   rec.gs_ip[2], rec.gs_ip[3], rec.gs_port,
        rec.gsid,   players,      rec.status,     rec.difficulty,
        rec.pw(),   rec.desc(),
    }) catch return false;
    return switch (command(s, &r, &.{ "SET", gamekey, body, "KEEPTTL" }) orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

/// Look up the game name for an engine gameid via the byid index, then delete the
/// game record and that index entry.
pub fn removeGameById(gameid: u32) void {
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{gameid}) catch return;

    // Resolves a name through byid, which a concurrent create may have just rebound.
    game_index_lock.lock();
    defer game_index_lock.unlock();
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", idkey }) orelse return;
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
    // Recover the gsid (record fields: "gameid ip port gsid players <pw>") so we can
    // also drop the name from the per-GS reverse index — otherwise dead names pile up
    // in bygs until the GS disconnects. Parse it to a value BEFORE the next command
    // reuses the reader buffer (val aliases it).
    var gsid: ?u32 = null;
    if (command(s, &r, &.{ "GET", gamekey })) |grep| switch (grep) {
        .bulk => |b| if (b) |val| {
            var it = std.mem.splitScalar(u8, val, ' ');
            _ = it.next(); // gameid
            _ = it.next(); // ip
            _ = it.next(); // port
            if (it.next()) |t| gsid = std.fmt.parseInt(u32, t, 10) catch null;
        },
        else => {},
    };
    _ = command(s, &r, &.{ "DEL", gamekey });
    _ = command(s, &r, &.{ "DEL", idkey });
    _ = command(s, &r, &.{ "SREM", prefix ++ "games", ncopy[0..name.len] });
    if (gsid) |gid| {
        var gb: [64]u8 = undefined;
        const gskey = std.fmt.bufPrint(&gb, prefix ++ "game:bygs:{x}", .{gid}) catch return;
        _ = command(s, &r, &.{ "SREM", gskey, ncopy[0..name.len] });
    }
}

/// Expire every game hosted by a GS that disconnected, via its bygs set.
pub fn expireGamesByGs(gsid: u32) void {
    var gb: [64]u8 = undefined;
    const gskey = std.fmt.bufPrint(&gb, prefix ++ "game:bygs:{x}", .{gsid}) catch return;

    // Bulk removal over the same index keys as create and close.
    game_index_lock.lock();
    defer game_index_lock.unlock();
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SMEMBERS", gskey }) orelse return;
    const count = switch (rep) {
        .array_len => |n| if (n <= 0) {
            _ = command(s, &r, &.{ "DEL", gskey });
            return;
        } else @as(usize, @intCast(n)),
        else => return,
    };
    // Drain the set members into a local buffer (can't issue DELs mid-reply).
    var pending: [64][48]u8 = undefined;
    var plen: [64]u8 = undefined;
    var got: usize = 0;
    for (0..count) |_| {
        // Abandoning replies mid-array desyncs a pooled connection: the next `command` resets
        // the Reader, dropping BUFFERED bytes but not the ones still on the socket, so it
        // reads this array's leftovers as its own reply. Dropping the connection costs one
        // reconnect and cannot silently corrupt the next caller.
        const er = readReply(&r) orelse {
            dropConn(s);
            return;
        };
        const member = switch (er) {
            .bulk => |b| b orelse continue,
            else => {
                dropConn(s);
                return;
            },
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
        const grep = command(s, &r, &.{ "GET", gamekey }) orelse continue;
        if (switch (grep) {
            .bulk => |b| b,
            else => null,
        }) |val| {
            if (parseGame(val)) |rec| {
                var ik: [64]u8 = undefined;
                const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}", .{rec.gameid}) catch null;
                if (idkey) |k| _ = command(s, &r, &.{ "DEL", k });
            }
        }
        _ = command(s, &r, &.{ "DEL", gamekey });
    }
    _ = command(s, &r, &.{ "DEL", gskey });
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

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(s, &r, &.{ "SET", key, body, "PX", px });
    } else command(s, &r, &.{ "SET", key, body });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn lookupRoute(client_ip: [4]u8) ?Route {
    var kb: [64]u8 = undefined;
    const key = routeKey(&kb, client_ip);

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return null;
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

/// Next realm-global game token, or null if redis could not answer.
///
/// The token is what a client presents to the gateway, so it has to be unique across the whole
/// realm — a per-process counter hands two realmd instances the same number and the second client
/// is spliced to the first one's game. INCR is atomic across instances, which is the only reason
/// several realmds can mint at once.
///
/// The wire field is 16 bits, so the counter is folded into 1..65535: 0 is skipped because the
/// engine and the game list both read it as "no game". Wrapping is safe in practice — a route
/// lives `route_ttl_s` (60s default), so a collision needs 65535 games inside that window.
pub fn mintToken() ?u16 {
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "INCR", prefix ++ "token:seq" }) orelse return null;
    const n = switch (rep) {
        .int => |v| v,
        else => return null,
    };
    // INCR is signed and unbounded; fold to the 16-bit wire field, avoiding 0.
    return @intCast(@as(u64, @bitCast(n)) % 65535 + 1);
}

pub fn recordTokenRoute(token: u16, gs_ip: [4]u8, gs_port: u16, real_gameid: u32, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = tokenRouteKey(&kb, token);
    // Packed binary route: ip[4] ++ port(u16 LE) ++ gameid(u32 LE) = 10 bytes. Redis is
    // binary-safe, so the d2ingress reads these 10 bytes directly — no string parsing.
    var vb: [10]u8 = undefined;
    @memcpy(vb[0..4], &gs_ip);
    std.mem.writeInt(u16, vb[4..6], gs_port, .little);
    std.mem.writeInt(u32, vb[6..10], real_gameid, .little);
    const body: []const u8 = &vb;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(s, &r, &.{ "SET", key, body, "PX", px });
    } else command(s, &r, &.{ "SET", key, body });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn lookupTokenRoute(token: u16) ?TokenRoute {
    var kb: [64]u8 = undefined;
    const key = tokenRouteKey(&kb, token);

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return null;
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
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{"PING"}) orelse return false;
    return switch (rep) {
        .status => |txt| std.mem.eql(u8, txt, "PONG"),
        else => false,
    };
}

test "a command encodes as one RESP array of bulk strings" {
    var c = CmdBuf{ .fd = undefined }; // small enough that nothing flushes to the socket
    c.add(&.{ "GET", prefix ++ "game:meph" });
    try std.testing.expect(c.ok);
    try std.testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$16\r\nrealmd:game:meph\r\n", c.buf[0..c.len]);
}

test "a pipeline is several commands in one buffer" {
    var c = CmdBuf{ .fd = undefined };
    c.add(&.{ "GET", "a" });
    c.add(&.{ "GET", "b" });
    try std.testing.expectEqualStrings(
        "*2\r\n$3\r\nGET\r\n$1\r\na\r\n" ++ "*2\r\n$3\r\nGET\r\n$1\r\nb\r\n",
        c.buf[0..c.len],
    );
}

test "pipelined replies parse back to back, nulls included" {
    var r = Reader{ .fd = undefined };
    const stream = "$2\r\nhi\r\n" ++ "$-1\r\n" ++ ":7\r\n" ++ "$4\r\na\r\nb\r\n";
    @memcpy(r.buf[0..stream.len], stream);
    r.fill = stream.len;
    try std.testing.expectEqualStrings("hi", readReply(&r).?.bulk.?);
    try std.testing.expect(readReply(&r).?.bulk == null); // an expired game
    try std.testing.expectEqual(@as(i64, 7), readReply(&r).?.int);
    // binary-safe: a CRLF inside the payload is payload, not a frame boundary
    try std.testing.expectEqualStrings("a\r\nb", readReply(&r).?.bulk.?);
}

test "the reader compacts consumed bytes so a long pipeline fits" {
    var r = Reader{ .fd = undefined };
    const one = "$2\r\nhi\r\n";
    @memcpy(r.buf[0..one.len], one);
    r.fill = one.len;
    _ = readReply(&r);
    try std.testing.expectEqual(r.fill, r.pos); // everything buffered has been consumed
    r.fd = -1; // a read on this fails, so fillMore returns false AFTER compacting
    _ = r.fillMore();
    try std.testing.expectEqual(@as(usize, 0), r.pos);
    try std.testing.expectEqual(@as(usize, 0), r.fill);
}

test "the pool hands every concurrent caller its own connection slot" {
    const a = acquire();
    const b = acquire();
    try std.testing.expect(a != b);
    release(a);
    release(b);
    var seen = [_]bool{false} ** POOL_N;
    var held: [POOL_N]*Slot = undefined;
    for (&held) |*h| {
        h.* = acquire();
        const idx = (@intFromPtr(h.*) - @intFromPtr(&slots[0])) / @sizeOf(Slot);
        try std.testing.expect(!seen[idx]); // the whole pool, each slot exactly once
        seen[idx] = true;
    }
    for (held) |h| release(h);
}

test "a slot's connection is dropped independently of the rest of the pool" {
    const a = acquire();
    defer release(a);
    a.fd = 4242; // pretend it connected
    const b = acquire();
    defer release(b);
    b.fd = null;
    dropConn(b); // must not disturb a's connection
    try std.testing.expectEqual(@as(?net.Socket, 4242), a.fd);
    a.fd = null; // leave the pool as we found it
}
