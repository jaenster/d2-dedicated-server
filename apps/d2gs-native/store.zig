//! The native server's link to the realm: redis, over libc sockets and `packages/resp`.
//!
//! Same arrangement as the wine DLL (apps/d2gs/realmclient/redis.zig) and the same IO-free codec,
//! so the two cannot drift; only the socket layer differs. One connection, one lock over the whole
//! request/reply cycle — two threads sharing it desyncs, and the symptom is reads coming back
//! empty while writes still look fine.
const std = @import("std");
const resp = @import("resp");

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn usleep(usec: c_uint) c_int;

/// Linux's sockaddr_in: a 2-byte family, no BSD `sa_len`. Splitting it into two bytes the way the
/// Darwin layout does puts 0x0210 in the family slot, and every connect fails with nothing to say
/// why — which is exactly how this arrived.
const sockaddr_in = extern struct {
    family: u16 = 2, // AF_INET
    port: u16, // big-endian
    addr: [4]u8,
    zero: [8]u8 = @splat(0),
};

var host: [4]u8 = .{ 127, 0, 0, 1 };
var port: u16 = 6379;
var configured = false;
var fd: c_int = -1;
var busy = std.atomic.Value(bool).init(false);
var rx: [16384]u8 = undefined;

pub fn configure(ip: [4]u8, p: u16) void {
    host = ip;
    port = p;
    configured = true;
}

pub fn enabled() bool {
    return configured;
}

fn lock() void {
    while (busy.swap(true, .acquire)) _ = usleep(200);
}

fn unlock() void {
    busy.store(false, .release);
}

fn drop() void {
    if (fd >= 0) _ = close(fd);
    fd = -1;
}

fn ensure() ?c_int {
    if (fd >= 0) return fd;
    if (!configured) return null;
    const s = socket(2, 1, 0); // AF_INET, SOCK_STREAM
    if (s < 0) return null;
    const sa = sockaddr_in{ .port = std.mem.nativeToBig(u16, port), .addr = host };
    if (connect(s, &sa, @sizeOf(sockaddr_in)) != 0) {
        _ = close(s);
        return null;
    }
    fd = s;
    return fd;
}

fn sendAll(s: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(s, bytes.ptr + off, bytes.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn readReply(s: c_int) ?resp.Reply {
    var fill: usize = 0;
    while (true) {
        switch (resp.parse(rx[0..fill])) {
            .ok => |o| return o.reply,
            .invalid => {
                drop();
                return null;
            },
            .need_more => {
                if (fill == rx.len) {
                    drop(); // a reply we cannot resynchronise after
                    return null;
                }
                const n = recv(s, rx[fill..].ptr, rx.len - fill, 0);
                if (n <= 0) {
                    drop();
                    return null;
                }
                fill += @intCast(n);
            },
        }
    }
}

/// One command, one reply. Slices in the reply point into the shared buffer and are valid until
/// the next call.
pub fn cmd(args: []const []const u8) ?resp.Reply {
    lock();
    defer unlock();
    const s = ensure() orelse return null;
    var tx: [1024]u8 = undefined;
    const wire = resp.encode(&tx, args) orelse return null;
    if (!sendAll(s, wire)) {
        drop();
        return null;
    }
    return readReply(s);
}

/// Same, but the LAST argument may be arbitrarily large — a .d2s save or a control packet is
/// bigger than any sane command buffer, so its header is encoded and the payload streamed after.
pub fn cmdBig(head: []const []const u8, tail: []const u8) ?resp.Reply {
    lock();
    defer unlock();
    const s = ensure() orelse return null;
    var tx: [1024]u8 = undefined;
    var n: usize = 0;
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

pub fn ping() bool {
    const r = cmd(&.{"PING"}) orelse return false;
    return switch (r) {
        .status => true,
        else => false,
    };
}

// the operations this server needs

/// Publish this server: where clients reach it, its capacity, its load, and whether it is full.
/// The TTL is how a server that dies leaves the fleet without anyone having to notice.
pub fn putHeartbeat(gsid: u32, ip: [4]u8, gs_port: u16, maxgame: u32, live: u32, full: bool, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gs:{x}", .{gsid}) catch return false;
    var v: [15]u8 = undefined;
    @memcpy(v[0..4], &ip);
    std.mem.writeInt(u16, v[4..6], gs_port, .little);
    std.mem.writeInt(u32, v[6..10], maxgame, .little);
    std.mem.writeInt(u32, v[10..14], live, .little);
    v[14] = @intFromBool(full);
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    const r = cmd(&.{ "SET", key, &v, "PX", px }) orelse return false;
    switch (r) {
        .status, .int => {},
        .bulk => |b| if (b == null) return false,
        else => return false,
    }
    var ib: [16]u8 = undefined;
    _ = cmd(&.{ "SADD", "realmd:gs", std.fmt.bufPrint(&ib, "{x}", .{gsid}) catch return false }) orelse return false;
    return true;
}

/// Take the next create/join queued for this server, or 0 if there is none.
pub fn popRequest(gsid: u32, out: []u8) usize {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gsq:{x}", .{gsid}) catch return 0;
    const r = cmd(&.{ "LPOP", key }) orelse return 0;
    return switch (r) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            if (v.len > out.len) break :blk 0;
            @memcpy(out[0..v.len], v);
            break :blk v.len;
        },
        else => 0,
    };
}

/// Answer a request on the key named by the seq that came in its header.
pub fn putReply(seq: u32, packet: []const u8, ttl_s: u32) bool {
    var kb: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:gsreply:{x}", .{seq}) catch return false;
    const r = cmdBig(&.{ "SET", key }, packet) orelse return false;
    var pb: [16]u8 = undefined;
    const px = std.fmt.bufPrint(&pb, "{d}", .{@as(u64, ttl_s) * 1000}) catch return false;
    _ = cmd(&.{ "PEXPIRE", key, px }) orelse return false;
    return switch (r) {
        .status, .int => true,
        .bulk => |b| b != null,
        else => false,
    };
}

/// Report something that happened here. No answer to wait for and nobody in particular to tell,
/// so it goes on one list any realmd drains; `cap` bounds it against a realm with nothing running.
pub fn pushEvent(packet: []const u8, cap: u32, ttl_s: u32) bool {
    const r = cmdBig(&.{ "RPUSH", "realmd:gsev" }, packet) orelse return false;
    switch (r) {
        .int, .status => {},
        else => return false,
    }
    var cb: [16]u8 = undefined;
    const keep = std.fmt.bufPrint(&cb, "-{d}", .{cap}) catch return false;
    _ = cmd(&.{ "LTRIM", "realmd:gsev", keep, "-1" }) orelse return false;
    var pb: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&pb, "{d}", .{ttl_s}) catch return false;
    _ = cmd(&.{ "EXPIRE", "realmd:gsev", secs }) orelse return false;
    return true;
}

/// Read a character. 0 means absent — never a partial read, because a short save written anywhere
/// becomes a corrupt character and this feeds the engine directly.
pub fn getChar(account: []const u8, charname: []const u8, out: []u8) usize {
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ account, charname }) catch return 0;
    const r = cmd(&.{ "GET", key }) orelse return 0;
    return switch (r) {
        .bulk => |b| blk: {
            const v = b orelse break :blk 0;
            if (v.len > out.len) break :blk 0;
            @memcpy(out[0..v.len], v);
            break :blk v.len;
        },
        else => 0,
    };
}

/// Store a character and mark it for the realm's flush worker. Both or neither: a save redis took
/// but nobody was told about would sit there while Postgres fell behind.
pub fn putChar(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    var kb: [192]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "realmd:char:{s}:{s}", .{ account, charname }) catch return false;
    const set = cmdBig(&.{ "SET", key }, bytes) orelse return false;
    switch (set) {
        .status, .int => {},
        .bulk => |b| if (b == null) return false,
        else => return false,
    }
    var vb: [192]u8 = undefined;
    _ = cmd(&.{ "INCR", std.fmt.bufPrint(&vb, "realmd:charver:{s}/{s}", .{ account, charname }) catch return false }) orelse return false;
    var mb: [192]u8 = undefined;
    _ = cmd(&.{ "SADD", "realmd:dirty", std.fmt.bufPrint(&mb, "{s}/{s}", .{ account, charname }) catch return false }) orelse return false;
    return true;
}
