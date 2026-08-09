//! Postgres persistence backend — the durable store of record. Uses the vendored
//! pure-Zig `pg.zig` client (no libpq, so the static-musl scratch image is preserved).
//!
//! One concrete backend behind the store.zig facade (no adapter object): the facade
//! switches to these functions when durable/ephemeral = .pg. Schema:
//!   chars(account text, name text, d2s bytea, primary key(account,name))
//!   sessions(id bigint primary key, account text, expires_at timestamptz)
//!   games(name text primary key, gameid bigint, ip bigint, port int, gsid bigint,
//!         expires_at timestamptz)
//! Expiry is enforced with `expires_at` predicates on read (and an opportunistic
//! best-effort sweep). TTL math is done in SQL (now() + interval) so this module
//! needs no wall clock — convenient under 0.16 where the usual clock/sleep helpers
//! are unavailable.
//!
//! Concurrency: the pg.zig Pool is internally threadsafe, so per-call we just use
//! the pool's exec/query/row wrappers (which acquire+release a connection). The
//! *one-time* lazy pool creation + schema DDL is guarded by a spinlock. The pool
//! owns its own std.Io (a process-global Threaded) so it can drive blocking socket
//! IO from realmd's thread-per-peer workers.
const std = @import("std");
const pg = @import("pg");
const Spinlock = @import("realm_infra").lock.Spinlock;
const types = @import("realm_infra").types;
const fs = @import("fs.zig");

const Name = types.Name;
const GameRec = types.GameRec;
const Route = types.Route;
const TokenRoute = types.TokenRoute;

// Routes are tiny, high-churn and source-IP keyed — route them to the always-present
// filesystem backend (with its TTL) rather than carry a parallel SQL table.
pub fn recordRoute(client_ip: [4]u8, gs_ip: [4]u8, gs_port: u16, ttl_s: u32) bool {
    return fs.recordRoute(client_ip, gs_ip, gs_port, ttl_s);
}
pub fn lookupRoute(client_ip: [4]u8) ?Route {
    return fs.lookupRoute(client_ip);
}

// Token routes are likewise tiny and high-churn — delegate to the fs backend.
pub fn recordTokenRoute(token: u16, gs_ip: [4]u8, gs_port: u16, real_gameid: u32, ttl_s: u32) bool {
    return fs.recordTokenRoute(token, gs_ip, gs_port, real_gameid, ttl_s);
}
pub fn lookupTokenRoute(token: u16) ?TokenRoute {
    return fs.lookupTokenRoute(token);
}

// Accounts are durable, low-volume and simple — route them to the always-present
// filesystem backend rather than carry a parallel SQL schema.
pub fn createAccount(name: []const u8, pwhash: ?[20]u8) bool {
    return fs.createAccount(name, pwhash);
}
pub fn accountExists(name: []const u8) bool {
    return fs.accountExists(name);
}
pub fn accountPwHash(name: []const u8, out: *[20]u8) ?bool {
    return fs.accountPwHash(name, out);
}

// ── lazy global pool ─────────────────────────────────────────────────────────

var dsn: []const u8 = "";
var pool: ?*pg.Pool = null;
var schema_ready: bool = false;
var init_lock: Spinlock = .{};
// Owned by this module; the pool keeps a pointer to its `io()`.
var threaded: std.Io.Threaded = undefined;
var threaded_set: bool = false;

pub fn init(dsn_: []const u8) void {
    dsn = dsn_;
}

/// Ensure the global pool exists and the schema DDL has run, exactly once. Returns
/// the pool on success, null on any failure (so callers degrade to a no-op). Cheap
/// fast-path: once both are set we return without taking the lock.
fn ensurePool() ?*pg.Pool {
    if (pool != null and schema_ready) return pool;
    init_lock.lock();
    defer init_lock.unlock();

    if (pool == null) {
        if (dsn.len == 0) return null;
        if (!threaded_set) {
            // c_allocator is threadsafe — required because the pool's io may spawn
            // worker threads for blocking IO across realmd's per-peer threads.
            threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
            threaded_set = true;
        }
        const uri = std.Uri.parse(dsn) catch return null;
        const p = pg.Pool.initUri(threaded.io(), std.heap.c_allocator, uri, .{
            .size = 4,
            .timeout = 10_000,
        }) catch return null;
        pool = p;
    }

    const p = pool.?;
    if (!schema_ready) {
        createSchema(p) catch return null;
        schema_ready = true;
    }
    return p;
}

fn createSchema(p: *pg.Pool) !void {
    _ = try p.exec(
        \\create table if not exists chars(
        \\  account text not null,
        \\  name text not null,
        \\  d2s bytea not null,
        \\  primary key(account, name)
        \\)
    , .{});
    _ = try p.exec(
        \\create table if not exists sessions(
        \\  id bigint primary key,
        \\  account text not null,
        \\  expires_at timestamptz
        \\)
    , .{});
    _ = try p.exec(
        \\create table if not exists games(
        \\  name text primary key,
        \\  gameid bigint not null,
        \\  ip bigint not null,
        \\  port int not null,
        \\  gsid bigint not null,
        \\  expires_at timestamptz
        \\)
    , .{});
    // join password, player count + description (added separately so an existing table
    // migrates in place).
    _ = try p.exec("alter table games add column if not exists password text not null default ''", .{});
    _ = try p.exec("alter table games add column if not exists players int not null default 0", .{});
    _ = try p.exec("alter table games add column if not exists description text not null default ''", .{});
    _ = try p.exec("alter table games add column if not exists status int not null default 0", .{});
    _ = try p.exec("alter table games add column if not exists difficulty int not null default 0", .{});
    _ = try p.exec("create index if not exists games_gameid_idx on games(gameid)", .{});
    _ = try p.exec("create index if not exists games_gsid_idx on games(gsid)", .{});
}

// ── name sanitising (matches persist_fs.sanitize) ────────────────────────────

fn sanitize(name: []const u8, out: []u8) ?[]const u8 {
    if (name.len == 0 or name.len >= out.len) return null;
    for (name, 0..) |c, i| {
        const okc = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!okc) return null;
        out[i] = c;
    }
    return out[0..name.len];
}

/// A game name reduced to the key it is stored under.
///
/// LOWERCASED, and that is the point. Battle.net treats game names case-insensitively — "Jan" and
/// "jan" are the same game to a player typing one into the join box — but a key that preserves
/// case makes them two rows. The failure that produces is genuinely baffling from the outside:
/// CREATEGAME matches one record and answers "a game already exists with that name", while
/// JOINGAME matches the other and routes to a game that is not the one on screen, so the client
/// says "game name and password don't match" about a game it can see in the list.
fn gameKey(name: []const u8, out: []u8) ?[]const u8 {
    const safe = sanitize(name, out) orelse return null;
    for (out[0..safe.len]) |*c| c.* = std.ascii.toLower(c.*);
    return out[0..safe.len];
}

// ── ip <-> bigint helpers ────────────────────────────────────────────────────

fn ipToInt(ip: [4]u8) i64 {
    return (@as(i64, ip[0]) << 24) | (@as(i64, ip[1]) << 16) |
        (@as(i64, ip[2]) << 8) | @as(i64, ip[3]);
}

fn intToIp(v: i64) [4]u8 {
    const u: u32 = @truncate(@as(u64, @bitCast(v)));
    return .{
        @intCast((u >> 24) & 0xff),
        @intCast((u >> 16) & 0xff),
        @intCast((u >> 8) & 0xff),
        @intCast(u & 0xff),
    };
}

// ── characters (durable) ─────────────────────────────────────────────────────

pub fn saveCharD2s(account: []const u8, charname: []const u8, bytes: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into chars(account, name, d2s) values ($1, $2, $3)
        \\on conflict (account, name) do update set d2s = excluded.d2s
    , .{ a, c, bytes }) catch return false;
    return true;
}

pub fn getCharD2s(account: []const u8, charname: []const u8, out: []u8) usize {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const c = sanitize(charname, &cb) orelse return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row("select d2s from chars where account = $1 and name = $2", .{ a, c }) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const d2s = row.get([]const u8, 0) catch return 0;
    const n = @min(d2s.len, out.len);
    @memcpy(out[0..n], d2s[0..n]);
    return n;
}

pub fn deleteCharD2s(account: []const u8, charname: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec("delete from chars where account = $1 and name = $2", .{ a, c }) catch return false;
    return true;
}

pub fn listChars(account: []const u8, names: []Name) usize {
    var ab: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const p = ensurePool() orelse return 0;
    var result = p.query("select name from chars where account = $1", .{a}) catch return 0;
    defer result.deinit();
    var count: usize = 0;
    while (result.next() catch null) |row| {
        if (count >= names.len) continue; // drain the rest
        const nm = row.get([]const u8, 0) catch continue;
        if (nm.len == 0 or nm.len > names[count].buf.len) continue;
        @memcpy(names[count].buf[0..nm.len], nm);
        names[count].len = @intCast(nm.len);
        count += 1;
    }
    return count;
}

// ── sessions (ephemeral, TTL) ────────────────────────────────────────────────

pub fn saveSession(id: u64, account: []const u8, ttl_s: u32) bool {
    const p = ensurePool() orelse return false;
    const sid: i64 = @bitCast(id);
    if (ttl_s > 0) {
        _ = p.exec(
            \\insert into sessions(id, account, expires_at)
            \\values ($1, $2, now() + make_interval(secs => $3))
            \\on conflict (id) do update set account = excluded.account, expires_at = excluded.expires_at
        , .{ sid, account, @as(f64, @floatFromInt(ttl_s)) }) catch return false;
    } else {
        _ = p.exec(
            \\insert into sessions(id, account, expires_at)
            \\values ($1, $2, null)
            \\on conflict (id) do update set account = excluded.account, expires_at = null
        , .{ sid, account }) catch return false;
    }
    return true;
}

pub fn accountForSession(id: u64, out: []u8) ?[]const u8 {
    const p = ensurePool() orelse return null;
    sweepSessions(p);
    const sid: i64 = @bitCast(id);
    var row = (p.row(
        "select account from sessions where id = $1 and (expires_at is null or expires_at > now())",
        .{sid},
    ) catch return null) orelse return null;
    defer row.deinit() catch {};
    const account = row.get([]const u8, 0) catch return null;
    const n = @min(account.len, out.len);
    @memcpy(out[0..n], account[0..n]);
    return out[0..n];
}

pub fn expireSession(id: u64) void {
    const p = ensurePool() orelse return;
    const sid: i64 = @bitCast(id);
    _ = p.exec("delete from sessions where id = $1", .{sid}) catch {};
}

fn sweepSessions(p: *pg.Pool) void {
    _ = p.exec("delete from sessions where expires_at is not null and expires_at < now()", .{}) catch {};
}

// ── games (ephemeral, TTL; gameid/gsid columns are indexed) ──────────────────

pub fn registerGame(name: []const u8, gameid: u32, gs_ip: [4]u8, gs_port: u16, gsid: u32, players: u16, status: u8, difficulty: u8, password: []const u8, description: []const u8, ttl_s: u32) bool {
    var nb: [64]u8 = undefined;
    const safe = gameKey(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    const ip = ipToInt(gs_ip);
    if (ttl_s > 0) {
        _ = p.exec(
            \\insert into games(name, gameid, ip, port, gsid, players, status, difficulty, password, description, expires_at)
            \\values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now() + make_interval(secs => $11))
            \\on conflict (name) do update set
            \\  gameid = excluded.gameid, ip = excluded.ip, port = excluded.port,
            \\  gsid = excluded.gsid, players = excluded.players, status = excluded.status,
            \\  difficulty = excluded.difficulty, password = excluded.password,
            \\  description = excluded.description, expires_at = excluded.expires_at
        , .{ safe, @as(i64, gameid), ip, @as(i32, gs_port), @as(i64, gsid), @as(i32, players), @as(i32, status), @as(i32, difficulty), password, description, @as(f64, @floatFromInt(ttl_s)) }) catch return false;
    } else {
        _ = p.exec(
            \\insert into games(name, gameid, ip, port, gsid, players, status, difficulty, password, description, expires_at)
            \\values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, null)
            \\on conflict (name) do update set
            \\  gameid = excluded.gameid, ip = excluded.ip, port = excluded.port,
            \\  gsid = excluded.gsid, players = excluded.players, status = excluded.status,
            \\  difficulty = excluded.difficulty, password = excluded.password,
            \\  description = excluded.description, expires_at = null
        , .{ safe, @as(i64, gameid), ip, @as(i32, gs_port), @as(i64, gsid), @as(i32, players), @as(i32, status), @as(i32, difficulty), password, description }) catch return false;
    }
    return true;
}

/// Overwrite a game's player count. A single targeted update: it deliberately does not
/// touch expires_at, so a busy game's lease is governed by its registration, not its
/// traffic.
pub fn setGamePlayers(gameid: u32, players: u16) bool {
    const p = ensurePool() orelse return false;
    const res = p.exec(
        "update games set players = $1 where gameid = $2 and (expires_at is null or expires_at > now())",
        .{ @as(i32, players), @as(i64, gameid) },
    ) catch return false;
    return (res orelse 0) > 0;
}

pub fn findGame(name: []const u8) ?GameRec {
    var nb: [64]u8 = undefined;
    const safe = gameKey(name, &nb) orelse return null;
    const p = ensurePool() orelse return null;
    sweepGames(p);
    var row = (p.row(
        "select gameid, ip, port, gsid, password, players, description, status, difficulty from games where name = $1 and (expires_at is null or expires_at > now())",
        .{safe},
    ) catch return null) orelse return null;
    defer row.deinit() catch {};
    const gameid = row.get(i64, 0) catch return null;
    const ip = row.get(i64, 1) catch return null;
    const port = row.get(i32, 2) catch return null;
    const gsid = row.get(i64, 3) catch return null;
    const password = row.get([]const u8, 4) catch "";
    const players = row.get(i32, 5) catch 0;
    const description = row.get([]const u8, 6) catch "";
    const game_status = row.get(i32, 7) catch 0;
    const game_difficulty = row.get(i32, 8) catch 0;
    var rec = GameRec{
        .gameid = @truncate(@as(u64, @bitCast(gameid))),
        .gs_ip = intToIp(ip),
        .gs_port = @truncate(@as(u32, @bitCast(port))),
        .gsid = @truncate(@as(u64, @bitCast(gsid))),
        .players = @truncate(@as(u32, @bitCast(players))),
    };
    rec.setPw(password);
    rec.setDesc(description);
    rec.status = @truncate(@as(u32, @bitCast(game_status)));
    rec.difficulty = @truncate(@as(u32, @bitCast(game_difficulty)));
    return rec;
}

pub fn snapshotGames(out: []types.NamedGame) usize {
    const p = ensurePool() orelse return 0;
    sweepGames(p); // drop lapsed rows first so the listing matches findGame's view
    var result = p.query(
        "select name, gameid, ip, port, gsid, players, description, status from games where expires_at is null or expires_at > now()",
        .{},
    ) catch return 0;
    defer result.deinit();
    var n: usize = 0;
    while (result.next() catch null) |row| {
        if (n >= out.len) continue; // drain the rest
        const nm = row.get([]const u8, 0) catch continue;
        const gameid = row.get(i64, 1) catch continue;
        const ip = row.get(i64, 2) catch continue;
        const port = row.get(i32, 3) catch continue;
        const gsid = row.get(i64, 4) catch continue;
        const players = row.get(i32, 5) catch 0;
        const description = row.get([]const u8, 6) catch "";
        const game_status = row.get(i32, 7) catch 0;
        var ng = types.NamedGame{
            .gameid = @truncate(@as(u64, @bitCast(gameid))),
            .gs_ip = intToIp(ip),
            .gs_port = @truncate(@as(u32, @bitCast(port))),
            .gsid = @truncate(@as(u64, @bitCast(gsid))),
            .players = @truncate(@as(u32, @bitCast(players))),
            .status = @truncate(@as(u32, @bitCast(game_status))),
        };
        ng.setDesc(description);
        const ln: u8 = @intCast(@min(nm.len, ng.name.len));
        @memcpy(ng.name[0..ln], nm[0..ln]);
        ng.name_len = ln;
        out[n] = ng;
        n += 1;
    }
    return n;
}

pub fn removeGameById(gameid: u32) void {
    const p = ensurePool() orelse return;
    _ = p.exec("delete from games where gameid = $1", .{@as(i64, gameid)}) catch {};
}

pub fn expireGamesByGs(gsid: u32) void {
    const p = ensurePool() orelse return;
    _ = p.exec("delete from games where gsid = $1", .{@as(i64, gsid)}) catch {};
}

fn sweepGames(p: *pg.Pool) void {
    _ = p.exec("delete from games where expires_at is not null and expires_at < now()", .{}) catch {};
}

// ── housekeeping ─────────────────────────────────────────────────────────────

pub fn healthy() bool {
    const p = ensurePool() orelse return false;
    var row = (p.row("select 1", .{}) catch return false) orelse return false;
    defer row.deinit() catch {};
    return true;
}
