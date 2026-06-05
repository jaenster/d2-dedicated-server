//! D2CS client — the GS side of the PvPGN D2CS<->D2GS link.
//!
//! Connects outbound to PvPGN's D2CS, completes the auth handshake, advertises
//! capacity, then services game create/join requests by driving the engine
//! (token table + GAME_CreateBattleNetGame). Runs on its own thread.
//!
//! Status: WIP. Framing + handshake + dispatch loop are implemented; the auth
//! constants (version/checksum) and the create/join engine wiring still need to
//! be matched against the live PvPGN realm (see PVPGN.md).

const std = @import("std");
const p = @import("protocol.zig");
const server = @import("../engine/server.zig");
const log = @import("../log.zig");

// ── winsock (Game.exe already loaded ws2_32 + WSAStartup; we reuse it) ────────
const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;

const sockaddr_in = extern struct {
    family: u16,
    port: u16, // big-endian
    addr: u32, // big-endian
    zero: [8]u8 = .{0} ** 8,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, t: i32, proto: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn htons(v: u16) callconv(.winapi) u16;
extern "ws2_32" fn inet_addr(cp: [*:0]const u8) callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const INADDR_NONE: u32 = 0xffff_ffff;

// pvpgn d2gs identity — TODO: confirm against the realm's pvpgn build / d2cs.conf.
const D2GS_VERSION: u32 = 0x01;
const D2GS_CHECKSUM: u32 = 0x00;
const MAX_GAMES: u32 = 100;

var sock: SOCKET = INVALID_SOCKET;
var seqno: u32 = 0;

fn sendPacket(bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(sock, bytes.ptr + off, @intCast(bytes.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Read exactly `buf.len` bytes (blocking). false on disconnect/error.
fn recvAll(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(sock, buf.ptr + off, @intCast(buf.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn nextSeq() u32 {
    seqno +%= 1;
    return seqno;
}

fn sendAuthReply() void {
    var r = std.mem.zeroes(p.AuthReply);
    r.h = p.header(.authreply, @sizeOf(p.AuthReply), nextSeq());
    r.version = D2GS_VERSION;
    r.checksum = D2GS_CHECKSUM;
    r.signlen = 0; // sign left zero — relies on pvpgn skipping verification
    _ = sendPacket(std.mem.asBytes(&r));
    log.print("d2cs: sent AUTHREPLY");

    var info = std.mem.zeroes(p.SetGsInfo);
    info.h = p.header(.setgsinfo, @sizeOf(p.SetGsInfo), nextSeq());
    info.maxgame = MAX_GAMES;
    info.gameflag = 0;
    _ = sendPacket(std.mem.asBytes(&info));
    log.print("d2cs: sent SETGSINFO");
}

fn handleEcho(body: []const u8) void {
    // echo back the same payload with type echo
    var hbuf: [p.HEADER_LEN]u8 = undefined;
    const h = p.header(.echo, @intCast(p.HEADER_LEN + body.len), nextSeq());
    @memcpy(&hbuf, std.mem.asBytes(&h));
    _ = sendPacket(&hbuf);
    if (body.len > 0) _ = sendPacket(body);
}

fn handleJoinGame(body: []const u8) void {
    if (body.len < @sizeOf(p.JoinGameReq) - p.HEADER_LEN) return;
    const j: *const p.JoinGameReq = @ptrCast(@alignCast(body.ptr - p.HEADER_LEN));
    // Register the token so the engine's fpFindPlayerToken / SERVER_IsTokenValid
    // accept the incoming client. TODO: map gameid -> game-server id properly.
    server.QSERVER_PutNewGameOnTokenList(j.gameid, @truncate(j.token));
    log.hex("d2cs: JOINGAME token=0x", j.token);
}

fn dispatch(t: p.Type, body: []const u8) void {
    switch (t) {
        .authreq => sendAuthReply(),
        .echo => handleEcho(body),
        .creategame => log.print("d2cs: CREATEGAME (TODO: GAME_CreateBattleNetGame + reply)"),
        .joingame => handleJoinGame(body),
        .control => log.print("d2cs: CONTROL"),
        else => {},
    }
}

/// Connect + run the protocol loop once. Returns on disconnect.
fn run(addr: u32, port: u16) void {
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return;
    defer {
        _ = closesocket(sock);
        sock = INVALID_SOCKET;
    }
    const sa = sockaddr_in{ .family = AF_INET, .port = htons(port), .addr = addr };
    if (connect(sock, &sa, @sizeOf(sockaddr_in)) != 0) {
        log.print("d2cs: connect failed");
        return;
    }
    log.print("d2cs: connected, waiting for AUTHREQ");

    var hbuf: [p.HEADER_LEN]u8 = undefined;
    var body: [4096]u8 = undefined;
    while (true) {
        if (!recvAll(&hbuf)) break;
        const h: *const p.Header = @ptrCast(@alignCast(&hbuf));
        const blen: usize = if (h.size >= p.HEADER_LEN) h.size - p.HEADER_LEN else 0;
        if (blen > body.len) break; // oversized — bail
        if (blen > 0 and !recvAll(body[0..blen])) break;
        dispatch(@enumFromInt(h.type), body[0..blen]);
    }
    log.print("d2cs: disconnected");
}

const Args = struct { addr: u32, port: u16 };
var args: Args = undefined;

fn threadMain(_: ?*anyopaque) callconv(.winapi) u32 {
    var wsa: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsa);
    while (true) {
        run(args.addr, args.port);
        Sleep(5000); // reconnect backoff
    }
}

extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p_: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;

/// Start the D2CS client thread. `host` is a dotted-quad IPv4 string (DNS TODO).
pub fn start(host: [*:0]const u8, port: u16) void {
    const a = inet_addr(host);
    if (a == INADDR_NONE) {
        log.print("d2cs: bad host (dotted-quad IPv4 only for now)");
        return;
    }
    args = .{ .addr = a, .port = port };
    _ = CreateThread(null, 0, threadMain, null, 0, null);
    log.print("d2cs: client thread started");
}
