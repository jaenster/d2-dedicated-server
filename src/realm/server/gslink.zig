//! GS link — the d2cs<->d2gs control channel (the GS-facing side of d2cs).
//!
//! Game servers (our injected d2gs in Game.exe) connect OUTBOUND to this port,
//! wait for AUTHREQ, then reply AUTHREPLY + SETGSINFO + ADDRINFO and service
//! CREATEGAME (0x20) / JOINGAME (0x21) requests we send them. Each GS has its own
//! control connection; we keep a registry of them and route game creation to the
//! least-loaded one with spare capacity.
//!
//! A GS self-reports (via ADDRINFO 0x24) the public address clients must dial for
//! game traffic plus a stable `gsid` — necessary because behind a k8s Service the
//! control-connection peer IP is SNAT'd and useless as the client-facing address.
//! We fall back to the peer IP when a GS doesn't report one (single-host dev).
//!
//! 8-byte LE header `{ size:u16, type:u16, seqno:u32 }`. Create/join to a given GS
//! are serialised through that GS's `req_lock` (one request in flight per GS), so
//! replies need no seqno correlation; different GSes run concurrently.
const std = @import("std");
const net = @import("net.zig");
const log = @import("log.zig");
const state = @import("state.zig");
const Spinlock = @import("lock.zig").Spinlock;
const p = @import("realm_shared").protocol;

extern "c" fn usleep(usec: c_uint) c_int;

// Control message types — sourced from the SHARED d2cs<->d2gs protocol so both ends
// (this server-side gslink and the GS-side realm/client) agree on the wire by construction.
const TYPE_AUTHREQ = @intFromEnum(p.Type.authreq);
const TYPE_AUTHREPLY = @intFromEnum(p.Type.authreply);
const TYPE_SETGSINFO = @intFromEnum(p.Type.setgsinfo);
const TYPE_ECHO = @intFromEnum(p.Type.echo);
const TYPE_CREATEGAME = @intFromEnum(p.Type.creategame);
const TYPE_JOINGAME = @intFromEnum(p.Type.joingame);
const TYPE_UPDATEGAMEINFO = @intFromEnum(p.Type.updategameinfo);
const TYPE_CLOSEGAME = @intFromEnum(p.Type.closegame);
const TYPE_ADDRINFO = @intFromEnum(p.Type.addrinfo);

pub var realm_name: []const u8 = "TypeGuru";
/// Global override for the game-server IP advertised to clients (single-host dev /
/// NAT). When set it wins over a GS's self-reported and peer IPs for every GS.
pub var gs_ip_override: ?[4]u8 = null;

const max_gs = 64;

/// One registered game server (one control connection).
const Gs = struct {
    fd: net.Socket = -1,
    gsid: u32 = 0,
    peer_ip: [4]u8 = .{ 0, 0, 0, 0 }, // control-connection peer (fallback addr)
    pub_ip: [4]u8 = .{ 0, 0, 0, 0 }, // ADDRINFO self-reported client-facing addr
    port: u16 = 4000, // game port clients dial
    maxgame: u32 = 0, // advertised capacity (0 = unknown → unlimited)
    live_games: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    in_use: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // slot claimed
    registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // ADDRINFO seen → can host

    send_lock: Spinlock = .{}, // serialise writes to this GS fd
    req_lock: Spinlock = .{}, // one create/join in flight to this GS
    reply_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reply_result: u32 = 1,
    reply_gameid: u32 = 0,
    seqno: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Client-facing address: override > self-reported > control peer.
    fn ip(g: *Gs) [4]u8 {
        if (gs_ip_override) |o| return o;
        if (!isZero4(g.pub_ip)) return g.pub_ip;
        return g.peer_ip;
    }
};

const GsRegistry = struct {
    entries: [max_gs]Gs = [_]Gs{.{}} ** max_gs,
    lock: Spinlock = .{},

    /// Claim a free slot for a new connection (fields reset by the caller).
    fn alloc(self: *GsRegistry) ?*Gs {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.entries) |*g| {
            if (!g.in_use.load(.acquire)) {
                g.in_use.store(true, .release);
                g.registered.store(false, .release);
                return g;
            }
        }
        return null;
    }

    fn release(self: *GsRegistry, g: *Gs) void {
        self.lock.lock();
        defer self.lock.unlock();
        g.registered.store(false, .release);
        g.in_use.store(false, .release);
    }

    /// Least-loaded registered GS with spare capacity, or null if none.
    fn pickForCreate(self: *GsRegistry) ?*Gs {
        self.lock.lock();
        defer self.lock.unlock();
        var best: ?*Gs = null;
        var best_load: u32 = std.math.maxInt(u32);
        for (&self.entries) |*g| {
            if (!g.in_use.load(.acquire) or !g.registered.load(.acquire)) continue;
            const load = g.live_games.load(.acquire);
            if (g.maxgame != 0 and load >= g.maxgame) continue; // full
            if (load < best_load) {
                best = g;
                best_load = load;
            }
        }
        return best;
    }

    fn byId(self: *GsRegistry, gsid: u32) ?*Gs {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.entries) |*g| {
            if (g.in_use.load(.acquire) and g.registered.load(.acquire) and g.gsid == gsid) return g;
        }
        return null;
    }

    fn anyRegistered(self: *GsRegistry) bool {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.entries) |*g| {
            if (g.in_use.load(.acquire) and g.registered.load(.acquire)) return true;
        }
        return false;
    }
};

pub var registry: GsRegistry = .{};

/// Read-only view of one registered GS, for the admin API (does not leak the
/// internal Gs struct — only the fields the API exposes).
pub const GsInfo = struct { gsid: u32, ip: [4]u8, port: u16, maxgame: u32, live: u32 };

/// Snapshot the registered GSes into `buf` under the registry lock; returns the
/// number filled (capped at buf.len).
pub fn snapshot(buf: []GsInfo) usize {
    registry.lock.lock();
    defer registry.lock.unlock();
    var n: usize = 0;
    for (&registry.entries) |*g| {
        if (n >= buf.len) break;
        if (!g.in_use.load(.acquire) or !g.registered.load(.acquire)) continue;
        buf[n] = .{ .gsid = g.gsid, .ip = g.ip(), .port = g.port, .maxgame = g.maxgame, .live = g.live_games.load(.acquire) };
        n += 1;
    }
    return n;
}

/// Count of registered GSes (for /admin/status).
pub fn registeredCount() usize {
    registry.lock.lock();
    defer registry.lock.unlock();
    var n: usize = 0;
    for (&registry.entries) |*g| {
        if (g.in_use.load(.acquire) and g.registered.load(.acquire)) n += 1;
    }
    return n;
}

fn isZero4(a: [4]u8) bool {
    return a[0] == 0 and a[1] == 0 and a[2] == 0 and a[3] == 0;
}

fn nextSeq(g: *Gs) u32 {
    return g.seqno.fetchAdd(1, .monotonic) + 1;
}

fn sendPacket(g: *Gs, bytes: []const u8) bool {
    g.send_lock.lock();
    defer g.send_lock.unlock();
    return net.writeAll(g.fd, bytes);
}

/// True if at least one GS is registered and can host games.
pub fn ready() bool {
    return registry.anyRegistered();
}

// ── connection handler (a GS connects to us) ─────────────────────────────────

pub fn handle(fd: net.Socket, tag: []const u8) void {
    const g = registry.alloc() orelse {
        log.line(tag, "GS registry full ({d}); rejecting connection", .{max_gs});
        return;
    };
    defer {
        registry.release(g);
        state.global.expireGamesByGs(g.gsid);
        log.line(tag, "GS gsid=0x{x} disconnected; its games expired", .{g.gsid});
    }

    g.fd = fd;
    g.peer_ip = net.peerIp(fd);
    g.pub_ip = .{ 0, 0, 0, 0 };
    g.gsid = 0;
    g.port = 4000;
    g.maxgame = 0;
    g.live_games.store(0, .release);
    g.seqno.store(0, .release);
    g.reply_done.store(false, .release);
    log.line(tag, "GS connected from {d}.{d}.{d}.{d}; sending AUTHREQ", .{ g.peer_ip[0], g.peer_ip[1], g.peer_ip[2], g.peer_ip[3] });
    sendAuthReq(g);

    var hbuf: [8]u8 = undefined;
    var body: [4096]u8 = undefined;
    while (true) {
        if (!net.readFull(fd, &hbuf)) break;
        const size = std.mem.readInt(u16, hbuf[0..2], .little);
        const typ = std.mem.readInt(u16, hbuf[2..4], .little);
        if (size < 8) break;
        const blen: usize = size - 8;
        if (blen > body.len) break;
        if (blen > 0 and !net.readFull(fd, body[0..blen])) break;
        onPacket(tag, g, typ, body[0..blen]);
    }
}

fn sendAuthReq(g: *Gs) void {
    // AUTHREQ 0x10: sessionnum, signlen(=0), realmname\0
    var buf: [128]u8 = undefined;
    var pos: usize = 8;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little); // sessionnum
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .little); // signlen = 0
    pos += 4;
    @memcpy(buf[pos..][0..realm_name.len], realm_name);
    pos += realm_name.len;
    buf[pos] = 0;
    pos += 1;
    writeHeader(buf[0..8], @intCast(pos), TYPE_AUTHREQ, nextSeq(g));
    _ = sendPacket(g, buf[0..pos]);
}

fn onPacket(tag: []const u8, g: *Gs, typ: u16, body: []const u8) void {
    switch (typ) {
        TYPE_AUTHREPLY => log.line(tag, "GS AUTHREPLY (awaiting ADDRINFO to register)", .{}),
        TYPE_SETGSINFO => {
            if (body.len >= 4) g.maxgame = std.mem.readInt(u32, body[0..4], .little);
            log.line(tag, "GS SETGSINFO maxgame={d}", .{g.maxgame});
        },
        TYPE_ADDRINFO => {
            // { maxgame:u32, gsid:u32, ip:[4]u8, port:u16 } (see realm/protocol.zig)
            if (body.len >= 14) {
                g.maxgame = std.mem.readInt(u32, body[0..4], .little);
                g.gsid = std.mem.readInt(u32, body[4..8], .little);
                g.pub_ip = body[8..12].*;
                g.port = std.mem.readInt(u16, body[12..14], .little);
            }
            g.registered.store(true, .release);
            const a = g.ip();
            log.line(tag, "GS ADDRINFO gsid=0x{x} addr={d}.{d}.{d}.{d}:{d} maxgame={d} -> registered", .{ g.gsid, a[0], a[1], a[2], a[3], g.port, g.maxgame });
        },
        TYPE_ECHO => {
            var hbuf: [8]u8 = undefined;
            writeHeader(&hbuf, 8, TYPE_ECHO, nextSeq(g));
            _ = sendPacket(g, &hbuf);
        },
        TYPE_CREATEGAME, TYPE_JOINGAME => {
            // GS reply to our request: result, gameid.
            g.reply_result = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 1;
            g.reply_gameid = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
            g.reply_done.store(true, .release);
        },
        TYPE_UPDATEGAMEINFO => {}, // game population changes; ignore for now
        TYPE_CLOSEGAME => {
            const gameid = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
            state.global.removeGameById(gameid);
            if (g.live_games.load(.acquire) > 0) _ = g.live_games.fetchSub(1, .monotonic);
            log.line(tag, "GS CLOSEGAME gameid={d}", .{gameid});
        },
        else => log.line(tag, "GS unhandled control type 0x{x:0>2}", .{typ}),
    }
}

fn writeHeader(buf: []u8, size: u16, typ: u16, seq: u32) void {
    std.mem.writeInt(u16, buf[0..2], size, .little);
    std.mem.writeInt(u16, buf[2..4], typ, .little);
    std.mem.writeInt(u32, buf[4..8], seq, .little);
}

// ── request/response (called from client/MCP threads) ────────────────────────

const Result = struct { ok: bool, gameid: u32 };

fn awaitReply(g: *Gs) Result {
    // Poll the reply flag the control thread sets. Game create/join is rare and
    // latency-tolerant, so a short polling wait beats wrestling with condvars.
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) { // ~5s at 1ms
        if (g.reply_done.load(.acquire)) {
            return .{ .ok = g.reply_result == 0, .gameid = g.reply_gameid };
        }
        _ = usleep(1000); // 1ms
    }
    return .{ .ok = false, .gameid = 0 };
}

pub const CreateResult = struct { gsid: u32, gameid: u32, ip: [4]u8, port: u16 };

/// Route a game create to the least-loaded GS with capacity. Returns the chosen
/// GS's id + the engine gameid + the address clients dial, or null if no GS could
/// host it (none registered, all full, or the GS refused).
pub fn createGameRouted(name: []const u8, pass: []const u8, desc: []const u8, ladder: u8, expansion: bool, difficulty: u8, hardcore: bool) ?CreateResult {
    const g = registry.pickForCreate() orelse return null;
    g.req_lock.lock();
    defer g.req_lock.unlock();
    g.reply_done.store(false, .release);

    var buf: [512]u8 = undefined;
    var pos: usize = 8;
    buf[pos] = ladder;
    buf[pos + 1] = @intFromBool(expansion);
    buf[pos + 2] = difficulty;
    buf[pos + 3] = @intFromBool(hardcore);
    pos += 4;
    pos = putCStr(&buf, pos, name);
    pos = putCStr(&buf, pos, pass);
    pos = putCStr(&buf, pos, desc);
    writeHeader(buf[0..8], @intCast(pos), TYPE_CREATEGAME, nextSeq(g));
    if (!sendPacket(g, buf[0..pos])) return null;

    const r = awaitReply(g);
    if (!r.ok or r.gameid == 0) return null;
    _ = g.live_games.fetchAdd(1, .monotonic);
    return .{ .gsid = g.gsid, .gameid = r.gameid, .ip = g.ip(), .port = g.port };
}

/// Best-effort: tell the GS that owns `gsid` a client is joining `gameid`, so it can
/// fetch that account's character save. The client routes to the GS via the stored
/// game record regardless; this just primes the GS. Returns true on ack.
pub fn notifyJoin(gsid: u32, gameid: u32, token: u32, charname: []const u8, account: []const u8) bool {
    const g = registry.byId(gsid) orelse return false;
    g.req_lock.lock();
    defer g.req_lock.unlock();
    g.reply_done.store(false, .release);

    var buf: [160]u8 = undefined;
    std.mem.writeInt(u32, buf[8..12], gameid, .little);
    std.mem.writeInt(u32, buf[12..16], token, .little);
    var pos = putCStr(&buf, 16, charname);
    pos = putCStr(&buf, pos, account);
    writeHeader(buf[0..8], @intCast(pos), TYPE_JOINGAME, nextSeq(g));
    if (!sendPacket(g, buf[0..pos])) return false;

    return awaitReply(g).ok;
}

fn putCStr(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    buf[pos + s.len] = 0;
    return pos + s.len + 1;
}
