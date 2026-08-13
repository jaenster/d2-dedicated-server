//! D2CS client — the GS side of the PvPGN D2CS<->D2GS link.
//!
//! Connects outbound to PvPGN's D2CS, completes the auth handshake, advertises
//! capacity, then services game create/join requests by driving the engine
//! (token table + GAME_CreateBattleNetGame). Runs on its own thread.
//!
//! Status: WIP. Framing + handshake + dispatch loop are implemented; the auth
//! constants (version/checksum) and the create/join engine wiring still need to
//! be matched against the live realm.

const std = @import("std");
const p = @import("realm_proto").protocol;
const server = @import("../engine/server.zig");
const command = @import("../engine/command.zig");
const joinctx = @import("joinctx.zig");
const poolstat = @import("../runtime/poolstat.zig");
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

// getaddrinfo (Win32 ADDRINFOA, 32-bit layout) so the GS can dial D2CS by DNS name
// (e.g. a k8s Service) instead of a dotted-quad only.
const addrinfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*sockaddr_in,
    next: ?*addrinfo,
};
extern "ws2_32" fn getaddrinfo(node: [*:0]const u8, service: ?[*:0]const u8, hints: ?*const addrinfo, res: **addrinfo) callconv(.winapi) i32;
extern "ws2_32" fn freeaddrinfo(res: *addrinfo) callconv(.winapi) void;

const INADDR_NONE: u32 = 0xffff_ffff;

// pvpgn d2gs identity — TODO: confirm against the realm's pvpgn build / d2cs.conf.
const D2GS_VERSION: u32 = 0x01;
const D2GS_CHECKSUM: u32 = 0x00;

/// Game capacity this GS advertises to D2CS (SETGSINFO maxgame). Set by start().
pub var max_games: u32 = 100;
/// Public address clients dial for game traffic, self-reported via ADDRINFO. Behind
/// a k8s Service the control-conn peer IP is SNAT'd, so the GS must announce its own.
pub var public_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var public_port: u16 = 4000;
/// Stable id keying this GS in a fleet (hash of the pod/host name). Set by start().
pub var gsid: u32 = 0;

var sock: SOCKET = INVALID_SOCKET;
var seqno: u32 = 0;

// A tiny atomic lock (std.Thread.Mutex isn't built for the GS DLL target). Contention is
// near-zero, but one guarded section is a blocking send(): on socket back-pressure a pure
// spinner burns a core, and one of the two threads taking it is the engine tick thread, which
// owes every live game a frame every 40 ms. So spin only briefly, then yield.
const Lock = struct {
    held: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *Lock) void {
        var spins: u32 = 0;
        while (self.held.swap(true, .acquire)) : (spins += 1) {
            if (spins < 64) std.atomic.spinLoopHint() else Sleep(if (spins < 128) 0 else 1);
        }
    }
    fn unlock(self: *Lock) void {
        self.held.store(false, .release);
    }
};

// Replies are sent from the gslink control thread, but CLOSEGAME is sent from the
// engine tick thread (srvtrace's game-destroy hook). Serialize so two senders can't
// interleave bytes on the shared socket.
var send_lock: Lock = .{};

fn sendPacket(bytes: []const u8) bool {
    send_lock.lock();
    defer send_lock.unlock();
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
    info.maxgame = max_games;
    info.gameflag = 0;
    _ = sendPacket(std.mem.asBytes(&info));
    log.print("d2cs: sent SETGSINFO");

    // Tell D2CS the public address clients must dial + our fleet id (our extension).
    var ai = std.mem.zeroes(p.AddrInfo);
    ai.h = p.header(.addrinfo, @sizeOf(p.AddrInfo), nextSeq());
    ai.maxgame = max_games;
    ai.gsid = gsid;
    ai.ip = public_ip;
    ai.port = public_port;
    _ = sendPacket(std.mem.asBytes(&ai));
    log.print("d2cs: sent ADDRINFO");
}

fn handleEcho(body: []const u8) void {
    // echo back the same payload with type echo
    var hbuf: [p.HEADER_LEN]u8 = undefined;
    const h = p.header(.echo, @intCast(p.HEADER_LEN + body.len), nextSeq());
    @memcpy(&hbuf, std.mem.asBytes(&h));
    _ = sendPacket(&hbuf);
    if (body.len > 0) _ = sendPacket(body);
}

fn sendCreateGameReply(result: u32, gameid: u32) void {
    var r = std.mem.zeroes(p.CreateGameReply);
    r.h = p.header(.creategame, @sizeOf(p.CreateGameReply), nextSeq());
    r.result = result;
    r.gameid = gameid;
    _ = sendPacket(std.mem.asBytes(&r));
}

fn sendJoinGameReply(result: u32, gameid: u32) void {
    var r = std.mem.zeroes(p.JoinGameReply);
    r.h = p.header(.joingame, @sizeOf(p.JoinGameReply), nextSeq());
    r.result = result;
    r.gameid = gameid;
    _ = sendPacket(std.mem.asBytes(&r));
}

// ── game name -> gameid tracking (for CLOSEGAME on destroy) ───────────────────
// We know the gameid createGame returned — the same id realmd indexed the game by.
// Remember name->gameid on create so that when the engine destroys the game later
// (srvtrace's game-destroy hook hands us the NAME), we can tell realmd which gameid
// to drop. Without this, dead games linger in realmd's join list until their redis
// TTL (~hours) and clients joining one get "game name and password don't match".
const GameSlot = struct { name: [16]u8 = undefined, len: u8 = 0, gameid: u32 = 0, used: bool = false };
var games_lock: Lock = .{};
var games_tracked = [_]GameSlot{.{}} ** 256;

// Count of games that exist on this GS, from CREATE (recordGame, before the first
// join) to DESTROY (takeGameId). The tick loop reads this to skip the engine's
// per-tick server work when zero — covering the create→join gap that a join-based
// count would miss (and would deadlock: the join can't be serviced if we skip).
var live_count = std.atomic.Value(u32).init(0);

/// Number of games live on this GS (create→destroy). Lock-free, called every tick.
pub fn liveGames() u32 {
    return live_count.load(.monotonic);
}

fn recordGame(name: []const u8, gameid: u32) void {
    games_lock.lock();
    defer games_lock.unlock();
    var free: ?usize = null;
    for (&games_tracked, 0..) |*g, i| {
        if (g.used and g.gameid == gameid) {
            free = i; // reuse: a recycled gameid replaces its stale entry
            break;
        }
        if (!g.used and free == null) free = i;
    }
    const idx = free orelse return; // table full — let the realmd-side TTL reap it
    if (!games_tracked[idx].used) _ = live_count.fetchAdd(1, .monotonic); // fresh slot, not a reuse
    const n = @min(name.len, 16);
    @memcpy(games_tracked[idx].name[0..n], name[0..n]);
    games_tracked[idx].len = @intCast(n);
    games_tracked[idx].gameid = gameid;
    games_tracked[idx].used = true;
}

/// Look up the gameid for `name`, leaving the entry in place. Null if it was never
/// tracked — which is the normal case for a game this GS didn't create.
fn peekGameId(name: []const u8) ?u32 {
    games_lock.lock();
    defer games_lock.unlock();
    for (&games_tracked) |*g| {
        if (g.used and std.mem.eql(u8, g.name[0..g.len], name)) return g.gameid;
    }
    return null;
}

/// Look up + forget the gameid for `name`. Null if it was never tracked.
fn takeGameId(name: []const u8) ?u32 {
    games_lock.lock();
    defer games_lock.unlock();
    for (&games_tracked) |*g| {
        if (g.used and std.mem.eql(u8, g.name[0..g.len], name)) {
            g.used = false;
            _ = live_count.fetchSub(1, .monotonic);
            return g.gameid;
        }
    }
    return null;
}

fn sendCloseGame(gameid: u32) void {
    var r = std.mem.zeroes(p.CloseGame);
    r.h = p.header(.closegame, @sizeOf(p.CloseGame), nextSeq());
    r.gameid = gameid;
    _ = sendPacket(std.mem.asBytes(&r));
    log.hex("d2cs: sent CLOSEGAME gameid=0x", gameid);
}

/// srvtrace game-destroy observer: tell realmd to drop the game from the join list.
/// Registered as `srvtrace.on_game_destroy` by the GS realm bootstrap.
pub fn onGameDestroyed(name: []const u8) void {
    if (takeGameId(name)) |gid| sendCloseGame(gid);
}

fn sendUpdateGameInfo(gameid: u32, flag: u32, players: u32, char: []const u8, level: u32, class: u32) void {
    var buf: [@sizeOf(p.UpdateGameInfo) + 24]u8 = undefined;
    var r = std.mem.zeroes(p.UpdateGameInfo);
    r.flag = flag;
    r.gameid = gameid;
    r.players = players;
    r.charlevel = level;
    r.charclass = class;
    @memcpy(buf[0..@sizeOf(p.UpdateGameInfo)], std.mem.asBytes(&r));
    // `n` is spelled usize on purpose. @min against a comptime bound gives the result the
    // smallest type that holds it — here u5 — and then `@sizeOf(UpdateGameInfo) + n` is u5
    // arithmetic that overflows at 32, so every character whose name is 4 or more letters
    // long panicked this thread on the way into a game.
    const n: usize = @min(char.len, buf.len - @sizeOf(p.UpdateGameInfo) - 1);
    @memcpy(buf[@sizeOf(p.UpdateGameInfo)..][0..n], char[0..n]);
    buf[@sizeOf(p.UpdateGameInfo) + n] = 0; // cstr terminator
    const total = @sizeOf(p.UpdateGameInfo) + n + 1;
    const hdr = p.header(.updategameinfo, @intCast(total), nextSeq());
    @memcpy(buf[0..@sizeOf(p.Header)], std.mem.asBytes(&hdr));
    _ = sendPacket(buf[0..total]);
}

/// srvtrace player-count observer: report this GS's own client count for the game so
/// realmd's join list stays honest. Fires on the engine tick thread, like CLOSEGAME.
///
/// A game we never tracked is one we didn't create, so we have no gameid to name it by
/// and stay quiet rather than guess.
pub fn onPlayersChanged(name: []const u8, players: u32, joined: bool, char: []const u8, level: u32, class: u32) void {
    const gid = peekGameId(name) orelse return;
    sendUpdateGameInfo(gid, if (joined) p.GAMEINFO_ENTER else p.GAMEINFO_LEAVE, players, char, level, class);
}

/// CREATEGAMEREQ: ladder/expansion/difficulty/hardcore byte flags, then
/// gamename/gamepass/gamedesc/acct/char/ip cstrs (null-terminated in `body`).
fn handleCreateGame(body: []const u8) void {
    if (body.len < 5) {
        sendCreateGameReply(1, 0);
        return;
    }
    var off: usize = 4;
    const name = p.readCStr(body, &off);
    const pass = p.readCStr(body, &off);
    const desc = p.readCStr(body, &off);

    // Never hand the engine a name it is already hosting. Its own de-duplicator
    // (SetGameName @0x52f940) formats the name pointer into a stack buffer with
    // `sprintf(buf + len, "~%d", (int)szGameName)` and blows the stack cookie —
    // the whole process dies with 0xC0000409, taking every other game with it.
    // On a real realm D2CS guarantees uniqueness so the path is never walked; here
    // two clients racing to create the same name reach it every time.
    if (peekGameId(name) != null) {
        log.print("d2cs: CREATEGAME refused — already hosting that name");
        sendCreateGameReply(p.CREATE_NAME_TAKEN, 0);
        return;
    }

    // The engine keeps ONE memory-pool manager per game and there are eight in total, one of
    // which is the global system's — so seven games, and asking for the eighth does not fail,
    // it raises 0xe0000001 and kills the process along with every game already on it. Refusing
    // here turns a server death into the client being told the server is full.
    if (poolstat.freeManagers() == 0) {
        log.print("d2cs: CREATEGAME refused — no memory-pool manager free (this GS is at its game limit)");
        sendCreateGameReply(p.CREATE_SERVER_FULL, 0);
        return;
    }

    const ladder = body[0];
    const expansion = body[1] != 0;
    const difficulty: u3 = @truncate(body[2]);
    const hardcore = body[3] != 0;
    const flags = server.gameFlags(difficulty, expansion, hardcore);

    // Enqueue for the tick thread (engine isn't safe to call from here directly).
    // The engine writes the server token (= gameid).
    const game_id = command.createGame(name, pass, desc, flags, ladder);
    if (game_id != 0) {
        recordGame(name, game_id); // remember name->gameid so destroy can CLOSEGAME it
        sendCreateGameReply(0, game_id);
        log.hex("d2cs: CREATEGAME spawned, gameid=0x", game_id);
    } else {
        sendCreateGameReply(1, 0);
        log.print("d2cs: CREATEGAME failed");
    }
}

/// JOINGAMEREQ: gameid, token, charname\0, account\0. We cache the
/// token/char/account mapping so fpGetDatabaseCharacter can fetch the right save
/// (the engine's join path carries the char + token but never the account).
fn handleJoinGame(body: []const u8) void {
    if (body.len < 8) {
        sendJoinGameReply(1, 0);
        return;
    }
    const gameid = std.mem.readInt(u32, body[0..4], .little);
    const token = std.mem.readInt(u32, body[4..8], .little);
    var off: usize = 8;
    const charname = p.readCStr(body, &off);
    const account = p.readCStr(body, &off);
    // Optional 3rd cstr: the joining player's guild tag (cut Guild Halls feature),
    // resolved by realmd. Absent from older realmd builds → empty.
    const guild_tag = if (off < body.len) p.readCStr(body, &off) else "";
    // The game's own token was registered by GAME_CreateBattleNetGame; this join
    // token authorizes a client to enter `gameid`, validated when the client
    // connects to :4000 (engine calls fpFindPlayerToken). We don't touch the
    // engine token table here — just remember who is joining so we can resolve
    // the account (and guild) when the engine asks us for the character save.
    if (charname.len > 0 and account.len > 0) {
        joinctx.remember(token, gameid, charname, account, guild_tag);
        if (guild_tag.len > 0) log.print("d2cs: JOINGAME cached char/account/guild for fetch") else log.print("d2cs: JOINGAME cached char/account for fetch");
    }
    sendJoinGameReply(if (command.allow_create) 0 else 1, gameid);
    log.hex("d2cs: JOINGAME ack for gameid=0x", gameid);
}

fn dispatch(t: p.Type, body: []const u8) void {
    switch (t) {
        .authreq => sendAuthReply(),
        .echo => handleEcho(body),
        .creategame => handleCreateGame(body),
        .joingame => handleJoinGame(body),
        .control => log.print("d2cs: CONTROL"),
        else => {},
    }
}

/// Resolve `host` to a network-order IPv4. Tries inet_addr (dotted-quad), then
/// getaddrinfo (DNS) so a k8s Service name works. Null if it can't be resolved.
fn resolveHost(host: [*:0]const u8) ?u32 {
    const direct = inet_addr(host);
    if (direct != INADDR_NONE) return direct;
    var hints = std.mem.zeroes(addrinfo);
    hints.family = AF_INET;
    hints.socktype = SOCK_STREAM;
    var res: *addrinfo = undefined;
    if (getaddrinfo(host, null, &hints, &res) != 0) return null;
    defer freeaddrinfo(res);
    var cur: ?*addrinfo = res;
    while (cur) |a| : (cur = a.next) {
        if (a.family == AF_INET) {
            if (a.addr) |sa| return sa.addr;
        }
    }
    return null;
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

const Args = struct { host: [*:0]const u8, port: u16 };
var args: Args = undefined;

fn threadMain(_: ?*anyopaque) callconv(.winapi) u32 {
    var wsa: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsa);
    while (true) {
        // Resolve every attempt so a re-pointed Service / changed pod IP is picked up.
        if (resolveHost(args.host)) |addr| {
            run(addr, args.port);
        } else {
            log.print("d2cs: host resolve failed");
        }
        Sleep(5000); // reconnect backoff
    }
}

extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p_: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;

/// Start the D2CS client thread. `host` may be a dotted-quad IPv4 or a DNS name
/// (resolved on the thread). `pub_ip`:`pub_port` is the public game address clients
/// dial; `maxgame` the advertised capacity; `gs_id` this GS's stable fleet id.
pub fn start(host: [*:0]const u8, port: u16, pub_ip: [4]u8, pub_port: u16, maxgame: u32, gs_id: u32) void {
    args = .{ .host = host, .port = port };
    public_ip = pub_ip;
    public_port = pub_port;
    max_games = maxgame;
    gsid = gs_id;
    _ = CreateThread(null, 0, threadMain, null, 0, null);
    log.print("d2cs: client thread started");
}
