//! Redis, from inside the game server. Built x86-windows against `realm_proto`/`resp`/`obs`,
//! deliberately not `realm_infra`, so libc sockets never enter this build — framing lives in
//! `packages/resp` as a pure codec shared with realmd's parser, this file is only the socket half.
//! One connection, opened lazily and dropped on any IO error so the next call reconnects. Called
//! from the engine's own thread while servicing a game, so it must never block forever: the
//! socket carries a receive timeout and a failed op returns rather than retrying mid-tick.
const std = @import("std");
const resp = @import("resp");
const savequeue = @import("savequeue.zig");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const SOL_SOCKET: i32 = 0xffff;
const SO_RCVTIMEO: i32 = 0x1006;
const SO_SNDTIMEO: i32 = 0x1005;

const sockaddr_in = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8 = [_]u8{0} ** 8,
};

extern "ws2_32" fn socket(af: i32, t: i32, proto: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, name: i32, val: [*]const u8, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn htons(v: u16) callconv(.winapi) u16;
extern "ws2_32" fn inet_addr(cp: [*:0]const u8) callconv(.winapi) u32;
extern "ws2_32" fn gethostbyname(name: [*:0]const u8) callconv(.winapi) ?*const hostent;

/// Winsock's `hostent`. Only the address list is read; the rest is here so the offsets are right.
const hostent = extern struct {
    h_name: ?[*:0]const u8,
    h_aliases: ?[*]const ?[*:0]const u8,
    h_addrtype: i16,
    h_length: i16,
    h_addr_list: ?[*]const ?*const u32,
};
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount() callconv(.winapi) u32;

const INADDR_NONE: u32 = 0xffff_ffff;

/// Long enough that a busy redis is not mistaken for a dead one, short enough that a wedged
/// connection cannot stall a game's tick for a noticeable time.
const io_timeout_ms: u32 = 2000;

/// One connection, more than one thread reaching for it (heartbeat on the server tick, character
/// fetch on the join path); an interleaved command/reply cycle desyncs the connection — observed
/// as joins failing with the character sitting readable in redis, once the d2dbs fallback was
/// removed. Spin-with-yield rather than a real lock: contention is light, and the DLL has no lock
/// primitive of its own (realm_infra, which has one, is deliberately not in this build).
var busy = std.atomic.Value(bool).init(false);

fn lock() void {
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) Sleep(0);
}

fn unlock() void {
    busy.store(false, .release);
}

var host_buf: [256]u8 = [_]u8{0} ** 256;
var host_len: usize = 0;
var port: u16 = 6379;
var sock: SOCKET = INVALID_SOCKET;
var configured = false;

/// `addr` is "host:port". The host may be a dotted quad or a name — in a cluster it is a Service
/// name, and resolving it is this file's job: a GS that cannot reach the store never publishes
/// itself, so it stays out of the fleet and takes no games, silently.
/// A stable id for one game server in the fleet: the host name this process runs under, together
/// with the game port it owns.
///
/// Stable across restarts, because the realm indexes live games by it — and distinct per server,
/// which the host name alone is not: two servers on one machine hash identically and the second
/// to register silently replaces the first. The port is what separates them and is equally stable.
/// A machine with no name to give falls back to its public address, which identifies it just as
/// well.
///
/// It lives here rather than in either server because both publish into the same fleet. Two
/// derivations that drift apart give two servers the same id, and the symptom is one of them
/// disappearing from a realm that never logged anything wrong.
pub fn fleetId(host_name: []const u8, public_ip: [4]u8, gs_port: u16) u32 {
    var buf: [264]u8 = undefined;
    var n: usize = 0;
    if (host_name.len != 0 and host_name.len <= 256) {
        @memcpy(buf[0..host_name.len], host_name);
        n = host_name.len;
    } else {
        buf[0..4].* = public_ip;
        n = 4;
    }
    std.mem.writeInt(u16, buf[n..][0..2], gs_port, .little);
    var h: u32 = 2166136261;
    for (buf[0 .. n + 2]) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

pub fn configure(addr: []const u8) void {
    var host = addr;
    if (std.mem.lastIndexOfScalar(u8, addr, ':')) |i| {
        host = addr[0..i];
        port = std.fmt.parseInt(u16, addr[i + 1 ..], 10) catch 6379;
    }
    if (host.len == 0 or host.len >= host_buf.len) return;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    host_len = host.len;
    configured = true;
}

pub fn enabled() bool {
    return configured;
}

fn drop() void {
    if (sock != INVALID_SOCKET) {
        _ = closesocket(sock);
        sock = INVALID_SOCKET;
    }
}

/// The configured host as a network-order IPv4, by literal first and by name second. Not cached:
/// a Service name outlives the address behind it, and one lookup per reconnect is nothing next to
/// the connect it precedes.
fn resolve() ?u32 {
    const literal = inet_addr(@ptrCast(&host_buf));
    if (literal != INADDR_NONE) return literal;
    const ent = gethostbyname(@ptrCast(&host_buf)) orelse return null;
    if (@as(i32, ent.h_addrtype) != AF_INET or ent.h_length != 4) return null;
    const list = ent.h_addr_list orelse return null;
    const first = list[0] orelse return null;
    return first.*;
}

fn ensure() ?SOCKET {
    if (sock != INVALID_SOCKET) return sock;
    if (!configured) return null;
    const s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return null;
    const ip = resolve() orelse {
        _ = closesocket(s);
        return null;
    };
    // Both directions: a send that blocks forever wedges the tick just as surely as a read.
    const tv = std.mem.toBytes(io_timeout_ms);
    _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(u32));
    _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, @sizeOf(u32));
    const sa = sockaddr_in{ .family = AF_INET, .port = htons(port), .addr = ip };
    if (connect(s, &sa, @sizeOf(sockaddr_in)) != 0) {
        _ = closesocket(s);
        return null;
    }
    sock = s;
    return s;
}

fn sendAll(s: SOCKET, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(s, bytes.ptr + off, @intCast(bytes.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// A reply and the buffer it points into. Slices are only valid until the next call.
pub const Reply = struct {
    value: resp.Reply,
    /// Bytes consumed from the read buffer — internal, but kept so a caller reading a pipeline
    /// can tell a short reply from a long one.
    len: usize,
};

var rx: [16384]u8 = undefined;

/// Send one command and read one reply. Null on any IO or framing failure, with the connection
/// dropped so the next call starts clean — a desynced connection can never be reasoned about.
pub fn command(args: []const []const u8) ?Reply {
    lock();
    defer unlock();
    const s = ensure() orelse return null;
    var tx: [1024]u8 = undefined;
    // A command whose arguments do not fit is a programming error here, not a runtime condition:
    // the large payload path (a character save) uses `commandBig`.
    const wire = resp.encode(&tx, args) orelse return null;
    if (!sendAll(s, wire)) {
        drop();
        return null;
    }
    return readReply(s);
}

/// Same, but the LAST argument may be arbitrarily large — a .d2s save is bigger than any sane
/// command buffer, so its header is encoded and the payload streamed straight after it.
pub fn commandBig(head: []const []const u8, tail: []const u8) ?Reply {
    lock();
    defer unlock();
    const s = ensure() orelse return null;
    var tx: [1024]u8 = undefined;
    var n: usize = 0;
    // Array header counts every argument, including the streamed one.
    n += (std.fmt.bufPrint(tx[n..], "*{d}\r\n", .{head.len + 1}) catch return null).len;
    for (head) |a| {
        n += (std.fmt.bufPrint(tx[n..], "${d}\r\n", .{a.len}) catch return null).len;
        if (n + a.len + 2 > tx.len) return null;
        @memcpy(tx[n..][0..a.len], a);
        n += a.len;
        tx[n] = '\r';
        tx[n + 1] = '\n';
        n += 2;
    }
    n += (std.fmt.bufPrint(tx[n..], "${d}\r\n", .{tail.len}) catch return null).len;
    if (!sendAll(s, tx[0..n]) or !sendAll(s, tail) or !sendAll(s, "\r\n")) {
        drop();
        return null;
    }
    return readReply(s);
}

fn readReply(s: SOCKET) ?Reply {
    var fill: usize = 0;
    while (true) {
        switch (resp.parse(rx[0..fill])) {
            .ok => |o| return .{ .value = o.reply, .len = o.consumed },
            .need_more => {
                if (fill == rx.len) {
                    drop(); // a reply larger than the buffer; we cannot resynchronise
                    return null;
                }
                const n = recv(s, rx[fill..].ptr, @intCast(rx.len - fill), 0);
                if (n <= 0) {
                    drop();
                    return null;
                }
                fill += @intCast(n);
            },
            .invalid => {
                drop();
                return null;
            },
        }
    }
}

// the operations the game server actually needs

/// A character as this server took it: the bytes, and the store version they were at.
pub const Loaded = struct {
    len: usize,
    /// The value of `realmd:charver:<a>/<c>` when these bytes were read. Every save this server
    /// later makes is fenced against it, so a save built from THESE bytes can never land on top of
    /// somebody else's newer ones. 0 means the store had no version — a character that has never
    /// been saved, or a redis that lost its state.
    ver: u64,
};

/// Read a character and the version it is at.
///
/// The VERSION IS READ FIRST, and that order is the whole point. Read the other way round, a save
/// landing between the two reads gives us its bytes while we record the older version — and the
/// fence would then happily let us overwrite those newer bytes with something built from them.
/// This way the same race gives us a version older than our bytes, and our next save is refused:
/// conservative, which is the direction a save fence must fail in.
pub fn getCharVersioned(account: []const u8, charname: []const u8, out: []u8) Loaded {
    const ver = charVersion(account, charname);
    return .{ .len = getChar(account, charname, out), .ver = ver };
}

/// The store's current version for a character, 0 if it has none.
pub fn charVersion(account: []const u8, charname: []const u8) u64 {
    var vb: [192]u8 = undefined;
    const verkey = std.fmt.bufPrint(&vb, "realmd:charver:{s}/{s}", .{ account, charname }) catch return 0;
    const rep = command(&.{ "GET", verkey }) orelse return 0;
    return switch (rep.value) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            break :blk std.fmt.parseInt(u64, v, 10) catch 0;
        },
        else => 0,
    };
}

/// Fetch a character save into `out`, returning its length. 0 if absent or unreadable.
pub fn getChar(account: []const u8, charname: []const u8, out: []u8) usize {
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ account, charname }) catch return 0;
    const rep = command(&.{ "GET", key }) orelse return 0;
    return switch (rep.value) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            const n = @min(v.len, out.len);
            // A save that does not fit is reported as absent rather than truncated: a short read
            // stored anywhere becomes a corrupt character, which is worse than a failed load.
            if (v.len > out.len) break :blk 0;
            @memcpy(out[0..n], v[0..n]);
            break :blk n;
        },
        else => 0,
    };
}

/// The characters realmd's `sanitize` accepts in a key. A name outside this set is one realmd
/// will refuse to read back, so writing it here would store a save at an address the login path
/// can never reach — the same silent rollback as writing under the wrong account, one step
/// further along. Refuse it on this side too, where the save still exists to complain about.
pub fn keyable(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// What happened to a fenced save.
pub const SaveResult = union(enum) {
    /// Stored; the character is now at this version.
    stored: u64,
    /// REFUSED because the store has moved on: somebody wrote this character after we loaded it.
    /// Our bytes are older than what is there, and writing them would be a rollback. Never retry
    /// one of these — the save is genuinely obsolete.
    stale: u64,
    /// The store could not be reached or did not answer. Nothing is known and nothing was written;
    /// this one IS worth retrying.
    unavailable,
};

/// Store a character save, but only if nothing has written it since we loaded it.
///
/// This is the mechanism that makes a rollback structurally impossible rather than merely
/// unlikely. Every other guard in this repo — the seat table, the retry queue's age bound, the
/// character lock, refusing to delete a character in a game — narrows the ways older bytes can
/// reach the store. This one closes the question: the store itself will not accept them.
///
/// `expect` is the version this server read with the character. The whole compare-set-increment
/// runs inside redis, so nothing can interleave between the check and the write.
///
/// A current version of ZERO is accepted whatever `expect` says. It means the store has no version
/// for this character: either it has never been saved, or redis lost its state and was refilled
/// from postgres. In both cases a live session's bytes are the newest thing in existence, and
/// refusing them would turn a cache flush into the very data loss this exists to prevent. The
/// realm's character lock is what keeps two servers from being in that position at once.
pub fn putCharFenced(account: []const u8, charname: []const u8, save: []const u8, expect: u64) SaveResult {
    if (!keyable(account) or !keyable(charname)) return .unavailable;
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ account, charname }) catch return .unavailable;
    var vb: [192]u8 = undefined;
    const verkey = std.fmt.bufPrint(&vb, "realmd:charver:{s}/{s}", .{ account, charname }) catch return .unavailable;
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, "realmd:chars:{s}", .{account}) catch return .unavailable;
    var mb: [192]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return .unavailable;
    var eb: [24]u8 = undefined;
    const expect_s = std.fmt.bufPrint(&eb, "{d}", .{expect}) catch return .unavailable;

    // Returns the new version on success, or -(current+1) when it refuses, so the caller learns
    // what the store is actually at without a second round trip.
    const script =
        \\local cur = tonumber(redis.call('GET', KEYS[2]) or '0')
        \\if cur ~= 0 and cur ~= tonumber(ARGV[1]) then return -(cur + 1) end
        \\redis.call('SET', KEYS[1], ARGV[4])
        \\redis.call('SADD', KEYS[3], ARGV[2])
        \\redis.call('SADD', KEYS[4], ARGV[3])
        \\return redis.call('INCR', KEYS[2])
    ;
    const rep = commandBig(&.{
        "EVAL",         script,  "4",     key,
        verkey,         setkey,  "realmd:dirty",
        expect_s,       charname, member,
    }, save) orelse return .unavailable;
    return switch (rep.value) {
        .int => |v| if (v > 0)
            .{ .stored = @intCast(v) }
        else
            .{ .stale = @intCast(-v - 1) },
        else => .unavailable,
    };
}

/// Store a character save and mark it for the realm's flush worker. Both, or neither — a save
/// redis takes but nobody is told about would sit there while postgres fell behind.
///
/// The account's character set is written too. realmd's own save does it (`saveCharD2s`: SET +
/// SADD), and that set is what `listChars` reads: a character whose newest bytes are only in
/// redis and whose name is not in the set is one the character screen does not list until
/// postgres catches up.
pub fn putChar(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    if (!keyable(account) or !keyable(charname)) return false;
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ account, charname }) catch return false;
    const set = commandBig(&.{ "SET", key }, bytes) orelse return false;
    switch (set.value) {
        .status, .int => {},
        .bulk => |b| if (b == null) return false,
        else => return false,
    }
    var sb: [192]u8 = undefined;
    const setkey = std.fmt.bufPrint(&sb, "realmd:chars:{s}", .{account}) catch return false;
    _ = command(&.{ "SADD", setkey, charname }) orelse return false;
    var vb: [192]u8 = undefined;
    const verkey = std.fmt.bufPrint(&vb, "realmd:charver:{s}/{s}", .{ account, charname }) catch return false;
    _ = command(&.{ "INCR", verkey }) orelse return false;
    var mb: [128]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return false;
    _ = command(&.{ "SADD", "realmd:dirty", member }) orelse return false;
    return true;
}

/// Store a character save, and if the store will not take it, keep it and try again.
///
/// This is what every save path should call. `putChar` alone reports a failure the caller can only
/// log: the bytes belong to a buffer the engine is about to reuse, so a store that blinked for
/// half a second costs a player their session — and on the way out of a game there is no later
/// save to make up for it. Parking them costs a few KB and makes the failure a delay.
///
/// The return value is whether it is DURABLE NOW, not whether it is safe: false with `pending()`
/// non-zero means it is queued, false with `park` having refused means it really is gone, which is
/// the only case worth shouting about.
pub fn putCharDurable(account: []const u8, charname: []const u8, save: []const u8, expect: u64) SaveResult {
    const r = putCharFenced(account, charname, save, expect);
    switch (r) {
        .stored => {
            // A success supersedes anything queued for this character: retrying an older save on
            // top of a newer one is a rollback caused by the retry machinery itself.
            savequeue.drop(account, charname, save.len);
        },
        .stale => {
            // Genuinely obsolete. Queueing it would be queueing a rollback, and anything already
            // queued for this character is at least as obsolete, so that goes too.
            savequeue.drop(account, charname, save.len);
        },
        .unavailable => _ = savequeue.park(account, charname, save, expect, GetTickCount()),
    }
    return r;
}

/// How many saves are waiting for the store to come back. Zero on a healthy server.
pub fn pending() usize {
    return savequeue.depth();
}

/// Retry one queued save. Call from the server's own tick; one per tick is plenty, because the
/// queue is only ever non-empty while the store is unwell and hammering it does not help.
///
/// Returns true if one was stored, so a caller can drain faster while it is making progress.
pub fn retryPending() bool {
    var acct: [32]u8 = undefined;
    var name: [24]u8 = undefined;
    var save: [savequeue.max_bytes]u8 = undefined;
    const p = savequeue.peek(&acct, &name, &save, GetTickCount()) orelse return false;
    // Retried under the SAME fence it was parked with, so a queued save is no more able to
    // overwrite a newer one than a fresh save is. A refusal means the character moved on while we
    // were unable to write, and the queued bytes are obsolete: drop them rather than spin.
    switch (putCharFenced(p.account, p.charname, p.save, p.expect)) {
        .stored, .stale => {
            savequeue.drop(p.account, p.charname, p.save.len);
            return true;
        },
        .unavailable => return false,
    }
}

/// Publish this server's heartbeat: it exists, where clients reach it, and how loaded it is.
/// The TTL is what makes a server that dies disappear without anyone having to notice.
/// Publish this server into the realm's view. `labels` is what it says it IS — `k=v` pairs
/// separated by newlines, `v=<engine>` first — appended after the fixed part so a realm that
/// predates labels reads the record unchanged. A fleet hosting more than one engine is not
/// interchangeable, and this is how the realm can ask for the right one instead of the free one.
pub fn putHeartbeat(gsid: u32, ip: [4]u8, gs_port: u16, maxgame: u32, live: u32, full: bool, ttl_s: u32, labels: []const u8) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gs:{x}", .{gsid}) catch return false;
    var vb: [15 + 96]u8 = undefined;
    @memcpy(vb[0..4], &ip);
    std.mem.writeInt(u16, vb[4..6], gs_port, .little);
    std.mem.writeInt(u32, vb[6..10], maxgame, .little);
    std.mem.writeInt(u32, vb[10..14], live, .little);
    vb[14] = @intFromBool(full);
    const nlab = @min(labels.len, vb.len - 15);
    @memcpy(vb[15..][0..nlab], labels[0..nlab]);
    const val = vb[0 .. 15 + nlab];
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const rep = command(&.{ "SET", key, val, "PX", px }) orelse return false;
    switch (rep.value) {
        .status, .int => {},
        .bulk => |b| if (b == null) return false,
        else => return false,
    }
    var idb: [16]u8 = undefined;
    const idstr = std.fmt.bufPrint(&idb, "{x}", .{gsid}) catch return false;
    _ = command(&.{ "SADD", "realmd:gs", idstr }) orelse return false;
    return true;
}

/// Take the next request queued for this server, or 0 if there is none.
///
/// Polled from the server tick rather than blocked on: a blocking pop would hold the connection
/// this server also uses to fetch characters and publish itself, and the tick is frequent enough
/// that a poll costs a client nothing it can perceive.
pub fn popRequest(gsid: u32, out: []u8) usize {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gsq:{x}", .{gsid}) catch return 0;
    const rep = command(&.{ "LPOP", key }) orelse return 0;
    return switch (rep.value) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            if (v.len > out.len) break :blk 0;
            @memcpy(out[0..v.len], v);
            break :blk v.len;
        },
        else => 0,
    };
}

/// Answer a request, keyed by the seq that came in its header. Short-lived: the realm is waiting
/// on it right now, and a reply nobody collected is of no use to anyone later.
pub fn putReply(seq: u32, packet: []const u8, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gsreply:{x}", .{seq}) catch return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const rep = commandBig(&.{ "SET", key }, packet) orelse return false;
    _ = command(&.{ "PEXPIRE", key, px }) orelse return false;
    return switch (rep.value) {
        .status, .int => true,
        .bulk => |b| b != null,
        else => false,
    };
}

/// Report something that happened here — a player entering or leaving, a game ending. Unlike a
/// create or a join there is no answer to wait for and nobody in particular to tell, so it goes
/// onto one list any realmd drains.
///
/// `cap` bounds the list against a realm with nothing running: the oldest go first, because a
/// player who left an hour ago is not news.
pub fn pushEvent(packet: []const u8, cap: u32, ttl_s: u32) bool {
    const rep = commandBig(&.{ "RPUSH", "realmd:gsev" }, packet) orelse return false;
    switch (rep.value) {
        .int, .status => {},
        else => return false,
    }
    var cb: [16]u8 = undefined;
    const keep = std.fmt.bufPrint(&cb, "-{d}", .{cap}) catch return false;
    _ = command(&.{ "LTRIM", "realmd:gsev", keep, "-1" }) orelse return false;
    var pb: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&pb, "{d}", .{ttl_s}) catch return false;
    _ = command(&.{ "EXPIRE", "realmd:gsev", secs }) orelse return false;
    return true;
}

/// True if redis answers. Used at boot to say so once, rather than discovering it per game.
pub fn ping() bool {
    const rep = command(&.{"PING"}) orelse return false;
    return switch (rep.value) {
        .status => true,
        else => false,
    };
}

test "the DLL's redis client encodes commands the shared codec can read back" {
    // The socket half cannot be exercised here, but the framing can — and framing is where a bug
    // in this file would be invisible until a character came back wrong.
    var buf: [128]u8 = undefined;
    const wire = resp.encode(&buf, &.{ "GET", "realmd:char:acct:Hero" }).?;
    try std.testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$21\r\nrealmd:char:acct:Hero\r\n", wire);
}
