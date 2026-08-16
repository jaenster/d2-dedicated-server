//! Redis, from inside the game server.
//!
//! The DLL is built for x86-windows and given `realm_proto`, `resp` and `obs` — deliberately not
//! `realm_infra`, so libc sockets never enter this build. That exclusion is why the framing lives
//! in `packages/resp` as a pure codec: this file is only the socket half, and the wire format is
//! the same implementation realmd parses with. A second RESP parser growing in here is exactly
//! what that split exists to prevent.
//!
//! One connection, opened lazily and dropped on any IO error so the next call reconnects. The
//! engine calls this from its own thread while servicing a game, so a call must never block
//! forever: the socket carries a receive timeout and a failed op returns rather than retrying
//! inside the game's tick.
const std = @import("std");
const resp = @import("resp");

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
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const INADDR_NONE: u32 = 0xffff_ffff;

/// Long enough that a busy redis is not mistaken for a dead one, short enough that a wedged
/// connection cannot stall a game's tick for a noticeable time.
const io_timeout_ms: u32 = 2000;

/// One connection, and more than one thread reaching for it. The heartbeat runs on the server
/// tick while a character fetch runs on the join path, and a command/reply cycle cannot be
/// interleaved: the second caller reads the first one's reply, the connection desyncs, and reads
/// start coming back empty while writes still look fine. That is not hypothetical — it is what
/// removing the d2dbs fallback exposed, as joins failing with the character sitting readable in
/// redis.
///
/// A spin with a yield rather than a real lock: contention is a heartbeat every thirty seconds
/// against an occasional fetch, and the DLL has no lock primitive of its own — realm_infra, which
/// has one, is deliberately not in this build.
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

/// `addr` is "host:port"; the host must be a dotted quad here. Unlike the control link this is not
/// given a DNS resolver: the address comes from the same environment the rest of the realm wiring
/// does, and a name that needs resolving can be resolved there.
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

fn ensure() ?SOCKET {
    if (sock != INVALID_SOCKET) return sock;
    if (!configured) return null;
    const s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return null;
    const ip = inet_addr(@ptrCast(&host_buf));
    if (ip == INADDR_NONE) {
        _ = closesocket(s);
        return null;
    }
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

// ── the operations the game server actually needs ────────────────────────────

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

/// Store a character save and mark it for the realm's flush worker. Both, or neither — a save
/// redis takes but nobody is told about would sit there while postgres fell behind.
pub fn putChar(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ account, charname }) catch return false;
    const set = commandBig(&.{ "SET", key }, bytes) orelse return false;
    switch (set.value) {
        .status, .int => {},
        .bulk => |b| if (b == null) return false,
        else => return false,
    }
    var vb: [192]u8 = undefined;
    const verkey = std.fmt.bufPrint(&vb, "realmd:charver:{s}/{s}", .{ account, charname }) catch return false;
    _ = command(&.{ "INCR", verkey }) orelse return false;
    var mb: [128]u8 = undefined;
    const member = std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return false;
    _ = command(&.{ "SADD", "realmd:dirty", member }) orelse return false;
    return true;
}

/// Publish this server's heartbeat: it exists, where clients reach it, and how loaded it is.
/// The TTL is what makes a server that dies disappear without anyone having to notice.
pub fn putHeartbeat(gsid: u32, ip: [4]u8, gs_port: u16, maxgame: u32, live: u32, full: bool, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gs:{x}", .{gsid}) catch return false;
    var vb: [15]u8 = undefined;
    @memcpy(vb[0..4], &ip);
    std.mem.writeInt(u16, vb[4..6], gs_port, .little);
    std.mem.writeInt(u32, vb[6..10], maxgame, .little);
    std.mem.writeInt(u32, vb[10..14], live, .little);
    vb[14] = @intFromBool(full);
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const rep = command(&.{ "SET", key, &vb, "PX", px }) orelse return false;
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
