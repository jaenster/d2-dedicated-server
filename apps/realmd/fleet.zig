//! The fleet of game servers, as the whole realm sees it.
//!
//! There is no control connection to a game server. Servers publish themselves into the shared
//! store; create and join are handed to a server's queue there and answered on a reply key; what
//! happens on a server comes back as events any instance drains. So every instance sees the same
//! fleet and can dispatch to all of it, which is the whole reason the realm can run as more than
//! one replica.
//!
//! The wire format did not change — the same `{ size:u16, type:u16, seqno:u32 }` control packets,
//! now carried by redis. The `seqno` does real work here: over one socket with one request in
//! flight "the next reply is mine" was true by construction, and through a shared queue it is
//! false. Correlating is the difference between an answer and somebody else's answer.
const std = @import("std");
const log = @import("realm_infra").log;
const state = @import("state.zig");
const store = @import("store.zig");
const p = @import("realm_proto").protocol;

extern "c" fn usleep(usec: c_uint) c_int;

/// Global override for the game-server address advertised to clients (single-host dev / NAT).
/// When set it wins over what a server reports for itself.
pub var gs_ip_override: ?[4]u8 = null;

/// Bound on one fleet snapshot.
const max_gs = 64;

/// Read-only view of one game server, for the admin API.
pub const GsInfo = struct { gsid: u32, ip: [4]u8, port: u16, maxgame: u32, live: u32 };

fn addrOf(rec: store.GsRec) [4]u8 {
    return gs_ip_override orelse rec.gs_ip;
}

/// The fleet, newest view the store has. Every call is a round trip, so callers that only want a
/// count use `registeredCount` and callers that only want a yes/no use `ready`.
pub fn snapshot(buf: []GsInfo) usize {
    var recs: [max_gs]store.GsRec = undefined;
    const n = store.snapshotGs(recs[0..@min(recs.len, buf.len)]);
    for (0..n) |i| {
        buf[i] = .{
            .gsid = recs[i].gsid,
            .ip = addrOf(recs[i]),
            .port = recs[i].gs_port,
            .maxgame = recs[i].maxgame,
            .live = recs[i].live_games,
        };
    }
    return n;
}

pub fn registeredCount() usize {
    var recs: [max_gs]store.GsRec = undefined;
    return store.snapshotGs(&recs);
}

/// True if the realm can host a game at all. Not the same as "has room" — a fleet that is full is
/// still a fleet, and the caller tells the player something different for each.
pub fn ready() bool {
    return registeredCount() > 0;
}

fn find(gsid: u32) ?store.GsRec {
    var recs: [max_gs]store.GsRec = undefined;
    const n = store.snapshotGs(&recs);
    for (recs[0..n]) |r| {
        if (r.gsid == gsid) return r;
    }
    return null;
}

// dispatch

const REPLY_TIMEOUT_US: u64 = 5_000_000;

/// How long a queued request is worth delivering. Past this the client that asked for it has given
/// up, and handing it to a server later would create a game nobody is waiting for.
const request_ttl_s: u32 = 30;

/// Request ids must not collide ACROSS instances — two realmds using the same seq would collect
/// each other's replies.
///
/// The instance owns the top half of the number and counts in the bottom half, so instances hold
/// disjoint ranges by construction rather than by being unlikely to meet. That is the same
/// discriminator session ids already use, and it costs nothing; a realm-wide counter would be a
/// store round trip on every create to buy the same property.
var seq_ctr = std.atomic.Value(u16).init(0);

fn nextSeq() u32 {
    const low = seq_ctr.fetchAdd(1, .monotonic) +% 1;
    return (@as(u32, @truncate(state.instance_hash)) << 16) | low;
}

const Result = struct { ok: bool, gameid: u32, result: u32 = 1 };

/// Hand `packet` to `gsid` and wait for the answer carrying the same seq.
fn dispatch(gsid: u32, packet: []const u8, seq: u32) Result {
    const failed = Result{ .ok = false, .gameid = 0, .result = 1 };
    if (!store.pushGsRequest(gsid, packet, request_ttl_s)) return failed;
    var waited_us: u64 = 0;
    // Poll tightly at first — a healthy server answers in milliseconds — then back off, so a
    // server that never answers does not spin a thread for the whole timeout.
    var nap: c_uint = 200;
    var buf: [256]u8 = undefined;
    while (waited_us < REPLY_TIMEOUT_US) {
        if (store.takeGsReply(seq, &buf)) |n| {
            if (n < p.HEADER_LEN + 8) return failed;
            const body = buf[p.HEADER_LEN..n];
            const result = std.mem.readInt(u32, body[0..4], .little);
            return .{ .ok = result == 0, .gameid = std.mem.readInt(u32, body[4..8], .little), .result = result };
        }
        _ = usleep(nap);
        waited_us += nap;
        if (nap < 10_000) nap *= 2;
    }
    return failed;
}

fn writeHeader(buf: []u8, size: u16, typ: p.Type, seq: u32) void {
    std.mem.writeInt(u16, buf[0..2], size, .little);
    std.mem.writeInt(u16, buf[2..4], @intFromEnum(typ), .little);
    std.mem.writeInt(u32, buf[4..8], seq, .little);
}

fn putCStr(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    buf[pos + s.len] = 0;
    return pos + s.len + 1;
}

pub const CreateResult = struct { gsid: u32, gameid: u32, ip: [4]u8, port: u16 };

/// Why createGameRouted came back empty. The caller has three different things to say to the
/// player and only this tells them apart: a name someone else already has is not the same news as
/// a realm with no servers in it.
pub const CreateFailure = enum { no_gs, name_taken, refused, all_full };
/// Set by createGameRouted when it returns null. Read it immediately.
pub threadlocal var last_create_failure: CreateFailure = .no_gs;

/// Route a game create to the least-loaded server with room. Null if none could host it.
pub fn createGameRouted(name: []const u8, pass: []const u8, desc: []const u8, ladder: u8, expansion: bool, difficulty: u8, hardcore: bool) ?CreateResult {
    last_create_failure = .no_gs;
    // Retry across servers: "I am full" is a fact about one server, not about the request, so a
    // refusal there should not fail a create while the rest of the fleet is idle.
    var attempts: usize = 0;
    while (attempts < max_gs) : (attempts += 1) {
        const gsid = store.pickAndReserveGs() orelse {
            // Nothing has room. Which of the two answers that is depends on whether there is a
            // fleet at all, and the player is told something different for each.
            last_create_failure = if (registeredCount() > 0) .all_full else .no_gs;
            return null;
        };
        const rec = find(gsid) orelse {
            store.releaseGsSlot(gsid);
            continue; // expired between the pick and the lookup
        };

        var buf: [512]u8 = undefined;
        var pos: usize = p.HEADER_LEN;
        buf[pos] = ladder;
        buf[pos + 1] = @intFromBool(expansion);
        buf[pos + 2] = difficulty;
        buf[pos + 3] = @intFromBool(hardcore);
        pos += 4;
        pos = putCStr(&buf, pos, name);
        pos = putCStr(&buf, pos, pass);
        pos = putCStr(&buf, pos, desc);
        const seq = nextSeq();
        writeHeader(buf[0..p.HEADER_LEN], @intCast(pos), .creategame, seq);

        const r = dispatch(gsid, buf[0..pos], seq);
        if (r.ok and r.gameid != 0) {
            return .{ .gsid = gsid, .gameid = r.gameid, .ip = addrOf(rec), .port = rec.gs_port };
        }
        // The game did not happen, so the slot we reserved for it is free again.
        store.releaseGsSlot(gsid);
        // A name this server already hosts is final; trying the next one would only scatter
        // same-named games across the fleet.
        if (r.result == p.CREATE_NAME_TAKEN) {
            last_create_failure = .name_taken;
            return null;
        }
        if (r.result == p.CREATE_SERVER_FULL) {
            // The server publishes its own `full` as it answers, so the next pick skips it.
            last_create_failure = .all_full;
            continue;
        }
        last_create_failure = .refused;
        return null;
    }
    return null;
}

/// Tell the server that owns `gsid` a client is joining `gameid`, so it can fetch that account's
/// character save. Returns true on ack.
pub fn notifyJoin(gsid: u32, gameid: u32, token: u32, charname: []const u8, account: []const u8, guild_tag: []const u8) bool {
    var buf: [160]u8 = undefined;
    std.mem.writeInt(u32, buf[8..12], gameid, .little);
    std.mem.writeInt(u32, buf[12..16], token, .little);
    var pos = putCStr(&buf, 16, charname);
    pos = putCStr(&buf, pos, account);
    pos = putCStr(&buf, pos, guild_tag); // cut Guild Halls: the player's guild tag (empty = none)
    const seq = nextSeq();
    writeHeader(buf[0..p.HEADER_LEN], @intCast(pos), .joingame, seq);
    return dispatch(gsid, buf[0..pos], seq).ok;
}

// events (game server -> realm)

/// Apply one event. Shape and meaning are unchanged from when these travelled a socket; what
/// changed is that any instance may be the one to apply it.
fn apply(typ: p.Type, body: []const u8) void {
    switch (typ) {
        .addrinfo => {
            // A server that just started hosts nothing, so any game record still naming it is a
            // leftover — from one that died without deregistering, or from records that outlived
            // a realmd restart. They must go, or their names stay taken forever and create-game
            // rejects them as duplicates.
            if (body.len < 14) return;
            const gsid = std.mem.readInt(u32, body[4..8], .little);
            state.global.expireGamesByGs(gsid);
            log.line("fleet", "game server 0x{x} started; its stale games expired", .{gsid});
        },
        .updategameinfo => {
            // The server is the only party that sees players leave, so its count replaces ours
            // outright rather than adjusting it — an absolute value cannot drift if an event
            // is lost.
            if (body.len < 20) return;
            const flag = std.mem.readInt(u32, body[0..4], .little);
            const gameid = std.mem.readInt(u32, body[4..8], .little);
            const players = std.mem.readInt(u32, body[8..12], .little);
            const level = std.mem.readInt(u32, body[12..16], .little);
            const class = std.mem.readInt(u32, body[16..20], .little);
            var off: usize = 20;
            const char = p.readCStr(body, &off);
            _ = state.global.setGamePlayers(gameid, @intCast(@min(players, 0xFFFF)));
            // The roster is what makes the join screen's detail panel able to name anyone; the
            // count alone only fills the PLAYERS column.
            state.global.setGameMember(gameid, flag != p.GAMEINFO_LEAVE, char, @intCast(@min(level, 255)), @intCast(@min(class, 255)));
            // Freed as the player leaves rather than when the game ends, so a character is
            // available for its next game immediately. Matched by name because a departure
            // carries no account, which is why the realm keeps the pairing itself.
            if (flag == p.GAMEINFO_LEAVE and char.len > 0) _ = store.releaseGameCharByName(gameid, char);
        },
        .closegame => {
            if (body.len < 8) return;
            const gameid = std.mem.readInt(u32, body[4..8], .little);
            if (gameid == 0) return;
            // Whatever the game still holds is free now. A backstop for players the engine never
            // reported leaving — a client that vanished, or a server lost mid-game — since
            // otherwise those characters would stay claimed until their lease ran out.
            _ = store.releaseGameChars(gameid);
            state.global.removeGameById(gameid);
            log.line("fleet", "game {d} closed", .{gameid});
        },
        else => {},
    }
}

/// Drain game-server events forever. Every instance runs one; each event is consumed by exactly
/// one of them, which is what makes applying it safe.
pub fn consumeEvents() void {
    var buf: [1024]u8 = undefined;
    // Idle at 50 ms rather than blocking: a BLPOP would hold a store connection open per instance
    // for the whole time nothing is happening, and 50 ms is far below anything a player can see.
    var nap: c_uint = 1_000;
    while (true) {
        const n = store.popGsEvent(&buf) orelse {
            _ = usleep(nap);
            if (nap < 50_000) nap *= 2;
            continue;
        };
        nap = 1_000; // busy: come straight back for the next one
        if (n < p.HEADER_LEN) continue;
        const size = std.mem.readInt(u16, buf[0..2], .little);
        const typ = std.mem.readInt(u16, buf[2..4], .little);
        if (size > n or size < p.HEADER_LEN) continue;
        apply(@enumFromInt(typ), buf[p.HEADER_LEN..size]);
    }
}
