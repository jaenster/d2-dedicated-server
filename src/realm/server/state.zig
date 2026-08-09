//! Shared in-process state: the realm session table.
//!
//! This is THE stateful seam. Today it is an in-memory fixed table guarded by a
//! spinlock (single instance). For multi-instance, this same API gets backed by
//! a shared Store (Postgres/Redis) so any realmd can resolve a session another
//! created — the protocol handlers above it stay stateless. Keep all durable
//! cross-connection state behind here.
//!
//! A session is minted by bnetd at realm logon (SID_LOGONREALMEX) and resolved
//! by d2cs at MCP_STARTUP. Because we own both ends, the realm handoff carries a
//! plain session id in the MCP chunk — no pvpgn-style shared-secret crypto.
const std = @import("std");
const Spinlock = @import("realm_infra").lock.Spinlock;
const store = @import("store.zig");

extern "c" fn time(t: ?*c_long) c_long; // POSIX seconds, for a game's elapsed-time line

pub const max_name = 31;

/// Multi-instance mode: sessions/games go to the shared Store (a shared volume)
/// instead of process memory, so any instance resolves what another created.
/// Set by main() from REALMD_SHARED.
pub var shared: bool = false;
/// Per-instance high bits so session ids minted by different instances never
/// collide (the MCP chunk carries a full u64). Set by main() from REALMD_INSTANCE.
pub var instance_hash: u32 = 0;
var shared_ctr = std.atomic.Value(u32).init(1);

pub const Session = struct {
    id: u64 = 0,
    account: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    account_len: u8 = 0,
    in_use: bool = false,

    pub fn name(s: *const Session) []const u8 {
        return s.account[0..s.account_len];
    }
};

/// One character in a game, as the join screen's detail panel lists them. Filled from the
/// hosting GS's UPDATEGAMEINFO — realmd sees a request to join, not an arrival, so this is
/// the only honest source for who is actually in there.
pub const Member = struct {
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    level: u8 = 0,
    class: u8 = 0,

    pub fn name_slice(m: *const Member) []const u8 {
        return m.name[0..m.name_len];
    }
};

/// A D2 game holds eight.
pub const max_members = 8;

/// Who is in a game, and since when — the two things the join screen's detail panel needs
/// that no store record carries. Keyed by engine gameid and kept per instance, so it works
/// the same whether games live in memory or in a shared store.
pub const Roster = struct {
    gameid: u32 = 0,
    created: i64 = 0,
    members: [max_members]Member = [_]Member{.{}} ** max_members,
    count: u8 = 0,
    in_use: bool = false,
};

pub const Game = struct {
    name: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    name_len: u8 = 0,
    gameid: u32 = 0, // engine server token (= the token the client passes to the GS)
    gs_ip: [4]u8 = .{ 0, 0, 0, 0 }, // d2gs address the client connects to
    gs_port: u16 = 4000, // d2gs game port the client connects to
    gsid: u32 = 0, // which GS in the fleet hosts this game
    players: u16 = 0, // live player count for the join-screen list (the GS owns it)
    status: u8 = 0, // creator's .d2s status bits — what kind of game a joiner must match
    difficulty: u8 = 0, // 0 Normal, 1 Nightmare, 2 Hell
    password: [16]u8 = [_]u8{0} ** 16, // join password (empty = open game)
    pw_len: u8 = 0,
    description: [32]u8 = [_]u8{0} ** 32, // creator's blurb, shown beside the name
    desc_len: u8 = 0,
    in_use: bool = false,

    pub fn name_slice(g: *const Game) []const u8 {
        return g.name[0..g.name_len];
    }
    pub fn pw(g: *const Game) []const u8 {
        return g.password[0..g.pw_len];
    }
    pub fn desc(g: *const Game) []const u8 {
        return g.description[0..g.desc_len];
    }
};

pub const State = struct {
    lock: Spinlock = .{},
    sessions: [1024]Session = [_]Session{.{}} ** 1024,
    next_id: u64 = 1,
    games: [512]Game = [_]Game{.{}} ** 512,
    rosters: [256]Roster = [_]Roster{.{}} ** 256,

    /// Mint a session for `account`, returning its id (0 on failure).
    pub fn mintSession(st: *State, account: []const u8) u64 {
        if (shared) {
            const id = (@as(u64, instance_hash) << 32) | shared_ctr.fetchAdd(1, .monotonic);
            return if (store.saveSession(id, account)) id else 0;
        }
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.sessions) |*s| {
            if (s.in_use) continue;
            const n: u8 = @intCast(@min(account.len, max_name));
            @memcpy(s.account[0..n], account[0..n]);
            s.account_len = n;
            s.id = st.next_id;
            s.in_use = true;
            st.next_id += 1;
            return s.id;
        }
        return 0;
    }

    /// Copy the session's account name for `id` into `out`; returns its slice,
    /// or null if no such session. (Copies under lock so callers can't race a
    /// concurrent free.)
    pub fn accountForSession(st: *State, id: u64, out: []u8) ?[]const u8 {
        if (shared) return store.accountForSession(id, out);
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.sessions) |*s| {
            if (s.in_use and s.id == id) {
                const n = @min(s.account_len, out.len);
                @memcpy(out[0..n], s.account[0..n]);
                return out[0..n];
            }
        }
        return null;
    }

    /// Longest game name we key on. Battle.net caps game names well under this.
    const max_key = 64;

    /// Game names are CASE-INSENSITIVE on Battle.net: a player who makes "Jan" is joined by
    /// someone typing "jan". Every lookup and every registration therefore keys on a folded
    /// name, while the record keeps whatever casing the creator used for display. Without this
    /// the two spellings are two different games, and the second player silently ends up alone
    /// in an empty one.
    fn foldName(name: []const u8, buf: *[max_key]u8) []const u8 {
        const n = @min(name.len, max_key);
        for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return buf[0..n];
    }

    /// Register (or replace, by name) a hosted game. Returns false if full.
    pub fn registerGame(st: *State, name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32, players: u16, status: u8, difficulty: u8, password: []const u8, description: []const u8) bool {
        var kb: [max_key]u8 = undefined;
        const key = foldName(name, &kb);
        if (shared) return store.registerGame(key, gameid, gs_ip, gs_port, gsid, players, status, difficulty, password, description);
        st.lock.lock();
        defer st.lock.unlock();
        var slot: ?*Game = null;
        for (&st.games) |*g| {
            if (g.in_use and std.ascii.eqlIgnoreCase(g.name_slice(), name)) {
                slot = g;
                break;
            }
            if (slot == null and !g.in_use) slot = g;
        }
        const g = slot orelse return false;
        const n: u8 = @intCast(@min(name.len, max_name));
        @memcpy(g.name[0..n], name[0..n]);
        g.name_len = n;
        g.gameid = gameid;
        g.gs_ip = gs_ip;
        g.gs_port = gs_port;
        g.gsid = gsid;
        g.players = players;
        g.status = status;
        g.difficulty = difficulty;
        const pn: u8 = @intCast(@min(password.len, g.password.len));
        @memcpy(g.password[0..pn], password[0..pn]);
        g.pw_len = pn;
        const dn: u8 = @intCast(@min(description.len, g.description.len));
        @memcpy(g.description[0..dn], description[0..dn]);
        g.desc_len = dn;
        g.in_use = true;
        return true;
    }

    /// Look up a game by name; copies the record out under lock.
    pub fn findGame(st: *State, name: []const u8) ?Game {
        var kb: [max_key]u8 = undefined;
        const key = foldName(name, &kb);
        if (shared) {
            const rec = store.findGame(key) orelse return null;
            var g = Game{ .gameid = rec.gameid, .gs_ip = rec.gs_ip, .gs_port = rec.gs_port, .gsid = rec.gsid, .players = rec.players, .status = rec.status, .difficulty = rec.difficulty, .in_use = true };
            const n: u8 = @intCast(@min(name.len, max_name));
            @memcpy(g.name[0..n], name[0..n]);
            g.name_len = n;
            const pn: u8 = @intCast(@min(rec.pw_len, g.password.len));
            @memcpy(g.password[0..pn], rec.password[0..pn]);
            g.pw_len = pn;
            const dn: u8 = @intCast(@min(rec.desc_len, g.description.len));
            @memcpy(g.description[0..dn], rec.description[0..dn]);
            g.desc_len = dn;
            return g;
        }
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and std.ascii.eqlIgnoreCase(g.name_slice(), name)) return g.*;
        }
        return null;
    }

    /// Set a game's player count from the GS that hosts it (UPDATEGAMEINFO). Returns
    /// false if no such game is registered — normal for a stale id, worth logging.
    pub fn setGamePlayers(st: *State, gameid: u32, players: u16) bool {
        if (shared) return store.setGamePlayers(gameid, players);
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and g.gameid == gameid) {
                g.players = players;
                return true;
            }
        }
        return false;
    }

    /// Note that a game now exists, starting its clock. Called when realmd registers it.
    pub fn noteGameCreated(st: *State, gameid: u32) void {
        st.lock.lock();
        defer st.lock.unlock();
        const r = st.rosterSlot(gameid) orelse return;
        r.* = .{ .gameid = gameid, .created = time(null), .in_use = true };
    }

    /// Forget a game's roster (CLOSEGAME / GS disconnect), freeing the slot.
    pub fn forgetGameRoster(st: *State, gameid: u32) void {
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.rosters) |*r| {
            if (r.in_use and r.gameid == gameid) r.* = .{};
        }
    }

    /// The roster entry for `gameid`, reusing an existing one or claiming a free slot.
    /// Null when the table is full. Caller holds the lock.
    fn rosterSlot(st: *State, gameid: u32) ?*Roster {
        var free: ?*Roster = null;
        for (&st.rosters) |*r| {
            if (r.in_use and r.gameid == gameid) return r;
            if (free == null and !r.in_use) free = r;
        }
        return free;
    }

    /// Add or remove a character from a game's roster, from the hosting GS's
    /// UPDATEGAMEINFO. Kept here rather than in the store because it changes on every
    /// join and leave, and a store write per player movement is a lot of traffic for a
    /// cosmetic panel — with the consequence, in multi-instance mode, that only the
    /// instance holding that GS's link can list a game's players.
    pub fn setGameMember(st: *State, gameid: u32, joined: bool, char: []const u8, level: u8, class: u8) void {
        if (char.len == 0) return;
        st.lock.lock();
        defer st.lock.unlock();
        const r = st.rosterSlot(gameid) orelse return;
        if (!r.in_use) r.* = .{ .gameid = gameid, .created = time(null), .in_use = true };

        var i: usize = 0;
        while (i < r.count) : (i += 1) {
            if (!std.ascii.eqlIgnoreCase(r.members[i].name_slice(), char)) continue;
            if (joined) {
                // Already listed — refresh it, since a level can change between joins.
                r.members[i].level = level;
                r.members[i].class = class;
            } else {
                // Compact rather than leave a hole: the panel walks the first `count`
                // entries, and a gap would silently truncate the list at it.
                r.members[i] = r.members[r.count - 1];
                r.members[r.count - 1] = .{};
                r.count -= 1;
            }
            return;
        }
        if (!joined or r.count >= max_members) return;
        var m = Member{ .level = level, .class = class };
        const n: u8 = @intCast(@min(char.len, m.name.len));
        @memcpy(m.name[0..n], char[0..n]);
        m.name_len = n;
        r.members[r.count] = m;
        r.count += 1;
    }

    /// Copy a game's roster out under the lock. Returns how many were filled.
    pub fn gameMembers(st: *State, gameid: u32, out: []Member) usize {
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.rosters) |*r| {
            if (!r.in_use or r.gameid != gameid) continue;
            const n = @min(@as(usize, r.count), out.len);
            @memcpy(out[0..n], r.members[0..n]);
            return n;
        }
        return 0;
    }

    /// When a game was first seen here, or 0 if this instance never registered it.
    pub fn gameCreated(st: *State, gameid: u32) i64 {
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.rosters) |*r| {
            if (r.in_use and r.gameid == gameid) return r.created;
        }
        return 0;
    }

    /// Remove a game by engine gameid (called on CLOSEGAME).
    pub fn removeGameById(st: *State, gameid: u32) void {
        st.forgetGameRoster(gameid);
        if (shared) return store.removeGameById(gameid); // store's games-by-id reverse index
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and g.gameid == gameid) g.in_use = false;
        }
    }

    /// Mark a game not-in-use by name (admin close). Returns true if one was found.
    pub fn closeGameByName(st: *State, name: []const u8) bool {
        var kb: [max_key]u8 = undefined;
        const name_folded = foldName(name, &kb);
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and std.ascii.eqlIgnoreCase(g.name_slice(), name_folded)) {
                g.in_use = false;
                return true;
            }
        }
        return false;
    }

    /// Count of in-use sessions (in-memory path; admin status).
    pub fn sessionCount(st: *State) usize {
        st.lock.lock();
        defer st.lock.unlock();
        var n: usize = 0;
        for (&st.sessions) |*s| {
            if (s.in_use) n += 1;
        }
        return n;
    }

    /// Expire every game hosted by a GS that just disconnected, so clients stop being
    /// routed to a dead server and creators can reuse the names.
    pub fn expireGamesByGs(st: *State, gsid: u32) void {
        if (shared) return store.expireGamesByGs(gsid); // store's games-by-gs index
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and g.gsid == gsid) g.in_use = false;
        }
    }
};

pub var global: State = .{};

/// Read-only view of one active game, for the admin API.
pub const GameInfo = struct {
    name: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    name_len: u8 = 0,
    gameid: u32 = 0,
    gsid: u32 = 0,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    port: u16 = 0,
    players: u16 = 0,
    /// Creator's character status bits — what kind of game it is (hardcore/expansion/ladder).
    status: u8 = 0,
    description: [32]u8 = [_]u8{0} ** 32,
    desc_len: u8 = 0,

    pub fn name_slice(g: *const GameInfo) []const u8 {
        return g.name[0..g.name_len];
    }
    pub fn desc(g: *const GameInfo) []const u8 {
        return g.description[0..g.desc_len];
    }
};

/// Snapshot active games into `buf`; returns the number filled. Shared mode enumerates
/// the backing store (fs/redis/pg); in-memory mode walks the local table under the lock.
pub fn snapshotGames(buf: []GameInfo) usize {
    // Shared mode: games live in the store (redis/pg), not the in-memory table — enumerate
    // them there and convert to GameInfo.
    if (shared) {
        var tmp: [256]store.NamedGame = undefined;
        const cap = @min(buf.len, tmp.len);
        const m = store.snapshotGames(tmp[0..cap]);
        for (tmp[0..m], 0..) |ng, i| {
            var gi = GameInfo{ .gameid = ng.gameid, .gsid = ng.gsid, .ip = ng.gs_ip, .port = ng.gs_port, .players = ng.players, .status = ng.status };
            const ln: u8 = @intCast(@min(ng.name_len, max_name));
            @memcpy(gi.name[0..ln], ng.name[0..ln]);
            gi.name_len = ln;
            const dn: u8 = @intCast(@min(ng.desc_len, gi.description.len));
            @memcpy(gi.description[0..dn], ng.description[0..dn]);
            gi.desc_len = dn;
            buf[i] = gi;
        }
        return m;
    }
    global.lock.lock();
    defer global.lock.unlock();
    var n: usize = 0;
    for (&global.games) |*g| {
        if (n >= buf.len) break;
        if (!g.in_use) continue;
        var gi = GameInfo{ .gameid = g.gameid, .gsid = g.gsid, .ip = g.gs_ip, .port = g.gs_port, .players = g.players, .status = g.status, .name_len = g.name_len, .desc_len = g.desc_len };
        @memcpy(gi.name[0..g.name_len], g.name[0..g.name_len]);
        @memcpy(gi.description[0..g.desc_len], g.description[0..g.desc_len]);
        buf[n] = gi;
        n += 1;
    }
    return n;
}
