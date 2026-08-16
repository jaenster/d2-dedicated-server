//! The realm's control link, from the Mac image's side.
//!
//! Same channel `apps/d2gs/realmclient/d2cs.zig` speaks on Windows and the same wire types, but a
//! different engine underneath: this build has no `GAME_CreateBattleNetGame` and no realm callback
//! table, so a game is made by calling `GAME_CreateGame` 0x001ac3f3 — the one the 0x67 packet uses
//! — with a null client. That is survivable: the only two things it does with the client are store
//! it in the new player record and hand it to a map that has a null-client singleton branch, which
//! is also where the new game's id ends up (0x00552568).
//!
//! Several games at once, which the engine's own scheduler does not do — see `max_games` for what
//! that takes.

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
    /// One game's tick. `QSERVER_TickAllGames` reaches it through the lock/unlock pair above and
    /// passes the locked game, so it needs nothing from `gpGameTable` — which is what lets a host
    /// run more than the one game that table schedules.
    const server_game_loop: u32 = 0x001ae017;
    /// Flushes what the games queued. Unlike the loop it DOES read `gpGameTable[1]`, so it is run
    /// once per game with that word pointed at the game in question.
    const dispatch_and_cleanup: u32 = 0x001ae82b;
    /// (name, out_existing_name) -> 1 when the name is FREE, 0 when a client still holds the seat.
    /// The GAMELOGON path refuses on a 0 and refuses silently, so this is where a character that
    /// cannot come back gets stuck. Replaced outright, like `SERVER_IsTokenValid`.
    const find_player_by_name: u32 = 0x001aa39a;
    /// (game, client id, notify) — unlinks the client from its game and from both server tables and
    /// frees it. The character is saved either way; `notify` only gates one extra call, which a
    /// client whose socket is already gone has nobody to receive.
    const clean_up_client: u32 = 0x001a8e10;
    /// `D2ClientStrc*[256]`, keyed by a hash of the character name, and its critical section.
    const client_by_name: u32 = 0x0053716c;
    const client_by_name_cs: u32 = 0x00537140;
    /// The same clients keyed by id, which is the list `CleanUpClient` walks.
    const client_by_id: u32 = 0x00536d40;
    const client_by_id_cs: u32 = 0x00536d14;
};

/// Client fields, as `CreateClient` 0x001a88f5 fills them.
const client_id: u32 = 0x00;
const client_name: u32 = 0x0d;
const client_next_by_id: u32 = 0x4ac;
const client_next_by_name: u32 = 0x4b0;
const client_game: u32 = 0x1a8;

/// What `QSERVER_TickAllGames` writes into the game before running its loop, and the word the reap
/// stopwatch sits next to.
const game_tick_flag: u32 = 0x1dbc;

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

/// How many games this engine hosts at once as it stands, which is one — because of what the
/// engine's own scheduler does, not because a game is expensive:
///
///   * `QSERVER_TickAllGames` 0x001ae778 services `gpGameTable[1]` (0x00537570) and nothing else.
///     Its argument is a catch-up flag for the 40 ms budget, not a token, so a game anywhere else
///     in the table exists and never ticks.
///   * `QSERVER_GenerateGameToken` 0x001ac1d9 walks the table from a counter its own arithmetic
///     pins at 1, so after the first two calls it always reports the table full.
///   * `GAME_DestroyGame` 0x001acf33 clears that same word when the game it is destroying is the
///     one in it.
///
/// None of that stops the engine running several, and this server does. `ServerGameLoop` is passed
/// the game, and `0x00537570` has ten references in the whole image — all of them in QSERVER/GAME
/// management, none inside a game's own tick. So a created game is taken straight back out of that
/// word and kept here (`runCreate`), and `tickGames` points the word at each game in turn and runs
/// the per-game body itself.
///
/// The ceiling is Fog's, not QSERVER's: the pool allocator hands out eight managers and the Global
/// Pool System keeps one, which is where the Windows build's seven comes from.
const max_games: u32 = 7;

/// How many of those slots this server actually uses, from `D2GS_MAX_GAMES`.
///
/// One, until the crash below is fixed. Concurrent games SIGSEGV inside the engine's own
/// `CleanUpClient` at 0x001a8ee1, within a round or two of `--spread`, always just after a game's
/// last client leaves — measured on real amd64 hardware, where one game at a time ran 60/60 clean.
/// `listedById` guards the one call this file makes into that function, but the fault has not been
/// reproduced against the guard yet, and a default that crashes is worse than a default that
/// serialises. Raise it with D2GS_MAX_GAMES to test.
var game_cap: u32 = 1;

fn readGameCap() void {
    const v = env("D2GS_MAX_GAMES") orelse return;
    const n = std.fmt.parseInt(u32, v, 10) catch return;
    game_cap = @min(@max(n, 1), max_games);
}

/// Where a game is in its life. Only `waiting` is held open: a game that has had a player in it is
/// finished the moment it empties, and one already given up on must not be revived.
const Phase = enum { waiting, played, released };

/// One hosted game. `gameid` is the engine's, from a large seed; `join_id` is the small one the
/// realm knows it by, because that is what survives being truncated to the u16 a client carries in
/// its GAMELOGON. A zero `gameid` means the slot is free.
const Slot = struct {
    gameid: u32 = 0,
    join_id: u16 = 0,
    /// What the realm calls it. Kept because a create naming it is a client that wants in, not a
    /// new game — see `freeSlotFor`.
    name: [36]u8 = @splat(0),
    phase: Phase = .released,
    held_since_ms: i64 = 0,
    last_clients: u32 = 0,
    /// Whether a client has asked to join this game. The engine's own client count cannot answer
    /// that on its own — see `holdGameForItsFirstPlayer`.
    join_resolved: bool = false,
    empty_ms: i64 = 0,
    freeing: bool = false,
};

var slots: [max_games]Slot = @splat(.{});
var next_join_id: u16 = 0;

fn slotByJoinId(id: u16) ?*Slot {
    if (id == 0) return null;
    for (&slots) |*s| if (s.gameid != 0 and s.join_id == id) return s;
    return null;
}

fn liveGames() u32 {
    var n: u32 = 0;
    for (&slots) |*s| {
        if (s.gameid != 0) n += 1;
    }
    return n;
}

/// The engine schedules exactly one game, out of `gpGameTable[1]`. Everything that reads that word
/// is management — the name check, the dispatch, the destroy — so servicing several games is a
/// matter of pointing it at each in turn rather than leaving one there forever. It is left cleared
/// between passes, which is also what keeps `QSERVER_GenerateGameToken` willing to issue again.
fn setEngineSlot(id: u32) void {
    const enter: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.enter_critical_section));
    const leave: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.leave_critical_section));
    const cs = image.at(addr.token_table_cs);
    enter(cs);
    defer leave(cs);
    const table: [*]u32 = @ptrFromInt(image.at(addr.token_table));
    table[1] = id;
}

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
    const mine = slotByJoinId(token);
    if (mine) |s| s.join_resolved = true;
    const answer = if (mine) |s|
        s.gameid
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
    jmpTo(loaded.at(addr.is_token_valid), @intFromPtr(&serverIsTokenValid));
    jmpTo(loaded.at(addr.find_player_by_name), @intFromPtr(&gameFindPlayerByName));
}

fn jmpTo(site: usize, target: usize) void {
    const rel: i32 = @bitCast(@as(u32, @truncate(target)) -% @as(u32, @truncate(site + 5)));
    const at: [*]u8 = @ptrFromInt(site);
    at[0] = 0xe9;
    std.mem.writeInt(i32, at[1..5], rel, .little);
}

/// What the realm last told us about a character, which is the only thing that makes throwing it
/// out of a game legitimate. Only realmd writes it, so a client cannot name somebody else's
/// character to have them evicted.
/// It also names the game the realm placed the character in, and that is what makes it safe. A
/// seat held inside THAT game is the character arriving, and the engine is right to call the name
/// taken; a seat anywhere else is the game it has just left and has not been cleaned out of yet.
/// Without the distinction the release fires on the join it is meant to let through.
const Vouch = struct {
    name: [16]u8 = @splat(0),
    game: u32 = 0,
    at_ms: i64 = 0,
};
var vouches: [max_games * 4]Vouch = @splat(.{});
var vouch_next: usize = 0;

fn vouchFor(name: []const u8, game: u32) void {
    const v = &vouches[vouch_next % vouches.len];
    vouch_next += 1;
    v.* = .{ .game = game, .at_ms = nowMs() };
    const n = @min(name.len, v.name.len - 1);
    @memcpy(v.name[0..n], name[0..n]);
}

/// The realm's outstanding join for this character, if it has one. Single use: a released seat must
/// not authorise releasing the next one, or a character that legitimately re-joins is thrown out of
/// the game it just entered.
fn takeVouch(name: []const u8) ?u32 {
    for (&vouches) |*v| {
        if (v.at_ms == 0) continue;
        // Only has to cover the walk from JOINGAMEREQ to the GAMELOGON that follows it.
        if (nowMs() - v.at_ms > 30_000) {
            v.at_ms = 0;
            continue;
        }
        if (!eqlName(cstr(&v.name), name)) continue;
        const g = v.game;
        v.at_ms = 0;
        return g;
    }
    return null;
}

/// Whether the by-id table still lists this exact client, which is what makes it safe to hand to
/// `CleanUpClient`.
fn listedById(id: u32, client: u32) bool {
    const enter: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.enter_critical_section));
    const leave: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.leave_critical_section));
    const cs = image.at(addr.client_by_id_cs);
    enter(cs);
    defer leave(cs);
    const buckets: [*]const u32 = @ptrFromInt(image.at(addr.client_by_id));
    var c = buckets[id & 0xff];
    while (c != 0) : (c = @as(*const u32, @ptrFromInt(c + client_next_by_id)).*) {
        if (c == client) return true;
    }
    return false;
}

fn eqlName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Let a character come straight back after the game it was in.
///
/// The engine refuses a GAMELOGON whose character still holds a seat, and refuses it with SILENCE —
/// the caller answers a 0 by falling out of its switch, so nothing goes back on the wire and the
/// client sits at the loading screen until its own timeout. The seat outlives the game because it
/// belongs to the CLIENT: `GAME_DestroyGame` frees the game and never calls `CleanUpClient`, and the
/// client's own teardown lands a second or so after its socket died. While games were made one at a
/// time the create waited long enough to hide it; overlapping games do not, and one player going
/// straight into the next game is refused about half the time.
///
/// So the seat is released rather than the check bypassed: find the client in the by-name table,
/// take its game off its own `pGame`, and hand both to the engine's own `CleanUpClient`, which
/// unlinks it from the game and from both tables and saves the character on the way out. The realm
/// having issued a join is the authorization; without one this answers exactly as the engine would.
///
/// This is `apps/d2gs/runtime/rejoin.zig` for the Mac build, and the same reasoning.
fn gameFindPlayerByName(name_ptr: [*:0]const u8, out: ?[*]u8) callconv(.c) u32 {
    const name = std.mem.span(name_ptr);

    var holder: u32 = 0;
    {
        const enter: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.enter_critical_section));
        const leave: *const fn (usize) callconv(.c) void = @ptrFromInt(image.at(addr.leave_critical_section));
        const cs = image.at(addr.client_by_name_cs);
        enter(cs);
        defer leave(cs);
        // Every bucket, rather than the engine's hash of the name: it costs 256 pointer reads once
        // per join and needs no agreement about which hash this build uses.
        const buckets: [*]const u32 = @ptrFromInt(image.at(addr.client_by_name));
        outer: for (0..256) |b| {
            var c = buckets[b];
            while (c != 0) {
                const cname: [*:0]const u8 = @ptrFromInt(c + client_name);
                if (eqlName(std.mem.span(cname), name)) {
                    holder = c;
                    break :outer;
                }
                c = @as(*const u32, @ptrFromInt(c + client_next_by_name)).*;
            }
        }
    }

    if (holder == 0) return 1; // free, which is what the engine says with a 1

    const held_in = @as(*const u32, @ptrFromInt(holder + client_game)).*;
    const target = takeVouch(name);
    // Answer as the engine would when there is nothing to release: no realm join behind this
    // name, or the seat is in the very game the realm is sending it to, which is a duplicate
    // logon rather than a leftover. The caller wants the existing name for its message.
    if (held_in == 0 or target == null or held_in == target.?) {
        if (out) |o| {
            const cname: [*:0]const u8 = @ptrFromInt(holder + client_name);
            const s = std.mem.span(cname);
            const n = @min(s.len, 15);
            @memcpy(o[0..n], s[0..n]);
            o[n] = 0;
        }
        return 0;
    }

    const id = @as(*const u32, @ptrFromInt(holder + client_id)).*;
    // `CleanUpClient` walks the by-ID bucket for this id and dereferences each link BEFORE testing
    // it for null (0x001a8ee1; the `TEST EAX,EAX` two instructions later can never be reached with
    // a null). A client the by-name table still lists but the by-id table has already dropped
    // therefore faults instead of being cleaned up. The two go out of step exactly when a game's
    // last client is leaving, which is when this is called.
    if (!listedById(id, holder)) {
        note("d2gs-native: seat \"{s}\" is half-unlinked; leaving it to the engine\n", .{name});
        return 0;
    }
    const cleanup: *const fn (u32, u32, u32) callconv(.c) void = @ptrFromInt(image.at(addr.clean_up_client));
    cleanup(held_in, id, 0);
    note("d2gs-native: released \"{s}\" from game 0x{x} so it can join 0x{x}\n", .{ name, held_in, target.? });
    return 1;
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
    readGameCap();
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
    if (req_pending.load(.acquire)) switch (admit(cstr(&req_name))) {
        .wait => {},
        .refuse => {
            req_slot_ms = nowMs() - req_armed_ms;
            req_gameid = 0;
            req_result = p.CREATE_SERVER_FULL;
            req_pending.store(false, .release);
            req_done.store(true, .release);
        },
        .take => |s| {
            req_slot_ms = nowMs() - req_armed_ms;
            runCreate(s);
            req_pending.store(false, .release);
            req_done.store(true, .release);
        },
    };
    // A game with nobody left in it is finished as far as the realm is concerned, whether or not
    // the engine has got round to freeing it: it must stop being somewhere a client can be sent,
    // and its slot must stop counting against the realm's capacity. Waiting for the engine's
    // collect instead is what made the round after a finished one arrive at a realm that still
    // thought this server was full.
    for (&slots) |*s| {
        if (s.gameid == 0) continue;
        if (s.phase != .released and gameIsAlive(s.gameid)) continue;
        sendCloseGame(s.join_id);
        note("d2gs-native: gslink CLOSEGAME gameid={d} ({d} game(s) left)\n", .{ s.join_id, liveGames() - 1 });
        s.* = .{};
    }
}

/// The slot a create should be answered into, or null to keep waiting for one.
///
/// The engine is about a second behind a client that walks out: the connection is gone, and the
/// game still counts it until the engine gets round to the disconnect. A create that arrives in
/// that second on a server with nothing free must wait rather than be refused — a refusal reaches
/// the player as "the realm is down" for a server that is about to be idle.
///
/// What must NOT wait is the other client of a game already here: it lost the race to create a game
/// its partner made, and a refusal is the answer it wants, because the realm turns that into a
/// join. The name tells them apart — same name is the race, a different name is a new game.
const Admission = union(enum) {
    /// Make the game here.
    take: *Slot,
    /// Answer now, with a refusal the realm turns into a join or reports as full.
    refuse,
    /// Keep holding: nothing is free, but a game is on its way out.
    wait,
};

fn admit(name: []const u8) Admission {
    for (&slots) |*s| {
        if (s.gameid != 0 and std.mem.eql(u8, cstr(&s.name), name)) return .refuse;
    }
    for (slots[0..game_cap]) |*s| {
        if (s.gameid == 0) return .{ .take = s };
    }
    return if (nowMs() >= req_deadline_ms) .refuse else .wait;
}

/// Whether the engine still has this game. Not `gpGameTable` — the games we host are not in it —
/// but the engine's own id lookup, which is what the join path resolves through too. It hands the
/// game back LOCKED, so every caller has to give it up again.
fn gameIsAlive(id: u32) bool {
    const from_id: *const fn (u32) callconv(.c) u32 = @ptrFromInt(image.at(addr.game_from_id));
    const g = from_id(id);
    if (g == 0) return false;
    const unlock: *const fn (u32) callconv(.c) void = @ptrFromInt(image.at(addr.game_unlock));
    unlock(g);
    return true;
}

/// Service every game this server hosts, the way `QSERVER_TickAllGames` services the one the engine
/// schedules: lock the game, arm it, run its loop, unlock, then let the dispatch flush what it
/// queued. The pacing is ours because the engine's is a single global budget — calling its tick
/// once per game would advance the first and skip the rest.
pub fn tickGames() bool {
    if (nowMs() - last_tick_ms < tick_period_ms) return false;
    last_tick_ms = nowMs();

    const from_id: *const fn (u32) callconv(.c) u32 = @ptrFromInt(image.at(addr.game_from_id));
    const unlock: *const fn (u32) callconv(.c) void = @ptrFromInt(image.at(addr.game_unlock));
    const loop: *const fn (u32) callconv(.c) void = @ptrFromInt(image.at(addr.server_game_loop));
    const dispatch: *const fn (usize, u32) callconv(.c) u32 = @ptrFromInt(image.at(addr.dispatch_and_cleanup));

    var ticked = false;
    for (&slots) |*s| {
        if (s.gameid == 0) continue;
        // The dispatch reads this word, and a destroy during the loop clears it — so it is set for
        // the whole of one game's turn and cleared again below.
        setEngineSlot(s.gameid);
        const g = from_id(s.gameid);
        if (g != 0) {
            const armed: *u32 = @ptrFromInt(g + game_tick_flag);
            armed.* = 0x400;
            loop(g);
            unlock(g);
            ticked = true;
        }
        // Forced, because the dispatch keeps a 40 ms budget of its own in a global and honours it
        // only when both arguments are zero. Called the engine's way, the first game would spend
        // that budget and every game after it would return without flushing — which reads as
        // clients that never leave and joins that never land. A forced call does not touch the
        // global either, so the pacing stays the one `tickGames` does.
        _ = dispatch(1, 0);
    }
    // Left clear: `QSERVER_GenerateGameToken` will only issue while the slot it walks is free, and
    // the name check reads the same word.
    setEngineSlot(0);
    return ticked;
}

var last_tick_ms: i64 = 0;
/// The engine's own budget between passes over a game, in `QSERVER_TickAllGames`.
const tick_period_ms: i64 = 40;

// ── engine ───────────────────────────────────────────────────────────────────
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
    for (&slots) |*s| {
        if (s.gameid != 0) holdOne(s);
    }
}

fn holdOne(s: *Slot) void {
    // This does not just find the game, it LOCKS it — `EnterCriticalSection(game->0x18)` — and
    // every one of the engine's own callers unlocks before it returns. Reading two fields out of a
    // game and walking away with its critical section held would leave the game permanently locked
    // against its own destroy, once per tick.
    const from_id: *const fn (u32) callconv(.c) u32 = @ptrFromInt(image.at(addr.game_from_id));
    const game = from_id(s.gameid);
    if (game == 0) return;
    const unlock: *const fn (u32) callconv(.c) void = @ptrFromInt(image.at(addr.game_unlock));
    defer unlock(game);

    const clients: *const u32 = @ptrFromInt(game + game_clients);
    if (clients.* != s.last_clients) {
        s.last_clients = clients.*;
        note("d2gs-native: game {d} has {d} client(s), {d}ms in\n", .{ s.join_id, clients.*, nowMs() - s.held_since_ms });
        // On every change, including back down to zero, which is the one realmd cannot work out
        // for itself.
        sendPlayers(s.join_id, clients.*);
    }
    // A brand-new game reports one client before it has any: `GAME_CreateGame` is given a null
    // client and still files a player record for it, which the engine drops again a tick or two
    // later. Taking that for a player is what let the reap collect a game the moment it was made —
    // the count went 1, then 0, and the game was gone before the client it existed for had
    // finished connecting. So a real player is one this server has answered a GAMELOGON for.
    if (clients.* != 0) {
        if (s.phase == .waiting and s.join_resolved) s.phase = .played;
        if (s.phase != .waiting) return;
    }
    switch (s.phase) {
        .played => {
            s.phase = .released;
            s.empty_ms = nowMs();
            note("d2gs-native: game {d} is empty — the engine may collect it\n", .{s.join_id});
        },
        .released => {},
        .waiting => {
            if (nowMs() - s.held_since_ms > unjoined_grace_s * 1000) {
                s.phase = .released;
                note("d2gs-native: game {d} was never joined — the engine may collect it\n", .{s.join_id});
                return;
            }
            const empty_since: *u32 = @ptrFromInt(game + game_empty_since);
            empty_since.* = 0;
        },
    }
}

/// The 0x67 handler's call, with the packet's fields spelled out. Everything but the name, the
/// description and the flags is the constant that path passes for a plain expansion game.
fn runCreate(slot: *Slot) void {
    req_gameid = 0;
    // The engine files a new game in `gpGameTable[1]`, and `QSERVER_GenerateGameToken` only issues
    // while that word is free. It is kept clear between passes for exactly this.
    setEngineSlot(0);
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

    const singleton: *const u32 = @ptrFromInt(image.at(addr.last_gameid));
    const id = singleton.*;
    // A game the engine did not file under the token it schedules is one it never made.
    if (id == 0 or engineTokenValid(1) != id) {
        setEngineSlot(0);
        req_result = p.CREATE_FAILED;
        return;
    }
    // Take it out of the engine's one scheduled slot and keep it here instead. From now on this
    // server decides when the game is serviced, and the word is free for the next create. Nothing
    // is lost by moving it: `ServerGameLoop` is passed the game, and the join path resolves through
    // `SERVER_IsTokenValid`, which is ours.
    setEngineSlot(0);

    next_join_id = if (next_join_id == std.math.maxInt(u16)) 1 else next_join_id + 1;
    // Whatever id the engine reuses for it, this is a new game and nobody is in it yet. The phase
    // has to be set HERE and not left to the next tick's `holdGameForItsFirstPlayer`: the same pump
    // that ran this create goes on to look for a game that has finished, and a phase still reading
    // `released` from the last one makes it report the game it has just made as closed.
    slot.* = .{
        .gameid = id,
        .join_id = next_join_id,
        .name = req_name,
        .phase = .waiting,
        .held_since_ms = nowMs(),
    };
    req_gameid = slot.join_id;
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
    info.maxgame = game_cap;
    _ = sendAll(std.mem.asBytes(&info));

    var ai = std.mem.zeroes(p.AddrInfo);
    ai.h = header(.addrinfo, @sizeOf(p.AddrInfo));
    ai.maxgame = game_cap;
    ai.gsid = gsid;
    ai.ip = public_ip;
    ai.port = public_port;
    _ = sendAll(std.mem.asBytes(&ai));
    note("d2gs-native: gslink registered {d}.{d}.{d}.{d}:{d} maxgame={d}\n", .{
        public_ip[0], public_ip[1], public_ip[2], public_ip[3], public_port, game_cap,
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
    if (charname.len > 0 and account.len > 0) {
        seated = chardb.place(account, charname);
        // The realm has placed this character in a game, which is what makes releasing whatever
        // seat it still holds ELSEWHERE legitimate — see `takeVouch`.
        // Only when the game is actually known. A vouch recorded with a zero target authorises
        // releasing the seat from ANY game, since no game's id is zero — which evicts a player who
        // is still in the world rather than one who has left.
        if (slotByJoinId(@truncate(gid))) |s| vouchFor(charname, s.gameid);
    }
    note("d2gs-native: gslink JOINGAMEREQ gameid={d} char=\"{s}\" seated={} known={}\n", .{
        gid, charname, seated, slotByJoinId(@truncate(gid)) != null,
    });

    var r = std.mem.zeroes(p.JoinGameReply);
    r.h = header(.joingame, @sizeOf(p.JoinGameReply));
    r.result = if (slotByJoinId(@truncate(gid)) != null and seated) 0 else 1;
    r.gameid = gid;
    _ = sendAll(std.mem.asBytes(&r));
}

/// Tell the realm how many players a game holds now.
///
/// realmd increments its own count on every join it authorises (`d2cs.zig` `g.players + 1`) and
/// never decrements: it cannot, because it only ever sees the request to join, never the arrival or
/// the departure. The count comes back down solely because the server that hosts the game reports
/// an absolute figure — which this one did not do at all, so a game's count only ever went up. A
/// game whose name is reused across sessions therefore reached the engine's eight-player ceiling
/// and every further join was refused `0x2b`, "game is full", with nobody in it.
///
/// Absolute, never a delta, so a lost message cannot make it drift. The name is left empty: the
/// count is what is wrong, and realmd's roster ignores an empty one rather than filing a blank
/// member. A GS that knows who arrived should send the name and `GAMEINFO_ENTER`/`_LEAVE` instead.
fn sendPlayers(gid: u16, players: u32) void {
    var buf: [@sizeOf(p.UpdateGameInfo) + 1]u8 = undefined;
    var r = std.mem.zeroes(p.UpdateGameInfo);
    r.h = header(.updategameinfo, buf.len);
    r.flag = p.GAMEINFO_UPDATE;
    r.gameid = gid;
    r.players = players;
    @memcpy(buf[0..@sizeOf(p.UpdateGameInfo)], std.mem.asBytes(&r));
    buf[@sizeOf(p.UpdateGameInfo)] = 0; // the empty character name
    _ = sendAll(&buf);
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
    const host = text[0..colon];
    if (dottedQuad(host)) |oct| {
        ip.* = oct;
        return;
    }
    // A name, which is what a k8s Service is. Refusing one meant every deployment had to be given a
    // ClusterIP by hand, and that changes whenever the Service is recreated.
    ip.* = try resolve(host);
}

fn dottedQuad(host: []const u8) ?[4]u8 {
    var oct: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    for (&oct) |*o| o.* = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return oct;
}

const AddrInfoC = extern struct {
    flags: c_int,
    family: c_int,
    socktype: c_int,
    protocol: c_int,
    addrlen: u32,
    addr: ?*std.posix.sockaddr.in,
    canonname: ?[*:0]u8,
    next: ?*AddrInfoC,
};
extern "c" fn getaddrinfo(node: [*:0]const u8, service: ?[*:0]const u8, hints: ?*const AddrInfoC, res: **AddrInfoC) c_int;
extern "c" fn freeaddrinfo(res: *AddrInfoC) void;

fn resolve(host: []const u8) ![4]u8 {
    var z: [256]u8 = undefined;
    if (host.len >= z.len) return error.NameTooLong;
    @memcpy(z[0..host.len], host);
    z[host.len] = 0;

    var hints = std.mem.zeroes(AddrInfoC);
    hints.family = std.posix.AF.INET;
    hints.socktype = std.posix.SOCK.STREAM;
    var res: *AddrInfoC = undefined;
    if (getaddrinfo(@ptrCast(&z), null, &hints, &res) != 0) return error.NotResolved;
    defer freeaddrinfo(res);

    var it: ?*AddrInfoC = res;
    while (it) |a| : (it = a.next) {
        if (a.family != std.posix.AF.INET) continue;
        const sa = a.addr orelse continue;
        return @bitCast(sa.addr);
    }
    return error.NotResolved;
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
    // Anything that is not a dotted quad — a name, or "10.1.2.3.4" — is handed to resolve() on
    // purpose, so there is no parse error left to assert and the outcome depends on DNS. Only
    // `dottedQuad` can be checked without a resolver.
    try std.testing.expectEqual(@as(?[4]u8, null), dottedQuad("realm.example"));
    try std.testing.expectEqual(@as(?[4]u8, null), dottedQuad("10.1.2.3.4"));
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 1, 2, 3 }), dottedQuad("10.1.2.3"));
}

test "game flags carry difficulty, the client-update gate and expansion" {
    try std.testing.expectEqual(@as(u32, 0x10_0004), gameFlags(0, true, false));
    try std.testing.expectEqual(@as(u32, 0x10_2804), gameFlags(2, true, true));
}
