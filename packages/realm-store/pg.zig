//! Postgres persistence backend — the durable store of record. Uses the vendored pure-Zig
//! `pg.zig` client (no libpq, so the static-musl scratch image is preserved).
//!
//! Schema: chars(account, name, d2s, version, metadata), accounts(name, pwhash, is_admin),
//! userdata(account, key,
//! value), guilds(name, data), ext_kv(ext, key, value). Nothing short-lived is here — sessions, games, routes and the
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
const ExtKey = types.ExtKey;

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

// extension keyspace (durable)
//
// Every operation is scoped by `ext`, and the name is sanitised the same way an account is, so an
// extension cannot address another's rows even by asking for them. Keys are opaque to us and go
// through the parameter binder; only their LENGTH is checked, since a listing has to hand them
// back through a fixed-size `ExtKey`.

pub fn getExt(ext: []const u8, key: []const u8, out: []u8) usize {
    var nb: [64]u8 = undefined;
    const e = sanitize(ext, &nb) orelse return 0;
    if (key.len == 0 or key.len > types.ext_key_max) return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row("select value from ext_kv where ext = $1 and key = $2", .{ e, key }) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const v = row.get([]const u8, 0) catch return 0;
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return n;
}

pub fn setExt(ext: []const u8, key: []const u8, value: []const u8) bool {
    var nb: [64]u8 = undefined;
    const e = sanitize(ext, &nb) orelse return false;
    if (key.len == 0 or key.len > types.ext_key_max) return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into ext_kv(ext, key, value) values ($1, $2, $3)
        \\on conflict (ext, key) do update set value = excluded.value, updated = now()
    , .{ e, key, value }) catch return false;
    return true;
}

pub fn delExt(ext: []const u8, key: []const u8) bool {
    var nb: [64]u8 = undefined;
    const e = sanitize(ext, &nb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec("delete from ext_kv where ext = $1 and key = $2", .{ e, key }) catch return false;
    return true;
}

/// Keys in this extension's namespace that start with `prefix` (empty = all), into a caller-owned
/// array. Returns how many were written; a full array is a truncated answer, not an error.
pub fn listExtKeys(ext: []const u8, prefix: []const u8, out: []ExtKey) usize {
    if (out.len == 0) return 0;
    var nb: [64]u8 = undefined;
    const e = sanitize(ext, &nb) orelse return 0;
    if (prefix.len > types.ext_key_max) return 0;
    const p = ensurePool() orelse return 0;
    // `like` would need the prefix escaped into a second buffer; `starts_with` takes it as a plain
    // parameter, so a key containing `%` still means itself.
    var result = p.query(
        \\select key from ext_kv where ext = $1 and starts_with(key, $2) order by key
    , .{ e, prefix }) catch return 0;
    defer result.deinit();
    var count: usize = 0;
    while (result.next() catch null) |row| {
        if (count >= out.len) continue; // drain the rest, as listAccounts does
        const k = row.get([]const u8, 0) catch continue;
        out[count].set(k);
        count += 1;
    }
    return count;
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
    // Which engine this character belongs to, and everything else anyone wants to remember about
    // it. Two columns rather than one because they answer to different owners: the realm routes
    // and gates on `version`, so it is typed, indexable and not something an extension can
    // overwrite by writing the wrong key; `metadata` is free-form and belongs to whoever wrote it.
    // Empty version means "no engine recorded", which reads as no constraint — that is what every
    // character created before this column existed is.
    _ = try p.exec("alter table chars add column if not exists version text not null default ''", .{});
    _ = try p.exec("alter table chars add column if not exists metadata jsonb not null default '{}'::jsonb", .{});
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
    // The extension keyspace. One table for every extension, partitioned by the `ext` column
    // rather than a table per extension: an extension gets a namespace without getting DDL
    // rights, so nothing it stores can collide with the realm's own schema or with another
    // extension's. `value` is bytea because JSON is only one of the things people will keep here.
    _ = try p.exec(
        \\create table if not exists ext_kv(
        \\  ext text not null,
        \\  key text not null,
        \\  value bytea not null,
        \\  updated timestamptz not null default now(),
        \\  primary key(ext, key)
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

// character version + metadata (durable)
//
// Neither is written by `saveCharD2s`: a save carries the character's bytes and nothing about
// which engine wrote them, so stamping the version there would make every save a chance to change
// it. The version is set once, at creation.
//
// The writers upsert rather than update, and have to. A character's bytes land in redis first and
// reach this table only when the flush worker moves them, so at creation there is no row yet — an
// UPDATE would silently stamp nothing, and the character would come out of its first flush with
// no engine recorded. Inserting the record row here with empty bytes is harmless: the flush's own
// upsert fills the bytes in and leaves these columns alone.

/// The engine a character belongs to, empty when nothing recorded one.
pub fn charVersion(account: []const u8, charname: []const u8, out: []u8) usize {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const c = sanitize(charname, &cb) orelse return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row("select version from chars where account = $1 and name = $2", .{ a, c }) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const v = row.get([]const u8, 0) catch return 0;
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return n;
}

pub fn setCharVersion(account: []const u8, charname: []const u8, version: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into chars(account, name, d2s, version) values ($1, $2, ''::bytea, $3)
        \\on conflict (account, name) do update set version = excluded.version
    , .{ a, c, version }) catch return false;
    return true;
}

/// The whole metadata document, as JSON text.
pub fn getCharMeta(account: []const u8, charname: []const u8, out: []u8) usize {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const c = sanitize(charname, &cb) orelse return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row("select metadata::text from chars where account = $1 and name = $2", .{ a, c }) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const v = row.get([]const u8, 0) catch return 0;
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return n;
}

/// Shallow-merge a JSON object into the metadata, which is what two extensions writing different
/// keys need: `set` would have each of them delete the other's work on every write.
pub fn mergeCharMeta(account: []const u8, charname: []const u8, json: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into chars(account, name, d2s, metadata) values ($1, $2, ''::bytea, $3::jsonb)
        \\on conflict (account, name) do update set metadata = chars.metadata || excluded.metadata
    , .{ a, c, json }) catch return false;
    return true;
}

/// One top-level key, as text. A JSON string comes back unquoted (`->>`), which is what a caller
/// reading a version or a season number wants; an object or array comes back as its JSON.
pub fn getCharMetaKey(account: []const u8, charname: []const u8, key: []const u8, out: []u8) usize {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const c = sanitize(charname, &cb) orelse return 0;
    const p = ensurePool() orelse return 0;
    var row = (p.row(
        "select metadata->>$3 from chars where account = $1 and name = $2",
        .{ a, c, key },
    ) catch return 0) orelse return 0;
    defer row.deinit() catch {};
    const v = (row.get(?[]const u8, 0) catch return 0) orelse return 0;
    const n = @min(v.len, out.len);
    @memcpy(out[0..n], v[0..n]);
    return n;
}

/// Set one top-level key to a JSON string. `to_jsonb($4::text)` rather than a raw fragment: the
/// value is data, so a caller storing `"} , "admin": true` stores that text and nothing else.
pub fn setCharMetaKey(account: []const u8, charname: []const u8, key: []const u8, value: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into chars(account, name, d2s, metadata)
        \\values ($1, $2, ''::bytea, jsonb_build_object($3::text, $4::text))
        \\on conflict (account, name) do update
        \\  set metadata = jsonb_set(chars.metadata, array[$3::text], to_jsonb($4::text), true)
    , .{ a, c, key, value }) catch return false;
    return true;
}

/// The account's characters with the engine each belongs to — one round trip, because the char
/// list needs both for every row and asking per character would be a query per character.
pub fn listCharsFull(account: []const u8, out: []types.CharRec) usize {
    var ab: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const p = ensurePool() orelse return 0;
    var result = p.query("select name, version from chars where account = $1", .{a}) catch return 0;
    defer result.deinit();
    var count: usize = 0;
    while (result.next() catch null) |row| {
        if (count >= out.len) continue; // drain the rest
        const nm = row.get([]const u8, 0) catch continue;
        if (nm.len == 0 or nm.len > out[count].name.buf.len) continue;
        const v = row.get([]const u8, 1) catch "";
        out[count] = .{};
        @memcpy(out[count].name.buf[0..nm.len], nm);
        out[count].name.len = @intCast(nm.len);
        out[count].version.set(v);
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
