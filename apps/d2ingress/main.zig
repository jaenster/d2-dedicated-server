//! d2ingress — the cloud-native game-traffic gateway, a "QServer of QServers" fronting
//! the GS fleet. Clients connect to ONE public address for game traffic (:4000); the
//! d2ingress reads the realm-global game TOKEN from the client's first packet (the D2GS
//! GAMELOGON 0x68), looks up which backend GS owns that token, REWRITES the token in the
//! packet to the GS's real engine gameid, dials the GS, replays the rewritten first
//! packet, and splices the rest of the connection byte-for-byte.
//!
//! Routing is TOKEN-based, not source-IP based. realmd mints a realm-globally-unique
//! token per CREATE/JOIN and records {token -> gs_ip,gs_port,real_gameid} in redis (a
//! packed 10-byte value); because the token is unique across the realm, two clients behind
//! ONE public IP never collide. NAT-proof, and any front pod resolves any token.
//!
//! ZERO HEAP, BARE SOCKETS, ONE THREAD, ON THE STACK, FULLY NON-BLOCKING. The entire
//! gateway state lives in one `Gateway` value in main()'s frame — no globals, no allocator.
//! A single `poll()` loop drives everything, and NOTHING blocks it: not the splice, and not
//! the route lookup. The route store is redis, reached over a persistent NON-BLOCKING
//! connection that sits in the same poll set. A new connection's lookup is an async,
//! pipelined `GET`: we fire it and park the connection in `.awaiting_route` (it occupies no
//! poll slots) — the loop keeps serving everyone else. Redis replies come back in send
//! order on the one connection, so a FIFO of {slot, generation} matches each reply to its
//! waiting connection (the generation guards against a slot being recycled before its
//! answer arrives). The lookup "can take a second" and only that one connection waits.
//!
//! Splice uses the proxy buffer-pool model: read then TRY TO WRITE IMMEDIATELY (a packet
//! usually leaves in the same event — low latency, no buffer retained); only a partial /
//! EAGAIN write parks its remainder in a pooled buffer for a later POLLOUT, so buffers are
//! held only by stalled connections and a small pool serves far more connections. Pool
//! exhaustion just defers the read (TCP backpressure), never drops data. The active table
//! swap-removes on close; idle sleeps in poll(-1) at 0% CPU.
const std = @import("std");
const builtin = @import("builtin");
const infra = @import("realm_infra");
const config = infra.config;
const log = infra.log;

// Raw-wire offset of the u16 game token inside the D2GS GAMELOGON (0x68) packet:
//   nId(u8, =0x68) ++ nGameHash(u32) ++ nGameToken(u16) ++ ...   → token at byte 5.
const TOKEN_OFFSET: usize = 5;
const GAMELOGON_ID: u8 = 0x68;
const MIN_LOGON_BYTES: usize = TOKEN_OFFSET + 2;

/// How many leading bytes of a GS→client buffer are the engine's 0xAF greeting frame that d2ingress
/// must strip (see stripGsGreeting). Returns 0 when `buf` does not begin with a COMPLETE 0xAF
/// frame — not 0xAF, too short to read the flag byte, or a declared frame longer than what's
/// buffered — so the caller forwards those bytes verbatim rather than eating payload. The 0xAF
/// frame is 2 bytes for 0xAF00, else byte[1]+1 (mirrors the client's packet demux @0x52a8d0).
fn greetingStripLen(buf: []const u8) u32 {
    if (buf.len < 2 or buf[0] != 0xAF) return 0;
    const af_len: u32 = if (buf[1] == 0) 2 else @as(u32, buf[1]) + 1;
    return if (af_len <= buf.len) af_len else 0;
}

test "greetingStripLen: 0xAF00 greeting" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 2), greetingStripLen(&.{ 0xAF, 0x00 })); // exact 2-byte greeting
    try t.expectEqual(@as(u32, 2), greetingStripLen(&.{ 0xAF, 0x00, 0x01, 0x02 })); // greeting + payload
}

test "greetingStripLen: 0xAF with non-zero flag uses byte[1]+1 length" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 2), greetingStripLen(&.{ 0xAF, 0x01, 0x99 })); // 0xAF01 = 2 bytes
    try t.expectEqual(@as(u32, 6), greetingStripLen(&.{ 0xAF, 0x05, 1, 2, 3, 4, 5, 6 })); // len byte[1]+1=6
}

test "greetingStripLen: does not strip when frame is incomplete or absent" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0), greetingStripLen(&.{0xAF})); // 1 byte: can't read the flag
    try t.expectEqual(@as(u32, 0), greetingStripLen(&.{ 0xAF, 0x05, 1, 2 })); // declares 6, only 4 buffered
    try t.expectEqual(@as(u32, 0), greetingStripLen(&.{ 0x6B, 0x00 })); // not a 0xAF frame (ENTERGAME)
    try t.expectEqual(@as(u32, 0), greetingStripLen(&.{})); // empty
    try t.expectEqual(@as(u32, 0), greetingStripLen(&.{ 0x01, 0xAF })); // 0xAF not first
}

test "greetingStripLen: strips exactly the greeting, leaving the payload intact" {
    const t = std.testing;
    const buf = [_]u8{ 0xAF, 0x00, 0x02, 0xDE, 0xAD }; // greeting then a 3-byte world packet
    const n = greetingStripLen(&buf);
    try t.expectEqualSlices(u8, &.{ 0x02, 0xDE, 0xAD }, buf[n..]);
}

// Redis token-route value is a packed 10 bytes: ip[4] ++ port(u16 LE) ++ gameid(u32 LE),
// written by realmd's redis adapter. Key: "realmd:troute:<token-hex, no pad>".
const ROUTE_BYTES: usize = 10;
const ROUTE_KEY_PREFIX = "realmd:troute:";

// Static sizing (all inside the Gateway value on main()'s stack — no heap). MAX_CONN
// connection slots, but only POOL_N data buffers, shared among the connections CURRENTLY
// stalled mid-write (most forwards write through instantly and hold no buffer).
const MAX_CONN: usize = 1024;
const POOL_N: usize = 256;
const BUF_SZ: usize = 4 * 1024;
const REDIS_OUT_SZ: usize = 64 * 1024; // pipelined GET commands awaiting send
const REDIS_IN_SZ: usize = 64 * 1024; // reply bytes awaiting parse

// ── bare libc: sockets, fcntl, poll, getaddrinfo (no net.zig — the gateway is bare) ──
const posix = std.posix;
const is_linux = builtin.target.os.tag == .linux;
const O_NONBLOCK: c_int = if (is_linux) 0o4000 else 0x0004; // linux 0x800, darwin 0x4
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
extern "c" fn getsockopt(fd: c_int, level: c_int, optname: c_int, optval: *anyopaque, optlen: *c_uint) c_int;
// fcntl is VARIADIC in C (int fcntl(int, int, ...)). It MUST be declared variadic: on
// arm64 the variadic arg goes on the stack, so a fixed 3rd-arg declaration passes it in the
// wrong place → garbage flags (this silently left sockets BLOCKING, hanging the accept loop).
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
extern "c" fn poll(fds: [*]posix.pollfd, nfds: c_uint, timeout: c_int) c_int;
extern "c" fn inet_addr(cp: [*:0]const u8) c_uint;

fn lastErrno() c_int {
    return std.c._errno().*;
}
const EAGAIN: c_int = @intFromEnum(posix.E.AGAIN);
const EINPROGRESS: c_int = @intFromEnum(posix.E.INPROGRESS);

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
// REALMD_INGRESS_TRACE=1 → hexdump every spliced chunk both directions (debug; verbose).
var trace: bool = false;

// Monotonic milliseconds — used to back off redis reconnect attempts so an unreachable
// redis makes the loop SLEEP (poll timeout) instead of hammering connect() in a spin.
const timespec = extern struct { sec: c_long, nsec: c_long };
const CLOCK_MONOTONIC: c_int = if (is_linux) 1 else 6; // linux 1, darwin 6
extern "c" fn clock_gettime(clk: c_int, tp: *timespec) c_int;
fn nowMs() i64 {
    var ts: timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
const REDIS_RECONNECT_MS: i64 = 1000; // min gap between redis connect attempts

// struct addrinfo — ai_addr vs ai_canonname order DIFFERS by OS (Linux: addr first;
// BSD/darwin: canonname first). One-time use to resolve the redis host at startup.
const addrinfo = if (is_linux) extern struct {
    flags: c_int,
    family: c_int,
    socktype: c_int,
    protocol: c_int,
    addrlen: c_uint,
    addr: ?*posix.sockaddr.in,
    canonname: ?[*:0]u8,
    next: ?*addrinfo,
} else extern struct {
    flags: c_int,
    family: c_int,
    socktype: c_int,
    protocol: c_int,
    addrlen: c_uint,
    canonname: ?[*:0]u8,
    addr: ?*posix.sockaddr.in,
    next: ?*addrinfo,
};
extern "c" fn getaddrinfo(node: [*:0]const u8, service: ?[*:0]const u8, hints: ?*const addrinfo, res: **addrinfo) c_int;
extern "c" fn freeaddrinfo(res: *addrinfo) void;

/// Resolve a "host" (dotted-quad or DNS name) to network-order IPv4 octets. Blocking, but
/// called exactly once at startup for the redis host, never on the data path.
fn resolveHost(host: [:0]const u8) ?[4]u8 {
    const direct = inet_addr(host.ptr);
    if (direct != 0xffff_ffff) return @bitCast(direct);
    var hints = std.mem.zeroes(addrinfo);
    hints.family = posix.AF.INET;
    hints.socktype = posix.SOCK.STREAM;
    var res: *addrinfo = undefined;
    if (getaddrinfo(host.ptr, null, &hints, &res) != 0) return null;
    defer freeaddrinfo(res);
    var cur: ?*addrinfo = res;
    while (cur) |a| : (cur = a.next) {
        if (a.family == posix.AF.INET) {
            if (a.addr) |sa| return @bitCast(sa.addr);
        }
    }
    return null;
}

fn parseIp4(text: []const u8) ![4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return error.InvalidIp;
    return octets;
}

/// Bare non-blocking listening socket on bind_ip:port (SO_REUSEADDR).
fn listenTcp(bind_ip: []const u8, port: u16) !c_int {
    // A gateway writes to hung-up sockets as a matter of routine: the client leaves the game and
    // whatever the GS was mid-way through sending lands on a closed pipe. SIGPIPE's default is to
    // kill the process, so without this the gateway dies on an ordinary disconnect — silently,
    // exit 141, nothing in the log but the connection it happened to be serving.
    infra.net.ignoreBrokenPipes();
    const fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = close(fd);
    const one: c_int = 1;
    _ = setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one, @sizeOf(c_int));
    var addr = std.mem.zeroes(posix.sockaddr.in);
    addr.family = posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = @bitCast(try parseIp4(bind_ip));
    if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);
    if (bind(fd, &addr, @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
    if (listen(fd, 128) != 0) return error.ListenFailed;
    if (!setNonBlock(fd)) return error.NonBlockFailed;
    return fd;
}

fn setNonBlock(fd: c_int) bool {
    const flags = fcntl(fd, F_GETFL);
    if (flags < 0) return false;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0;
}

/// A non-blocking IPv4 socket connect()'d toward ip:port. Returns the fd plus whether the
/// connection completed synchronously (rare) or is still in progress (watch POLLOUT).
const Dial = struct { fd: c_int, connected: bool };
fn dialNonBlock(ip: [4]u8, port: u16) ?Dial {
    const fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return null;
    if (!setNonBlock(fd)) {
        _ = close(fd);
        return null;
    }
    var addr = std.mem.zeroes(posix.sockaddr.in);
    addr.family = posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = @bitCast(ip); // already network byte order
    if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);
    if (connect(fd, &addr, @sizeOf(posix.sockaddr.in)) == 0) return .{ .fd = fd, .connected = true };
    const e = lastErrno();
    if (e == EINPROGRESS or e == EAGAIN) return .{ .fd = fd, .connected = false };
    _ = close(fd);
    return null;
}

/// SO_ERROR on a socket whose connect() was in progress: 0 = connected, else failed.
fn connectResult(fd: c_int) c_int {
    var err: c_int = 0;
    var len: c_uint = @sizeOf(c_int);
    if (getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &err, &len) != 0) return -1;
    return err;
}

const State = enum { free, handshake, awaiting_route, connecting, open };

/// One client⇄GS pairing. A direction holds a pooled buffer ONLY while stalled (or, for
/// c2g, while holding the first packet through handshake/lookup/connect): `c2g`/`g2c` is the
/// buffer index (-1 = none), `*_off..*_len` the unsent slice. `slot`/`gen` identify this
/// connection for async redis replies (gen bumped on reuse so a stale reply is discarded).
const Conn = struct {
    state: State = .free,
    cli: c_int = -1,
    gs: c_int = -1,
    slot: u32 = 0,
    gen: u32 = 0,
    c2g: i32 = -1,
    c2g_off: u32 = 0,
    c2g_len: u32 = 0,
    g2c: i32 = -1,
    g2c_off: u32 = 0,
    g2c_len: u32 = 0,
    cli_eof: bool = false,
    gs_eof: bool = false,
    c2g_bytes: u64 = 0, // total bytes spliced client->GS (diagnostics)
    g2c_bytes: u64 = 0, // total bytes spliced GS->client
    gs_greeted: bool = false, // stripped the GS's one leading 0xAF00 greeting yet?
};

const RedisState = enum { disconnected, connecting, ready };
const Pending = struct { slot: u32, gen: u32 };
const ParsedReply = struct {
    consumed: usize,
    found: bool, // true = a 10-byte route, false = nil/error (no route)
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    port: u16 = 0,
    gameid: u32 = 0,
};

/// The whole gateway, as one value that lives on main()'s stack (no globals, no heap).
const Gateway = struct {
    // Buffer pool: POOL_N fixed buffers handed out only to stalled connections.
    pool: [POOL_N][BUF_SZ]u8 = undefined,
    pool_free: [POOL_N]u16 = undefined,
    pool_top: usize = 0,

    // Connection table + compacted active set.
    conns: [MAX_CONN]Conn = undefined,
    active: [MAX_CONN]usize = undefined,
    n_active: usize = 0,
    gen_ctr: u32 = 0,

    // Redis: one persistent non-blocking connection in the poll set, plus a pipelined send
    // buffer, a reply parse buffer, and the FIFO matching outstanding GETs to connections.
    redis_ip: [4]u8 = .{ 127, 0, 0, 1 },
    redis_port: u16 = 6379,
    redis_fd: c_int = -1,
    redis_state: RedisState = .disconnected,
    redis_retry_at: i64 = 0, // monotonic-ms gate: don't re-dial redis before this (backoff)
    redis_out: [REDIS_OUT_SZ]u8 = undefined,
    redis_out_len: usize = 0,
    redis_in: [REDIS_IN_SZ]u8 = undefined,
    redis_in_len: usize = 0,
    pending: [MAX_CONN]Pending = undefined,
    pend_head: usize = 0,
    pend_count: usize = 0,

    fn init(g: *Gateway) void {
        for (0..POOL_N) |i| g.pool_free[i] = @intCast(i);
        g.pool_top = POOL_N;
        for (0..MAX_CONN) |i| g.active[i] = i;
        g.n_active = 0;
    }

    // ── buffer pool ────────────────────────────────────────────────────────────────────
    fn poolAcquire(g: *Gateway) ?u16 {
        if (g.pool_top == 0) return null;
        g.pool_top -= 1;
        return g.pool_free[g.pool_top];
    }
    fn poolRelease(g: *Gateway, idx: u16) void {
        g.pool_free[g.pool_top] = idx;
        g.pool_top += 1;
    }

    // ── connection table ───────────────────────────────────────────────────────────────
    fn allocConn(g: *Gateway) ?*Conn {
        if (g.n_active >= MAX_CONN) return null;
        const idx = g.active[g.n_active];
        g.n_active += 1;
        const c = &g.conns[idx];
        c.* = .{};
        c.slot = @intCast(idx);
        g.gen_ctr +%= 1;
        if (g.gen_ctr == 0) g.gen_ctr = 1; // gen 0 is reserved for "free slot"
        c.gen = g.gen_ctr;
        return c;
    }

    fn compactClosed(g: *Gateway) void {
        var p: usize = 0;
        while (p < g.n_active) {
            if (g.conns[g.active[p]].state == .free) {
                g.n_active -= 1;
                const freed = g.active[p];
                g.active[p] = g.active[g.n_active];
                g.active[g.n_active] = freed;
            } else p += 1;
        }
    }

    fn closeConn(g: *Gateway, c: *Conn) void {
        if (c.c2g_bytes != 0 or c.g2c_bytes != 0 or c.gs >= 0)
            // `greeted` is what makes a failed join readable. A join that dies leaves zero bytes
            // going back to the client whether the GS never accepted the connection, accepted it
            // and died, or greeted us and then refused the GAMELOGON in silence — three different
            // faults in three different processes that print the same line without it. The engine
            // greets unprompted the moment it accepts, so seeing the greeting places the failure
            // after the accept and nowhere else.
            log.line("d2ingress", "conn closed: client->GS={d}B GS->client={d}B (cli_eof={} gs_eof={} greeted={})", .{
                c.c2g_bytes, c.g2c_bytes, c.cli_eof, c.gs_eof, c.gs_greeted,
            });
        if (c.cli >= 0) _ = close(c.cli);
        if (c.gs >= 0) _ = close(c.gs);
        if (c.c2g >= 0) g.poolRelease(@intCast(c.c2g));
        if (c.g2c >= 0) g.poolRelease(@intCast(c.g2c));
        c.* = .{}; // state = .free, gen = 0
    }

    // ── redis: pending FIFO ─────────────────────────────────────────────────────────────
    fn pendPush(g: *Gateway, slot: u32, gen: u32) bool {
        if (g.pend_count >= MAX_CONN) return false;
        g.pending[(g.pend_head + g.pend_count) % MAX_CONN] = .{ .slot = slot, .gen = gen };
        g.pend_count += 1;
        return true;
    }
    fn pendPop(g: *Gateway) ?Pending {
        if (g.pend_count == 0) return null;
        const p = g.pending[g.pend_head];
        g.pend_head = (g.pend_head + 1) % MAX_CONN;
        g.pend_count -= 1;
        return p;
    }

    // ── redis: connection lifecycle ─────────────────────────────────────────────────────
    fn redisConnect(g: *Gateway) void {
        if (g.redis_fd >= 0) { // never leak a prior (failed/half-open) socket
            _ = close(g.redis_fd);
            g.redis_fd = -1;
        }
        const d = dialNonBlock(g.redis_ip, g.redis_port) orelse {
            g.redis_state = .disconnected;
            return;
        };
        g.redis_fd = d.fd;
        g.redis_state = if (d.connected) .ready else .connecting;
    }

    /// Tear down redis on error/close: drop the socket, clear buffers, and fail every
    /// connection still waiting on a route (their answer is never coming).
    fn redisDrop(g: *Gateway) void {
        if (g.redis_fd >= 0) _ = close(g.redis_fd);
        g.redis_fd = -1;
        g.redis_state = .disconnected;
        g.redis_out_len = 0;
        g.redis_in_len = 0;
        while (g.pendPop()) |p| {
            const c = &g.conns[p.slot];
            if (c.gen == p.gen and c.state == .awaiting_route) g.closeConn(c);
        }
    }

    /// Pipeline a `GET realmd:troute:<token>` and remember which connection it's for.
    /// False if the send buffer or the waiting line is full (caller drops the connection).
    fn redisRequestRoute(g: *Gateway, c: *Conn, token: u16) bool {
        var cmd: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&cmd, "GET " ++ ROUTE_KEY_PREFIX ++ "{x}\r\n", .{token}) catch return false;
        if (g.pend_count >= MAX_CONN) return false;
        if (g.redis_out_len + s.len > REDIS_OUT_SZ) return false;
        @memcpy(g.redis_out[g.redis_out_len..][0..s.len], s);
        g.redis_out_len += s.len;
        _ = g.pendPush(c.slot, c.gen); // room checked above
        return true;
    }

    fn redisFlushOut(g: *Gateway) void {
        if (g.redis_out_len == 0) return;
        const w = write(g.redis_fd, &g.redis_out, g.redis_out_len);
        if (w <= 0) {
            if (w < 0 and lastErrno() == EAGAIN) return;
            g.redisDrop();
            return;
        }
        const wrote: usize = @intCast(w);
        if (wrote < g.redis_out_len) {
            std.mem.copyForwards(u8, g.redis_out[0..], g.redis_out[wrote..g.redis_out_len]);
            g.redis_out_len -= wrote;
        } else g.redis_out_len = 0;
    }

    /// Read reply bytes, parse every complete reply, and resolve each waiting connection.
    fn redisReadIn(g: *Gateway) void {
        if (g.redis_in_len >= REDIS_IN_SZ) {
            g.redisDrop();
            return;
        }
        const tail = g.redis_in[g.redis_in_len..];
        const r = read(g.redis_fd, tail.ptr, tail.len);
        if (r == 0) {
            g.redisDrop();
            return;
        }
        if (r < 0) {
            if (lastErrno() == EAGAIN) return;
            g.redisDrop();
            return;
        }
        g.redis_in_len += @intCast(r);

        var pos: usize = 0;
        while (pos < g.redis_in_len) {
            const c0 = g.redis_in[pos];
            if (c0 != '$' and c0 != '-' and c0 != '+' and c0 != ':') {
                g.redisDrop(); // protocol desync — resync by reconnecting
                return;
            }
            const pr = parseReply(g.redis_in[pos..g.redis_in_len]) orelse break; // incomplete
            g.applyReply(pr);
            pos += pr.consumed;
        }
        if (pos > 0) {
            if (pos < g.redis_in_len) std.mem.copyForwards(u8, g.redis_in[0..], g.redis_in[pos..g.redis_in_len]);
            g.redis_in_len -= pos;
        }
    }

    /// One reply → the head of the waiting line. Dial the GS (or drop on no-route/stale).
    fn applyReply(g: *Gateway, pr: ParsedReply) void {
        const p = g.pendPop() orelse return; // stray reply (shouldn't happen)
        const c = &g.conns[p.slot];
        if (c.gen != p.gen or c.state != .awaiting_route) return; // connection gone / recycled
        if (!pr.found) {
            log.line("d2ingress", "no route for waiting connection — dropping", .{});
            g.closeConn(c);
            return;
        }
        // c2g still holds the original first packet; rewrite its token to the GS gameid.
        const bi: u16 = @intCast(c.c2g);
        // The realm-minted token the client presented (before we rewrite it) — log it
        // next to the GS gameid so a trace links client token -> GS game. The gameid we
        // write here IS the GS game's nToken, i.e. the `token` field in the GS event log.
        const client_token = std.mem.readInt(u16, g.pool[bi][TOKEN_OFFSET..][0..2], .little);
        std.mem.writeInt(u16, g.pool[bi][TOKEN_OFFSET..][0..2], @truncate(pr.gameid), .little);
        const d = dialNonBlock(pr.ip, pr.port) orelse {
            log.line("d2ingress", "GS {d}.{d}.{d}.{d}:{d} dial failed", .{ pr.ip[0], pr.ip[1], pr.ip[2], pr.ip[3], pr.port });
            g.closeConn(c);
            return;
        };
        c.gs = d.fd;
        c.state = if (d.connected) .open else .connecting;
        log.line("d2ingress", "route client_token={d} -> GS {d}.{d}.{d}.{d}:{d} token={d}{s}", .{ client_token, pr.ip[0], pr.ip[1], pr.ip[2], pr.ip[3], pr.port, pr.gameid, if (d.connected) "" else " [connecting]" });
    }

    /// Service the redis fd this turn (connect-complete, flush sends, read replies).
    fn serviceRedis(g: *Gateway, re: i16) void {
        if (re & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            g.redisDrop();
            return;
        }
        if (g.redis_state == .connecting) {
            if (re & posix.POLL.OUT == 0) return;
            if (connectResult(g.redis_fd) != 0) {
                g.redisDrop();
                return;
            }
            g.redis_state = .ready;
        }
        if (g.redis_state == .ready) {
            if (re & posix.POLL.OUT != 0) g.redisFlushOut();
            if (re & posix.POLL.IN != 0) g.redisReadIn();
        }
    }

    // ── the event loop ──────────────────────────────────────────────────────────────────
    fn run(g: *Gateway, listen_fd: c_int) void {
        var pfds: [MAX_CONN * 2 + 2]posix.pollfd = undefined;
        var owner: [MAX_CONN * 2 + 2]*Conn = undefined;
        var is_gs: [MAX_CONN * 2 + 2]bool = undefined;

        while (true) {
            // Reconnect redis at most once per REDIS_RECONNECT_MS — without this gate a
            // down/unreachable redis spins connect() at ~100% CPU and floods it with SYNs.
            if (g.redis_state == .disconnected and nowMs() >= g.redis_retry_at) {
                g.redis_retry_at = nowMs() + REDIS_RECONNECT_MS;
                g.redisConnect();
            }

            pfds[0] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
            var n: usize = 1;

            // The redis fd, when present, sits right after the listener.
            var redis_pi: i32 = -1;
            if (g.redis_fd >= 0) {
                var ev: i16 = 0;
                switch (g.redis_state) {
                    .connecting => ev = posix.POLL.OUT,
                    .ready => {
                        ev = posix.POLL.IN;
                        if (g.redis_out_len > 0) ev |= posix.POLL.OUT;
                    },
                    .disconnected => {},
                }
                if (ev != 0) {
                    pfds[n] = .{ .fd = g.redis_fd, .events = ev, .revents = 0 };
                    redis_pi = @intCast(n);
                    n += 1;
                }
            }

            const have_buf = g.pool_top > 0;
            for (g.active[0..g.n_active]) |idx| {
                const c = &g.conns[idx];
                switch (c.state) {
                    .free, .awaiting_route => {}, // awaiting_route waits on redis, no fds of its own
                    .handshake => {
                        if (c.c2g >= 0 or have_buf) {
                            pfds[n] = .{ .fd = c.cli, .events = posix.POLL.IN, .revents = 0 };
                            owner[n] = c;
                            is_gs[n] = false;
                            n += 1;
                        }
                    },
                    .connecting => {
                        pfds[n] = .{ .fd = c.gs, .events = posix.POLL.OUT, .revents = 0 };
                        owner[n] = c;
                        is_gs[n] = true;
                        n += 1;
                    },
                    .open => {
                        var cev: i16 = 0;
                        if (!c.cli_eof and c.c2g < 0 and have_buf) cev |= posix.POLL.IN;
                        if (c.g2c >= 0 and c.g2c_off < c.g2c_len) cev |= posix.POLL.OUT;
                        if (cev != 0) {
                            pfds[n] = .{ .fd = c.cli, .events = cev, .revents = 0 };
                            owner[n] = c;
                            is_gs[n] = false;
                            n += 1;
                        }
                        var gev: i16 = 0;
                        if (!c.gs_eof and c.g2c < 0 and have_buf) gev |= posix.POLL.IN;
                        if (c.c2g >= 0 and c.c2g_off < c.c2g_len) gev |= posix.POLL.OUT;
                        if (gev != 0) {
                            pfds[n] = .{ .fd = c.gs, .events = gev, .revents = 0 };
                            owner[n] = c;
                            is_gs[n] = true;
                            n += 1;
                        }
                    },
                }
            }

            // Block until activity. Redis ready → sleep indefinitely (0% CPU). Otherwise wake
            // exactly at the next reconnect deadline (so we retry without spinning).
            const timeout: c_int = if (g.redis_state == .ready) -1 else blk: {
                const wait = g.redis_retry_at - nowMs();
                break :blk if (wait <= 0) REDIS_RECONNECT_MS else @intCast(@min(wait, REDIS_RECONNECT_MS));
            };
            const ready = poll(&pfds, @intCast(n), timeout);
            if (ready <= 0) continue;

            var remaining: usize = @intCast(ready);
            if (pfds[0].revents != 0) {
                g.acceptNew(listen_fd);
                remaining -= 1;
            }
            if (redis_pi >= 0 and pfds[@intCast(redis_pi)].revents != 0) {
                g.serviceRedis(pfds[@intCast(redis_pi)].revents);
                remaining -= 1;
            }

            var i: usize = 1;
            while (i < n and remaining > 0) : (i += 1) {
                if (@as(i32, @intCast(i)) == redis_pi) continue;
                const re = pfds[i].revents;
                if (re == 0) continue;
                remaining -= 1;
                const c = owner[i];
                if (c.state == .free) continue;
                switch (c.state) {
                    .handshake => g.serviceHandshake(c, re),
                    .connecting => g.serviceConnecting(c, re),
                    .open => g.serviceOpen(c, is_gs[i], re),
                    .free, .awaiting_route => {},
                }
            }

            g.compactClosed();
        }
    }

    fn acceptNew(g: *Gateway, listen_fd: c_int) void {
        while (true) {
            const cfd = accept(listen_fd, null, null);
            if (cfd < 0) {
                return;
            }
            if (!setNonBlock(cfd)) {
                _ = close(cfd);
                continue;
            }
            const c = g.allocConn() orelse {
                log.line("d2ingress", "connection table full ({d}) — dropping", .{MAX_CONN});
                _ = close(cfd);
                continue;
            };
            c.state = .handshake;
            c.cli = cfd;
            // The real client's setup waits for a connection-established (0xAF) packet promptly
            // after connect — without it it never advances into connecting-mode. The gateway
            // can't reach the GS yet (it needs the GAMELOGON token to route), so it speaks for
            // the GS and sends one now.
            //
            // We send 0xAF00. The client's receive demux reads 0xAF's SECOND byte as a phase
            // flag, and the two phases are disjoint receive paths in ThreadClientToServer
            // @0x52ab30 (gated on the flag ParseRecvBufferIntoPacketQueues @0x52a8d0 returns):
            //   `af 00` -> recv straight into the packet buffer and parse. No length framing,
            //              and DecompressPacket is never called on this path at all.
            //   `af 01` -> the length-framed loop that Huffman-decodes every frame.
            // We pick 0x00 and have the GS send with the engine's own raw mode (nMode==2 in
            // SendPacketToClient @0x52b330, the same exemption the 0xAF greeting itself uses), so
            // a STOCK client reads the stream natively with nothing patched on its side. Every
            // backend must agree on this byte, because we have to greet before we know which one
            // we'll route to.
            const af00 = [2]u8{ 0xaf, 0x00 };
            _ = write(cfd, &af00, af00.len);
            log.line("d2ingress", "accepted game connection (fd={d}) — sent 0xAF00, awaiting GAMELOGON", .{cfd});
        }
    }

    /// Accumulate the client's first bytes (in a pooled c2g buffer) until we can read the
    /// GAMELOGON token, then fire an ASYNC redis GET and park in .awaiting_route.
    fn serviceHandshake(g: *Gateway, c: *Conn, re: i16) void {
        if (re & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0 and re & posix.POLL.IN == 0) {
            g.closeConn(c);
            return;
        }
        if (c.c2g < 0) {
            const bi = g.poolAcquire() orelse return;
            c.c2g = bi;
            c.c2g_off = 0;
            c.c2g_len = 0;
        }
        const bi: u16 = @intCast(c.c2g);
        if (c.c2g_len >= BUF_SZ) {
            g.closeConn(c);
            return;
        }
        const tail = g.pool[bi][c.c2g_len..];
        const got = read(c.cli, tail.ptr, tail.len);
        if (got == 0) {
            g.closeConn(c);
            return;
        }
        if (got < 0) {
            if (lastErrno() == EAGAIN) return;
            g.closeConn(c);
            return;
        }
        const before: u32 = c.c2g_len;
        c.c2g_len += @intCast(got);
        c.c2g_bytes += @intCast(got);
        if (trace) log.hexdump("d2ingress C->GS (logon)", g.pool[bi][before..c.c2g_len]);
        if (c.c2g_len < MIN_LOGON_BYTES) return;

        if (g.pool[bi][0] != GAMELOGON_ID) {
            log.line("d2ingress", "first packet id 0x{x:0>2} != GAMELOGON 0x68 — dropping", .{g.pool[bi][0]});
            g.closeConn(c);
            return;
        }
        const token = std.mem.readInt(u16, g.pool[bi][TOKEN_OFFSET..][0..2], .little);
        // Async: pipeline the GET; the reply (a later poll wake on the redis fd) finishes the
        // setup in applyReply. The loop serves everyone else meanwhile.
        if (!g.redisRequestRoute(c, token)) {
            g.closeConn(c);
            return;
        }
        c.state = .awaiting_route;
    }

    fn serviceConnecting(g: *Gateway, c: *Conn, re: i16) void {
        // Say so. A game server that will not take the connection is the one failure the client
        // cannot see any other way — it is answered by nothing at all, exactly like a game that
        // was never created, and blaming it on the realm costs an afternoon.
        if (re & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            log.line("d2ingress", "the GS refused the connection (errno {d}) — the client is dropped", .{connectResult(c.gs)});
            g.closeConn(c);
            return;
        }
        if (re & posix.POLL.OUT == 0) return;
        const err = connectResult(c.gs);
        if (err != 0) {
            log.line("d2ingress", "could not connect to the GS: errno {d} — the client is dropped", .{err});
            g.closeConn(c);
            return;
        }
        c.state = .open;
    }

    fn serviceOpen(g: *Gateway, c: *Conn, gs_side: bool, re: i16) void {
        if (gs_side) {
            if (re & posix.POLL.OUT != 0) g.flush(c.gs, &c.c2g, &c.c2g_off, &c.c2g_len, &c.gs_eof);
            // First GS read carries the leading 0xAF greeting that d2ingress must strip (see
            // stripGsGreeting); every read after that is a verbatim splice.
            if (re & posix.POLL.IN != 0) {
                if (c.gs_greeted)
                    g.pump(c.gs, &c.g2c, &c.g2c_off, &c.g2c_len, c.cli, &c.gs_eof, &c.cli_eof, "d2ingress GS->C", &c.g2c_bytes)
                else
                    g.stripGsGreeting(c);
            }
            if (re & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) c.gs_eof = true;
        } else {
            if (re & posix.POLL.OUT != 0) g.flush(c.cli, &c.g2c, &c.g2c_off, &c.g2c_len, &c.cli_eof);
            if (re & posix.POLL.IN != 0) g.pump(c.cli, &c.c2g, &c.c2g_off, &c.c2g_len, c.gs, &c.cli_eof, &c.gs_eof, "d2ingress C->GS", &c.c2g_bytes);
            if (re & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) c.cli_eof = true;
        }
        g.propagateEofAndMaybeClose(c);
    }

    /// Read from `src` into a pooled buffer, then TRY to write it all to `dst` at once. Full
    /// write → release immediately (no retention, low latency). Partial/EAGAIN → park the
    /// remainder for a later POLLOUT. Gated to only run when idx.* == -1 and the pool has room.
    fn pump(g: *Gateway, src: c_int, idx: *i32, off: *u32, len: *u32, dst: c_int, src_eof: *bool, dst_eof: *bool, dir: []const u8, total: *u64) void {
        const bi = g.poolAcquire() orelse return;
        const got = read(src, &g.pool[bi], BUF_SZ);
        if (got == 0) {
            src_eof.* = true;
            g.poolRelease(bi);
            return;
        }
        if (got < 0) {
            g.poolRelease(bi);
            if (lastErrno() == EAGAIN) return;
            src_eof.* = true;
            return;
        }
        const un: u32 = @intCast(got);
        total.* += un;
        if (trace) log.hexdump(dir, g.pool[bi][0..un]);
        const w = write(dst, &g.pool[bi], un);
        if (w == got) {
            g.poolRelease(bi);
            return;
        }
        if (w < 0 and lastErrno() != EAGAIN) {
            g.poolRelease(bi);
            dst_eof.* = true;
            return;
        }
        idx.* = @intCast(bi);
        off.* = if (w > 0) @intCast(w) else 0;
        len.* = un;
    }

    /// Pre-splice phase: the real 1.14d engine opens the game stream with one leading 0xAF
    /// greeting (nocompress forces 0xAF00). d2ingress already sent the client its OWN 0xAF00 to prompt
    /// GAMELOGON, so the GS's copy MUST be dropped — forwarding it leaves the client reading a
    /// stray 0xAF as a bogus opcode, desyncing before ENTERGAME (the classic ~49-byte stall).
    /// We strip ONE validated 0xAF frame (see greetingStripLen) on the first GS read, forward
    /// whatever follows, then hand the session to pump(). If the first byte is NOT 0xAF,
    /// something upstream is wrong: forward as-is and log — never silently eat payload.
    /// (Assumes the 2-byte greeting arrives in one read, which it does on the loopback splice.)
    fn stripGsGreeting(g: *Gateway, c: *Conn) void {
        const bi = g.poolAcquire() orelse return;
        const got = read(c.gs, &g.pool[bi], BUF_SZ);
        if (got == 0) {
            c.gs_eof = true;
            g.poolRelease(bi);
            return;
        }
        if (got < 0) {
            g.poolRelease(bi);
            if (lastErrno() != EAGAIN) c.gs_eof = true;
            return;
        }
        c.gs_greeted = true; // only the first GS read carries the greeting
        const un: u32 = @intCast(got);
        const start = greetingStripLen(g.pool[bi][0..un]);
        if (start == 0 and g.pool[bi][0] != 0xAF)
            log.line("d2ingress", "GS's first byte is 0x{x:0>2}, not a 0xAF greeting — forwarding as-is", .{g.pool[bi][0]});
        const payload = g.pool[bi][start..un];
        if (payload.len == 0) { // greeting only; splice the rest on the next read
            g.poolRelease(bi);
            return;
        }
        c.g2c_bytes += payload.len;
        if (trace) log.hexdump("d2ingress GS->C", payload);
        const w = write(c.cli, payload.ptr, payload.len);
        if (w == @as(isize, @intCast(payload.len))) {
            g.poolRelease(bi);
            return;
        }
        if (w < 0 and lastErrno() != EAGAIN) {
            g.poolRelease(bi);
            c.cli_eof = true;
            return;
        }
        // Partial write: park the unsent remainder for a later POLLOUT, shifted to buffer start
        // so the existing flush(off..len) logic sends exactly it.
        const sent: u32 = if (w > 0) @intCast(w) else 0;
        const rem = payload[sent..];
        std.mem.copyForwards(u8, g.pool[bi][0..rem.len], rem);
        c.g2c = @intCast(bi);
        c.g2c_off = 0;
        c.g2c_len = @intCast(rem.len);
    }

    fn flush(g: *Gateway, dst: c_int, idx: *i32, off: *u32, len: *u32, dst_eof: *bool) void {
        if (idx.* < 0) return;
        const bi: u16 = @intCast(idx.*);
        const s = g.pool[bi][off.*..len.*];
        const w = write(dst, s.ptr, s.len);
        if (w <= 0) {
            if (w < 0 and lastErrno() == EAGAIN) return;
            g.poolRelease(bi);
            idx.* = -1;
            off.* = 0;
            len.* = 0;
            dst_eof.* = true;
            return;
        }
        off.* += @intCast(w);
        if (off.* >= len.*) {
            g.poolRelease(bi);
            idx.* = -1;
            off.* = 0;
            len.* = 0;
        }
    }

    fn propagateEofAndMaybeClose(g: *Gateway, c: *Conn) void {
        if (c.cli_eof and c.c2g < 0) _ = shutdown(c.gs, 1);
        if (c.gs_eof and c.g2c < 0) _ = shutdown(c.cli, 1);
        const c2g_done = c.cli_eof and c.c2g < 0;
        const g2c_done = c.gs_eof and c.g2c < 0;
        if (c2g_done and g2c_done) g.closeConn(c);
    }
};

/// Parse one RESP reply for a GET: `$<len>\r\n<bytes>\r\n` (bulk, our 10-byte route),
/// `$-1\r\n` (nil = no route), or `-err`/`+ok`/`:int` (treated as no route). Returns null
/// when the buffer doesn't yet hold a complete reply.
fn parseReply(buf: []const u8) ?ParsedReply {
    if (buf.len == 0) return null;
    const crlf = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    switch (buf[0]) {
        '$' => {
            const len = std.fmt.parseInt(i64, buf[1..crlf], 10) catch return .{ .consumed = crlf + 2, .found = false };
            if (len < 0) return .{ .consumed = crlf + 2, .found = false }; // nil
            const ulen: usize = @intCast(len);
            const total = crlf + 2 + ulen + 2;
            if (buf.len < total) return null; // payload not fully arrived
            const payload = buf[crlf + 2 .. crlf + 2 + ulen];
            if (ulen < ROUTE_BYTES) return .{ .consumed = total, .found = false };
            return .{
                .consumed = total,
                .found = true,
                .ip = payload[0..4].*,
                .port = std.mem.readInt(u16, payload[4..6], .little),
                .gameid = std.mem.readInt(u32, payload[6..10], .little),
            };
        },
        else => return .{ .consumed = crlf + 2, .found = false }, // -err / +ok / :int → no route
    }
}

test "parseReply: complete 10-byte route decodes ip/port/gameid" {
    const t = std.testing;
    // ip 127.0.0.1, port 4100 (LE 04 10), gameid 10 (LE 0A 00 00 00)
    const reply = "$10\r\n" ++ [_]u8{ 127, 0, 0, 1, 0x04, 0x10, 0x0A, 0, 0, 0 } ++ "\r\n";
    const pr = parseReply(reply) orelse return error.ExpectedReply;
    try t.expect(pr.found);
    try t.expectEqual(reply.len, pr.consumed);
    try t.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &pr.ip);
    try t.expectEqual(@as(u16, 4100), pr.port);
    try t.expectEqual(@as(u32, 10), pr.gameid);
}

test "parseReply: nil / error / short-bulk are 'no route' (found=false)" {
    const t = std.testing;
    const nil = parseReply("$-1\r\n") orelse return error.ExpectedReply;
    try t.expect(!nil.found);
    try t.expectEqual(@as(usize, 5), nil.consumed);
    try t.expect(!(parseReply("-ERR nope\r\n").?.found)); // redis error reply
    try t.expect(!(parseReply("$4\r\nabcd\r\n").?.found)); // bulk shorter than a route
}

test "parseReply: returns null until a full reply has arrived" {
    const t = std.testing;
    try t.expectEqual(@as(?ParsedReply, null), parseReply("")); // empty
    try t.expectEqual(@as(?ParsedReply, null), parseReply("$10")); // no CRLF yet
    try t.expectEqual(@as(?ParsedReply, null), parseReply("$10\r\n" ++ [_]u8{ 1, 2, 3 })); // payload partial
}

pub fn main() !void {
    const cfg = config.fromEnv();
    log.json = cfg.log_json;
    trace = getenv("REALMD_INGRESS_TRACE") != null;
    if (trace) log.line("d2ingress", "REALMD_INGRESS_TRACE on — hexdumping spliced traffic", .{});

    // Resolve the redis host once (blocking, startup only). cfg.redis_addr is "host:port".
    var host_buf: [256]u8 = undefined;
    var host: []const u8 = cfg.redis_addr;
    var rport: u16 = 6379;
    if (std.mem.lastIndexOfScalar(u8, cfg.redis_addr, ':')) |i| {
        host = cfg.redis_addr[0..i];
        rport = std.fmt.parseInt(u16, cfg.redis_addr[i + 1 ..], 10) catch 6379;
    }
    if (host.len == 0 or host.len >= host_buf.len) host = "127.0.0.1";
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    const host_z = host_buf[0..host.len :0];
    const redis_ip = resolveHost(host_z) orelse {
        log.line("d2ingress", "cannot resolve redis host '{s}'", .{host});
        return error.RedisResolveFailed;
    };

    const listen_fd = try listenTcp(cfg.bind, cfg.ingress_port);
    log.line("d2ingress", "d2ingress listening on {s}:{d} (poll loop, redis {d}.{d}.{d}.{d}:{d}, conns={d}, pool={d}x{d})", .{ cfg.bind, cfg.ingress_port, redis_ip[0], redis_ip[1], redis_ip[2], redis_ip[3], rport, MAX_CONN, POOL_N, BUF_SZ });

    // The whole gateway lives here, in main()'s frame — no globals, no heap. `.{}` applies
    // the field defaults (redis_fd=-1, redis_state=.disconnected, all counters 0; the big
    // buffers stay `undefined`); init() then fills the pool/active free lists.
    var gw: Gateway = .{};
    gw.init();
    gw.redis_ip = redis_ip;
    gw.redis_port = rport;
    gw.run(listen_fd);
}
