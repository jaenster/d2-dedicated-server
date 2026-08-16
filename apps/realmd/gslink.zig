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
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const obs = @import("realm_infra").obs;
const state = @import("state.zig");
const store = @import("store.zig");
const Lock = @import("realm_infra").lock.Lock;
const p = @import("realm_proto").protocol;

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
const TYPE_LEAVE_FLAG = p.GAMEINFO_LEAVE;
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
    /// This GS answered a create with "server full". Our own count cannot see that: a finished
    /// game holds its engine slot through the reap window, so the GS runs out while we still
    /// think it has room. Cleared the moment any game on it closes, which is exactly when room
    /// reappears — the GS is the one that knows, and CLOSEGAME is it saying so.
    full: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    in_use: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // slot claimed
    registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // ADDRINFO seen → can host

    send_lock: Lock = .{}, // serialise writes to this GS fd
    req_lock: Lock = .{}, // one create/join in flight to this GS
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
    lock: Lock = .{},

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
            if (g.full.load(.acquire)) continue; // said so itself; waiting on a close
            const load = g.live_games.load(.acquire);
            if (g.maxgame != 0 and load >= g.maxgame) continue; // full
            if (load < best_load) {
                best = g;
                best_load = load;
            }
        }
        return best;
    }

    /// The least-loaded registered GS, capacity ignored. Only for the last look before a create is
    /// refused: the realm's count is a snapshot, and a server that has just watched its last player
    /// leave is free before the realm has been told. Asking it costs one round trip and it answers
    /// for itself — which on a server that hosts ONE game is the difference between the next game
    /// starting and a player being told the realm is down.
    fn pickAnyRegistered(self: *GsRegistry) ?*Gs {
        self.lock.lock();
        defer self.lock.unlock();
        var best: ?*Gs = null;
        var best_load: u32 = std.math.maxInt(u32);
        for (&self.entries) |*g| {
            if (!g.in_use.load(.acquire) or !g.registered.load(.acquire)) continue;
            const load = g.live_games.load(.acquire);
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

/// Publish this server into the shared fleet view, so instances that do not hold its control
/// connection can still see that it exists and how loaded it is. Called wherever its load or
/// capacity changes, and on the link's own echo so a healthy server keeps its record alive.
///
/// Best-effort on purpose: the local registry is what dispatch actually uses, so a store that is
/// down degrades the realm to what it was before this existed rather than failing a create.
fn publish(g: *Gs) void {
    if (!g.registered.load(.acquire)) return;
    _ = store.registerGs(.{
        .gsid = g.gsid,
        .gs_ip = g.ip(),
        .gs_port = g.port,
        .maxgame = g.maxgame,
        .live_games = g.live_games.load(.acquire),
        .full = g.full.load(.acquire),
    });
}

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
    obs.setSystem(); // GS control link — not a user's connection
    const g = registry.alloc() orelse {
        log.line(tag, "GS registry full ({d}); rejecting connection", .{max_gs});
        return;
    };
    defer {
        const was_registered = g.registered.load(.acquire);
        // Its control connection is gone, so no instance can dispatch to it: take it out of
        // the shared view now rather than waiting for the record to expire.
        if (g.gsid != 0) store.removeGs(g.gsid);
        registry.release(g);
        // Only a connection that got as far as ADDRINFO owns any games. Anything else is
        // a port probe — `nc -z`, a k8s readiness check, run-stack's own await — and it
        // arrives with gsid still 0. Expiring "gsid 0's games" on its way out is at best
        // a line of noise per probe and at worst reaps real records that happen to carry
        // no gs id yet.
        if (was_registered) {
            state.global.expireGamesByGs(g.gsid);
            log.line(tag, "GS gsid=0x{x} disconnected; its games expired", .{g.gsid});
        }
    }

    g.fd = fd;
    g.peer_ip = net.peerIp(fd);
    g.pub_ip = .{ 0, 0, 0, 0 };
    g.gsid = 0;
    g.port = 4000;
    g.maxgame = 0;
    g.live_games.store(0, .release);
    g.full.store(false, .release);
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
            // A GS that just came up hosts nothing, so any game record still naming it is a
            // leftover — from a GS that died without deregistering, or from records that
            // outlived a realmd restart in the shared store. They must go, or their names
            // stay taken forever and create-game rejects them as duplicates.
            state.global.expireGamesByGs(g.gsid);
            g.registered.store(true, .release);
            publish(g);
            const a = g.ip();
            log.line(tag, "GS ADDRINFO gsid=0x{x} addr={d}.{d}.{d}.{d}:{d} maxgame={d} -> registered", .{ g.gsid, a[0], a[1], a[2], a[3], g.port, g.maxgame });
        },
        TYPE_ECHO => {
            var hbuf: [8]u8 = undefined;
            writeHeader(&hbuf, 8, TYPE_ECHO, nextSeq(g));
            _ = sendPacket(g, &hbuf);
            publish(g); // keeps the shared record from expiring while the link is healthy
        },
        TYPE_CREATEGAME, TYPE_JOINGAME => {
            // GS reply to our request: result, gameid.
            g.reply_result = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 1;
            g.reply_gameid = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
            g.reply_done.store(true, .release);
        },
        TYPE_UPDATEGAMEINFO => {
            // { flag:u32, gameid:u32, players:u32 } (see realm/protocol.zig). The GS is the
            // only party that sees players leave, so its count replaces ours outright rather
            // than adjusting it — an absolute value can't drift if a message is lost.
            if (body.len >= 20) {
                const flag = std.mem.readInt(u32, body[0..4], .little);
                const gameid = std.mem.readInt(u32, body[4..8], .little);
                const players = std.mem.readInt(u32, body[8..12], .little);
                const level = std.mem.readInt(u32, body[12..16], .little);
                const class = std.mem.readInt(u32, body[16..20], .little);
                var off: usize = 20;
                const char = p.readCStr(body, &off);
                const known = state.global.setGamePlayers(gameid, @intCast(@min(players, 0xFFFF)));
                // The roster is what makes the join screen's detail panel able to name
                // anyone; the count alone only fills the PLAYERS column.
                state.global.setGameMember(gameid, flag != TYPE_LEAVE_FLAG, char, @intCast(@min(level, 255)), @intCast(@min(class, 255)));
                // Freed as the player leaves rather than when the game ends, so a character is
                // available for its next game immediately. Matched by name because a departure
                // carries no account, which is why the realm keeps the pairing itself.
                if (flag == TYPE_LEAVE_FLAG and char.len > 0) _ = store.releaseGameCharByName(gameid, char);
                log.line(tag, "GS UPDATEGAMEINFO gameid={d} players={d} flag={d} char='{s}' lvl={d} class={d}{s}", .{
                    gameid, players, flag, char, level, class, if (known) "" else " (no such game)",
                });
            }
        },
        TYPE_CLOSEGAME => {
            const gameid = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
            // Whatever the game still holds is free now. A backstop for players the engine never
            // reported leaving — a client that vanished, or a server lost mid-game — since
            // otherwise those characters would stay claimed until their lease ran out.
            if (gameid != 0) _ = store.releaseGameChars(gameid);
            // Capacity first, store second. The slot is free the instant the GS says so, and it
            // is what the very next create is routed on; dropping the game record is a round trip
            // to the ephemeral store, and doing it first put a store's worth of latency between
            // "a server has room" and this realm being willing to use it. On a one-game server
            // that is the whole gap between two games — the create after every game was refused
            // while the slot it wanted had already been given back.
            if (g.live_games.load(.acquire) > 0) _ = g.live_games.fetchSub(1, .monotonic);
            g.full.store(false, .release); // a slot came free — this GS can host again
            publish(g);
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

const Result = struct { ok: bool, gameid: u32, result: u32 = 1 };

/// p.CREATE_NAME_TAKEN, spelled locally because this reply is shared by CREATE and JOIN.
const proto_create_name_taken: u32 = p.CREATE_NAME_TAKEN;
const proto_create_server_full: u32 = p.CREATE_SERVER_FULL;

const REPLY_TIMEOUT_US: u64 = 5_000_000;

/// How long a queued request is worth delivering. Past this the client that asked for it has
/// given up, and handing it to a server later would create a game nobody is waiting for.
const request_ttl_s: u32 = 30;

/// Send a request through the store and wait for the answer, correlating on the seq in its
/// header.
///
/// This is what makes any instance able to serve any client: the request goes to the server's
/// queue rather than down a socket, so the realmd holding that socket is no longer special. The
/// seq was always in the header and was always ignored — over one connection with one request in
/// flight, "the next reply is mine" was true by construction. Through a shared queue it is simply
/// false, and matching is the difference between an answer and somebody else's answer.
fn dispatchViaStore(gsid_to: u32, packet: []const u8, seq: u32) Result {
    if (!store.pushGsRequest(gsid_to, packet, request_ttl_s)) return .{ .ok = false, .gameid = 0, .result = 1 };
    var waited_us: u64 = 0;
    var nap: c_uint = 200;
    var buf: [256]u8 = undefined;
    while (waited_us < REPLY_TIMEOUT_US) {
        if (store.takeGsReply(seq, &buf)) |n| {
            if (n >= p.HEADER_LEN + 8) {
                const body = buf[p.HEADER_LEN..n];
                return .{
                    .ok = std.mem.readInt(u32, body[0..4], .little) == 0,
                    .gameid = std.mem.readInt(u32, body[4..8], .little),
                    .result = std.mem.readInt(u32, body[0..4], .little),
                };
            }
            return .{ .ok = false, .gameid = 0, .result = 1 };
        }
        _ = usleep(nap);
        waited_us += nap;
        if (nap < 10_000) nap *= 2;
    }
    return .{ .ok = false, .gameid = 0, .result = 1 };
}

fn awaitReply(g: *Gs) Result {
    // Poll the reply flag the control thread sets — 0.16 has no condvar outside Io, and a
    // create/join is rare enough that polling is fine. The interval matters: this runs while
    // holding req_lock, and a flat 1 ms woke the thread 5000 times for a GS that never
    // answered. Poll tightly at first (a healthy GS answers in ms) then back off.
    var waited_us: u64 = 0;
    var nap: c_uint = 200;
    while (waited_us < REPLY_TIMEOUT_US) {
        if (g.reply_done.load(.acquire)) {
            return .{ .ok = g.reply_result == 0, .gameid = g.reply_gameid, .result = g.reply_result };
        }
        _ = usleep(nap);
        waited_us += nap;
        if (nap < 10_000) nap *= 2;
    }
    return .{ .ok = false, .gameid = 0, .result = 1 };
}

pub const CreateResult = struct { gsid: u32, gameid: u32, ip: [4]u8, port: u16 };

/// Why createGameRouted came back empty. The caller has three different things to say
/// to the player and only this tells them apart: a name someone else already has is
/// not the same news as a realm with no servers in it.
pub const CreateFailure = enum { no_gs, name_taken, refused, all_full };
/// Set by createGameRouted when it returns null. Read it immediately.
pub var last_create_failure: CreateFailure = .no_gs;

/// Route a game create to the least-loaded GS with capacity. Returns the chosen
/// GS's id + the engine gameid + the address clients dial, or null if no GS could
/// host it (none registered, all full, or the GS refused).
pub fn createGameRouted(name: []const u8, pass: []const u8, desc: []const u8, ladder: u8, expansion: bool, difficulty: u8, hardcore: bool) ?CreateResult {
    // Retry across GSes: a GS that just dropped its control connection can linger in
    // the registry for a moment before its handler deregisters it. If the send fails,
    // that GS is dead — unregister it (so we don't pick it again) and try the next.
    var attempts: usize = 0;
    var asked_beyond_capacity = false;
    last_create_failure = .no_gs;
    while (attempts < max_gs) : (attempts += 1) {
        const g = registry.pickForCreate() orelse blk: {
            // Every server is at the capacity this realm has recorded for it. That is a snapshot,
            // and the newest thing about it is already a round trip old; the server itself knows
            // whether the game it is holding is over. Ask once, and only once, before saying no.
            if (asked_beyond_capacity) return null;
            asked_beyond_capacity = true;
            last_create_failure = .all_full;
            break :blk registry.pickAnyRegistered() orelse return null;
        };
        g.req_lock.lock();
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
        if (!sendPacket(g, buf[0..pos])) {
            g.req_lock.unlock();
            g.registered.store(false, .release); // dead GS; its handler frees the slot
            continue;
        }
        const r = awaitReply(g);
        g.req_lock.unlock();
        if (!r.ok or r.gameid == 0) {
            // A name this GS already hosts is final, and trying the next GS would only
            // scatter same-named games across the fleet.
            if (r.result == proto_create_name_taken) {
                last_create_failure = .name_taken;
                return null;
            }
            // "I am full" is a fact about that GS, not about the request, so try the next one
            // rather than failing while the rest of the fleet is idle. Flag it instead of forcing
            // the live count to capacity: that count is what CLOSEGAME walks back down, and
            // overwriting it means every close spends itself undoing a number we made up before
            // the GS is picked again — one that reported full while hosting three games stayed
            // unpickable for four closes it would never receive.
            if (r.result == proto_create_server_full) {
                last_create_failure = .all_full;
                g.full.store(true, .release);
                publish(g);
                continue;
            }
            last_create_failure = .refused;
            return null;
        }
        _ = g.live_games.fetchAdd(1, .monotonic);
        // Deliberately NOT published here. Everything between the GS accepting a create and this
        // returning is time in which the game exists but the realm has not recorded it yet, and a
        // second client creating the same name loses the race and then cannot join what it was
        // told already exists. A store round trip in that gap made every stress round fail.
        // The count reaches the shared view on the next echo, which is soon enough for a view.
        return .{ .gsid = g.gsid, .gameid = r.gameid, .ip = g.ip(), .port = g.port };
    }
    return null;
}

/// Best-effort: tell the GS that owns `gsid` a client is joining `gameid`, so it can
/// fetch that account's character save. The client routes to the GS via the stored
/// game record regardless; this just primes the GS. Returns true on ack.
pub fn notifyJoin(gsid: u32, gameid: u32, token: u32, charname: []const u8, account: []const u8, guild_tag: []const u8) bool {
    const g = registry.byId(gsid) orelse return false;
    g.req_lock.lock();
    defer g.req_lock.unlock();
    g.reply_done.store(false, .release);

    var buf: [160]u8 = undefined;
    std.mem.writeInt(u32, buf[8..12], gameid, .little);
    std.mem.writeInt(u32, buf[12..16], token, .little);
    var pos = putCStr(&buf, 16, charname);
    pos = putCStr(&buf, pos, account);
    pos = putCStr(&buf, pos, guild_tag); // cut Guild Halls: the player's guild tag (empty = none)
    writeHeader(buf[0..8], @intCast(pos), TYPE_JOINGAME, nextSeq(g));
    if (!sendPacket(g, buf[0..pos])) return false;

    return awaitReply(g).ok;
}

fn putCStr(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    buf[pos + s.len] = 0;
    return pos + s.len + 1;
}

test "a GS that reported full is pickable again after one close, not after enough closes" {
    var reg: GsRegistry = .{};
    const g = reg.alloc().?;
    g.gsid = 7;
    g.maxgame = 7;
    g.registered.store(true, .release);
    // Three games live, and the engine still refuses a fourth: its finished games hold their
    // slots through the reap window, which our count cannot see.
    g.live_games.store(3, .release);
    try std.testing.expect(reg.pickForCreate() != null);

    g.full.store(true, .release);
    try std.testing.expect(reg.pickForCreate() == null);

    // One close is one free slot. Forcing live_games to maxgame instead would need four.
    g.full.store(false, .release);
    _ = g.live_games.fetchSub(1, .monotonic);
    try std.testing.expect(reg.pickForCreate() != null);
    try std.testing.expectEqual(@as(u32, 2), g.live_games.load(.acquire));
}

test "a fleet with no recorded capacity still has one server asked before the create is refused" {
    var reg: GsRegistry = .{};
    const a = reg.alloc().?;
    a.gsid = 1;
    a.maxgame = 1;
    a.live_games.store(1, .release);
    a.registered.store(true, .release);
    const b = reg.alloc().?;
    b.gsid = 2;
    b.maxgame = 1;
    b.live_games.store(1, .release);
    b.full.store(true, .release);
    b.registered.store(true, .release);

    try std.testing.expect(reg.pickForCreate() == null);
    // Both are at capacity, so the least loaded of them is the one worth asking — and a server
    // that is not registered at all is still never asked.
    try std.testing.expectEqual(@as(u32, 1), reg.pickAnyRegistered().?.gsid);
    a.registered.store(false, .release);
    try std.testing.expectEqual(@as(u32, 2), reg.pickAnyRegistered().?.gsid);
    b.registered.store(false, .release);
    try std.testing.expect(reg.pickAnyRegistered() == null);
}

test "a GS at its advertised capacity is skipped, and a second GS takes the create" {
    var reg: GsRegistry = .{};
    const a = reg.alloc().?;
    a.gsid = 1;
    a.maxgame = 7;
    a.live_games.store(7, .release);
    a.registered.store(true, .release);
    try std.testing.expect(reg.pickForCreate() == null);

    const b = reg.alloc().?;
    b.gsid = 2;
    b.maxgame = 7;
    b.live_games.store(2, .release);
    b.registered.store(true, .release);
    try std.testing.expectEqual(@as(u32, 2), reg.pickForCreate().?.gsid);
}
