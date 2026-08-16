//! Postgres persistence backend — the durable store of record. Uses the vendored pure-Zig
//! `pg.zig` client (no libpq, so the static-musl scratch image is preserved).
//!
//! Schema: chars(account, name, d2s), accounts(name, pwhash, is_admin), userdata(account, key,
//! value), guilds(name, data). Nothing short-lived is here — sessions, games, routes and the
//! fleet are in flight and belong to Redis; a Postgres copy would be a second answer to a
//! question that must have one.
//!
//! Concurrency: the pg.zig Pool is internally threadsafe; one-time lazy pool creation + schema
//! DDL is guarded by a spinlock. The pool owns its own std.Io (process-global Threaded) to drive
//! blocking socket IO from realmd's thread-per-peer workers.
const std = @import("std");
const pg = @import("pg");
const Lock = @import("realm_infra").lock.Lock;
const types = @import("realm_infra").types;

const Name = types.Name;

// accounts, profiles and guilds (durable)
//
// These used to route to the filesystem backend, on the argument that they are low-volume and
// simple. That holds right up until there is more than one instance, at which point "the file on
// this pod" is a different answer per pod: an account created on one is missing on the other, and
// an admin flagged on one is an ordinary user on the other. Low volume is a reason not to cache
// them, not a reason not to share them.

pub fn createAccount(name: []const u8, pwhash: ?[20]u8) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    // ON CONFLICT DO NOTHING and report whether we inserted: "create" must fail on an existing
    // account rather than silently reset its password.
    const res = p.exec(
        \\insert into accounts(name, pwhash) values ($1, $2) on conflict (name) do nothing
    , .{ a, if (pwhash) |*h| @as(?[]const u8, h) else null }) catch return false;
    return res == 1;
}

pub fn accountExists(name: []const u8) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    var row = (p.row("select 1 from accounts where name = $1", .{a}) catch return false) orelse return false;
    row.deinit() catch {};
    return true;
}

/// Null if there is no such account; false if it exists without a password.
pub fn accountPwHash(name: []const u8, out: *[20]u8) ?bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return null;
    const p = ensurePool() orelse return null;
    var row = (p.row("select pwhash from accounts where name = $1", .{a}) catch return null) orelse return null;
    defer row.deinit() catch {};
    const h = row.get(?[]const u8, 0) catch return null;
    const bytes = h orelse return false;
    if (bytes.len != 20) return false;
    @memcpy(out, bytes[0..20]);
    return true;
}

pub fn setAccountPassword(name: []const u8, hash: [20]u8) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    const res = p.exec("update accounts set pwhash = $2 where name = $1", .{ a, @as([]const u8, &hash) }) catch return false;
    return res == 1;
}

/// Remove an account. Idempotent — true even if it was already gone.
pub fn deleteAccount(name: []const u8) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec("delete from accounts where name = $1", .{a}) catch return false;
    _ = p.exec("delete from userdata where account = $1", .{a}) catch return false;
    return true;
}

pub fn listAccounts(names: [][32]u8) usize {
    const p = ensurePool() orelse return 0;
    var result = p.query("select name from accounts order by name", .{}) catch return 0;
    defer result.deinit();
    var count: usize = 0;
    while (result.next() catch null) |row| {
        if (count >= names.len) continue; // drain the rest
        const nm = row.get([]const u8, 0) catch continue;
        if (nm.len == 0 or nm.len >= names[count].len) continue;
        @memset(&names[count], 0);
        @memcpy(names[count][0..nm.len], nm);
        count += 1;
    }
    return count;
}

/// Set/clear the account's admin flag. False if there is no such account.
pub fn setAdmin(name: []const u8, admin: bool) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    const res = p.exec("update accounts set is_admin = $2 where name = $1", .{ a, admin }) catch return false;
    return res == 1;
}

pub fn accountIsAdmin(name: []const u8) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    var row = (p.row("select is_admin from accounts where name = $1", .{a}) catch return false) orelse return false;
    defer row.deinit() catch {};
    return row.get(bool, 0) catch false;
}

/// BNCS profile values, addressed by key path ("profile\\sex"). Absent = empty, which is what
/// the client is shown for a field nobody has filled in.
pub fn getUserData(account: []const u8, key_: []const u8, out: []u8) usize {
    var nb: [64]u8 = undefined;
    const a = sanitize(account, &nb) orelse return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row("select value from userdata where account = $1 and key = $2", .{ a, key_ }) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const v = row.get([]const u8, 0) catch return 0;
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return n;
}

pub fn setUserData(account: []const u8, key_: []const u8, value: []const u8) bool {
    var nb: [64]u8 = undefined;
    const a = sanitize(account, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into userdata(account, key, value) values ($1, $2, $3)
        \\on conflict (account, key) do update set value = excluded.value
    , .{ a, key_, value }) catch return false;
    return true;
}

pub fn saveGuild(name: []const u8, bytes: []const u8) bool {
    var nb: [64]u8 = undefined;
    const g = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into guilds(name, data) values ($1, $2)
        \\on conflict (name) do update set data = excluded.data
    , .{ g, bytes }) catch return false;
    return true;
}

pub fn getGuild(name: []const u8, out: []u8) usize {
    var nb: [64]u8 = undefined;
    const g = sanitize(name, &nb) orelse return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row("select data from guilds where name = $1", .{g}) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const v = row.get([]const u8, 0) catch return 0;
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return n;
}

/// Idempotent — true even if it was already gone, so a repeated delete is not an error.
pub fn deleteGuild(name: []const u8) bool {
    var nb: [64]u8 = undefined;
    const g = sanitize(name, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec("delete from guilds where name = $1", .{g}) catch return false;
    return true;
}

pub fn listGuilds(names: []Name) usize {
    const p = ensurePool() orelse return 0;
    var result = p.query("select name from guilds order by name", .{}) catch return 0;
    defer result.deinit();
    var count: usize = 0;
    while (result.next() catch null) |row| {
        if (count >= names.len) continue; // drain the rest
        const nm = row.get([]const u8, 0) catch continue;
        if (nm.len == 0 or nm.len > names[count].buf.len) continue;
        @memset(&names[count].buf, 0);
        @memcpy(names[count].buf[0..nm.len], nm);
        names[count].len = @intCast(nm.len);
        count += 1;
    }
    return count;
}

// lazy global pool

var dsn: []const u8 = "";
var pool: ?*pg.Pool = null;
var schema_ready: bool = false;
var init_lock: Lock = .{};
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
    // join password, player count + description (added separately so an existing table
    // migrates in place).
    _ = try p.exec(
        \\create table if not exists accounts(
        \\  name text primary key,
        \\  pwhash bytea,
        \\  is_admin boolean not null default false
        \\)
    , .{});
    _ = try p.exec(
        \\create table if not exists userdata(
        \\  account text not null,
        \\  key text not null,
        \\  value text not null,
        \\  primary key(account, key)
        \\)
    , .{});
    _ = try p.exec(
        \\create table if not exists guilds(
        \\  name text primary key,
        \\  data bytea not null
        \\)
    , .{});
}

// name sanitising

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





// characters (durable)

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

// housekeeping

pub fn healthy() bool {
    const p = ensurePool() orelse return false;
    var row = (p.row("select 1", .{}) catch return false) orelse return false;
    defer row.deinit() catch {};
    return true;
}
