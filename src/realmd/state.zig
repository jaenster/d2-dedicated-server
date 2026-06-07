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
const Spinlock = @import("lock.zig").Spinlock;
const store = @import("store.zig");

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

pub const Game = struct {
    name: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    name_len: u8 = 0,
    gameid: u32 = 0, // engine server token (= the token the client passes to the GS)
    gs_ip: [4]u8 = .{ 0, 0, 0, 0 }, // d2gs address the client connects to (:4000)
    in_use: bool = false,

    pub fn name_slice(g: *const Game) []const u8 {
        return g.name[0..g.name_len];
    }
};

pub const State = struct {
    lock: Spinlock = .{},
    sessions: [1024]Session = [_]Session{.{}} ** 1024,
    next_id: u64 = 1,
    games: [512]Game = [_]Game{.{}} ** 512,

    /// Mint a session for `account`, returning its id (0 on failure).
    pub fn createSession(st: *State, account: []const u8) u64 {
        if (shared) {
            const id = (@as(u64, instance_hash) << 32) | shared_ctr.fetchAdd(1, .monotonic);
            return if (store.putSession(id, account)) id else 0;
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
    pub fn accountFor(st: *State, id: u64, out: []u8) ?[]const u8 {
        if (shared) return store.getSession(id, out);
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

    /// Register (or replace, by name) a hosted game. Returns false if full.
    pub fn addGame(st: *State, name: []const u8, gameid: u32, gs_ip: [4]u8) bool {
        if (shared) return store.putGame(name, gameid, gs_ip);
        st.lock.lock();
        defer st.lock.unlock();
        var slot: ?*Game = null;
        for (&st.games) |*g| {
            if (g.in_use and std.mem.eql(u8, g.name_slice(), name)) {
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
        g.in_use = true;
        return true;
    }

    /// Look up a game by name; copies the record out under lock.
    pub fn findGame(st: *State, name: []const u8) ?Game {
        if (shared) {
            const rec = store.getGame(name) orelse return null;
            var g = Game{ .gameid = rec.gameid, .gs_ip = rec.gs_ip, .in_use = true };
            const n: u8 = @intCast(@min(name.len, max_name));
            @memcpy(g.name[0..n], name[0..n]);
            g.name_len = n;
            return g;
        }
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and std.mem.eql(u8, g.name_slice(), name)) return g.*;
        }
        return null;
    }

    /// Remove a game by engine gameid (called on CLOSEGAME). In shared mode we
    /// look it up by name; the gameid path only applies to the in-memory table.
    pub fn removeGameById(st: *State, gameid: u32) void {
        if (shared) return; // games expire from the shared store; id->name reverse index TODO
        st.lock.lock();
        defer st.lock.unlock();
        for (&st.games) |*g| {
            if (g.in_use and g.gameid == gameid) g.in_use = false;
        }
    }
};

pub var global: State = .{};
