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
const resp = @import("resp");

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

/// Read and classify one RESP reply. Bulk/array payloads stay in `r.buf`.
///
/// The framing itself lives in the `resp` module rather than here, because the game server needs
/// the same parser and cannot have this file: it is built for x86-windows and given no libc
/// sockets. Two parsers for one format is one more than can stay correct, and a framing bug in
/// the DLL is the hardest place to see one.
fn readReply(r: *Reader) ?Reply {
    while (true) {
        switch (resp.parse(r.buf[r.pos..r.fill])) {
            .ok => |o| {
                r.pos += o.consumed;
                return switch (o.reply) {
                    .status => |s| .{ .status = s },
                    .int => |v| .{ .int = v },
                    .bulk => |b| .{ .bulk = b },
                    .array_len => |n| .{ .array_len = n },
                    .err => .err,
                };
            },
            // A reply can straddle reads — a d2s save is many times an MTU.
            .need_more => if (!r.fillMore()) return null,
            // Framing is lost; there is no way to find the next reply's start.
            .invalid => return null,
        }
    }
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

// ── save durability ──────────────────────────────────────────────────────────
//
// Redis holds the live character; Postgres is the store of record. Between a save landing here
// and reaching Postgres there is a window, and losing that window loses a player's progress —
// the one failure in this design that cannot be repaired afterwards.
//
// So the dirty set is not a queue of saves, it is a set of NAMES. A flusher reads whatever bytes
// are current rather than bytes carried in a message, which makes duplicated and out-of-order
// work harmless: every flusher writes the newest save. That is what removes the need for
// exactly-once delivery, acknowledgements, or ordering.
//
// This is deliberately NOT the character lock. That lock says which game owns a character and is
// about gameplay; this says the stored copy is newer than Postgres and is about durability. A
// lock cannot do this job: the writer never contends for it, so holding one would not stop a save
// landing mid-flush. Only the version does.
//
// TWO RULES, or the rest is theatre:
//   * a dirty blob must NEVER carry a TTL — expiry would delete the only copy
//   * redis must not be allowed to evict these keys (noeviction, or their own instance)

fn charVerKey(buf: []u8, account: []const u8, charname: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "charver:{s}/{s}", .{ account, charname }) catch buf[0..0];
}

/// Record that the stored character is newer than Postgres, and return the version stamped on it.
/// Callers keep that version so the flusher can tell whether it flushed THIS save or an older one.
pub fn markCharDirty(account: []const u8, charname: []const u8) ?u64 {
    var vb: [128]u8 = undefined;
    const verkey = charVerKey(&vb, account, charname);
    if (verkey.len == 0) return null;
    var mb: [96]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return null;

    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return null;
    // One round trip: this runs on every save.
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "INCR", verkey });
    c.add(&.{ "SADD", prefix ++ "dirty", member });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return null;
    }
    var r: Reader = .{ .fd = fd };
    const rep = readReply(&r) orelse {
        dropConn(s);
        return null;
    };
    const ver: u64 = switch (rep) {
        .int => |v| @intCast(@max(v, 0)),
        else => {
            dropConn(s);
            return null;
        },
    };
    if (readReply(&r) == null) dropConn(s); // drain SADD, or the connection desyncs
    return ver;
}

/// Up to `out.len` characters whose stored copy is newer than Postgres. Not a claim: several
/// flushers may take the same name and each will write the same current bytes.
pub fn dirtyChars(out: [][]u8, lens: []usize) usize {
    var cb: [16]u8 = undefined;
    const cnt = std.fmt.bufPrint(&cb, "{d}", .{out.len}) catch return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SRANDMEMBER", prefix ++ "dirty", cnt }) orelse return 0;
    const count = switch (rep) {
        .array_len => |n| if (n <= 0) return 0 else @as(usize, @intCast(n)),
        else => return 0,
    };
    var n: usize = 0;
    for (0..count) |_| {
        const er = readReply(&r) orelse {
            dropConn(s);
            return n;
        };
        const member = switch (er) {
            .bulk => |b| b orelse continue,
            else => {
                dropConn(s);
                return n;
            },
        };
        if (n >= out.len) continue;
        const ln = @min(member.len, out[n].len);
        @memcpy(out[n][0..ln], member[0..ln]);
        lens[n] = ln;
        n += 1;
    }
    return n;
}

/// Current version of a character's stored copy, 0 if it has never been saved.
pub fn charVersion(account: []const u8, charname: []const u8) u64 {
    var vb: [128]u8 = undefined;
    const verkey = charVerKey(&vb, account, charname);
    if (verkey.len == 0) return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", verkey }) orelse return 0;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            break :blk std.fmt.parseInt(u64, v, 10) catch 0;
        },
        else => 0,
    };
}

/// Clear the dirty flag, but ONLY if no newer save landed while we were flushing.
///
/// This is the whole correctness argument for the flusher. Clearing unconditionally would drop
/// the flag for a save that reached redis mid-flush and never reached Postgres. Compare and clear
/// in one script so nothing can land between the two.
pub fn clearDirtyIfUnchanged(account: []const u8, charname: []const u8, ver: u64) bool {
    var vb: [128]u8 = undefined;
    const verkey = charVerKey(&vb, account, charname);
    if (verkey.len == 0) return false;
    var mb: [96]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return false;
    var nb: [24]u8 = undefined;
    const vstr = std.fmt.bufPrint(&nb, "{d}", .{ver}) catch return false;

    const script =
        \\if redis.call('GET', KEYS[1]) == ARGV[1] then
        \\  return redis.call('SREM', KEYS[2], ARGV[2])
        \\end
        \\return 0
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "2", verkey, prefix ++ "dirty", vstr, member }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

// ── character ownership ──────────────────────────────────────────────────────
//
// A character may be in exactly one game. The holder writes its own id into the lock, so the
// lock does not merely say "taken" — it says WHO by, which is what lets a join be refused with a
// reason instead of silence, and what makes releasing safe.
//
// Every mutation is compare-and-swap against that owner id. A release that just DELs is the
// classic distributed-lock bug: if the TTL lapses mid-session and another game takes the
// character, a blind DEL frees somebody else's lock and two games hold one character.
//
// The TTL is a backstop for a holder that dies without releasing — refreshed while the game
// lives, so it only fires when nothing is refreshing it.

fn charLockKey(buf: []u8, account: []const u8, charname: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "charlock:{s}/{s}", .{ account, charname }) catch buf[0..0];
}

/// Take the character for `owner`. False if it is held at all — including by the same game.
///
/// A seat, not a game. Two clients presenting one character to the SAME game are two seats, and
/// the engine refuses the second outright; making the claim re-takeable by its own owner made
/// those two indistinguishable and let the realm say yes to a join the engine would then drop in
/// silence. So the claim is strict, and exactly one seat holds it.
///
/// Nothing is locked out by this: the claim is released when the player leaves, when the game
/// ends, and by its own lease if the server holding it dies. A client whose session died has its
/// seat reaped by the engine, which reports the departure and frees the character.
pub fn lockChar(account: []const u8, charname: []const u8, owner: []const u8, ttl_s: u32) bool {
    var kb: [96]u8 = undefined;
    const key = charLockKey(&kb, account, charname);
    if (key.len == 0) return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    // SET NX first; if it loses, take it anyway when the holder is already us.
    const rep = command(s, &r, &.{ "SET", key, owner, "NX", "PX", px }) orelse return false;
    return switch (rep) {
        .status => true,
        // A nil bulk is SET NX declining: somebody holds it, and that somebody may be the same
        // game. Still a refusal — see above.
        .bulk => |b| b != null,
        else => false,
    };
}

/// Keep the lease alive while the game runs. False if we no longer hold it — which means the
/// lease lapsed and somebody else took the character, and the caller must stop treating it as
/// theirs rather than carry on regardless.
pub fn refreshCharLock(account: []const u8, charname: []const u8, owner: []const u8, ttl_s: u32) bool {
    var kb: [96]u8 = undefined;
    const key = charLockKey(&kb, account, charname);
    if (key.len == 0) return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const script =
        \\if redis.call('GET', KEYS[1]) == ARGV[1] then
        \\  return redis.call('PEXPIRE', KEYS[1], ARGV[2])
        \\end
        \\return 0
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner, px }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

/// Release, but only if we still hold it. Compare-and-delete in one step, so a lapsed lease
/// cannot make us free the game that took the character after us.
pub fn unlockChar(account: []const u8, charname: []const u8, owner: []const u8) bool {
    var kb: [96]u8 = undefined;
    const key = charLockKey(&kb, account, charname);
    if (key.len == 0) return false;
    const script =
        \\if redis.call('GET', KEYS[1]) == ARGV[1] then
        \\  return redis.call('DEL', KEYS[1])
        \\end
        \\return 0
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

/// Claim a game name before the game exists.
///
/// A game is only recorded once the server has accepted the create, and everything between those
/// two moments is a window in which a second client can be told the name is free, lose the race at
/// the server, and then fail to join what it was just told already exists. Claiming the name first
/// closes it: the loser learns immediately, while the winner's game is still being made.
///
/// The TTL is a backstop for a create that dies mid-flight, not the lifetime of the claim — a
/// successful create replaces it with the game record and releases this.
pub fn reserveGameName(name: []const u8, ttl_s: u32) bool {
    var kb: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamename:{s}", .{name}) catch return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SET", key, "1", "NX", "PX", px }) orelse return false;
    return switch (rep) {
        .status => true,
        .bulk => |b| b != null,
        else => false,
    };
}

/// Whether a create is currently holding this name. Lets a joiner tell "no such game" apart from
/// "the game is being made right now", which are the same thing to a client and very different to
/// the player.
pub fn gameNameReserved(name: []const u8) bool {
    var kb: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamename:{s}", .{name}) catch return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EXISTS", key }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

/// Give the name back — the create failed, or the game it named has ended.
pub fn releaseGameName(name: []const u8) void {
    var kb: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamename:{s}", .{name}) catch return;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = command(s, &r, &.{ "DEL", key });
}

/// Populate the cache from the store of record, but ONLY if nothing is cached yet.
///
/// The unconditional write this replaces could destroy a save. A miss reads the durable copy, and
/// if a newer save lands in redis before that copy is written back, an unconditional SET would put
/// the OLDER bytes over the newer ones — losing whatever the player did in between. Two instances
/// missing at once makes the window ordinary rather than exotic.
///
/// SET NX also removes the need to lock the load: instances that miss together all read, one wins
/// the write, and the losers simply discard what they read. Nothing to hold, nothing to expire,
/// and no way for a loader to lose the character it was trying to warm.
pub fn cacheCharIfAbsent(account: []const u8, charname: []const u8, bytes: []const u8) bool {
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
    const fd = s.fd orelse ensureConn(s) orelse return false;
    var cmd = CmdBuf{ .fd = fd };
    cmd.add(&.{ "SET", key, bytes, "NX" });
    // The account's char-set membership is what listChars reads, so it is not optional — and
    // SADD is idempotent, so re-adding an existing member costs nothing.
    cmd.add(&.{ "SADD", setkey, c });
    cmd.flush();
    if (!cmd.ok) {
        dropConn(s);
        return false;
    }
    var r: Reader = .{ .fd = fd };
    const rep = readReply(&r) orelse {
        dropConn(s);
        return false;
    };
    // A nil reply means somebody else got there first, which is a success for our purposes:
    // the cache holds a copy at least as new as ours.
    const stored = switch (rep) {
        .status, .int => true,
        .bulk => |b| b != null,
        else => false,
    };
    if (readReply(&r) == null) dropConn(s); // drain SADD or the connection desyncs
    return stored;
}

/// Remember that this game holds this character, so its locks can be released when it ends.
///
/// The game server reports a departure by character name only — it does not carry the account —
/// so the realm has to keep the pairing itself. The set is keyed by game, which is also what
/// makes closing a game able to free everything it held in one step.
pub fn addGameChar(gameid: u32, account: []const u8, charname: []const u8) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{d}", .{gameid}) catch return false;
    var mb: [96]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    return switch (command(s, &r, &.{ "SADD", key, member }) orelse return false) {
        .int, .status, .bulk => true,
        else => false,
    };
}

/// Free every character this game holds, and forget the pairing. Returns how many were freed.
///
/// Each release is still owner-checked: a character whose lease lapsed and was taken by another
/// game must not be freed by this one closing. Done in a single script so a character cannot be
/// claimed between the check and the delete.
pub fn releaseGameChars(gameid: u32, owner: []const u8) usize {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{d}", .{gameid}) catch return 0;
    const script =
        \\local n = 0
        \\for _, m in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  local lk = ARGV[2] .. m
        \\  if redis.call('GET', lk) == ARGV[1] then
        \\    redis.call('DEL', lk)
        \\    n = n + 1
        \\  end
        \\end
        \\redis.call('DEL', KEYS[1])
        \\return n
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner, prefix ++ "charlock:" }) orelse return 0;
    return switch (rep) {
        .int => |v| @intCast(@max(v, 0)),
        else => 0,
    };
}

/// Free one character this game holds, matched by name because that is all a departure carries.
pub fn releaseGameCharByName(gameid: u32, charname: []const u8, owner: []const u8) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{d}", .{gameid}) catch return false;
    var sb: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&sb, "/{s}", .{charname}) catch return false;
    const script =
        \\for _, m in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  if string.sub(m, -string.len(ARGV[3])) == ARGV[3] then
        \\    local lk = ARGV[2] .. m
        \\    if redis.call('GET', lk) == ARGV[1] then redis.call('DEL', lk) end
        \\    redis.call('SREM', KEYS[1], m)
        \\    return 1
        \\  end
        \\end
        \\return 0
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner, prefix ++ "charlock:", suffix }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

/// Who holds this character, or null if nobody. The point of storing the owner rather than a
/// bare flag: a refused join can say which game has it instead of failing silently.
pub fn charLockOwner(account: []const u8, charname: []const u8, out: []u8) ?[]const u8 {
    var kb: [96]u8 = undefined;
    const key = charLockKey(&kb, account, charname);
    if (key.len == 0) return null;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            const n = @min(v.len, out.len);
            @memcpy(out[0..n], v[0..n]);
            break :blk out[0..n];
        },
        else => null,
    };
}

/// Does redis answer? Used once at startup so an unreachable store is reported as itself rather
/// than as every join mysteriously failing later.
pub fn ping() bool {
    const s2 = acquire();
    defer release(s2);
    var r: Reader = undefined;
    const rep = command(s2, &r, &.{"PING"}) orelse return false;
    return switch (rep) {
        .status => true,
        else => false,
    };
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

// ── the game-server fleet, as every instance sees it ─────────────────────────
//
// One key per server plus a set to enumerate them, the same shape the game index uses. The record
// carries a TTL and the owning realmd refreshes it on the control link's own liveness traffic, so
// a realmd that dies with its sockets takes its servers out of the shared view without anyone
// having to notice and clean up.

fn gsKey(buf: []u8, gsid: u32) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "gs:{x}", .{gsid}) catch buf[0..0];
}

/// Publish (or refresh) one game server. Called on registration and whenever its load changes.
pub fn registerGs(rec: types.GsRec, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = gsKey(&kb, rec.gsid);
    if (key.len == 0) return false;
    // ip[4] ++ port(u16) ++ maxgame(u32) ++ live(u32) ++ full(u8) = 15 bytes.
    var vb: [15]u8 = undefined;
    @memcpy(vb[0..4], &rec.gs_ip);
    std.mem.writeInt(u16, vb[4..6], rec.gs_port, .little);
    std.mem.writeInt(u32, vb[6..10], rec.maxgame, .little);
    std.mem.writeInt(u32, vb[10..14], rec.live_games, .little);
    vb[14] = @intFromBool(rec.full);

    var idb: [16]u8 = undefined;
    const idstr = std.fmt.bufPrint(&idb, "{x}", .{rec.gsid}) catch return false;

    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return false;
    // SET + SADD in one round trip: this runs on every game create and close.
    var c = CmdBuf{ .fd = fd };
    if (ttl_s > 0) {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        c.add(&.{ "SET", key, &vb, "PX", px });
    } else {
        c.add(&.{ "SET", key, &vb });
    }
    c.add(&.{ "SADD", prefix ++ "gs", idstr });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return false;
    }
    var r: Reader = undefined;
    r = .{ .fd = fd };
    var ok = true;
    for (0..2) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            ok = false;
            break;
        }
    }
    return ok;
}

/// Drop a game server from the shared view — its control connection is gone.
pub fn removeGs(gsid: u32) void {
    var kb: [64]u8 = undefined;
    const key = gsKey(&kb, gsid);
    if (key.len == 0) return;
    var idb: [16]u8 = undefined;
    const idstr = std.fmt.bufPrint(&idb, "{x}", .{gsid}) catch return;

    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return;
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "DEL", key });
    c.add(&.{ "SREM", prefix ++ "gs", idstr });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return;
    }
    var r: Reader = .{ .fd = fd };
    for (0..2) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            return;
        }
    }
}

// ── dispatch ─────────────────────────────────────────────────────────────────
//
// Create and join travel the store rather than a socket, so the instance that serves a client
// need not be the one a game server happens to be connected to. The payload is the SAME control
// packet the link already carried — one wire format, not two — and the `seq` already in its
// header is the correlation id, so a reply can be matched to its request instead of assumed.
//
// Matching matters here in a way it did not over a socket. One connection with one request in
// flight made "the next reply is mine" true by construction; with several instances dispatching
// to one server it is simply false, and two realmds would take each other's answers.

fn gsQueueKey(buf: []u8, gsid: u32) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "gsq:{x}", .{gsid}) catch buf[0..0];
}

fn gsReplyKey(buf: []u8, seq: u32) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "gsreply:{x}", .{seq}) catch buf[0..0];
}

/// Hand a request to a game server. The TTL is a floor under a server that never reads its queue:
/// the request expires rather than being delivered to it minutes later, by which time the client
/// has long gone.
pub fn pushGsRequest(gsid: u32, packet: []const u8, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = gsQueueKey(&kb, gsid);
    if (key.len == 0) return false;
    var pb: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&pb, "{d}", .{ttl_s}) catch return false;

    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return false;
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "RPUSH", key, packet });
    // Refreshed per push, so a queue nobody drains disappears instead of growing forever.
    c.add(&.{ "EXPIRE", key, secs });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return false;
    }
    var r: Reader = .{ .fd = fd };
    var ok = true;
    for (0..2) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            ok = false;
            break;
        }
    }
    return ok;
}

/// Collect the reply to `seq`, or null if it has not arrived. Consumed as it is read, so a reply
/// is delivered exactly once and a stale one cannot be mistaken for a fresh answer.
pub fn takeGsReply(seq: u32, out: []u8) ?usize {
    var kb: [64]u8 = undefined;
    const key = gsReplyKey(&kb, seq);
    if (key.len == 0) return null;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    // GETDEL: reading and removing must not be two steps, or a retry could take it twice.
    const rep = command(s, &r, &.{ "GETDEL", key }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            const n = @min(v.len, out.len);
            @memcpy(out[0..n], v[0..n]);
            break :blk n;
        },
        else => null,
    };
}

/// Choose a game server for a new game and reserve a slot on it, in one indivisible step.
///
/// Selecting and then reserving as two operations is a read-modify-write across instances: two
/// realmds both see the same least-loaded server, both pick it, and one of the two games has
/// nowhere to go. A script cannot interleave, so the decision and the claim happen together.
///
/// Deliberately NOT a distributed lock. A lock would need a lease, an owner to verify, and an
/// answer for a holder that dies mid-create; this needs none of those because it never spans two
/// round trips.
///
/// Returns the chosen server's id, or null when every server is full — which is a real answer, not
/// a failure, and the caller has a different thing to tell the player for each.
pub fn pickAndReserveGs() ?u32 {
    const script =
        \\local best, bestload
        \\for _, id in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  local rec = redis.call('GET', KEYS[2] .. id)
        \\  if rec and #rec >= 15 then
        \\    local function u32(o)
        \\      return string.byte(rec,o) + string.byte(rec,o+1)*256
        \\           + string.byte(rec,o+2)*65536 + string.byte(rec,o+3)*16777216
        \\    end
        \\    local maxgame, live, full = u32(7), u32(11), string.byte(rec,15)
        \\    -- A server that said it is full knows something the count cannot see: a finished
        \\    -- game holds its engine slot through the reap window.
        \\    if full == 0 and (maxgame == 0 or live < maxgame) then
        \\      if not bestload or live < bestload then best, bestload = id, live end
        \\    end
        \\  end
        \\end
        \\if not best then return false end
        \\local key = KEYS[2] .. best
        \\local rec = redis.call('GET', key)
        \\local live = string.byte(rec,11) + string.byte(rec,12)*256
        \\          + string.byte(rec,13)*65536 + string.byte(rec,14)*16777216
        \\live = live + 1
        \\local b = string.char(live % 256, math.floor(live/256) % 256,
        \\                      math.floor(live/65536) % 256, math.floor(live/16777216) % 256)
        \\-- Rewrite only the load field, and KEEPTTL so reserving does not extend the server's
        \\-- own lease — that lease is how a dead server disappears, and it is not ours to renew.
        \\redis.call('SET', key, string.sub(rec,1,10) .. b .. string.sub(rec,15), 'KEEPTTL')
        \\return best
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "2", prefix ++ "gs", prefix ++ "gs:" }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            break :blk std.fmt.parseInt(u32, v, 16) catch null;
        },
        else => null,
    };
}

/// Every game server the realm can currently see, from any instance. Members whose record has
/// TTL'd out are pruned from the index as they are found, the same as `snapshotGames`.
pub fn snapshotGs(out: []types.GsRec) usize {
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SMEMBERS", prefix ++ "gs" }) orelse return 0;
    const count = switch (rep) {
        .array_len => |nn| if (nn <= 0) return 0 else @as(usize, @intCast(nn)),
        else => return 0,
    };
    var ids: [max_gs_snapshot][16]u8 = undefined;
    var idlen: [max_gs_snapshot]u8 = undefined;
    var got: usize = 0;
    for (0..count) |_| {
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
        if (got >= ids.len) continue;
        const ln: u8 = @intCast(@min(member.len, 16));
        @memcpy(ids[got][0..ln], member[0..ln]);
        idlen[got] = ln;
        got += 1;
    }
    if (got == 0) return 0;

    const fd = s.fd orelse return 0;
    var c = CmdBuf{ .fd = fd };
    for (0..got) |i| {
        var gk: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&gk, prefix ++ "gs:{s}", .{ids[i][0..idlen[i]]}) catch {
            c.ok = false;
            break;
        };
        c.add(&.{ "GET", key });
    }
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return 0;
    }

    var expired = [_]bool{false} ** max_gs_snapshot;
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
                expired[i] = true;
                any_expired = true;
                continue;
            },
            else => continue,
        };
        if (val.len < 15 or n >= out.len) continue;
        out[n] = .{
            .gsid = std.fmt.parseInt(u32, ids[i][0..idlen[i]], 16) catch continue,
            .gs_ip = .{ val[0], val[1], val[2], val[3] },
            .gs_port = std.mem.readInt(u16, val[4..6], .little),
            .maxgame = std.mem.readInt(u32, val[6..10], .little),
            .live_games = std.mem.readInt(u32, val[10..14], .little),
            .full = val[14] != 0,
        };
        n += 1;
    }

    if (any_expired and synced) {
        var args: [max_gs_snapshot + 2][]const u8 = undefined;
        args[0] = "SREM";
        args[1] = prefix ++ "gs";
        var na: usize = 2;
        for (0..got) |i| {
            if (expired[i]) {
                args[na] = ids[i][0..idlen[i]];
                na += 1;
            }
        }
        if (na > 2) {
            var rr: Reader = undefined;
            _ = command(s, &rr, args[0..na]);
        }
    }
    return n;
}

/// Bound on one fleet snapshot — mirrors gslink's own `max_gs`.
const max_gs_snapshot = 64;

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
