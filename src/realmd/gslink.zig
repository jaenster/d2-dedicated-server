//! GS link — the d2cs<->d2gs control channel (the GS-facing side of d2cs).
//!
//! Our injected game server (src/realm/d2cs.zig) connects OUTBOUND to this port,
//! waits for AUTHREQ, then replies AUTHREPLY + SETGSINFO and services CREATEGAME
//! (0x20) / JOINGAME (0x21) requests we send it. We give the GS its own port so
//! we never have to tell a GS control connection apart from a client MCP one.
//!
//! Because we own both ends there's no gameservlist IP whitelist and no shared
//! secret: the GS connects, we trust it, and the connection's peer IP is the
//! game-server address we hand to clients on join.
//!
//! 8-byte LE header `{ size:u16, type:u16, seqno:u32 }`. Layouts mirror
//! src/realm/protocol.zig (the GS already speaks this).
//!
//! MVP supports ONE registered GS (the common case). Create/join are serialised
//! through it (one request in flight), so replies need no seqno correlation —
//! the GS reuses its own seqno counter and doesn't echo ours.
const std = @import("std");
const net = @import("net.zig");
const log = @import("log.zig");
const state = @import("state.zig");
const Spinlock = @import("lock.zig").Spinlock;

extern "c" fn usleep(usec: c_uint) c_int;

const TYPE_AUTHREQ = 0x10;
const TYPE_AUTHREPLY = 0x11;
const TYPE_SETGSINFO = 0x12;
const TYPE_ECHO = 0x13;
const TYPE_CREATEGAME = 0x20;
const TYPE_JOINGAME = 0x21;
const TYPE_UPDATEGAMEINFO = 0x22;
const TYPE_CLOSEGAME = 0x23;

pub var realm_name: []const u8 = "TypeGuru";
/// Optional override for the game-server IP advertised to clients (when the GS
/// is behind NAT and its public IP differs from the control-connection peer IP).
pub var gs_ip_override: ?[4]u8 = null;

const Link = struct {
    fd: net.Socket = -1,
    gs_ip: [4]u8 = .{ 0, 0, 0, 0 },
    present: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    send_lock: Spinlock = .{}, // serialise writes to the GS fd (multiple threads)
    req_lock: Spinlock = .{}, // one create/join request in flight at a time

    reply_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reply_result: u32 = 1,
    reply_gameid: u32 = 0,
    seqno: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

var link: Link = .{};

fn nextSeq() u32 {
    return link.seqno.fetchAdd(1, .monotonic) + 1;
}

fn sendPacket(bytes: []const u8) bool {
    link.send_lock.lock();
    defer link.send_lock.unlock();
    return net.writeAll(link.fd, bytes);
}

/// True if a GS has completed AUTHREPLY and can host games.
pub fn ready() bool {
    return link.present.load(.acquire) and link.registered.load(.acquire);
}

/// The game-server IP clients should dial (override or control-conn peer IP).
pub fn gameServerIp() [4]u8 {
    return gs_ip_override orelse link.gs_ip;
}

// ── connection handler (the GS connects to us) ───────────────────────────────

pub fn handle(fd: net.Socket, tag: []const u8) void {
    // One GS at a time. If another is already present, reject the newcomer.
    if (link.present.swap(true, .acquire)) {
        log.line(tag, "a GS is already connected; rejecting extra connection", .{});
        return;
    }
    defer {
        link.registered.store(false, .release);
        link.present.store(false, .release);
    }

    link.fd = fd;
    link.gs_ip = net.peerIp(fd);
    log.line(tag, "GS connected from {d}.{d}.{d}.{d}; sending AUTHREQ", .{ link.gs_ip[0], link.gs_ip[1], link.gs_ip[2], link.gs_ip[3] });
    sendAuthReq();

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
        onPacket(tag, typ, body[0..blen]);
    }
    log.line(tag, "GS disconnected", .{});
}

fn sendAuthReq() void {
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
    writeHeader(buf[0..8], @intCast(pos), TYPE_AUTHREQ, nextSeq());
    _ = sendPacket(buf[0..pos]);
}

fn onPacket(tag: []const u8, typ: u16, body: []const u8) void {
    switch (typ) {
        TYPE_AUTHREPLY => {
            link.registered.store(true, .release);
            log.line(tag, "GS AUTHREPLY -> registered", .{});
        },
        TYPE_SETGSINFO => {
            const maxgame = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 0;
            log.line(tag, "GS SETGSINFO maxgame={d}", .{maxgame});
        },
        TYPE_ECHO => {
            var hbuf: [8]u8 = undefined;
            writeHeader(&hbuf, 8, TYPE_ECHO, nextSeq());
            _ = sendPacket(&hbuf);
        },
        TYPE_CREATEGAME, TYPE_JOINGAME => {
            // GS reply to our request: result, gameid.
            link.reply_result = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 1;
            link.reply_gameid = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
            link.reply_done.store(true, .release);
        },
        TYPE_UPDATEGAMEINFO => {}, // game population changes; ignore for now
        TYPE_CLOSEGAME => {
            const gameid = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
            state.global.removeGameById(gameid);
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

pub const Result = struct { ok: bool, gameid: u32 };

fn awaitReply() Result {
    // Poll the reply flag the control thread sets. Game create/join is rare and
    // latency-tolerant, so a short polling wait beats wrestling with condvars.
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) { // ~5s at 1ms
        if (link.reply_done.load(.acquire)) {
            return .{ .ok = link.reply_result == 0, .gameid = link.reply_gameid };
        }
        _ = usleep(1000); // 1ms
    }
    return .{ .ok = false, .gameid = 0 };
}

/// Ask the GS to create a game. Returns the engine gameid (0 on failure).
pub fn createGame(name: []const u8, pass: []const u8, desc: []const u8, ladder: u8, expansion: bool, difficulty: u8, hardcore: bool) u32 {
    if (!ready()) return 0;
    link.req_lock.lock();
    defer link.req_lock.unlock();
    link.reply_done.store(false, .release);

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
    writeHeader(buf[0..8], @intCast(pos), TYPE_CREATEGAME, nextSeq());
    if (!sendPacket(buf[0..pos])) return 0;

    const r = awaitReply();
    return if (r.ok) r.gameid else 0;
}

/// Ask the GS to authorise a join. The GS needs the account so it can fetch the
/// character save (the engine's dedicated-server path doesn't carry it), so we
/// send `{ gameid, token, charname\0, account\0 }`. Returns true on ack.
pub fn joinGame(gameid: u32, token: u32, charname: []const u8, account: []const u8) bool {
    if (!ready()) return false;
    link.req_lock.lock();
    defer link.req_lock.unlock();
    link.reply_done.store(false, .release);

    var buf: [160]u8 = undefined;
    std.mem.writeInt(u32, buf[8..12], gameid, .little);
    std.mem.writeInt(u32, buf[12..16], token, .little);
    var pos = putCStr(&buf, 16, charname);
    pos = putCStr(&buf, pos, account);
    writeHeader(buf[0..8], @intCast(pos), TYPE_JOINGAME, nextSeq());
    if (!sendPacket(buf[0..pos])) return false;

    return awaitReply().ok;
}

fn putCStr(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    buf[pos + s.len] = 0;
    return pos + s.len + 1;
}
