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
const fs = @import("persist_fs.zig");
const redis = @import("persist_redis.zig");
const pg = @import("persist_pg.zig");
const types = @import("store_types.zig");

pub const Name = types.Name;
pub const GameRec = types.GameRec;
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

/// BNFTP assets (version-check MPQ etc.) are static files — always filesystem.
pub fn getBnftp(filename: []const u8, out: []u8) ?[]const u8 {
    return fs.getBnftp(filename, out);
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

pub fn registerGame(name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32) bool {
    return switch (ephemeral) {
        .fs => fs.registerGame(name, gameid, gs_ip, gs_port, gsid, game_ttl_s),
        .redis => redis.registerGame(name, gameid, gs_ip, gs_port, gsid, game_ttl_s),
        .pg => pg.registerGame(name, gameid, gs_ip, gs_port, gsid, game_ttl_s),
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
