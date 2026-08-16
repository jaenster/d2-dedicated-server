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

/// True when redis is a CACHE in front of a different durable store, rather than being the
/// durable store itself. With durable=redis there is nothing to cache and nothing to flush.
fn cachingChars() bool {
    return ephemeral == .redis and durable != .redis;
}

/// Read the live character. Redis first, because that is where a game's most recent save lands
/// and Postgres may still be a flush behind it — reading Postgres first would hand back a stale
/// character and undo the player's last session.
pub fn getCharD2s(account: []const u8, charname: []const u8, out: []u8) usize {
    if (cachingChars()) {
        const cached = redis.getCharD2s(account, charname, out);
        if (cached != 0) return cached;
    }
    const n = switch (durable) {
        .fs => fs.getCharD2s(account, charname, out),
        .redis => redis.getCharD2s(account, charname, out),
        .pg => pg.getCharD2s(account, charname, out),
    };
    // Populate the cache, but do NOT mark it dirty: these bytes came FROM the durable store, so
    // flushing them back would be a write for no reason.
    //
    // `n == out.len` means the read exactly filled the caller's buffer, which cannot be told apart
    // from a save too big for it. Caching that would store a TRUNCATED character and then serve it
    // in preference to the intact one on disk — a silent corruption that survives every later read.
    //
    // Written only if the cache is still empty. An unconditional write here could put these
    // durable bytes OVER a newer save that landed while we were reading — losing whatever the
    // player did in between — and with several instances a shared miss makes that ordinary. The
    // conditional write is also why loading needs no lock: everyone who missed may read, one
    // wins, the rest discard.
    if (n != 0 and n != out.len and cachingChars()) _ = redis.cacheCharIfAbsent(account, charname, out[0..n]);
    return n;
}

/// Write the live character. Redis takes it and the character is marked dirty; the flush worker
/// moves it to the store of record. The save is acknowledged once redis has it, so a game's save
/// never waits on Postgres — which is the point of the cache, and why the dirty set has to be
/// crash-safe.
pub fn saveCharD2s(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    if (cachingChars()) {
        if (!redis.saveCharD2s(account, charname, bytes)) return false;
        // A save redis accepted but that never got marked would sit there looking clean while
        // Postgres stayed behind, so a failed mark has to fail the save.
        return markCharDirty(account, charname) != null;
    }
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

/// Move one character from the cache to the store of record.
///
/// Reads the CURRENT bytes rather than anything handed in, which is what makes a flush idempotent
/// and order-independent: two workers doing this at once both write the newest save.
pub fn flushCharToDurable(account: []const u8, charname: []const u8) bool {
    if (!cachingChars()) return true; // nothing behind the cache to fall behind
    var buf: [max_d2s]u8 = undefined;
    const n = redis.getCharD2s(account, charname, &buf);
    if (n == 0) return false;
    if (n == buf.len) return false; // implausibly large, likely truncated — do not persist it
    return switch (durable) {
        .fs => fs.saveCharD2s(account, charname, buf[0..n]),
        .redis => true,
        .pg => pg.saveCharD2s(account, charname, buf[0..n]),
    };
}

// ── save durability ──────────────────────────────────────────────────────────
//
// Redis is the mem-cache holding the live character; Postgres is the store of record. A save is
// marked dirty when redis has bytes Postgres has not seen, and the flush worker (any instance)
// walks that set. The mark carries a VERSION, which is what makes the flush safe: the flag is
// only cleared if no newer save landed while the flush was in flight.
//
// Redis-only for the same reason as the char lock — one instance's idea of "dirty" is not a
// durability mechanism. On fs/pg the durable backend is written directly, so nothing is pending.

pub fn markCharDirty(account: []const u8, charname: []const u8) ?u64 {
    return switch (ephemeral) {
        .redis => redis.markCharDirty(account, charname),
        .fs, .pg => null,
    };
}

pub fn dirtyChars(out: [][]u8, lens: []usize) usize {
    return switch (ephemeral) {
        .redis => redis.dirtyChars(out, lens),
        .fs, .pg => 0,
    };
}

pub fn charVersion(account: []const u8, charname: []const u8) u64 {
    return switch (ephemeral) {
        .redis => redis.charVersion(account, charname),
        .fs, .pg => 0,
    };
}

pub fn clearDirtyIfUnchanged(account: []const u8, charname: []const u8, ver: u64) bool {
    return switch (ephemeral) {
        .redis => redis.clearDirtyIfUnchanged(account, charname, ver),
        .fs, .pg => true,
    };
}

// ── character ownership ──────────────────────────────────────────────────────
//
// A character belongs to one game at a time, and the lock records WHICH — so a second login can
// be refused with a reason rather than issued and then silently dropped by the game server.
//
// Redis only, and that is not a limitation to route around: a lock that is not shared does not
// enforce anything across instances. On fs/pg `lockChar` reports success so a single instance
// behaves exactly as it did before this existed.

/// How long a character stays claimed without a refresh. Long enough to outlive a slow join,
/// short enough that a game server lost mid-session frees its characters within a game's length.
pub const char_lock_ttl_s: u32 = 300;

pub fn lockChar(account: []const u8, charname: []const u8, owner: []const u8) bool {
    return switch (ephemeral) {
        .redis => redis.lockChar(account, charname, owner, char_lock_ttl_s),
        .fs, .pg => true,
    };
}

pub fn refreshCharLock(account: []const u8, charname: []const u8, owner: []const u8) bool {
    return switch (ephemeral) {
        .redis => redis.refreshCharLock(account, charname, owner, char_lock_ttl_s),
        .fs, .pg => true,
    };
}

pub fn unlockChar(account: []const u8, charname: []const u8, owner: []const u8) bool {
    return switch (ephemeral) {
        .redis => redis.unlockChar(account, charname, owner),
        .fs, .pg => true,
    };
}

/// How long an unfinished create may hold a name. A backstop for a create that dies in flight,
/// comfortably longer than the server's own reply timeout.
pub const game_name_ttl_s: u32 = 30;

/// Claim a game name before dispatching the create, so two clients racing on one name resolve
/// here — where the loser can still be told — instead of at the game server, after which it has
/// nothing to join.
pub fn reserveGameName(name: []const u8) bool {
    return switch (ephemeral) {
        .redis => redis.reserveGameName(name, game_name_ttl_s),
        // One instance already serialises creates through its own game table.
        .fs, .pg => true,
    };
}

/// Whether a create is holding this name right now.
pub fn gameNameReserved(name: []const u8) bool {
    return switch (ephemeral) {
        .redis => redis.gameNameReserved(name),
        .fs, .pg => false,
    };
}

pub fn releaseGameName(name: []const u8) void {
    switch (ephemeral) {
        .redis => redis.releaseGameName(name),
        .fs, .pg => {},
    }
}

/// The owner id a game uses for the characters it holds. Stable across instances, because any
/// realmd may be the one that closes the game.
pub fn gameOwnerId(buf: []u8, gameid: u32) []const u8 {
    return std.fmt.bufPrint(buf, "game:{d}", .{gameid}) catch buf[0..0];
}

pub fn addGameChar(gameid: u32, account: []const u8, charname: []const u8) bool {
    return switch (ephemeral) {
        .redis => redis.addGameChar(gameid, account, charname),
        .fs, .pg => true,
    };
}

pub fn releaseGameChars(gameid: u32) usize {
    var ob: [32]u8 = undefined;
    const owner = gameOwnerId(&ob, gameid);
    return switch (ephemeral) {
        .redis => redis.releaseGameChars(gameid, owner),
        .fs, .pg => 0,
    };
}

pub fn releaseGameCharByName(gameid: u32, charname: []const u8) bool {
    var ob: [32]u8 = undefined;
    const owner = gameOwnerId(&ob, gameid);
    return switch (ephemeral) {
        .redis => redis.releaseGameCharByName(gameid, charname, owner),
        .fs, .pg => true,
    };
}

/// Which game holds this character, or null if it is free.
pub fn charLockOwner(account: []const u8, charname: []const u8, out: []u8) ?[]const u8 {
    return switch (ephemeral) {
        .redis => redis.charLockOwner(account, charname, out),
        .fs, .pg => null,
    };
}

// ── the game-server fleet (ephemeral, shared) ────────────────────────────────
//
// Only redis carries this: the point of publishing the fleet is that an instance which does NOT
// hold a server's control connection can still see it. fs and pg have no cross-instance story, so
// they report an empty fleet and every caller falls back to its own in-process registry — which is
// exactly right for a single instance, and is what those backends already imply.

pub const GsRec = types.GsRec;

/// How long a published game server survives without a refresh. Comfortably longer than the
/// control link's own liveness traffic, so a healthy server never blinks out, and short enough
/// that one lost with its realmd disappears within a game's lifetime.
pub const gs_ttl_s: u32 = 90;

pub fn registerGs(rec: GsRec) bool {
    return switch (ephemeral) {
        .redis => redis.registerGs(rec, gs_ttl_s),
        .fs, .pg => false,
    };
}

pub fn removeGs(gsid: u32) void {
    switch (ephemeral) {
        .redis => redis.removeGs(gsid),
        .fs, .pg => {},
    }
}

/// The fleet as the whole realm sees it. 0 means "nothing shared" — not "no servers".
pub fn snapshotGs(out: []GsRec) usize {
    return switch (ephemeral) {
        .redis => redis.snapshotGs(out),
        .fs, .pg => 0,
    };
}

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
