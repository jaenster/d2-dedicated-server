//! The realm's control link, from the Mac image's side.
//!
//! Same channel `apps/d2gs/realmclient/d2cs.zig` speaks on Windows and the same wire types, but a
//! different engine underneath: this build has no `GAME_CreateBattleNetGame` and no realm callback
//! table, so a game is made by calling `GAME_CreateGame` 0x001ac3f3 — the one the 0x67 packet uses
//! — with a null client. That is survivable: the only two things it does with the client are store
//! it in the new player record and hand it to a map that has a null-client singleton branch, which
//! is also where the new game's id ends up (0x00552568).
//!
//! One game at a time, always — see `max_games` for why that is a measurement rather than a
//! placeholder. A second create is refused rather than allowed to produce a game the engine would
//! never tick.

const std = @import("std");
const macho = @import("macho");
const chardb = @import("chardb.zig");
const p = @import("realm_proto").protocol;

// 0.16's std.posix has no socket layer, so the four calls this needs come straight from libc —
// the same shape `packages/realm-infra/net.zig` uses.
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn time(t: ?*i64) i64;

/// Milliseconds off the monotonic clock, for the one deadline here that is too short to be
/// measured in whole seconds. Falls back to `time()` if the clock cannot be read, which only
/// costs this the sub-second precision it was reaching for.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return time(null) *% 1000;
    return @as(i64, @intCast(ts.sec)) *% 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

var image: *const macho.load.Loaded = undefined;
var sock: c_int = -1;
var seqno: u32 = 0;
var started = false;

/// What the GS tells the realm to send clients to, and who it says it is.
var public_ip: [4]u8 = .{ 127, 0, 0, 1 };
var public_port: u16 = 4000;
var gsid: u32 = 0;

const addr = struct {
    /// (client, name, u8, u8, desc, u16, flags, u8, u8, u8, u8, u8, 0, 0) — __cdecl, void.
    const game_create: u32 = 0x001ac3f3;
    /// (u16 token) -> game id, or 0. The engine only ever issues token 1, so this doubles as
    /// "is a game live".
    const is_token_valid: u32 = 0x001abcff;
    /// Where 0x002de1f9 files a game id whose client is null — i.e. every game we make.
    const last_gameid: u32 = 0x00552568;
    /// `uint32 gpGameTable[]`, indexed by the u16 token, and the critical section
    /// `SERVER_IsTokenValid` reads it under. 0 and -1 both mean "no game".
    const token_table: u32 = 0x0053756c;
    const token_table_cs: u32 = 0x00537578;
    const enter_critical_section: u32 = 0x0002af3a;
    const leave_critical_section: u32 = 0x0002af43;
    /// (game id) -> the game struct with its critical section HELD, or 0. What
    /// `QSERVER_DispatchAndCleanup` turns the id at 0x00537570 into before it reads anything out of
    /// the game — and what it hands back to `game_unlock` the moment it is done.
    const game_from_id: u32 = 0x001abd47;
    const game_unlock: u32 = 0x001abdda;
};

/// How many clients are in the game: what the reap reads to decide it is empty (0x001ae8bf) and
/// what the join gate compares against 7 before it will admit an eighth (0x001a7a66).
const game_clients: u32 = 0x8c;
/// When the game was last seen empty, in the same milliseconds the reap window is measured in.
/// Zero means "not empty yet", and the engine re-stamps it the next time it looks (0x001ae8dc).
const game_empty_since: u32 = 0x1dc0;

/// How long a game the realm has made is held open before the engine is allowed to collect it as
/// abandoned. It only has to cover the walk from "the realm answered CREATEGAME" to "that client
/// finished its GAMELOGON", which is well under a second — but a client that never arrives must not
/// hold the server's only game slot forever either.
const unjoined_grace_s: i64 = 30;

/// How long a create will wait for the one slot to be freed by a game that is already over. It
/// covers a dispatch pass, not a game — the alternative is refusing a realm that was told a moment
/// ago that this server had room, and it is bounded well inside the control thread's own wait.
///
/// It has to outlast the gap between a client's socket closing and the engine counting it gone,
/// which is up to three seconds, not the one the disconnect path suggests. In milliseconds because
/// `time()` counts whole seconds: a deadline of `time() + 3` elapses anywhere from two seconds to
/// three depending on where in the second it was set, and the create that lost this race lost it
/// by less than that truncation.
const create_wait_ms: i64 = 4000;

/// The engine's token table has three entries and no bounds check, so a lookup past the end is a
/// wild read. Nothing above this may be handed to SERVER_IsTokenValid.
const engine_token_max: u32 = 2;

/// How many games this engine hosts at once, and it is one — not as a placeholder but as a
/// measurement. What looks like a game table at 0x0053756c is not one:
///
///   * `QSERVER_TickAllGames` 0x001ae778 advances `0x00537570` and nothing else. There is no walk
///     and no list head; a second game would exist and never tick.
///   * `GAME_DestroyGame` 0x001acf33 clears that same word when the game it is destroying is the
///     one in it, and `SERVER_IsTokenValid` 0x001abcff hands it straight back.
///   * `QSERVER_GenerateGameToken` 0x001ac1d9 rotates a counter clamped to 1 (`CMP DX,1; CMOVA
///     DX,CX`) over that word, so it can only ever issue one token, and the word above it
///     (0x00537574) is an unrelated global `QSERVER_InitializeServerState` fills from the registry.
///
/// So the Windows cap of seven — Fog hands out eight pool managers and the Global Pool System keeps
/// one — is never the binding constraint here: this build has room for a single game pointer, and
/// runs out of that first. Raising this number would place games the engine cannot tick.
const max_games: u32 = 1;

/// The engine's id for the live game, and the small id the realm knows it by. The two differ
/// because the engine counts games from a large seed while the realm's id has to survive being
/// truncated to the u16 the client carries in its GAMELOGON.
var live_gameid: u32 = 0;
var live_join_id: u16 = 0;
var next_join_id: u16 = 0;
/// What the realm calls the game in the slot. Kept because a create naming it is a client that
/// wants in, not a new game — see `slotIsReady`.
var live_name: [36]u8 = @splat(0);

/// Answers "what game is this token", for realm join ids as well as engine ones.
///
/// One GAMELOGON asks this THREE times, from three different functions — 0x001a7a36 in the handler
/// itself, 0x001aca92 in the name check and 0x001acda1 in the seating — and every one of them is
/// handed the u16 the client sent. Translating only the first is what made the second game per
/// process go silent rather than refused: the handler resolved the game and took its success path,
/// then the name check asked the engine's table for token 2, got nothing, and returned 0. Its
/// caller answers a 0 by falling straight out of the switch — no seat, no 0xB4, no anything.
///
/// So the translation belongs in the function, not at a call site. For an id the realm issued the
/// live game is the answer; for anything else this is the engine's own lookup, lock and all, which
/// is what keeps the no-realm path working — and it declines to index the table with a realm id,
/// which the engine would have done unchecked.
fn serverIsTokenValid(id: u32) callconv(.c) u32 {
    const token: u16 = @truncate(id);
    const mine = token != 0 and token == live_join_id and live_gameid != 0;
    if (mine) join_resolved = true;
    const answer = if (mine)
        live_gameid
    else if (token <= engine_token_max) engineTokenValid(token) else 0;
    // The one line that tells a refused join apart from a join that never arrived. The engine asks
    // repeatedly with the same token, so only a change is worth a line.
    if (token != last_note_token or answer != last_note_answer) {
        last_note_token = token;
        last_note_answer = answer;
        note("d2gs-native: game token {d} -> 0x{x}\n", .{ token, answer });
    }
    return answer;
}

var last_note_token: u16 = 0;
var last_note_answer: u32 = 0;

/// The engine's table lookup, under the engine's own lock: `gpGameTable[token]`, where 0 and -1
/// both mean "no game". Open-coded rather than called, because the function it lives in is the one
/// being replaced.
fn engineTokenValid(token: u16) u32 {
    const enter: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.enter_critical_section));
    const leave: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.leave_critical_section));
    const cs = image.at(addr.token_table_cs);
    enter(cs);
    defer leave(cs);
    const table: [*]const u32 = @ptrFromInt(image.at(addr.token_table));
    const v = table[token];
    return if (v == 0 or v == 0xffff_ffff) 0 else v;
}

/// Replace `SERVER_IsTokenValid` outright: `jmp rel32` over its prologue. Runs before the image is
/// made read-only, and only where our own code is addressable in 32 bits — which is the same
/// condition the byte patches are already gated on.
pub fn installTokenResolver(loaded: *const macho.load.Loaded) void {
    image = loaded;
    const site = loaded.at(addr.is_token_valid);
    const rel: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(&serverIsTokenValid))) -%
        @as(u32, @truncate(site + 5)));
    const at: [*]u8 = @ptrFromInt(site);
    at[0] = 0xe9;
    std.mem.writeInt(i32, at[1..5], rel, .little);
}

/// The create is engine work, so it runs on the tick thread; this is the handoff.
var req_pending = std.atomic.Value(bool).init(false);
var req_done = std.atomic.Value(bool).init(false);
var req_name: [36]u8 = undefined;
var req_desc: [36]u8 = undefined;
var req_flags: u32 = 0;
var req_result: u32 = p.CREATE_FAILED;
var req_gameid: u32 = 0;
/// When `pump` must stop waiting for the slot and answer whatever it can.
var req_deadline_ms: i64 = 0;
/// When the request was handed to the tick thread, and how much of the answer's latency was spent
/// waiting for the previous game to leave the one slot. On a server that hosts a single game that
/// wait is the gap between one game and the next, so it is the thing to measure before tuning it.
var req_armed_ms: i64 = 0;
var req_slot_ms: i64 = 0;

/// Two senders share the socket: the control thread answers requests, the tick thread reports a
/// game closing.
var send_lock = std.atomic.Value(bool).init(false);

pub fn start(loaded: *const macho.load.Loaded) void {
    image = loaded;
    const realm = env("D2GS_REALM") orelse {
        note("d2gs-native: gslink off (set D2GS_REALM=host:port to register with a realm)\n", .{});
        return;
    };
    const advertised = env("D2GS_GS_ADDR") orelse "127.0.0.1:4000";
    parseAddr(advertised, &public_ip, &public_port) catch {
        note("d2gs-native: D2GS_GS_ADDR=\"{s}\" is not host:port\n", .{advertised});
        return;
    };
    gsid = identity();
    started = true;
    _ = std.Thread.spawn(.{}, thread, .{realm}) catch |e| {
        note("d2gs-native: gslink thread: {s}\n", .{@errorName(e)});
        started = false;
    };
}

/// Called once per server tick. Runs whatever the control thread queued, and watches for the game
/// going away — the engine has no hook to tell us, but its token stops resolving.
pub fn pump() void {
    if (!started) return;
    if (req_pending.load(.acquire) and slotIsReady()) {
        req_slot_ms = nowMs() - req_armed_ms;
        runCreate();
        req_pending.store(false, .release);
        req_done.store(true, .release);
    }
    // A game with nobody left in it is finished as far as the realm is concerned, whether or not
    // the engine has got round to freeing it: it must stop being somewhere a client can be sent,
    // and this server's one slot must stop counting against the realm's capacity. Waiting for the
    // engine's collect instead is what made the round after a finished one arrive at a realm that
    // still thought this server was full.
    if (live_gameid != 0 and (phase == .released or tokenValid(1) == 0)) {
        sendCloseGame(live_join_id);
        note("d2gs-native: gslink CLOSEGAME gameid={d}\n", .{live_join_id});
        live_gameid = 0;
        live_join_id = 0;
        live_name = @splat(0);
        freeing = true;
    }
    // The realm has been told, but the slot is not free until the engine has destroyed the game,
    // and only then can the next create be answered. On a one-game server that interval is dead
    // time between rounds, so it is reported rather than inferred.
    if (freeing and tokenValid(1) == 0) {
        freeing = false;
        note("d2gs-native: engine freed the slot {d}ms after the game emptied\n", .{nowMs() - empty_ms});
    }
}

/// Whether a create can be answered now, or is worth holding for the one slot to come free.
///
/// The engine is about a second behind a client that walks out: the connection is gone, and the
/// game still counts it until the engine gets round to the disconnect. On a server with one game
/// slot that second IS the gap between one game and the next, so the create that arrives in it
/// must wait rather than be refused — a refusal reaches the player as "the realm is down" for a
/// server that is about to be idle.
///
/// What must NOT wait is the other client of the game already here: it lost the race to create a
/// game its partner made, and a refusal is the answer it wants, because the realm turns that into
/// a join. The name tells them apart — same name is the race, a different name is the next game.
fn slotIsReady() bool {
    if (tokenValid(1) == 0) return true;
    if (std.mem.eql(u8, cstr(&live_name), cstr(&req_name))) return true;
    return nowMs() >= req_deadline_ms;
}

// ── engine ───────────────────────────────────────────────────────────────────

/// Where the live game is in its life. Only `waiting` is held open: a game that has had a player in
/// it is finished the moment it empties, and one already given up on must not be revived.
const Phase = enum { waiting, played, released };
var phase: Phase = .released;
var held_id: u32 = 0;
var held_since_ms: i64 = 0;
var last_clients: u32 = 0;
/// When the game was seen with nobody in it, and whether the engine still has to free the slot.
var empty_ms: i64 = 0;
var freeing = false;
/// Whether a client has asked to join the game currently in the slot. The engine's own client count
/// cannot answer that on its own — see `holdGameForItsFirstPlayer`.
var join_resolved = false;

/// The engine's empty-game reap is a stopwatch, and `applyPatches` has shortened it to a
/// millisecond so a finished game frees the one slot this build has immediately. That leaves the
/// other end exposed: a game the realm has just created is also empty, and would be collected
/// before the client it was made for could connect. So while it has never had a player, its
/// empty-since stamp is put back to zero every pass, which is the engine's own "not empty yet" —
/// it re-stamps it to now, and the window never elapses. Once someone has been in, the stopwatch is
/// left alone and the engine collects the game on its own, through its own locked destroy path.
pub fn holdGameForItsFirstPlayer() void {
    const id = tokenValid(1);
    if (id == 0) {
        held_id = 0;
        return;
    }
    // A game id this has not seen before is a game nobody has joined yet. `runCreate` clears the id
    // as well as setting it, because the engine hands out game structs from a pool and the next game
    // can land on the address the last one had — going by the id alone would carry the finished
    // game's "someone has been in this" into a game that is still waiting for its first client.
    if (id != held_id) {
        held_id = id;
        held_since_ms = nowMs();
        phase = .waiting;
    }
    // This does not just find the game, it LOCKS it — `EnterCriticalSection(game->0x18)` — and
    // every one of the engine's own callers unlocks before it returns. Reading two fields out of a
    // game and walking away with its critical section held would leave the game permanently locked
    // against its own destroy, once per tick.
    const from_id: *const fn (u32) callconv(.c) u32 = @ptrFromInt(image.at(addr.game_from_id));
    const game = from_id(id);
    if (game == 0) return;
    const unlock: *const fn (u32) callconv(.c) void = @ptrFromInt(image.at(addr.game_unlock));
    defer unlock(game);

    const clients: *const u32 = @ptrFromInt(game + game_clients);
    if (clients.* != last_clients) {
        last_clients = clients.*;
        note("d2gs-native: game {d} has {d} client(s), {d}ms in\n", .{ live_join_id, clients.*, nowMs() - held_since_ms });
    }
    // A brand-new game reports one client before it has any: `GAME_CreateGame` is given a null
    // client and still files a player record for it, which the engine drops again a tick or two
    // later. Taking that for a player is what let the reap collect a game the moment it was made —
    // the count went 1, then 0, and the game was gone before the client it existed for had
    // finished connecting. So a real player is one this server has answered a GAMELOGON for.
    if (clients.* != 0) {
        if (phase == .waiting and join_resolved) phase = .played;
        if (phase != .waiting) return;
    }
    switch (phase) {
        .played => {
            phase = .released;
            empty_ms = nowMs();
            note("d2gs-native: game {d} is empty — the engine may collect it\n", .{live_join_id});
        },
        .released => {},
        .waiting => {
            if (nowMs() - held_since_ms > unjoined_grace_s * 1000) {
                phase = .released;
                note("d2gs-native: game {d} was never joined — the engine may collect it\n", .{live_join_id});
                return;
            }
            const empty_since: *u32 = @ptrFromInt(game + game_empty_since);
            empty_since.* = 0;
        },
    }
}

/// "Is the engine's one game slot occupied, and by what". The engine's table, not the resolver
/// above it: this asks about the slot, and the resolver's job is to answer about realm ids.
fn tokenValid(token: u32) u32 {
    return engineTokenValid(@truncate(token));
}

/// The 0x67 handler's call, with the packet's fields spelled out. Everything but the name, the
/// description and the flags is the constant that path passes for a plain expansion game.
fn runCreate() void {
    req_gameid = 0;
    if (tokenValid(1) != 0) {
        req_result = p.CREATE_SERVER_FULL;
        return;
    }
    const Create = fn (
        client: u32,
        name: [*:0]const u8,
        a2: u32,
        a3: u32,
        desc: [*:0]const u8,
        a5: u32,
        flags: u32,
        a7: u32,
        a8: u32,
        a9: u32,
        a10: u32,
        a11: u32,
        a12: u32,
        a13: u32,
    ) callconv(.c) void;
    const create: *const Create = @ptrFromInt(image.at(addr.game_create));
    create(0, @ptrCast(&req_name), 0, 1, @ptrCast(&req_desc), 0, req_flags, 0, 0, 0, 0, 0, 0, 0);
    // Whatever id the engine reuses for it, this is a new game and nobody is in it yet. The phase
    // has to be set HERE and not left to the next tick's `holdGameForItsFirstPlayer`: the same pump
    // that ran this create goes on to look for a game that has finished, and a phase still reading
    // `released` from the last one makes it report the game it has just made as closed.
    held_id = 0;
    held_since_ms = nowMs();
    phase = .waiting;
    join_resolved = false;

    const singleton: *const u32 = @ptrFromInt(image.at(addr.last_gameid));
    const id = singleton.*;
    // A game the engine did not file under token 1 is one no join can reach, so it is not a game
    // we can honestly report.
    if (id == 0 or tokenValid(1) != id) {
        req_result = p.CREATE_FAILED;
        return;
    }
    next_join_id = if (next_join_id == std.math.maxInt(u16)) 1 else next_join_id + 1;
    live_join_id = next_join_id;
    live_gameid = id;
    live_name = req_name;
    req_gameid = live_join_id;
    req_result = p.CREATE_OK;
}

// ── control connection ───────────────────────────────────────────────────────

fn thread(realm: []const u8) void {
    var ip: [4]u8 = undefined;
    var port: u16 = 6115;
    parseAddr(realm, &ip, &port) catch {
        note("d2gs-native: D2GS_REALM=\"{s}\" is not host:port\n", .{realm});
        return;
    };
    // The character store sits one port below the control link on the same host, as
    // `apps/d2gs/d2gs.zig` derives it on Windows.
    chardb.configure(image, ip, port);
    if (env("D2GS_D2DBS")) |a| {
        var dip: [4]u8 = undefined;
        var dport: u16 = 0;
        if (parseAddr(a, &dip, &dport)) chardb.setAddress(dip, dport) else |_| {
            note("d2gs-native: D2GS_D2DBS=\"{s}\" is not host:port\n", .{a});
        }
    }
    var complained = false;
    while (true) {
        if (connectOnce(ip, port)) {
            complained = false;
            serve();
            _ = close(sock);
            sock = -1;
            note("d2gs-native: gslink disconnected\n", .{});
        } else if (!complained) {
            complained = true;
            note("d2gs-native: gslink cannot reach {d}.{d}.{d}.{d}:{d} — retrying\n", .{ ip[0], ip[1], ip[2], ip[3], port });
        }
        // A realm that is not up yet is the normal case at boot; keep asking.
        _ = usleep(2_000_000);
    }
}

fn connectOnce(ip: [4]u8, port: u16) bool {
    const s = socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (s < 0) return false;
    const sa = std.posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
    if (connect(s, &sa, @sizeOf(std.posix.sockaddr.in)) != 0) {
        _ = close(s);
        return false;
    }
    sock = s;
    note("d2gs-native: gslink connected to {d}.{d}.{d}.{d}:{d} gsid=0x{x}\n", .{ ip[0], ip[1], ip[2], ip[3], port, gsid });
    return true;
}

fn serve() void {
    var body: [1024]u8 = undefined;
    while (true) {
        var head: [p.HEADER_LEN]u8 = undefined;
        if (!recvAll(&head)) return;
        const size = std.mem.readInt(u16, head[0..2], .little);
        const typ = std.mem.readInt(u16, head[2..4], .little);
        if (size < p.HEADER_LEN or size - p.HEADER_LEN > body.len) return;
        const n = size - p.HEADER_LEN;
        if (!recvAll(body[0..n])) return;
        onPacket(typ, body[0..n]);
    }
}

fn onPacket(typ: u16, body: []const u8) void {
    switch (typ) {
        @intFromEnum(p.Type.authreq) => sendRegistration(),
        @intFromEnum(p.Type.echo) => {
            var h: [p.HEADER_LEN]u8 = undefined;
            writeHeader(&h, p.HEADER_LEN, @intFromEnum(p.Type.echo));
            _ = sendAll(&h);
        },
        @intFromEnum(p.Type.creategame) => onCreateGame(body),
        @intFromEnum(p.Type.joingame) => onJoinGame(body),
        else => {},
    }
}

/// AUTHREPLY + SETGSINFO + ADDRINFO in one burst — the realm only counts a GS as able to host
/// once the last of the three arrives.
fn sendRegistration() void {
    var auth = std.mem.zeroes(p.AuthReply);
    auth.h = header(.authreply, @sizeOf(p.AuthReply));
    auth.version = 1;
    _ = sendAll(std.mem.asBytes(&auth));

    var info = std.mem.zeroes(p.SetGsInfo);
    info.h = header(.setgsinfo, @sizeOf(p.SetGsInfo));
    info.maxgame = max_games;
    _ = sendAll(std.mem.asBytes(&info));

    var ai = std.mem.zeroes(p.AddrInfo);
    ai.h = header(.addrinfo, @sizeOf(p.AddrInfo));
    ai.maxgame = max_games;
    ai.gsid = gsid;
    ai.ip = public_ip;
    ai.port = public_port;
    _ = sendAll(std.mem.asBytes(&ai));
    note("d2gs-native: gslink registered {d}.{d}.{d}.{d}:{d} maxgame={d}\n", .{
        public_ip[0], public_ip[1], public_ip[2], public_ip[3], public_port, max_games,
    });
}

fn onCreateGame(body: []const u8) void {
    var result: u32 = p.CREATE_FAILED;
    var gid: u32 = 0;
    if (body.len >= 4) {
        var off: usize = 4;
        copyz(&req_name, readCStr(body, &off));
        _ = readCStr(body, &off); // password: the realm already matched it
        copyz(&req_desc, readCStr(body, &off));
        req_flags = gameFlags(body[2], body[1] != 0, body[3] != 0);

        req_done.store(false, .release);
        req_armed_ms = nowMs();
        req_slot_ms = -1;
        req_deadline_ms = req_armed_ms + create_wait_ms;
        req_pending.store(true, .release);
        var waited: u32 = 0;
        while (!req_done.load(.acquire) and waited < 5000) : (waited += 5) _ = usleep(5000);
        // A request the tick thread never got to must not stay armed, or it would create a game
        // nobody is waiting for the moment the slot frees.
        req_pending.store(false, .release);
        if (req_done.load(.acquire)) {
            result = req_result;
            gid = req_gameid;
        }
    }
    var r = std.mem.zeroes(p.CreateGameReply);
    r.h = header(.creategame, @sizeOf(p.CreateGameReply));
    r.result = result;
    r.gameid = gid;
    _ = sendAll(std.mem.asBytes(&r));
    note("d2gs-native: gslink CREATEGAME \"{s}\" -> result={d} gameid={d} slot={d}ms total={d}ms\n", .{
        cstr(&req_name), result, gid, req_slot_ms, nowMs() - req_armed_ms,
    });
}

/// JOINGAMEREQ: gameid, token, charname\0, account\0, guild\0. It arrives before the client does,
/// and it is the only place this server is ever told which account a character belongs to — the
/// GAMELOGON that follows carries the name alone. That is what makes it the moment to fetch the
/// save: `chardb.place` writes it where the engine's own loader looks, and without it every join
/// ends in reason 0x0e, "no character".
fn onJoinGame(body: []const u8) void {
    const gid = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 0;
    var off: usize = 8;
    const charname = readCStr(body, &off);
    const account = readCStr(body, &off);

    var seated = false;
    if (charname.len > 0 and account.len > 0) seated = chardb.place(account, charname);

    var r = std.mem.zeroes(p.JoinGameReply);
    r.h = header(.joingame, @sizeOf(p.JoinGameReply));
    r.result = if (gid == live_join_id and gid != 0 and seated) 0 else 1;
    r.gameid = gid;
    _ = sendAll(std.mem.asBytes(&r));
}

fn sendCloseGame(gid: u32) void {
    var c = std.mem.zeroes(p.CloseGame);
    c.h = header(.closegame, @sizeOf(p.CloseGame));
    c.gameid = gid;
    _ = sendAll(std.mem.asBytes(&c));
}

/// Bit 2 gates the per-frame client update and the engine asserts without it; bits 12-14 are the
/// difficulty. Same set `apps/d2gs/engine/server.zig` builds, and the same one the 0x67 probe used.
fn gameFlags(difficulty: u8, expansion: bool, hardcore: bool) u32 {
    var f: u32 = @as(u32, difficulty & 7) << 12;
    f |= 0x04;
    if (expansion) f |= 0x10_0000;
    if (hardcore) f |= 0x800;
    return f;
}

// ── plumbing ─────────────────────────────────────────────────────────────────

fn header(t: p.Type, size: u16) p.Header {
    seqno +%= 1;
    return .{ .size = size, .type = @intFromEnum(t), .seqno = seqno };
}

fn writeHeader(buf: []u8, size: u16, typ: u16) void {
    seqno +%= 1;
    std.mem.writeInt(u16, buf[0..2], size, .little);
    std.mem.writeInt(u16, buf[2..4], typ, .little);
    std.mem.writeInt(u32, buf[4..8], seqno, .little);
}

fn sendAll(bytes: []const u8) bool {
    while (send_lock.swap(true, .acquire)) _ = usleep(1000);
    defer send_lock.store(false, .release);
    if (sock < 0) return false;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(sock, bytes.ptr + off, bytes.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn recvAll(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(sock, buf.ptr + off, buf.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn readCStr(body: []const u8, off: *usize) []const u8 {
    const from = off.*;
    var i = from;
    while (i < body.len and body[i] != 0) : (i += 1) {}
    off.* = @min(i + 1, body.len);
    return body[from..i];
}

fn copyz(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    @memset(dst[n..], 0);
}

fn cstr(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

fn env(name: []const u8) ?[]const u8 {
    var nbuf: [64]u8 = undefined;
    const z = std.fmt.bufPrintZ(&nbuf, "{s}", .{name}) catch return null;
    const v = std.c.getenv(z.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn parseAddr(text: []const u8, ip: *[4]u8, port: *u16) !void {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.NoPort;
    port.* = try std.fmt.parseInt(u16, text[colon + 1 ..], 10);
    var it = std.mem.splitScalar(u8, text[0..colon], '.');
    for (ip) |*o| o.* = try std.fmt.parseInt(u8, it.next() orelse return error.NotDotted, 10);
    if (it.next() != null) return error.NotDotted;
}

/// A fleet needs one id per server, and the host name alone is not it: two servers on one machine
/// would collide. FNV-1a over name and port, as the Windows side derives it.
fn identity() u32 {
    if (env("D2GS_GSID")) |s| {
        if (std.fmt.parseInt(u32, s, 0)) |v| return v else |_| {}
    }
    var h: u32 = 2166136261;
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&name) catch name[0..0];
    for (host) |c| h = (h ^ c) *% 16777619;
    for (std.mem.asBytes(&public_port)) |c| h = (h ^ c) *% 16777619;
    return h;
}

fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

test "host:port parses into octets and a port" {
    var ip: [4]u8 = undefined;
    var port: u16 = 0;
    try parseAddr("10.1.2.3:6115", &ip, &port);
    try std.testing.expectEqual([4]u8{ 10, 1, 2, 3 }, ip);
    try std.testing.expectEqual(@as(u16, 6115), port);
    try std.testing.expectError(error.NoPort, parseAddr("10.1.2.3", &ip, &port));
    try std.testing.expectError(error.InvalidCharacter, parseAddr("realm.example:6115", &ip, &port));
    try std.testing.expectError(error.NotDotted, parseAddr("10.1.2.3.4:6115", &ip, &port));
}

test "game flags carry difficulty, the client-update gate and expansion" {
    try std.testing.expectEqual(@as(u32, 0x10_0004), gameFlags(0, true, false));
    try std.testing.expectEqual(@as(u32, 0x10_2804), gameFlags(2, true, true));
}
