//! Postgres persistence backend — the durable store of record. Uses the vendored pure-Zig
//! `pg.zig` client (no libpq, so the static-musl scratch image is preserved).
//!
//! Schema: chars(account, name, d2s, version, metadata, created), accounts(name, pwhash, is_admin),
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

/// The next page of account names after `after` (empty: from the start), in name order. A caller
/// that has to see every account pages through with the last name it got, so no account past a
/// buffer's end is silently left out.
pub fn listAccountsAfter(after: []const u8, names: [][32]u8) usize {
    const p = ensurePool() orelse return 0;
    var result = p.query("select name from accounts where name > $1 order by name limit $2", .{ after, @as(i64, @intCast(names.len)) }) catch return 0;
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

/// Whether any account carries the admin flag. One question to the store rather than a walk of
/// the accounts, which a buffer would cut short.
pub fn anyAdmin() bool {
    const p = ensurePool() orelse return false;
    var row = (p.row("select 1 from accounts where is_admin limit 1", .{}) catch return false) orelse return false;
    row.deinit() catch {};
    return true;
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
    // One transaction, serialised across every instance by an advisory lock. Replicas start
    // together, and two `create table if not exists` of the same new table race in the catalog:
    // the loser fails on pg_type's unique index, and realmd exits at boot on a store it could not
    // prepare. Under the lock the second instance waits, then finds everything already there.
    const conn = try p.acquire();
    defer conn.release();
    try conn.begin();
    errdefer conn.rollback() catch {};
    var locked = (try conn.row("select pg_advisory_xact_lock($1)", .{schema_lock_key})) orelse return error.NoLockRow;
    try locked.deinit();
    // Past the advisory lock, a DDL statement that cannot get its table lock fails instead of
    // queueing: a queued ALTER holds up every later query on the table behind it, so one slow
    // reader would stall the whole realm for as long as it ran. Failing costs a retry.
    _ = try conn.exec("set local lock_timeout = '5s'", .{});
    _ = try conn.exec(
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
    // Character names, claimed across the whole realm.
    //
    // `chars` is keyed by (account, name), so two accounts could each hold a "Bob" — and everything
    // downstream that identifies a character by NAME then has two answers: the game server's seat
    // table, its save-retry queue, a departing player's seat release, and, on the Mac engine, the
    // save file itself, which is literally `<save path><charname>.d2s`. The result is not a
    // rollback but a character swap.
    //
    // A separate claim table rather than a unique index on `chars`: an index would have to be
    // created over data that may already contain duplicates, and that failure would happen at
    // startup, in the schema bootstrap, taking the realm down. This starts empty and only ever
    // grows, so it cannot fail on anything already there — and `claimCharName` checks `chars` too,
    // which is what covers the characters that predate it.
    _ = try conn.exec(
        \\create table if not exists charnames(
        \\  lname text primary key,
        \\  account text not null,
        \\  name text not null
        \\)
    , .{});
    try addCharsColumn(conn, "version", "text not null default ''");
    try addCharsColumn(conn, "metadata", "jsonb not null default '{}'::jsonb");
    // When the row was first written, which is what orders an account's character list. `now()`
    // and not `clock_timestamp()`: a volatile default would stamp every EXISTING row as the column
    // is added, in whatever order the heap holds them; a stable one gives them all the same time,
    // so the name tie-break in `char_order` puts them in alphabetical order instead.
    try addCharsColumn(conn, "created", "timestamptz not null default now()");
    // The character's ladder standing, derived from its save whenever the save is written here, so
    // opening a board is an index range rather than a read of every save on the realm. NULL means
    // not derived yet: a row that predates these columns, or one whose first save has not landed.
    // `ladderRebuild` fills those in. The .d2s status byte, the client's row stats dword, and the
    // experience - see apps/realmd/ladder.zig for what each holds.
    try addCharsColumn(conn, "ladder_status", "smallint");
    try addCharsColumn(conn, "ladder_stats", "bigint");
    try addCharsColumn(conn, "ladder_exp", "bigint");
    // A board is one (ladder, hardcore, expansion) kind, ranked by experience.
    if (!try hasIndex(conn, "chars_ladder_board")) {
        _ = try conn.exec("create index if not exists chars_ladder_board on chars ((ladder_status & 100), ladder_exp desc) where ladder_status is not null", .{});
    }
    // join password, player count + description (added separately so an existing table
    // migrates in place).
    _ = try conn.exec(
        \\create table if not exists accounts(
        \\  name text primary key,
        \\  pwhash bytea,
        \\  is_admin boolean not null default false
        \\)
    , .{});
    _ = try conn.exec(
        \\create table if not exists userdata(
        \\  account text not null,
        \\  key text not null,
        \\  value text not null,
        \\  primary key(account, key)
        \\)
    , .{});
    _ = try conn.exec(
        \\create table if not exists guilds(
        \\  name text primary key,
        \\  data bytea not null
        \\)
    , .{});
    // The extension keyspace. One table for every extension, partitioned by the `ext` column
    // rather than a table per extension: an extension gets a namespace without getting DDL
    // rights, so nothing it stores can collide with the realm's own schema or with another
    // extension's. `value` is bytea because JSON is only one of the things people will keep here.
    _ = try conn.exec(
        \\create table if not exists ext_kv(
        \\  ext text not null,
        \\  key text not null,
        \\  value bytea not null,
        \\  updated timestamptz not null default now(),
        \\  primary key(ext, key)
        \\)
    , .{});
    try conn.commit();
}

/// Postgres advisory-lock key for the schema bootstrap ("realmd", then a counter).
const schema_lock_key: i64 = 0x7265616c6d640001;

/// Add a column to `chars` unless it is already there.
///
/// Asked first rather than left to `add column if not exists`: that form takes the table's ACCESS
/// EXCLUSIVE lock before it finds it has nothing to do, so every instance start would queue behind
/// any running query on `chars`, and every character read after it would queue behind that.
fn addCharsColumn(conn: *pg.Conn, comptime name: []const u8, comptime decl: []const u8) !void {
    if (try conn.row(
        "select 1 from information_schema.columns where table_schema = current_schema() and table_name = 'chars' and column_name = $1",
        .{name},
    )) |found| {
        var r = found;
        try r.deinit();
        return;
    }
    _ = try conn.exec("alter table chars add column if not exists " ++ name ++ " " ++ decl, .{});
}

/// Whether an index exists, asked first for the same reason as `addCharsColumn`: `create index if
/// not exists` takes its table lock before it finds there is nothing to do.
fn hasIndex(conn: *pg.Conn, comptime name: []const u8) !bool {
    if (try conn.row("select 1 from pg_indexes where schemaname = current_schema() and indexname = $1", .{name})) |found| {
        var r = found;
        try r.deinit();
        return true;
    }
    return false;
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

/// A character's place on the ladder, as the realm derives it from the save. The store keeps it
/// beside the save and never interprets it beyond the board filter and the ranking order.
pub const Standing = struct {
    /// The .d2s status byte: ladder 0x40, expansion 0x20, hardcore 0x04.
    status: u8,
    /// The row's stats dword as the client reads it; class in the low nibble, level at bit 16.
    stats: u32,
    experience: u32,
};

/// Write a save, and with it the standing derived from it, in one statement: the board can never
/// disagree with the save the store of record holds.
pub fn saveCharD2s(account: []const u8, charname: []const u8, bytes: []const u8, standing: Standing) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into chars(account, name, d2s, ladder_status, ladder_stats, ladder_exp) values ($1, $2, $3, $4, $5, $6)
        \\on conflict (account, name) do update set d2s = excluded.d2s,
        \\  ladder_status = excluded.ladder_status, ladder_stats = excluded.ladder_stats, ladder_exp = excluded.ladder_exp
    , .{ a, c, bytes, @as(i16, standing.status), @as(i64, standing.stats), @as(i64, standing.experience) }) catch return false;
    return true;
}

/// Which characters a board holds: ladder characters of one kind, and of one class for a class
/// board. `kind` is the status byte's ladder|expansion|hardcore bits (mask 0x64 = 100).
pub const BoardKey = struct { kind: u8, class: ?u8 };

/// A ladder row as the store holds it.
pub const LadderRow = struct {
    name: Name = .{},
    standing: Standing = .{ .status = 0, .stats = 0, .experience = 0 },
};

const board_where =
    \\ladder_status is not null and (ladder_status & 100) = $1 and ($2 < 0 or (ladder_stats & 15) = $2)
;
/// The ladder's order: experience, then level, then the name's bytes.
const board_order =
    \\ladder_exp desc, ((ladder_stats >> 16) & 255) desc, name collate "C"
;

/// `out.len` rows of a board from zero-based rank `first` on. Reads the index, not the saves.
pub fn ladderPage(key: BoardKey, first: u32, out: []LadderRow) usize {
    const p = ensurePool() orelse return 0;
    const class: i32 = if (key.class) |cl| cl else -1;
    var result = p.query(
        "select name, ladder_status, ladder_stats, ladder_exp from chars where " ++ board_where ++
            " order by " ++ board_order ++ " limit $3 offset $4",
        .{ @as(i32, key.kind), class, @as(i64, @intCast(out.len)), @as(i64, first) },
    ) catch return 0;
    defer result.deinit();
    var count: usize = 0;
    while (result.next() catch null) |row| {
        if (count >= out.len) continue; // drain the rest
        const nm = row.get([]const u8, 0) catch continue;
        if (nm.len == 0 or nm.len > out[count].name.buf.len) continue;
        out[count] = .{};
        @memcpy(out[count].name.buf[0..nm.len], nm);
        out[count].name.len = @intCast(nm.len);
        out[count].standing = .{
            .status = @intCast((row.get(i16, 1) catch 0) & 0xff),
            .stats = @truncate(@as(u64, @bitCast(row.get(i64, 2) catch 0))),
            .experience = @truncate(@as(u64, @bitCast(row.get(i64, 3) catch 0))),
        };
        count += 1;
    }
    return count;
}

/// A character's zero-based rank on a board, name compared without case, if it is within the
/// first `limit` rows.
pub fn ladderRank(key: BoardKey, charname: []const u8, limit: u32) ?u32 {
    var cb: [64]u8 = undefined;
    const c = sanitize(charname, &cb) orelse return null;
    const p = ensurePool() orelse return null;
    const class: i32 = if (key.class) |cl| cl else -1;
    var row = (p.row(
        "select r from (select name, row_number() over (order by " ++ board_order ++ ") as r from chars where " ++
            board_where ++ " order by " ++ board_order ++ " limit $4) t where lower(name) = lower($3) order by r limit 1",
        .{ @as(i32, key.kind), class, c, @as(i64, limit) },
    ) catch return null) orelse return null;
    defer row.deinit() catch {};
    const r = row.get(i64, 0) catch return null;
    if (r < 1) return null;
    return @intCast(r - 1);
}

/// Derive standings from the saves the store holds: the rows that have none (`all` false: rows
/// from before the standing columns, the bootstrap), or every row (`all` true: a repair after the
/// derivation changed). Returns how many rows were written.
///
/// One row at a time, walking the primary key, so it holds no lock and no large buffer. Each write
/// is conditional on the save being the one it was derived from: a flush that lands meanwhile has
/// written a newer save with its own standing, and that must not be overwritten with this one.
pub fn ladderRebuild(all: bool, derive: *const fn (name: []const u8, save: []const u8) Standing) usize {
    const p = ensurePool() orelse return 0;
    var last_account: [64]u8 = undefined;
    var last_name: [64]u8 = undefined;
    var la: usize = 0;
    var ln: usize = 0;
    var written: usize = 0;
    const save = std.heap.c_allocator.alloc(u8, 64 * 1024) catch return 0;
    defer std.heap.c_allocator.free(save);
    while (true) {
        var row = (p.row(
            \\select account, name, d2s from chars
            \\where length(d2s) > 0 and (account, name) > ($1, $2) and ($3 or ladder_status is null)
            \\order by account, name limit 1
        , .{ last_account[0..la], last_name[0..ln], all }) catch return written) orelse return written;
        const a = row.get([]const u8, 0) catch "";
        const n = row.get([]const u8, 1) catch "";
        const d = row.get([]const u8, 2) catch "";
        if (a.len > last_account.len or n.len > last_name.len or d.len > save.len) {
            row.deinit() catch {};
            return written;
        }
        la = a.len;
        ln = n.len;
        @memcpy(last_account[0..la], a);
        @memcpy(last_name[0..ln], n);
        const dn = d.len;
        @memcpy(save[0..dn], d);
        row.deinit() catch {};

        const s = derive(last_name[0..ln], save[0..dn]);
        const res = p.exec(
            \\update chars set ladder_status = $4, ladder_stats = $5, ladder_exp = $6
            \\where account = $1 and name = $2 and d2s = $3
        , .{ last_account[0..la], last_name[0..ln], save[0..dn], @as(i16, s.status), @as(i64, s.stats), @as(i64, s.experience) }) catch continue;
        if ((res orelse 0) == 1) written += 1;
    }
}

/// Give a character that has just come into existence its row, and with it its `created` time,
/// before its first save reaches here.
///
/// The save goes to redis and the flush worker moves it here later, so without this a character's
/// creation time would be whenever the worker got to it: two characters made before a flush get
/// their order from the order they are flushed in, and the list, which is the char-select slot
/// layout, reshuffles when they land. An existing row is left alone.
pub fn recordCharCreated(account: []const u8, charname: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;
    _ = p.exec(
        \\insert into chars(account, name, d2s) values ($1, $2, ''::bytea)
        \\on conflict (account, name) do nothing
    , .{ a, c }) catch return false;
    return true;
}

/// Claim a character name for `account`, across the whole realm. False if somebody else has it.
///
/// Atomic: the primary key on `lname` is what decides, so two instances racing to create the same
/// name cannot both win. Re-claiming a name this account already holds succeeds, which is what
/// lets a player delete a character and make another with the same name.
///
/// The `chars` probe covers characters created before this table existed — they hold their names
/// without a claim row, and must still block a newcomer.
pub fn claimCharName(account: []const u8, charname: []const u8) bool {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return false;
    const c = sanitize(charname, &cb) orelse return false;
    const p = ensurePool() orelse return false;

    // Somebody else already has a character by this name from before the claim table.
    if (p.row("select 1 from chars where lower(name) = lower($1) and account <> $2", .{ c, a }) catch return false) |r| {
        var row = r;
        row.deinit() catch {};
        return false;
    }

    var row = (p.row(
        \\insert into charnames(lname, account, name) values (lower($1), $2, $1)
        \\on conflict (lname) do update set name = excluded.name
        \\where charnames.account = $2
        \\returning account
    , .{ c, a }) catch return false) orelse return false;
    defer row.deinit() catch {};
    return true;
}

/// Give a character name back, so it can be taken again. Called when a character is deleted.
pub fn releaseCharName(account: []const u8, charname: []const u8) void {
    var ab: [64]u8 = undefined;
    var cb: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return;
    const c = sanitize(charname, &cb) orelse return;
    const p = ensurePool() orelse return;
    _ = p.exec("delete from charnames where lname = lower($1) and account = $2", .{ c, a }) catch return;
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

/// How an account's characters are listed: oldest first, name breaking a tie.
///
/// The list is the character-select screen's layout — the client fills its slots in the order the
/// characters arrive — so it has to come out the same every time. Without an ORDER BY it did not:
/// every save is an UPDATE, which writes a new row version somewhere else in the heap, so a plain
/// scan returned the characters in a different order after each game and moved them between slots.
/// Creation order is the one order a save cannot change.
pub const char_order = " order by created, lower(name), name";

pub fn listChars(account: []const u8, names: []Name) usize {
    var ab: [64]u8 = undefined;
    const a = sanitize(account, &ab) orelse return 0;
    const p = ensurePool() orelse return 0;
    var result = p.query("select name from chars where account = $1" ++ char_order, .{a}) catch return 0;
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
    var result = p.query("select name, version from chars where account = $1" ++ char_order, .{a}) catch return 0;
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
