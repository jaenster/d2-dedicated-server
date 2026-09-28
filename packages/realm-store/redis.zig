//! Redis backend: RESP straight over a raw TCP socket, no hiredis, just the libc net helpers.
//! Bulk strings are read BINARY-SAFE (exactly <len> bytes, never newline-scanned) because d2s
//! saves contain NULs and stray \n.
//!
//! A connection is held for a whole command/reply cycle, so one shared connection bought
//! thread-per-peer no concurrency at all — hence a small POOL, whose slot lock must sleep rather
//! than spin (infra lock.zig) since it is held across a round trip. Anything needing N round trips
//! is pipelined into one instead of looping `command`.
//!
//! Lock order: game_index_lock before a pool slot, never the reverse.
//! Keys live under a "realmd:" prefix; chars durable, sessions/games ephemeral with PX TTL and
//! reverse indexes by gameid and by gs.
const std = @import("std");
const net = @import("realm_infra").net;
const Lock = @import("realm_infra").lock.Lock;
const types = @import("realm_infra").types;
const resp = @import("resp");

const Name = types.Name;
const GameRec = types.GameRec;
const Route = types.Route;
const TokenRoute = types.TokenRoute;
const GameRef = types.GameRef;
const claims = @import("realm_proto").claims;

const prefix = "realmd:";

// accounts, profiles and guilds (durable)
//
// One 22-byte record per account, the same layout the filesystem backend writes: [0] whether a
// password is set, [1..21] its hash, [21] the admin flag. Sharing the shape means a realm can be
// moved between backends by copying values, and means there is one thing to reason about rather
// than two.
//
// These used to route to the filesystem backend on the argument that they are low-volume and
// simple. That holds until there is more than one instance, at which point "the file on this pod"
// is a different answer per pod.

const account_rec_len = 22;

fn accountKey(buf: []u8, name: []const u8) ?[]const u8 {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return null;
    return std.fmt.bufPrint(buf, prefix ++ "account:{s}", .{a}) catch null;
}

fn readAccount(name: []const u8, out: *[account_rec_len]u8) bool {
    var kb: [128]u8 = undefined;
    const key = accountKey(&kb, name) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return false;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk false;
            if (v.len < account_rec_len) break :blk false;
            @memcpy(out, v[0..account_rec_len]);
            break :blk true;
        },
        else => false,
    };
}

fn writeAccount(name: []const u8, rec: *const [account_rec_len]u8, only_if_absent: bool) bool {
    var kb: [128]u8 = undefined;
    const key = accountKey(&kb, name) orelse return false;
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    if (only_if_absent) {
        // SET NX decides the winner, so two instances creating the same account cannot both
        // believe they did — which is the whole answer the caller wants.
        const rep = command(s, &r, &.{ "SET", key, rec, "NX" }) orelse return false;
        const won = switch (rep) {
            .status => true,
            .bulk => |b| b != null,
            else => false,
        };
        if (!won) return false;
    } else {
        _ = command(s, &r, &.{ "SET", key, rec }) orelse return false;
    }
    var r2: Reader = undefined;
    _ = command(s, &r2, &.{ "SADD", prefix ++ "accounts", a });
    return true;
}

pub fn createAccount(name: []const u8, pwhash: ?[20]u8) bool {
    var rec: [account_rec_len]u8 = [_]u8{0} ** account_rec_len;
    if (pwhash) |h| {
        rec[0] = 1;
        @memcpy(rec[1..21], &h);
    }
    return writeAccount(name, &rec, true);
}

pub fn accountExists(name: []const u8) bool {
    var rec: [account_rec_len]u8 = undefined;
    return readAccount(name, &rec);
}

/// Null if there is no such account; false if it exists without a password.
pub fn accountPwHash(name: []const u8, out: *[20]u8) ?bool {
    var rec: [account_rec_len]u8 = undefined;
    if (!readAccount(name, &rec)) return null;
    if (rec[0] == 0) return false;
    @memcpy(out, rec[1..21]);
    return true;
}

pub fn setAccountPassword(name: []const u8, hash: [20]u8) bool {
    var rec: [account_rec_len]u8 = undefined;
    if (!readAccount(name, &rec)) return false;
    rec[0] = 1;
    @memcpy(rec[1..21], &hash);
    return writeAccount(name, &rec, false);
}

pub fn setAdmin(name: []const u8, admin: bool) bool {
    var rec: [account_rec_len]u8 = undefined;
    if (!readAccount(name, &rec)) return false;
    rec[21] = if (admin) 1 else 0;
    return writeAccount(name, &rec, false);
}

pub fn accountIsAdmin(name: []const u8) bool {
    var rec: [account_rec_len]u8 = undefined;
    if (!readAccount(name, &rec)) return false;
    return rec[21] == 1;
}

/// Remove an account. Idempotent — true even if it was already gone.
pub fn deleteAccount(name: []const u8) bool {
    var kb: [128]u8 = undefined;
    const key = accountKey(&kb, name) orelse return false;
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = pipeline(s, &r, &.{
        &.{ "DEL", key },
        &.{ "SREM", prefix ++ "accounts", a },
    });
    return true;
}

pub fn listAccounts(names: [][32]u8) usize {
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SMEMBERS", prefix ++ "accounts" }) orelse return 0;
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
        if (filled >= names.len) continue; // drain the rest
        if (member.len == 0 or member.len >= names[filled].len) continue;
        @memset(&names[filled], 0);
        @memcpy(names[filled][0..member.len], member);
        filled += 1;
    }
    return filled;
}

fn userDataKey(buf: []u8, account: []const u8, key_: []const u8) ?[]const u8 {
    var nb: [64]u8 = undefined;
    const a = sanitize(account, &nb) orelse return null;
    // The key path is the client's ("profile\\sex"), so it is hashed into the field rather than
    // pasted into the key: it carries backslashes, and a key name is not the place for them.
    var h: u64 = 1469598103934665603;
    for (key_) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return std.fmt.bufPrint(buf, prefix ++ "userdata:{s}:{x}", .{ a, h }) catch null;
}

pub fn getUserData(account: []const u8, key_: []const u8, out: []u8) usize {
    var kb: [128]u8 = undefined;
    const key = userDataKey(&kb, account, key_) orelse return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return 0;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            const n = @min(v.len, out.len);
            @memcpy(out[0..n], v[0..n]);
            break :blk n;
        },
        else => 0,
    };
}

pub fn setUserData(account: []const u8, key_: []const u8, value: []const u8) bool {
    var kb: [128]u8 = undefined;
    const key = userDataKey(&kb, account, key_) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    return command(s, &r, &.{ "SET", key, value }) != null;
}

fn guildKey(buf: []u8, name: []const u8) ?[]const u8 {
    var nb: [64]u8 = undefined;
    const g = sanitize(name, &nb) orelse return null;
    return std.fmt.bufPrint(buf, prefix ++ "guild:{s}", .{g}) catch null;
}

pub fn saveGuild(name: []const u8, bytes: []const u8) bool {
    var kb: [128]u8 = undefined;
    const key = guildKey(&kb, name) orelse return false;
    var nb: [64]u8 = undefined;
    const g = sanitize(name, &nb) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    return pipeline(s, &r, &.{
        &.{ "SET", key, bytes },
        &.{ "SADD", prefix ++ "guilds", g },
    });
}

pub fn getGuild(name: []const u8, out: []u8) usize {
    var kb: [128]u8 = undefined;
    const key = guildKey(&kb, name) orelse return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return 0;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            const n = @min(v.len, out.len);
            @memcpy(out[0..n], v[0..n]);
            break :blk n;
        },
        else => 0,
    };
}

/// Idempotent — true even if it was already gone, so a repeated delete is not an error.
pub fn deleteGuild(name: []const u8) bool {
    var kb: [128]u8 = undefined;
    const key = guildKey(&kb, name) orelse return false;
    var nb: [64]u8 = undefined;
    const g = sanitize(name, &nb) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = pipeline(s, &r, &.{
        &.{ "DEL", key },
        &.{ "SREM", prefix ++ "guilds", g },
    });
    return true;
}

pub fn listGuilds(names: []Name) usize {
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "SMEMBERS", prefix ++ "guilds" }) orelse return 0;
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
        if (filled >= names.len) continue; // drain the rest
        if (member.len == 0 or member.len > names[filled].buf.len) continue;
        @memset(&names[filled].buf, 0);
        @memcpy(names[filled].buf[0..member.len], member);
        names[filled].len = @intCast(member.len);
        filled += 1;
    }
    return filled;
}

// connection state

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

/// Serialises every mutation of the GAME INDEX (record + by-id/by-gs reverse keys). Reads and
/// other keys stay concurrent.
///
/// Needed because the engine recycles game ids from a 1024-slot ring: a close interleaved with
/// a create that reused the id would resolve the NEW game's name via `byid:<id>` and delete the
/// record just written.
///
/// Held across IO (sleeping lock), always taken BEFORE a slot. Within-process only — two realmd
/// instances on one redis still race; the real cure is CLOSEGAME carrying the game NAME.
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

// RESP encode + reply read

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
/// Framing lives in the `resp` module, not here: the game server (x86-windows, no libc sockets)
/// needs the same parser and can't use this file. One parser for both keeps a framing bug from
/// hiding in the DLL, the hardest place to see one.
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

/// Send several commands as ONE round trip and drain their replies in order, for writes that
/// all have to land but whose replies carry no value (callers needing a value use `command`).
/// Every reply is consumed even on error, or the leftovers would desync the next caller.
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

// name sanitising

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

/// A game name reduced to the key it is stored under. LOWERCASED: Battle.net treats game names
/// case-insensitively ("Jan" == "jan"), so a case-preserving key would split CREATEGAME and
/// JOINGAME onto two different records for what the player sees as one game.
fn gameKey(name: []const u8, out: []u8) ?[]const u8 {
    const safe = sanitize(name, out) orelse return null;
    for (out[0..safe.len]) |*c| c.* = std.ascii.toLower(c.*);
    return out[0..safe.len];
}

// characters (durable)

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
    var mb: [192]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ a, c }) catch return false;
    var vb: [192]u8 = undefined;
    const verkey = std.fmt.bufPrint(&vb, prefix ++ "charver:{s}/{s}", .{ a, c }) catch return false;

    // Drop the save blob and remove the name from the account's char set. Mirror of
    // saveCharD2s (SET + SADD); idempotent — a missing key is fine.
    //
    // The dirty mark goes with it. A deleted character left in that set is work the flush worker
    // retries forever and can never finish, because the bytes it would move are gone.
    _ = pipeline(s, &r, &.{
        &.{ "DEL", key },
        &.{ "SREM", setkey, c },
        &.{ "SREM", prefix ++ "dirty", member },
        &.{ "DEL", verkey },
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

// sessions (ephemeral, PX TTL)

// extension cache
//
// The in-flight half of an extension's namespace, keyed `realmd:ext:<name>:<key>` so it sits
// beside the realm's own keys without ever being one of them. Durable extension state belongs in
// pg's ext_kv; this is for what an extension is willing to lose — rate limits, a cached leaderboard,
// a per-session scratch value.

/// Longest `realmd:ext:<name>:<key>` we will build. Bounded by ExtKey (96) plus the name and the
/// fixed prefix, rounded up.
const ext_key_buf = 192;

fn extKey(buf: []u8, ext: []const u8, key: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "ext:{s}:{s}", .{ ext, key }) catch null;
}

pub fn getExtCache(ext: []const u8, key: []const u8, out: []u8) usize {
    var kb: [ext_key_buf]u8 = undefined;
    const k = extKey(&kb, ext, key) orelse return 0;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", k }) orelse return 0;
    const bulk = switch (rep) {
        .bulk => |b| b orelse return 0, // nil → missing or expired
        else => return 0,
    };
    const n = @min(bulk.len, out.len);
    @memcpy(out[0..n], bulk[0..n]);
    return n;
}

/// `ttl_s` 0 means no expiry — an extension that wants a value to outlive its own uptime should
/// still be writing it durably, not leaning on this.
pub fn setExtCache(ext: []const u8, key: []const u8, value: []const u8, ttl_s: u32) bool {
    var kb: [ext_key_buf]u8 = undefined;
    const k = extKey(&kb, ext, key) orelse return false;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(s, &r, &.{ "SET", k, value, "PX", px });
    } else command(s, &r, &.{ "SET", k, value });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

pub fn delExtCache(ext: []const u8, key: []const u8) void {
    var kb: [ext_key_buf]u8 = undefined;
    const k = extKey(&kb, ext, key) orelse return;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = command(s, &r, &.{ "DEL", k });
}

/// Add to a counter in the extension's namespace and return the new value, setting the TTL only
/// when the key is created. The one operation a rate limit or a "kills this season" counter needs
/// and cannot build out of get+set without losing increments between instances.
pub fn incrExtCache(ext: []const u8, key: []const u8, by: i64, ttl_s: u32) ?i64 {
    var kb: [ext_key_buf]u8 = undefined;
    const k = extKey(&kb, ext, key) orelse return null;
    var bb: [24]u8 = undefined;
    const byv = std.fmt.bufPrint(&bb, "{d}", .{by}) catch return null;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "INCRBY", k, byv }) orelse return null;
    const v = switch (rep) {
        .int => |i| i,
        else => return null,
    };
    // Only a first increment gets the expiry: re-arming it on every hit would make a one-minute
    // rate-limit window slide forever for anyone who keeps hitting it.
    if (ttl_s > 0 and v == by) {
        var pb: [16]u8 = undefined;
        const secs = std.fmt.bufPrint(&pb, "{d}", .{ttl_s}) catch return v;
        var r2: Reader = undefined;
        _ = command(s, &r2, &.{ "EXPIRE", k, secs });
    }
    return v;
}

/// The record is `<account>` or `<account>\n<engine>`. One key rather than two because both halves
/// are established at the same moment and expire together; a reader that predates the engine half
/// stops at the newline and is unaffected.
pub fn saveSession(id: u64, account: []const u8, version: []const u8, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return false;
    var vb: [96]u8 = undefined;
    const val = if (version.len == 0)
        account
    else
        std.fmt.bufPrint(&vb, "{s}\n{s}", .{ account, version }) catch account;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(s, &r, &.{ "SET", key, val, "PX", px });
    } else command(s, &r, &.{ "SET", key, val });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

/// The engine half of a session record, empty when it has none.
pub fn versionForSession(id: u64, out: []u8) []const u8 {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return out[0..0];

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", key }) orelse return out[0..0];
    const bulk = switch (rep) {
        .bulk => |b| b orelse return out[0..0],
        else => return out[0..0],
    };
    const nl = std.mem.indexOfScalar(u8, bulk, '\n') orelse return out[0..0];
    const v = bulk[nl + 1 ..];
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return out[0..n];
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
    const acct = bulk[0 .. std.mem.indexOfScalar(u8, bulk, '\n') orelse bulk.len];
    const n = @min(acct.len, out.len);
    @memcpy(out[0..n], acct[0..n]);
    return out[0..n];
}

// login tickets
//
// A one-shot, short-lived password issued out of band — by a launcher, a website, or anything else
// that has already decided who the player is. In flight by nature: a ticket that outlives a
// restart is a ticket that outlived its reason, so this is redis and not the store of record.

fn ticketKey(buf: []u8, account: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "ticket:{s}", .{account}) catch null;
}

pub fn putLoginTicket(account: []const u8, ticket: []const u8, ttl_s: u32) bool {
    var kb: [128]u8 = undefined;
    const key = ticketKey(&kb, account) orelse return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = if (ttl_s > 0) blk: {
        var pb: [16]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
        break :blk command(s, &r, &.{ "SET", key, ticket, "PX", px });
    } else command(s, &r, &.{ "SET", key, ticket });
    return switch (rep orelse return false) {
        .status, .bulk, .int => true,
        .array_len, .err => false,
    };
}

/// Read and consume a ticket in one round trip. One-shot on purpose: a ticket that can be redeemed
/// twice is a password with a short expiry, and the point of it is that it is not one.
pub fn takeLoginTicket(account: []const u8, out: []u8) usize {
    var kb: [128]u8 = undefined;
    const key = ticketKey(&kb, account) orelse return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    // GETDEL is 6.2+; on an older server the script is the portable form of the same thing.
    const script =
        \\local v = redis.call('GET', KEYS[1])
        \\if v then redis.call('DEL', KEYS[1]) end
        \\return v
    ;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key }) orelse return 0;
    const bulk = switch (rep) {
        .bulk => |b| b orelse return 0,
        else => return 0,
    };
    const n = @min(bulk.len, out.len);
    @memcpy(out[0..n], bulk[0..n]);
    return n;
}

pub fn expireSession(id: u64) void {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "session:{x}", .{id}) catch return;

    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = command(s, &r, &.{ "DEL", key });
}

// games (ephemeral, PX TTL, reverse indexed by id and by gs)

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
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}.{d}", .{ gsid, gameid }) catch return false;
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

/// Decode the space-separated game record text.
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
pub fn setGamePlayers(game: GameRef, players: u16) bool {
    // When the server's own count last replaced ours: a join claimed before this is no longer in it.
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamecounted:{x}.{d}", .{ game.gsid, game.gameid }) catch return false;
    const script = lua_now_ms ++
        \\redis.call('SET', KEYS[1], string.format('%d', now_ms()), 'EX', 21600)
        \\return 1
    ;
    {
        const s = acquire();
        defer release(s);
        var r: Reader = undefined;
        _ = command(s, &r, &.{ "EVAL", script, "1", key });
    }
    return rewriteGamePlayers(game, .{ .set = players }, 0);
}

/// Move a game's player count by `delta`, floored at zero. For a claim the realm withdraws: the
/// game server never counted a player who never arrived, so only the realm's own bump comes back.
pub fn adjustGamePlayers(game: GameRef, delta: i32) bool {
    return rewriteGamePlayers(game, .{ .delta = delta }, 0);
}

/// Count a join the realm just authorised, against the record as it is NOW, and renew the game's
/// listing. False if the game is no longer indexed: a join never brings a closed game back.
pub fn countJoin(game: GameRef, ttl_s: u32) bool {
    return rewriteGamePlayers(game, .{ .delta = 1 }, @as(u64, ttl_s) * 1000);
}

const PlayerCount = union(enum) { set: u16, delta: i32 };

/// `renew_ms` > 0 also resets the record's and the id index's TTL to it; 0 keeps them.
///
/// One script: resolve the name through byid, rewrite the players field, and write it back only
/// if the record is still there. As separate commands, a close landing between the read and the
/// write (from another instance, which the in-process lock does not order against) was undone by
/// the write, and a `SET ... KEEPTTL` on a key that is gone leaves it with no TTL at all.
fn rewriteGamePlayers(game: GameRef, count: PlayerCount, renew_ms: u64) bool {
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}.{d}", .{ game.gsid, game.gameid }) catch return false;
    var vb: [24]u8 = undefined;
    const kind: []const u8, const val = switch (count) {
        .set => |n| .{ "set", std.fmt.bufPrint(&vb, "{d}", .{n}) catch return false },
        .delta => |d| .{ "delta", std.fmt.bufPrint(&vb, "{d}", .{d}) catch return false },
    };
    var pb: [24]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{renew_ms}) catch return false;
    // Record fields: gameid ip port gsid players status difficulty <pw> <description>.
    const script =
        \\local name = redis.call('GET', KEYS[1])
        \\if not name then return 0 end
        \\local gk = ARGV[1] .. 'game:' .. name
        \\local v = redis.call('GET', gk)
        \\if not v then return 0 end
        \\local head, n, tail = string.match(v, '^(%S+ %S+ %S+ %S+ )(%d+)(.*)$')
        \\if not head then return 0 end
        \\local p = tonumber(ARGV[3])
        \\if ARGV[2] == 'delta' then p = tonumber(n) + p end
        \\if p < 0 then p = 0 end
        \\if p > 65535 then p = 65535 end
        \\local nv = head .. string.format('%d', p) .. tail
        \\if tonumber(ARGV[4]) > 0 then
        \\  redis.call('SET', gk, nv, 'PX', ARGV[4])
        \\  redis.call('PEXPIRE', KEYS[1], ARGV[4])
        \\else
        \\  redis.call('SET', gk, nv, 'KEEPTTL')
        \\end
        \\return 1
    ;
    // Ordered against create/close in this process, as every game-index write is.
    game_index_lock.lock();
    defer game_index_lock.unlock();
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", idkey, prefix, kind, val, px }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

/// Look up the game name for an engine gameid via the byid index, then delete the
/// game record and that index entry.
pub fn removeGame(game: GameRef) void {
    var ik: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}.{d}", .{ game.gsid, game.gameid }) catch return;

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
                const idkey = std.fmt.bufPrint(&ik, prefix ++ "game:byid:{x}.{d}", .{ gsid, rec.gameid }) catch null;
                if (idkey) |k| _ = command(s, &r, &.{ "DEL", k });
            }
        }
        _ = command(s, &r, &.{ "DEL", gamekey });
    }
    _ = command(s, &r, &.{ "DEL", gskey });
}

// routes (ephemeral, PX TTL) — keyed by client source IP

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

// token routes (ephemeral, PX TTL) — keyed by realm-global token

fn tokenRouteKey(buf: []u8, token: u16) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "troute:{x}", .{token}) catch unreachable;
}

// save durability: Redis holds the live character, Postgres is the store of record. The window
// between a save landing here and reaching Postgres is the one failure that can't be repaired.
// The dirty set is a set of NAMES, not a queue: a flusher reads whatever bytes are current, so
// duplicated/out-of-order work is harmless. Deliberately NOT the character lock — that's gameplay
// ownership; this is durability, and a lock can't do the job since the writer never contends for
// it. TWO RULES: a dirty blob must NEVER carry a TTL, and redis must not evict these keys
// (noeviction, or a dedicated instance).

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

// character ownership
//
// A character may be in exactly one game. The holder writes its own id into the lock, so it says
// WHO holds it, letting a join be refused with a reason and releasing be safe.
//
// Every mutation is compare-and-swap against that owner id — a release that just DELs is the
// classic distributed-lock bug: a lapsed TTL mid-session lets another game take the character,
// then a blind DEL frees somebody else's lock and two games hold one character.
//
// TTL is a backstop for a holder that dies without releasing; refreshed while the game lives.

fn charLockKey(buf: []u8, account: []const u8, charname: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "charlock:{s}/{s}", .{ account, charname }) catch buf[0..0];
}

/// How a join's claim on a character came out.
pub const JoinClaim = union(enum) {
    /// The character was free.
    claimed,
    /// It was held by a join that never arrived; that claim was withdrawn.
    took_over: Withdrawn,
    /// Somebody holds it.
    held,
    /// The game is no longer in the index: it closed while the join was on its way.
    gone,
};

pub const Withdrawn = struct {
    game: GameRef,
    /// The join's bump is still in that game's player count: no count from its server has
    /// replaced it since.
    counted: bool,
};

/// Redis's clock in milliseconds, for scripts. One clock for every instance.
const lua_now_ms =
    \\local function now_ms()
    \\  local t = redis.call('TIME')
    \\  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
    \\end
    \\
;

/// The pending-join record and its flags are the realm/game-server contract in
/// `realm_proto.claims`; the parser is shared with the game servers' load check.
const lua_parse_join = claims.lua_parse_join;

/// Where a claim withdrawn as abandoned is remembered (`realmd:charleft:<member>` = game ref), so
/// the arrival it was waiting for can still reclaim the character if it turns up late.
const charleft = "charleft:";

/// Claim a character for a join into `game`, recording the claim as PENDING until the game
/// server reports the player arrived (`confirmGameChar`).
///
/// A pending claim is a join the realm authorised and nobody has seen complete. It is given up to
/// a new join when the same realm session asks again (a client joins one game at a time, so its
/// previous attempt is dead), or when its game reports arrivals and this one has not arrived within
/// `grace_s`. Otherwise it is held exactly like a seated character.
///
/// Once a game server has LOADED the character for the claim (flag 'D', set by the server's load
/// check in `realm_proto.claims`), the attempt is not dead however the client behaves: the same
/// session may not take it over, and only `loaded_grace_s` (well past any load) withdraws it.
/// Taking it over earlier is how one client would get the character into two games.
///
/// The game has to still be the one named `game_name` in the index, checked in the same script:
/// a join that waited for its character can outlive the game it is joining, and a claim on a game
/// that has closed is never released by that game's close.
pub fn claimCharForJoin(account: []const u8, charname: []const u8, game_name: []const u8, game: GameRef, session: u64, ttl_s: u32, grace_s: u32, loaded_grace_s: u32, game_ttl_s: u32) JoinClaim {
    var nb: [64]u8 = undefined;
    const safe = gameKey(game_name, &nb) orelse return .gone;
    var xb: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&xb, prefix ++ "game:byid:{x}.{d}", .{ game.gsid, game.gameid }) catch return .held;
    var gtb: [24]u8 = undefined;
    const game_px = std.fmt.bufPrint(&gtb, "{d}", .{@as(u64, game_ttl_s) * 1000}) catch return .held;
    var mb: [96]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return .held;
    var lb: [128]u8 = undefined;
    const lockkey = std.fmt.bufPrint(&lb, prefix ++ "charlock:{s}", .{member}) catch return .held;
    var jb: [128]u8 = undefined;
    const joinkey = std.fmt.bufPrint(&jb, prefix ++ "charjoin:{s}", .{member}) catch return .held;
    var gb: [64]u8 = undefined;
    const setkey = std.fmt.bufPrint(&gb, prefix ++ "gamechars:{x}.{d}", .{ game.gsid, game.gameid }) catch return .held;
    var ob: [32]u8 = undefined;
    const owner = std.fmt.bufPrint(&ob, "game:{x}.{d}", .{ game.gsid, game.gameid }) catch return .held;
    var ib: [32]u8 = undefined;
    const gid = std.fmt.bufPrint(&ib, "{x}.{d}", .{ game.gsid, game.gameid }) catch return .held;
    var sb: [24]u8 = undefined;
    const sess = std.fmt.bufPrint(&sb, "{x}", .{session}) catch return .held;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return .held;
    var tb: [16]u8 = undefined;
    const grace = std.fmt.bufPrint(&tb, "{d}", .{grace_s}) catch return .held;
    var lgb: [16]u8 = undefined;
    const loaded_grace = std.fmt.bufPrint(&lgb, "{d}", .{loaded_grace_s}) catch return .held;
    // -2 gone, -1 held, 0 claimed; a claim taken over answers "T<counted><ref>" with the game it
    // was taken from and whether its bump is still in that game's count.
    const script = lua_now_ms ++ lua_parse_join ++
        \\if redis.call('GET', KEYS[4]) ~= ARGV[8] then return -2 end
        \\local now = now_ms()
        \\local function take(flags)
        \\  redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[5])
        \\  redis.call('SET', KEYS[2], ARGV[3] .. '|' .. ARGV[4] .. '|' .. flags .. '|' .. string.format('%d', now), 'PX', ARGV[5])
        \\  redis.call('SADD', KEYS[3], ARGV[2])
        \\  redis.call('PEXPIRE', KEYS[3], ARGV[9])
        \\  redis.call('DEL', ARGV[7] .. 'charleft:' .. ARGV[2])
        \\end
        \\local holder = redis.call('GET', KEYS[1])
        \\if not holder then take('') return 0 end
        \\local g, s, f, at = parse_join(redis.call('GET', KEYS[2]))
        \\if not g or holder ~= ('game:' .. g) then return -1 end
        \\local loaded = string.find(f, 'D', 1, true) ~= nil
        \\local dead = (s == ARGV[4]) and not loaded
        \\if not dead and redis.call('EXISTS', ARGV[7] .. 'gamearrived:' .. g) == 1 then
        \\  local limit = loaded and ARGV[10] or ARGV[6]
        \\  dead = (now - at) > tonumber(limit) * 1000
        \\end
        \\if not dead then return -1 end
        \\redis.call('SREM', ARGV[7] .. 'gamechars:' .. g, ARGV[2])
        \\local counted = tonumber(redis.call('GET', ARGV[7] .. 'gamecounted:' .. g) or '0')
        \\take((g == ARGV[3]) and 'L' or '')
        \\return 'T' .. ((counted < at) and '1' or '0') .. g
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "4", lockkey, joinkey, setkey, idkey, owner, member, gid, sess, px, grace, prefix, safe, game_px, loaded_grace }) orelse return .held;
    return switch (rep) {
        .int => |v| if (v == 0) .claimed else if (v == -2) .gone else .held,
        .bulk => |b| blk: {
            const t = b orelse break :blk .held;
            if (t.len < 3 or t[0] != 'T') break :blk .held;
            const old = GameRef.parse(t[2..]) orelse break :blk .held;
            break :blk .{ .took_over = .{ .game = old, .counted = t[1] == '1' } };
        },
        else => .held,
    };
}

/// What an arrival did to the character's claim.
pub const Arrival = enum {
    /// Nothing to change: no pending claim of this game's to confirm.
    none,
    /// The pending claim is now a seat.
    confirmed,
    /// The claim had been withdrawn as abandoned and the character was free: it is this game's again.
    reclaimed,
    /// The character is claimed by ANOTHER game. It is in two places; the realm cannot undo that
    /// and the caller should say so.
    conflict,
};

/// The game server reports this character arrived in `gameid`: its claim stops being pending, and
/// the game is marked as one that reports arrivals. With no `account` (an older server) the member
/// is matched by name, and only when that match is unambiguous.
///
/// The server is the authority on who is in its game. An arrival for a character whose claim was
/// withdrawn as abandoned (a slow load, or an arrival held up in the event queue) takes the
/// character back for this game if nobody else has it, and only while the game is still indexed:
/// otherwise a player in the world would be free for a second login to take elsewhere.
pub fn confirmGameChar(game: GameRef, account: []const u8, charname: []const u8, game_ttl_s: u32, lock_ttl_s: u32) Arrival {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{x}.{d}", .{ game.gsid, game.gameid }) catch return .none;
    var ib: [32]u8 = undefined;
    const gid = std.fmt.bufPrint(&ib, "{x}.{d}", .{ game.gsid, game.gameid }) catch return .none;
    var tb: [16]u8 = undefined;
    const ttl = std.fmt.bufPrint(&tb, "{d}", .{game_ttl_s}) catch return .none;
    var xb: [64]u8 = undefined;
    const idkey = std.fmt.bufPrint(&xb, prefix ++ "game:byid:{x}.{d}", .{ game.gsid, game.gameid }) catch return .none;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, lock_ttl_s) * 1000}) catch return .none;
    const script = lua_parse_join ++
        \\redis.call('SET', ARGV[4] .. 'gamearrived:' .. ARGV[1], '1', 'EX', ARGV[5])
        \\local member = nil
        \\if ARGV[2] ~= '' then
        \\  member = ARGV[2] .. '/' .. ARGV[3]
        \\  if redis.call('SISMEMBER', KEYS[1], member) == 0 then
        \\    local lk = ARGV[4] .. 'charlock:' .. member
        \\    local tk = ARGV[4] .. 'charleft:' .. member
        \\    local holder = redis.call('GET', lk)
        \\    if holder then
        \\      if holder ~= 'game:' .. ARGV[1] then return 3 end
        \\      -- Ours, but the game's set lost it: put it back so a close still frees it.
        \\      redis.call('SADD', KEYS[1], member)
        \\      redis.call('EXPIRE', KEYS[1], ARGV[5])
        \\    else
        \\      if redis.call('GET', tk) ~= ARGV[1] or redis.call('EXISTS', KEYS[2]) == 0 then return 0 end
        \\      redis.call('SET', lk, 'game:' .. ARGV[1], 'PX', ARGV[6])
        \\      redis.call('SADD', KEYS[1], member)
        \\      redis.call('EXPIRE', KEYS[1], ARGV[5])
        \\      redis.call('DEL', tk)
        \\      return 2
        \\    end
        \\  end
        \\else
        \\  local n, sfx = 0, '/' .. ARGV[3]
        \\  for _, m in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\    if string.sub(m, -string.len(sfx)) == sfx then member = m n = n + 1 end
        \\  end
        \\  if n ~= 1 then return 0 end
        \\end
        \\local jk = ARGV[4] .. 'charjoin:' .. member
        \\local g = parse_join(redis.call('GET', jk))
        \\if g == ARGV[1] then
        \\  redis.call('DEL', jk)
        \\  return 1
        \\end
        \\return 0
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "2", key, idkey, gid, account, charname, prefix, ttl, px }) orelse return .none;
    return switch (rep) {
        .int => |v| switch (v) {
            1 => .confirmed,
            2 => .reclaimed,
            3 => .conflict,
            else => .none,
        },
        else => .none,
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

/// Claim a game name before the game exists. Without this, a second client could be told the
/// name is free, lose the create race at the server, and fail to join what it was just told
/// already exists. TTL is a backstop for a create that dies mid-flight; a successful create
/// replaces this with the game record.
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

/// Populate the cache from the store of record, but ONLY if nothing is cached yet. An
/// unconditional write could put OLDER bytes over a newer save that lands mid-miss. SET NX also
/// avoids locking the load: instances that miss together all read, one wins the write, the rest
/// discard what they read.
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

/// Free every character this game holds, and forget the pairing. Returns how many were freed.
///
/// Each release is still owner-checked: a character whose lease lapsed and was taken by another
/// game must not be freed by this one closing. Done in a single script so a character cannot be
/// claimed between the check and the delete.
pub fn releaseGameChars(game: GameRef, owner: []const u8) usize {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{x}.{d}", .{ game.gsid, game.gameid }) catch return 0;
    const script =
        \\local n = 0
        \\for _, m in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  local lk = ARGV[2] .. m
        \\  if redis.call('GET', lk) == ARGV[1] then
        \\    redis.call('DEL', lk)
        \\    redis.call('DEL', ARGV[3] .. 'charjoin:' .. m)
        \\    n = n + 1
        \\  end
        \\end
        \\redis.call('DEL', KEYS[1])
        \\redis.call('DEL', ARGV[3] .. 'gamearrived:' .. ARGV[4], ARGV[3] .. 'gamecounted:' .. ARGV[4])
        \\return n
    ;
    var ib: [32]u8 = undefined;
    const gid = std.fmt.bufPrint(&ib, "{x}.{d}", .{ game.gsid, game.gameid }) catch return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner, prefix ++ "charlock:", prefix, gid }) orelse return 0;
    return switch (rep) {
        .int => |v| @intCast(@max(v, 0)),
        else => 0,
    };
}

pub const LeasePass = struct {
    renewed: usize = 0,
    withdrawn: usize = 0,
    /// Of those withdrawn, how many still had their join's bump in the game's player count.
    uncount: usize = 0,
};

/// Renew the lease on every character this game holds.
///
/// The claim is a LEASE, not a permanent lock: `claimCharForJoin` takes it with a TTL so a game server
/// that dies without releasing cannot strand a character forever. That only works if something
/// renews it while the game is genuinely alive — otherwise the opposite failure appears, and it is
/// worse than the one the TTL prevents: the lease lapses under a running game, another game takes
/// the character, and two games hold one character with neither able to release the other's.
///
/// Owner-checked per member for that same reason, and done in one script so a character cannot be
/// taken between the check and the PEXPIRE.
///
/// A pending claim in a game that reports arrivals, older than `grace_s`, is a join that never
/// completed: it is withdrawn instead of renewed, so it cannot outlive its player for as long as
/// the game runs.
///
/// The game's character set is kept alive with it: it carries a TTL so a game that never reports a
/// close cannot leak it, and a game that outlives that TTL must not lose it, or its players' leases
/// stop being renewed while they play.
pub fn renewGameCharLeases(game: GameRef, owner: []const u8, ttl_s: u32, grace_s: u32, loaded_grace_s: u32, game_ttl_s: u32) LeasePass {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{x}.{d}", .{ game.gsid, game.gameid }) catch return .{};
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return .{};
    var ib: [32]u8 = undefined;
    const gid = std.fmt.bufPrint(&ib, "{x}.{d}", .{ game.gsid, game.gameid }) catch return .{};
    var tb: [16]u8 = undefined;
    const grace = std.fmt.bufPrint(&tb, "{d}", .{grace_s}) catch return .{};
    var gtb: [16]u8 = undefined;
    const game_ttl = std.fmt.bufPrint(&gtb, "{d}", .{game_ttl_s}) catch return .{};
    var lgb: [16]u8 = undefined;
    const loaded_grace = std.fmt.bufPrint(&lgb, "{d}", .{loaded_grace_s}) catch return .{};
    const script = lua_now_ms ++ lua_parse_join ++
        \\redis.call('EXPIRE', KEYS[1], ARGV[7])
        \\local n, w, u = 0, 0, 0
        \\local now = now_ms()
        \\local arrived = redis.call('EXISTS', ARGV[4] .. 'gamearrived:' .. ARGV[5]) == 1
        \\local counted = tonumber(redis.call('GET', ARGV[4] .. 'gamecounted:' .. ARGV[5]) or '0')
        \\for _, m in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  local lk = ARGV[3] .. m
        \\  if redis.call('GET', lk) == ARGV[1] then
        \\    local jk = ARGV[4] .. 'charjoin:' .. m
        \\    local g, _, f, at = parse_join(redis.call('GET', jk))
        \\    if g ~= ARGV[5] then at = nil end
        \\    local limit = (f and string.find(f, 'D', 1, true)) and ARGV[8] or ARGV[6]
        \\    if arrived and at and now - at > tonumber(limit) * 1000 then
        \\      redis.call('DEL', lk)
        \\      redis.call('DEL', jk)
        \\      redis.call('SREM', KEYS[1], m)
        \\      redis.call('SET', ARGV[4] .. 'charleft:' .. m, ARGV[5], 'PX', ARGV[2])
        \\      w = w + 1
        \\      if counted < at then u = u + 1 end
        \\    else
        \\      redis.call('PEXPIRE', lk, ARGV[2])
        \\      n = n + 1
        \\    end
        \\  end
        \\end
        \\return {n, w, u}
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner, px, prefix ++ "charlock:", prefix, gid, grace, game_ttl, loaded_grace }) orelse return .{};
    const len: usize = switch (rep) {
        .array_len => |n| if (n <= 0) return .{} else @intCast(n),
        else => return .{},
    };
    var out: [3]usize = .{ 0, 0, 0 };
    for (0..len) |i| {
        const e = readReply(&r) orelse {
            dropConn(s);
            return .{};
        };
        const v: i64 = switch (e) {
            .int => |x| x,
            else => 0,
        };
        if (i < out.len) out[i] = @intCast(@max(v, 0));
    }
    return .{ .renewed = out[0], .withdrawn = out[1], .uncount = out[2] };
}

/// Free one character this game holds, matched by name because that is all a departure carries.
/// Release the seat this game holds for exactly this character.
///
/// The unambiguous form of `releaseGameCharByName`, for a game server that told us which account
/// the departing player belongs to. Nothing is scanned and nothing is guessed: the member is
/// built, not matched, so a second character with the same name in the same game is untouched.
pub fn releaseGameCharExact(game: GameRef, account: []const u8, charname: []const u8, owner: []const u8) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{x}.{d}", .{ game.gsid, game.gameid }) catch return false;
    var mb: [96]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return false;
    var lb: [128]u8 = undefined;
    const lockkey = std.fmt.bufPrint(&lb, prefix ++ "charlock:{s}/{s}", .{ account, charname }) catch return false;
    var jb: [128]u8 = undefined;
    const joinkey = std.fmt.bufPrint(&jb, prefix ++ "charjoin:{s}/{s}", .{ account, charname }) catch return false;
    var tkb: [128]u8 = undefined;
    const leftkey = std.fmt.bufPrint(&tkb, prefix ++ charleft ++ "{s}/{s}", .{ account, charname }) catch return false;
    var ib: [32]u8 = undefined;
    const gid = std.fmt.bufPrint(&ib, "{x}.{d}", .{ game.gsid, game.gameid }) catch return false;
    // The lock is released only if this game still owns it — the same compare-and-swap every other
    // release does. A lapsed lease may already have been taken by somebody else, and a blind DEL
    // would free THEIR claim.
    //
    // A departure for a claim that took over an earlier attempt at this same game is that earlier
    // attempt's (see `lua_parse_join`), and is absorbed. The withdrawal marker goes either way: a
    // character that has left cannot be reclaimed by an arrival reported out of order.
    const script = lua_parse_join ++
        \\if redis.call('GET', KEYS[4]) == ARGV[3] then redis.call('DEL', KEYS[4]) end
        \\local g, s, f, at = parse_join(redis.call('GET', KEYS[3]))
        \\if g == ARGV[3] and string.find(f, 'L', 1, true) then
        \\  local rest = string.gsub(f, 'L', '')
        \\  redis.call('SET', KEYS[3], g .. '|' .. s .. '|' .. rest .. '|' .. string.format('%d', at), 'KEEPTTL')
        \\  return 0
        \\end
        \\if redis.call('SREM', KEYS[1], ARGV[2]) == 0 then return 0 end
        \\if redis.call('GET', KEYS[2]) == ARGV[1] then redis.call('DEL', KEYS[2]) redis.call('DEL', KEYS[3]) end
        \\return 1
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "4", key, lockkey, joinkey, leftkey, owner, member, gid }) orelse return false;
    return switch (rep) {
        .int => |v| v == 1,
        else => false,
    };
}

pub fn releaseGameCharByName(game: GameRef, charname: []const u8, owner: []const u8) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, prefix ++ "gamechars:{x}.{d}", .{ game.gsid, game.gameid }) catch return false;
    var sb: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&sb, "/{s}", .{charname}) catch return false;
    // Two passes, and the second only runs if the first found EXACTLY one match.
    //
    // Members are "account/charname" and the game server reports a departure by character name
    // alone — it never carries the account. Character names are only unique per account on this
    // realm, so a game can legitimately hold two members ending in "/Bob". Releasing the first the
    // set happens to yield (SMEMBERS is unordered) frees a lock belonging to a player who is still
    // in the world; another game then claims that character, both sessions write it, and whichever
    // finishes second silently discards the other. That is a rollback with no failure anywhere.
    //
    // Ambiguity therefore releases NOTHING. The lock lingers until the game ends, where
    // `releaseGameChars` frees everything the game held by gameid and needs no names at all — a
    // late release is a small delay, and the alternative is somebody else's character.
    var ib: [32]u8 = undefined;
    const gid = std.fmt.bufPrint(&ib, "{x}.{d}", .{ game.gsid, game.gameid }) catch return false;
    const script = lua_parse_join ++
        \\local hit, n = nil, 0
        \\for _, m in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  if string.sub(m, -string.len(ARGV[3])) == ARGV[3] then
        \\    hit = m
        \\    n = n + 1
        \\  end
        \\end
        \\if n ~= 1 then return 0 end
        \\local jk = ARGV[4] .. 'charjoin:' .. hit
        \\local g, s, f, at = parse_join(redis.call('GET', jk))
        \\if g == ARGV[5] and string.find(f, 'L', 1, true) then
        \\  local rest = string.gsub(f, 'L', '')
        \\  redis.call('SET', jk, g .. '|' .. s .. '|' .. rest .. '|' .. string.format('%d', at), 'KEEPTTL')
        \\  return 0
        \\end
        \\local lk = ARGV[2] .. hit
        \\if redis.call('GET', lk) == ARGV[1] then redis.call('DEL', lk) redis.call('DEL', ARGV[4] .. 'charjoin:' .. hit) end
        \\redis.call('SREM', KEYS[1], hit)
        \\return 1
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key, owner, prefix ++ "charlock:", suffix, prefix, gid }) orelse return false;
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

// the game-server fleet, as every instance sees it
//
// One key per server plus a set to enumerate them. The record carries a TTL refreshed on the
// control link's liveness traffic, so a dead realmd's servers drop out of the shared view
// without anyone having to notice and clean up.

fn gsKey(buf: []u8, gsid: u32) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "gs:{x}", .{gsid}) catch buf[0..0];
}

/// Publish (or refresh) one game server. Called on registration and whenever its load changes.
pub fn registerGs(rec: types.GsRec, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = gsKey(&kb, rec.gsid);
    if (key.len == 0) return false;
    // ip[4] ++ port(u16) ++ maxgame(u32) ++ live(u32) ++ full(u8) = 15 bytes, then the server's
    // labels. The tail is append-only for a reason: a reader that predates it stops at 15 and is
    // unaffected, and the Lua that decrements the live count keeps everything from byte 15 on.
    var vb: [15 + types.labels_max]u8 = undefined;
    @memcpy(vb[0..4], &rec.gs_ip);
    std.mem.writeInt(u16, vb[4..6], rec.gs_port, .little);
    std.mem.writeInt(u32, vb[6..10], rec.maxgame, .little);
    std.mem.writeInt(u32, vb[10..14], rec.live_games, .little);
    vb[14] = @intFromBool(rec.full);
    @memcpy(vb[15..][0..rec.labels_len], rec.labels[0..rec.labels_len]);
    const val = vb[0 .. 15 + @as(usize, rec.labels_len)];

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
        c.add(&.{ "SET", key, val, "PX", px });
    } else {
        c.add(&.{ "SET", key, val });
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

// dispatch
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

// events (game server -> realm)
//
// Create and join are requests with an answer, so they are a queue plus a reply key. A player
// joining or leaving, and a game ending, are neither: the server is telling the realm something
// already true, and nobody is waiting on it. They go onto one shared list that any instance
// drains, which is what lets the server report to "the realm" rather than to whichever realmd it
// happens to hold a socket to.
//
// Order is preserved per server because a list is a list, and that is the only ordering that
// matters: two events about the same game come from the same server.

const gs_event_key = prefix ++ "gsev";

/// Report something that happened on a game server. `cap` bounds the list so a realm with nothing
/// running does not accumulate events forever — the oldest go first, since a player who left an
/// hour ago is not news.
pub fn pushGsEvent(packet: []const u8, cap: u32, ttl_s: u32) bool {
    var cb: [16]u8 = undefined;
    const keep = std.fmt.bufPrint(&cb, "-{d}", .{cap}) catch return false;
    var pb: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&pb, "{d}", .{ttl_s}) catch return false;

    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return false;
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "RPUSH", gs_event_key, packet });
    c.add(&.{ "LTRIM", gs_event_key, keep, "-1" });
    c.add(&.{ "EXPIRE", gs_event_key, secs });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return false;
    }
    var r: Reader = .{ .fd = fd };
    for (0..3) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            return false;
        }
    }
    return true;
}

/// Take the next game-server event, oldest first. Null when there is nothing to apply.
///
/// Consumed as it is read, so exactly one instance applies each event. That is safe because every
/// event here is idempotent in effect but not in accounting — a close applied twice would decrement
/// a count that had already gone.
pub fn popGsEvent(out: []u8) ?usize {
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "LPOP", gs_event_key }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            if (v.len > out.len) break :blk null;
            @memcpy(out[0..v.len], v);
            break :blk v.len;
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

/// `pickAndReserveGs`, restricted to servers that publish `key=value` among their labels.
///
/// This is how a fleet running several engines stays usable: a 1.09d character's game has to land
/// on a 1.09d server or the client is handed a world it cannot parse, and "emptiest server" is the
/// wrong answer to that question. Null means no server both matches and has room — a different
/// thing from "the fleet is full", and the caller says so differently.
///
/// A server that does not publish the label at all does not match, deliberately: the alternative
/// is that one unlabelled server answers every request, which is exactly the mis-routing this
/// exists to prevent.
pub fn pickAndReserveGsMatching(key: []const u8, value: []const u8) ?u32 {
    const script =
        \\local want = '\n' .. ARGV[1] .. '=' .. ARGV[2] .. '\n'
        \\local best, bestload
        \\for _, id in ipairs(redis.call('SMEMBERS', KEYS[1])) do
        \\  local rec = redis.call('GET', KEYS[2] .. id)
        \\  if rec and #rec >= 15 then
        \\    local function u32(o)
        \\      return string.byte(rec,o) + string.byte(rec,o+1)*256
        \\           + string.byte(rec,o+2)*65536 + string.byte(rec,o+3)*16777216
        \\    end
        \\    local maxgame, live, full = u32(7), u32(11), string.byte(rec,15)
        \\    local labels = '\n' .. string.sub(rec,16) .. '\n'
        \\    if full == 0 and (maxgame == 0 or live < maxgame) and
        \\       string.find(labels, want, 1, true) then
        \\      if not bestload or live < bestload then best, bestload = id, live end
        \\    end
        \\  end
        \\end
        \\if not best then return false end
        \\local k = KEYS[2] .. best
        \\local rec = redis.call('GET', k)
        \\local live = string.byte(rec,11) + string.byte(rec,12)*256
        \\          + string.byte(rec,13)*65536 + string.byte(rec,14)*16777216
        \\live = live + 1
        \\local b = string.char(live % 256, math.floor(live/256) % 256,
        \\                      math.floor(live/65536) % 256, math.floor(live/16777216) % 256)
        \\redis.call('SET', k, string.sub(rec,1,10) .. b .. string.sub(rec,15), 'KEEPTTL')
        \\return best
    ;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "2", prefix ++ "gs", prefix ++ "gs:", key, value }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            break :blk std.fmt.parseInt(u32, v, 16) catch null;
        },
        else => null,
    };
}

/// Reserve a slot on ONE named server, the way `pickAndReserveGs` reserves on the one it chose.
/// False when that server is gone, is flagged full, or has no room — which is the whole point: a
/// caller that picked its own server still has to lose the same races the stock pick loses, or the
/// choice would be a way to overfill a server rather than a way to place a game.
///
/// This exists so an extension can decide WHICH server hosts a game (fleet.pickGs) without giving
/// up the atomic reserve; returning a gsid from a snapshot and reserving it in a second round trip
/// would let two instances both place a game on the last free slot.
pub fn reserveGs(gsid: u32) bool {
    const script =
        \\local rec = redis.call('GET', KEYS[1])
        \\if not rec or #rec < 15 then return 0 end
        \\local function u32(o)
        \\  return string.byte(rec,o) + string.byte(rec,o+1)*256
        \\       + string.byte(rec,o+2)*65536 + string.byte(rec,o+3)*16777216
        \\end
        \\local maxgame, live, full = u32(7), u32(11), string.byte(rec,15)
        \\if full ~= 0 then return 0 end
        \\if maxgame ~= 0 and live >= maxgame then return 0 end
        \\live = live + 1
        \\local b = string.char(live % 256, math.floor(live/256) % 256,
        \\                      math.floor(live/65536) % 256, math.floor(live/16777216) % 256)
        \\redis.call('SET', KEYS[1], string.sub(rec,1,10) .. b .. string.sub(rec,15), 'KEEPTTL')
        \\return 1
    ;
    var kb: [64]u8 = undefined;
    const key = gsKey(&kb, gsid);
    if (key.len == 0) return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "EVAL", script, "1", key }) orelse return false;
    return switch (rep) {
        .int => |i| i == 1,
        else => false,
    };
}

/// Give back a slot reserved by `pickAndReserveGs` when the create it was for did not happen.
///
/// Without this the reservation stands until the server's next heartbeat overwrites the count with
/// the truth, and in that window a server can be passed over for games it has room for. Floors at
/// zero and KEEPTTLs for the same reasons the reservation does.
pub fn releaseGsSlot(gsid: u32) void {
    const script =
        \\local rec = redis.call('GET', KEYS[1])
        \\if not rec or #rec < 15 then return 0 end
        \\local live = string.byte(rec,11) + string.byte(rec,12)*256
        \\          + string.byte(rec,13)*65536 + string.byte(rec,14)*16777216
        \\if live == 0 then return 0 end
        \\live = live - 1
        \\local b = string.char(live % 256, math.floor(live/256) % 256,
        \\                      math.floor(live/65536) % 256, math.floor(live/16777216) % 256)
        \\redis.call('SET', KEYS[1], string.sub(rec,1,10) .. b .. string.sub(rec,15), 'KEEPTTL')
        \\return 1
    ;
    var kb: [64]u8 = undefined;
    const key = gsKey(&kb, gsid);
    if (key.len == 0) return;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    _ = command(s, &r, &.{ "EVAL", script, "1", key });
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
        // Anything past the fixed part is what the server says it is. A record written before
        // labels existed simply has none, which reads as "matches no requirement".
        if (val.len > 15) out[n].setLabels(val[15..]);
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

/// Bound on one fleet snapshot.
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

// housekeeping

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

// chat (cross-instance)
//
// Chat used to be a process-global table keyed by socket, which made two realmd instances two
// disjoint channels wearing the same name: talk did not cross, a whisper could not find someone
// on the other instance, and the user list showed half the room. None of that degrades visibly —
// it just looks like the other players are not there.
//
// So the room lives here and the sockets stay local. Each instance keeps its own members (it owns
// their connections) and publishes them into a per-channel hash; anything that has to reach a
// member somewhere else is handed to that instance's inbox. Local delivery never makes a round
// trip, which keeps the common case — everyone in one channel on one instance — exactly as fast
// as it was.
//
// The records are opaque here on purpose: their shape is chat's business, and this module has no
// reason to know what a statstring is.

fn chanKey(buf: []u8, channel: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "chan:{s}", .{channel}) catch null;
}

fn chatUserKey(buf: []u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "chatuser:{s}", .{name}) catch null;
}

/// Publish a member: into the channel's roster, and into a by-name index so a whisper can find
/// which instance holds them without reading every channel.
///
/// The index carries a TTL and the caller refreshes it; that is what makes an instance which died
/// without tidying up disappear rather than haunting the roster forever.
pub fn chatPutMember(channel: []const u8, name: []const u8, rec: []const u8, ttl_s: u32) bool {
    var ck: [96]u8 = undefined;
    var uk: [96]u8 = undefined;
    const chan = chanKey(&ck, channel) orelse return false;
    const user = chatUserKey(&uk, name) orelse return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;

    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return false;
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "HSET", chan, name, rec });
    c.add(&.{ "SET", user, rec, "PX", px });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return false;
    }
    var r: Reader = .{ .fd = fd };
    for (0..2) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            return false;
        }
    }
    return true;
}

/// Refresh only the by-name index, without putting them in a channel roster. A player who went
/// off to a game, or left the channel, is still online and still whisperable — they are just not
/// in the room any more, so channel talk must stop reaching them while /whois keeps working.
pub fn chatPutIndex(name: []const u8, rec: []const u8, ttl_s: u32) bool {
    var uk: [96]u8 = undefined;
    const user = chatUserKey(&uk, name) orelse return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    return command(s, &r, &.{ "SET", user, rec, "PX", px }) != null;
}

/// Take a member out of a channel. Called on leave, on disconnect, and when someone goes off to
/// play — a player in a game is still connected but is not in the room.
pub fn chatDelMember(channel: []const u8, name: []const u8, drop_index: bool) void {
    var ck: [96]u8 = undefined;
    var uk: [96]u8 = undefined;
    const chan = chanKey(&ck, channel) orelse return;
    const user = chatUserKey(&uk, name) orelse return;
    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return;
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "HDEL", chan, name });
    if (drop_index) c.add(&.{ "DEL", user });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return;
    }
    var r: Reader = .{ .fd = fd };
    for (0..(if (drop_index) @as(usize, 2) else 1)) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            return;
        }
    }
}

/// Everyone in a channel, across every instance. `cb` is called per member with the name and its
/// record; both point into a shared buffer and are only valid for that call.
pub fn chatRoster(channel: []const u8, ctx: anytype, cb: *const fn (@TypeOf(ctx), []const u8, []const u8) void) usize {
    var ck: [96]u8 = undefined;
    const chan = chanKey(&ck, channel) orelse return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "HGETALL", chan }) orelse return 0;
    const count = switch (rep) {
        .array_len => |n| if (n <= 0) return 0 else @as(usize, @intCast(n)),
        else => return 0,
    };
    // HGETALL returns a flat field,value,field,value stream.
    var namebuf: [64]u8 = undefined;
    var namelen: usize = 0;
    var n: usize = 0;
    for (0..count) |i| {
        const er = readReply(&r) orelse {
            dropConn(s);
            return n;
        };
        const v = switch (er) {
            .bulk => |b| b orelse continue,
            else => continue,
        };
        if (i % 2 == 0) {
            namelen = @min(v.len, namebuf.len);
            @memcpy(namebuf[0..namelen], v[0..namelen]);
        } else {
            cb(ctx, namebuf[0..namelen], v);
            n += 1;
        }
    }
    return n;
}

/// How many are in a channel, realm-wide. Its own call because deciding who gets channel-operator
/// needs a count and nothing else.
pub fn chatChannelSize(channel: []const u8) usize {
    var ck: [96]u8 = undefined;
    const chan = chanKey(&ck, channel) orelse return 0;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "HLEN", chan }) orelse return 0;
    return switch (rep) {
        .int => |v| if (v > 0) @intCast(v) else 0,
        else => 0,
    };
}

/// Find one member by name, wherever they are. Null when nobody by that name is online.
pub fn chatFindMember(name: []const u8, out: []u8) ?usize {
    var uk: [96]u8 = undefined;
    const user = chatUserKey(&uk, name) orelse return null;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "GET", user }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            if (v.len > out.len) break :blk null;
            @memcpy(out[0..v.len], v);
            break :blk v.len;
        },
        else => null,
    };
}

fn chatInboxKey(buf: []u8, instance: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "chatin:{x}", .{instance}) catch null;
}

/// Hand an event to another instance to deliver to its own members.
pub fn chatPush(instance: u32, packet: []const u8, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = chatInboxKey(&kb, instance) orelse return false;
    var pb: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&pb, "{d}", .{ttl_s}) catch return false;
    const s = acquire();
    defer release(s);
    const fd = s.fd orelse ensureConn(s) orelse return false;
    var c = CmdBuf{ .fd = fd };
    c.add(&.{ "RPUSH", key, packet });
    // A chat line nobody drained is worthless in a minute's time, and an inbox for an instance
    // that has gone must not grow without bound.
    c.add(&.{ "EXPIRE", key, secs });
    c.flush();
    if (!c.ok) {
        dropConn(s);
        return false;
    }
    var r: Reader = .{ .fd = fd };
    for (0..2) |_| {
        if (readReply(&r) == null) {
            dropConn(s);
            return false;
        }
    }
    return true;
}

/// Take the next event addressed to this instance.
pub fn chatPop(instance: u32, out: []u8) ?usize {
    var kb: [64]u8 = undefined;
    const key = chatInboxKey(&kb, instance) orelse return null;
    const s = acquire();
    defer release(s);
    var r: Reader = undefined;
    const rep = command(s, &r, &.{ "LPOP", key }) orelse return null;
    return switch (rep) {
        .bulk => |b| blk: {
            const v = b orelse break :blk null;
            if (v.len > out.len) break :blk null;
            @memcpy(out[0..v.len], v);
            break :blk v.len;
        },
        else => null,
    };
}
