//! Persistence — the domain's storage vocabulary, in D2 ubiquitous language. Callers
//! say `getCharD2s` / `registerGame` / `mintSession`-side `putSession`; *which* backend
//! serves them (filesystem, Redis, Postgres) is an internal detail, chosen once at
//! startup. There is no Store/Repository adapter object threaded through callers — each
//! domain op is a thin `switch (backend)` over the concrete backends. Add a backend by
//! adding a branch, not by rewiring the call sites.
//!
//! Two independent backends so Postgres and Redis are co-equal: `durable` (character
//! saves — the store of record) and `ephemeral` (sessions + games — short-lived, TTL'd).
//! The common production split is durable=pg, ephemeral=redis. BNFTP assets are static
//! files and always come from the filesystem.
const std = @import("std");
const d2s = @import("d2s.zig");
const adapter = @import("realm_store");
const fs = adapter.fs;
const redis = adapter.redis;
const pg = adapter.pg;
const types = @import("realm_infra").types;

pub const Name = types.Name;
pub const GameRec = types.GameRec;
pub const Route = types.Route;
pub const TokenRoute = types.TokenRoute;
pub const max_chars = types.max_chars;

pub const Backend = enum { fs, redis, pg };

var durable: Backend = .fs; // character saves
var ephemeral: Backend = .fs; // sessions + games

// TTLs (seconds) for ephemeral records; 0 = no expiry. Games also get torn down
// explicitly on CLOSEGAME / GS disconnect — the TTL is a backstop against leaks.
var session_ttl_s: u32 = 3600; // 1h
var game_ttl_s: u32 = 21600; // 6h

pub const Config = struct {
    io: std.Io,
    data_dir: []const u8,
    durable: Backend = .fs,
    ephemeral: Backend = .fs,
    redis_addr: []const u8 = "",
    pg_dsn: []const u8 = "",
    session_ttl_s: u32 = 3600,
    game_ttl_s: u32 = 21600,
};

pub fn init(cfg: Config) void {
    durable = cfg.durable;
    ephemeral = cfg.ephemeral;
    session_ttl_s = cfg.session_ttl_s;
    game_ttl_s = cfg.game_ttl_s;
    // fs is always initialised: it serves BNFTP and is the default/fallback.
    fs.init(cfg.io, cfg.data_dir);
    if (cfg.durable == .redis or cfg.ephemeral == .redis) redis.init(cfg.redis_addr);
    if (cfg.durable == .pg or cfg.ephemeral == .pg) pg.init(cfg.pg_dsn);
}

// ── characters (durable) ─────────────────────────────────────────────────────

pub fn getCharD2s(account: []const u8, charname: []const u8, out: []u8) usize {
    return switch (durable) {
        .fs => fs.getCharD2s(account, charname, out),
        .redis => redis.getCharD2s(account, charname, out),
        .pg => pg.getCharD2s(account, charname, out),
    };
}

pub fn saveCharD2s(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    return switch (durable) {
        .fs => fs.saveCharD2s(account, charname, bytes),
        .redis => redis.saveCharD2s(account, charname, bytes),
        .pg => pg.saveCharD2s(account, charname, bytes),
    };
}

pub fn listChars(account: []const u8, names: []Name) usize {
    return switch (durable) {
        .fs => fs.listChars(account, names),
        .redis => redis.listChars(account, names),
        .pg => pg.listChars(account, names),
    };
}

/// Delete a character's save. Idempotent — true even if it was already gone.
pub fn deleteCharD2s(account: []const u8, charname: []const u8) bool {
    return switch (durable) {
        .fs => fs.deleteCharD2s(account, charname),
        .redis => redis.deleteCharD2s(account, charname),
        .pg => pg.deleteCharD2s(account, charname),
    };
}

// ── per-account userdata (BNCS profile: SID_READ/WRITEUSERDATA 0x26/0x27) ─────
// Key-path addressed ("profile\\sex"), durable and low-volume → always fs (same
// policy as accounts; redis/pg don't carry a parallel schema for it).
pub fn getUserData(account: []const u8, key: []const u8, out: []u8) usize {
    return fs.getUserData(account, key, out);
}
pub fn setUserData(account: []const u8, key: []const u8, value: []const u8) bool {
    return fs.setUserData(account, key, value);
}

/// Largest .d2s we will clone. A real 1.14d save is a few KB (a full char with stash is
/// well under this); refusing larger avoids a silently-truncated, corrupt copy.
const max_d2s = 32 * 1024;

/// Clone a character to a new name (and optionally a different account): read the source
/// save, rewrite its embedded name + checksum, and persist it at the destination. Works on
/// every backend (it goes through get/saveCharD2s). Returns false if the source is missing,
/// the name is invalid, the save is implausibly large, or the destination already exists.
pub fn copyChar(src_account: []const u8, src_char: []const u8, dst_account: []const u8, dst_char: []const u8) bool {
    if (dst_char.len == 0 or dst_char.len > d2s.name_max) return false;
    var buf: [max_d2s]u8 = undefined;
    const n = getCharD2s(src_account, src_char, &buf);
    if (n == 0 or n == buf.len) return false; // missing, or too large (likely truncated)
    // Don't clobber an existing destination char.
    var probe: [16]u8 = undefined;
    if (getCharD2s(dst_account, dst_char, &probe) != 0) return false;
    if (!d2s.setName(buf[0..n], dst_char)) return false;
    d2s.fixChecksum(buf[0..n]);
    return saveCharD2s(dst_account, dst_char, buf[0..n]);
}

/// Result of a classic -> expansion conversion.
pub const UpgradeResult = enum { upgraded, already_expansion, no_such_char, failed };

/// Convert a character to Lord of Destruction by setting the expansion bit in its .d2s
/// status byte and repairing the checksum. That bit is the whole conversion as far as a
/// save file is concerned — everything else an expansion character gains, the game
/// materializes on load, the same way a freshly created character grows from a bare
/// 335-byte header on first play.
///
/// Already-expansion characters report that rather than failing: the client's only test
/// is result == 0, so re-running it must not look like an error.
pub fn upgradeCharToExpansion(account: []const u8, charname: []const u8) UpgradeResult {
    var buf: [max_d2s]u8 = undefined;
    const n = getCharD2s(account, charname, &buf);
    if (n == 0) return .no_such_char;
    if (n == buf.len) return .failed; // implausibly large, likely truncated
    const st = d2s.status(buf[0..n]) orelse return .failed;
    if (st & d2s.status_expansion != 0) return .already_expansion;
    d2s.setStatus(buf[0..n], st | d2s.status_expansion);
    d2s.fixChecksum(buf[0..n]);
    return if (saveCharD2s(account, charname, buf[0..n])) .upgraded else .failed;
}

// ── accounts (durable) ───────────────────────────────────────────────────────

/// Create an account. `pwhash` null = password-less. Returns false if it exists.
pub fn createAccount(name: []const u8, pwhash: ?[20]u8) bool {
    return switch (durable) {
        .fs => fs.createAccount(name, pwhash),
        .redis => redis.createAccount(name, pwhash),
        .pg => pg.createAccount(name, pwhash),
    };
}

pub fn accountExists(name: []const u8) bool {
    return switch (durable) {
        .fs => fs.accountExists(name),
        .redis => redis.accountExists(name),
        .pg => pg.accountExists(name),
    };
}

/// Whether the account has a password (filling `out` when true), null if no such
/// account.
pub fn accountPwHash(name: []const u8, out: *[20]u8) ?bool {
    return switch (durable) {
        .fs => fs.accountPwHash(name, out),
        .redis => redis.accountPwHash(name, out),
        .pg => pg.accountPwHash(name, out),
    };
}

/// Set an account's password hash (single xSHA-1 of the new password). Durable,
/// low-volume → always fs (same policy as account creation). False if no account.
pub fn setAccountPassword(name: []const u8, hash: [20]u8) bool {
    return fs.setAccountPassword(name, hash);
}

/// List account names for the admin API. Accounts live on the filesystem for all
/// backends (redis/pg route createAccount → fs), so this always reads fs.
pub fn listAccounts(names: [][32]u8) usize {
    return fs.listAccounts(names);
}

/// Set/clear an account's admin flag (web-UI access). Accounts are always fs-backed.
pub fn setAdmin(name: []const u8, admin: bool) bool {
    return fs.setAdmin(name, admin);
}

/// Whether an account is flagged admin in the store.
pub fn accountIsAdmin(name: []const u8) bool {
    return fs.accountIsAdmin(name);
}

/// BNFTP assets (version-check MPQ etc.) are static files — always filesystem.
pub fn getBnftp(filename: []const u8, out: []u8) ?[]const u8 {
    return fs.getBnftp(filename, out);
}

/// Last-modified time of a BNFTP asset (unix seconds), or null if we don't have it.
pub fn bnftpMtime(filename: []const u8) ?i64 {
    return fs.bnftpMtime(filename);
}

// ── guilds (durable) ─────────────────────────────────────────────────────────
// The cut Guild Halls feature. Like accounts, guilds are always fs-backed (low
// volume, durable); the service layer (server/guilds.zig) owns the blob format.

pub fn saveGuild(name: []const u8, bytes: []const u8) bool {
    return fs.saveGuild(name, bytes);
}

pub fn getGuild(name: []const u8, out: []u8) usize {
    return fs.getGuild(name, out);
}

pub fn deleteGuild(name: []const u8) bool {
    return fs.deleteGuild(name);
}

pub fn listGuilds(names: []Name) usize {
    return fs.listGuilds(names);
}

// ── sessions (ephemeral) ─────────────────────────────────────────────────────

pub fn saveSession(id: u64, account: []const u8) bool {
    return switch (ephemeral) {
        .fs => fs.saveSession(id, account, session_ttl_s),
        .redis => redis.saveSession(id, account, session_ttl_s),
        .pg => pg.saveSession(id, account, session_ttl_s),
    };
}

pub fn accountForSession(id: u64, out: []u8) ?[]const u8 {
    return switch (ephemeral) {
        .fs => fs.accountForSession(id, out),
        .redis => redis.accountForSession(id, out),
        .pg => pg.accountForSession(id, out),
    };
}

pub fn expireSession(id: u64) void {
    switch (ephemeral) {
        .fs => fs.expireSession(id),
        .redis => redis.expireSession(id),
        .pg => pg.expireSession(id),
    }
}

// ── games (ephemeral) ────────────────────────────────────────────────────────

pub fn registerGame(name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32, players: u16, status: u8, difficulty: u8, password: []const u8, description: []const u8) bool {
    return switch (ephemeral) {
        .fs => fs.registerGame(name, gameid, gs_ip, gs_port, gsid, players, status, difficulty, password, description, game_ttl_s),
        .redis => redis.registerGame(name, gameid, gs_ip, gs_port, gsid, players, status, difficulty, password, description, game_ttl_s),
        .pg => pg.registerGame(name, gameid, gs_ip, gs_port, gsid, players, status, difficulty, password, description, game_ttl_s),
    };
}

/// Overwrite a hosted game's player count (UPDATEGAMEINFO from the GS that hosts it).
/// False if no live game carries that id.
pub fn setGamePlayers(gameid: u32, players: u16) bool {
    return switch (ephemeral) {
        .fs => fs.setGamePlayers(gameid, players),
        .redis => redis.setGamePlayers(gameid, players),
        .pg => pg.setGamePlayers(gameid, players),
    };
}

pub fn findGame(name: []const u8) ?GameRec {
    return switch (ephemeral) {
        .fs => fs.findGame(name),
        .redis => redis.findGame(name),
        .pg => pg.findGame(name),
    };
}

pub fn removeGameById(gameid: u32) void {
    switch (ephemeral) {
        .fs => fs.removeGameById(gameid),
        .redis => redis.removeGameById(gameid),
        .pg => pg.removeGameById(gameid),
    }
}

pub fn expireGamesByGs(gsid: u32) void {
    switch (ephemeral) {
        .fs => fs.expireGamesByGs(gsid),
        .redis => redis.expireGamesByGs(gsid),
        .pg => pg.expireGamesByGs(gsid),
    }
}

pub const NamedGame = types.NamedGame;

/// Enumerate active games from the shared store (for /admin/games when shared). Each
/// backend walks its own game index: fs the games dir, redis the `games` set, pg the
/// games table — all filtering on TTL/expiry.
pub fn snapshotGames(out: []types.NamedGame) usize {
    return switch (ephemeral) {
        .fs => fs.snapshotGames(out),
        .redis => redis.snapshotGames(out),
        .pg => pg.snapshotGames(out),
    };
}

// ── routes (ephemeral) ───────────────────────────────────────────────────────
// {client source IP → backend GS addr}, recorded by realmd on JOINGAME and looked
// up by the d2ingress per connection to splice game traffic to the right GS.

pub fn recordRoute(client_ip: [4]u8, gs_ip: [4]u8, gs_port: u16, ttl_s: u32) bool {
    return switch (ephemeral) {
        .fs => fs.recordRoute(client_ip, gs_ip, gs_port, ttl_s),
        .redis => redis.recordRoute(client_ip, gs_ip, gs_port, ttl_s),
        .pg => pg.recordRoute(client_ip, gs_ip, gs_port, ttl_s),
    };
}

pub fn lookupRoute(client_ip: [4]u8) ?Route {
    return switch (ephemeral) {
        .fs => fs.lookupRoute(client_ip),
        .redis => redis.lookupRoute(client_ip),
        .pg => pg.lookupRoute(client_ip),
    };
}

// ── token routes (ephemeral) ─────────────────────────────────────────────────
// {realm-global token → backend GS addr + engine gameid}, recorded by realmd on
// CREATE/JOIN and looked up by the d2ingress from the token in the client's first
// GAMELOGON packet. NAT-proof: the token is unique across the realm so two clients
// behind one public IP never collide (unlike the source-IP route map above).

/// Process-local fallback counter for the backends that cannot mint across instances.
var local_token_ctr = std.atomic.Value(u16).init(1);

/// Next game token, unique across the whole realm.
///
/// Only redis can promise that: the token identifies a route the gateway will resolve, so two
/// instances handing out the same number splices the second client into the first one's game.
/// INCR is atomic across instances; the fs and pg paths fall back to a process-local counter and
/// are therefore single-instance only.
pub fn mintToken() u16 {
    if (ephemeral == .redis) {
        if (redis.mintToken()) |t| return t;
    }
    // Wrap at u16, skipping 0 — the engine and the game list both read 0 as "no game".
    const n = local_token_ctr.fetchAdd(1, .monotonic);
    return if (n == 0) 1 else n;
}

pub fn recordTokenRoute(token: u16, gs_ip: [4]u8, gs_port: u16, real_gameid: u32, ttl_s: u32) bool {
    return switch (ephemeral) {
        .fs => fs.recordTokenRoute(token, gs_ip, gs_port, real_gameid, ttl_s),
        .redis => redis.recordTokenRoute(token, gs_ip, gs_port, real_gameid, ttl_s),
        .pg => pg.recordTokenRoute(token, gs_ip, gs_port, real_gameid, ttl_s),
    };
}

pub fn lookupTokenRoute(token: u16) ?TokenRoute {
    return switch (ephemeral) {
        .fs => fs.lookupTokenRoute(token),
        .redis => redis.lookupTokenRoute(token),
        .pg => pg.lookupTokenRoute(token),
    };
}

// ── health ───────────────────────────────────────────────────────────────────

fn backendHealthy(b: Backend) bool {
    return switch (b) {
        .fs => fs.healthy(),
        .redis => redis.healthy(),
        .pg => pg.healthy(),
    };
}

/// Ready only if every backend actually in use is reachable.
pub fn healthy() bool {
    return backendHealthy(durable) and backendHealthy(ephemeral);
}
