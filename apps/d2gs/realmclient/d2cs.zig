//! The realm-facing side of the game server.
//!
//! There is no control connection. This server publishes itself into the shared store, takes
//! create/join requests from its own queue there, and reports what happens on it as events any
//! realmd can apply. The realm and the game server never speak directly, which is what lets either
//! side be replaced, restarted, or run several times over without the other noticing.
//!
//! The wire format is unchanged: the same 8-byte `{ size:u16, type:u16, seqno:u32 }` control
//! packets that used to travel a socket now travel redis. The `seqno` finally does the job its name
//! implies — over one socket with one request in flight "the next reply is mine" was true by
//! construction, and through a shared queue it is simply false.

const std = @import("std");
const p = @import("realm_proto").protocol;
const server = @import("../engine/server.zig");
const command = @import("../engine/command.zig");
const joinctx = @import("joinctx.zig");
const redis = @import("redis.zig");
const poolstat = @import("../runtime/poolstat.zig");
const log = @import("../log.zig");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
extern "kernel32" fn CreateThread(a: ?*anyopaque, st: usize, f: *const fn (?*anyopaque) callconv(.winapi) u32, p_: ?*anyopaque, fl: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;

/// Game capacity this GS advertises. Set by start().
pub var max_games: u32 = 100;
/// Public address clients dial for game traffic. Behind a k8s Service the peer IP a realm would
/// observe is SNAT'd, so the server announces its own.
pub var public_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var public_port: u16 = 4000;
/// Stable id keying this GS in a fleet (hash of the pod/host name). Set by start().
pub var gsid: u32 = 0;

/// True once this server's record is in the shared store — readiness, as opposed to liveness.
/// A server the realm cannot see is perfectly alive but cannot be given a game.
pub var registered: bool = false;

/// A tiny atomic lock (std.Thread.Mutex isn't built for the GS DLL target).
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

var seqno: u32 = 0;

fn nextSeq() u32 {
    seqno +%= 1;
    return seqno;
}

/// How long a reply is worth keeping. The realm is waiting on it right now; one nobody collected is
/// of no use to anyone later.
const reply_ttl_s: u32 = 30;
/// Backstops on the event list for a realm with nothing draining it.
const event_cap: u32 = 4096;
const event_ttl_s: u32 = 3600;

/// Answer the request carrying `seq`. Only ever called from the queue thread, and the seq is passed
/// down from the request rather than held in a global — game events fire on the engine tick thread,
/// and a shared "currently servicing" flag routed those into a reply key instead. The realm then
/// never learned a player had left, so the character stayed seated in a game that had ended.
fn reply(seq: u32, bytes: []const u8) void {
    _ = redis.putReply(seq, bytes, reply_ttl_s);
}

/// Report something that happened here. Fire and forget: nobody is waiting, and a store that is
/// briefly away must not stall a game.
fn emit(bytes: []const u8) void {
    _ = redis.pushEvent(bytes, event_cap, event_ttl_s);
}

fn sendCreateGameReply(seq: u32, result: u32, gameid: u32) void {
    var r = std.mem.zeroes(p.CreateGameReply);
    r.h = p.header(.creategame, @sizeOf(p.CreateGameReply), seq);
    r.result = result;
    r.gameid = gameid;
    reply(seq, std.mem.asBytes(&r));
}

fn sendJoinGameReply(seq: u32, result: u32, gameid: u32) void {
    var r = std.mem.zeroes(p.JoinGameReply);
    r.h = p.header(.joingame, @sizeOf(p.JoinGameReply), seq);
    r.result = result;
    r.gameid = gameid;
    reply(seq, std.mem.asBytes(&r));
}

// game name -> gameid tracking (for CLOSEGAME on destroy): createGame's gameid is the id realmd
// indexed the game by. Remember name->gameid on create, since the engine's destroy hook
// (srvtrace) hands us only the NAME — without this, dead games linger in realmd's join list until
// their redis TTL (~hours), and clients joining one get "game name and password don't match".
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

/// srvtrace game-destroy observer: tell the realm to drop the game from the join list.
/// Registered as `srvtrace.on_game_destroy` by the GS realm bootstrap. Runs on the engine
/// tick thread.
pub fn onGameDestroyed(name: []const u8) void {
    const gid = takeGameId(name) orelse return;
    var r = std.mem.zeroes(p.CloseGame);
    r.h = p.header(.closegame, @sizeOf(p.CloseGame), nextSeq());
    r.gameid = gid;
    emit(std.mem.asBytes(&r));
    log.hex("d2cs: game closed, gameid=0x", gid);
    // The realm routes the next create on this server's published load, so a freed slot that
    // waits for the next heartbeat is a slot the realm will not use for up to half a minute.
    // On a server that hosts one game that is the whole gap between two games.
    publish();
}

/// srvtrace player-count observer: report this GS's own client count for the game so
/// the realm's join list stays honest. Fires on the engine tick thread.
///
/// A game we never tracked is one we didn't create, so we have no gameid to name it by
/// and stay quiet rather than guess.
pub fn onPlayersChanged(name: []const u8, players: u32, joined: bool, char: []const u8, level: u32, class: u32) void {
    const gid = peekGameId(name) orelse return;
    var buf: [@sizeOf(p.UpdateGameInfo) + 24]u8 = undefined;
    var r = std.mem.zeroes(p.UpdateGameInfo);
    r.flag = if (joined) p.GAMEINFO_ENTER else p.GAMEINFO_LEAVE;
    r.gameid = gid;
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
    emit(buf[0..total]);
}

/// CREATEGAMEREQ: ladder/expansion/difficulty/hardcore byte flags, then
/// gamename/gamepass/gamedesc cstrs (null-terminated in `body`).
fn handleCreateGame(seq: u32, body: []const u8) void {
    if (body.len < 5) {
        sendCreateGameReply(seq, 1, 0);
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
    if (peekGameId(name) != null) {
        log.print("d2cs: CREATEGAME refused — already hosting that name");
        sendCreateGameReply(seq, p.CREATE_NAME_TAKEN, 0);
        return;
    }

    // The engine keeps ONE memory-pool manager per game and there are eight in total, one of
    // which is the global system's — so seven games, and asking for the eighth does not fail,
    // it raises 0xe0000001 and kills the process along with every game already on it. Refusing
    // here turns a server death into the client being told the server is full.
    if (poolstat.freeManagers() == 0) {
        log.print("d2cs: CREATEGAME refused — no memory-pool manager free (this GS is at its game limit)");
        sendCreateGameReply(seq, p.CREATE_SERVER_FULL, 0);
        publish(); // say so in the record too, so the realm stops routing here
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
        sendCreateGameReply(seq, 0, game_id);
        log.hex("d2cs: CREATEGAME spawned, gameid=0x", game_id);
    } else {
        sendCreateGameReply(seq, 1, 0);
        log.print("d2cs: CREATEGAME failed");
    }
}

/// JOINGAMEREQ: gameid, token, charname\0, account\0. We cache the
/// token/char/account mapping so fpGetDatabaseCharacter can fetch the right save
/// (the engine's join path carries the char + token but never the account).
fn handleJoinGame(seq: u32, body: []const u8) void {
    if (body.len < 8) {
        sendJoinGameReply(seq, 1, 0);
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
    sendJoinGameReply(seq, if (command.allow_create) 0 else 1, gameid);
    log.hex("d2cs: JOINGAME ack for gameid=0x", gameid);
}

// the request queue

/// Drained on its OWN thread, never from the engine tick.
///
/// Creating a game hands work to the tick loop and waits for it. Calling it FROM the tick means
/// the tick cannot advance to do that work, so every create returns 0 — which presents as the
/// server refusing perfectly good requests, with nothing in the log to say why.
fn queueThreadMain(_: ?*anyopaque) callconv(.winapi) u32 {
    while (true) {
        pumpQueue();
        Sleep(20);
    }
}

var queue_thread_started = false;

pub fn startQueueConsumer() void {
    if (queue_thread_started or !redis.enabled() or gsid == 0) return;
    queue_thread_started = true;
    _ = CreateThread(null, 0, queueThreadMain, null, 0, null);
    log.print("d2cs: taking create/join from the store");
}

pub fn pumpQueue() void {
    if (!redis.enabled() or gsid == 0) return;
    var buf: [1024]u8 = undefined;
    const n = redis.popRequest(gsid, &buf);
    if (n < p.HEADER_LEN) return;
    const size = std.mem.readInt(u16, buf[0..2], .little);
    const typ = std.mem.readInt(u16, buf[2..4], .little);
    const seq = std.mem.readInt(u32, buf[4..8], .little);
    if (size > n or size < p.HEADER_LEN) return; // truncated; nothing sensible to answer
    const body = buf[p.HEADER_LEN..size];
    switch (@as(p.Type, @enumFromInt(typ))) {
        .creategame => handleCreateGame(seq, body),
        .joingame => handleJoinGame(seq, body),
        else => {},
    }
}

// publishing this server

const heartbeat_ttl_s: u32 = 90;
var last_publish_ms: u32 = 0;

/// Write this server's record: it exists, where clients reach it, and how loaded it is.
///
/// The server reports itself rather than being reported by a realm that holds its connection. That
/// is the point: the record outlives any one instance's view of the fleet, and its TTL is how a
/// server that dies leaves without anyone having to notice.
///
/// `full` is the server answering a question its own game count cannot: a finished game holds its
/// engine memory-pool slot through the reap window, so it can be out of room while the count still
/// shows space.
fn publish() void {
    if (!redis.enabled() or gsid == 0) return;
    const full = poolstat.freeManagers() == 0;
    if (redis.putHeartbeat(gsid, public_ip, public_port, max_games, liveGames(), full, heartbeat_ttl_s)) {
        last_publish_ms = GetTickCount();
        registered = true;
    }
}

/// Called every tick. Refreshes at a third of the TTL: often enough that a healthy server never
/// blinks out of the fleet, rarely enough that it is not a store round trip per frame.
pub fn heartbeat() void {
    if (!redis.enabled() or gsid == 0) return;
    // Wrapping subtraction: GetTickCount rolls over about every 49 days, and a server that has
    // been up that long must not stop reporting itself.
    if (registered and GetTickCount() -% last_publish_ms < heartbeat_ttl_s * 1000 / 3) return;
    publish();
}

/// Announce this server has just started, so the realm expires whatever games still name it.
///
/// A server that just came up hosts nothing, so any game record naming it is a leftover — from one
/// that died without deregistering, or from records that outlived a realmd restart. They must go,
/// or their names stay taken forever and create-game rejects them as duplicates.
fn announceBoot() void {
    var ai = std.mem.zeroes(p.AddrInfo);
    ai.h = p.header(.addrinfo, @sizeOf(p.AddrInfo), nextSeq());
    ai.maxgame = max_games;
    ai.gsid = gsid;
    ai.ip = public_ip;
    ai.port = public_port;
    emit(std.mem.asBytes(&ai));
}

fn bootThreadMain(_: ?*anyopaque) callconv(.winapi) u32 {
    // Retry: the game server and the store come up in whatever order the deployment gives them,
    // and a server that gave up on its first attempt would be invisible to the realm forever.
    while (!redis.enabled() or !redis.ping()) Sleep(2000);
    publish();
    announceBoot();
    log.print("d2cs: published to the realm store");
    return 0;
}

/// Join a realm. `pub_ip`:`pub_port` is the public game address clients dial; `maxgame` the
/// advertised capacity; `gs_id` this GS's stable fleet id.
pub fn start(pub_ip: [4]u8, pub_port: u16, maxgame: u32, gs_id: u32) void {
    public_ip = pub_ip;
    public_port = pub_port;
    max_games = maxgame;
    gsid = gs_id;
    _ = CreateThread(null, 0, bootThreadMain, null, 0, null);
}
