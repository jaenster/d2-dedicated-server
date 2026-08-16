//! Server counters — is it ticking, how fast, how many games/players, what the item
//! pipeline is producing.
//!
//! Written on the engine tick thread from feature hooks, read on the health thread
//! (runtime/feature/health.zig serves /stats and /metrics). No lock, no allocation: counters
//! are plain 32-bit words (atomic on x86 when aligned), and the per-game table holds COPIES
//! of scalars rather than engine pointers, so a reader can never dereference a freed game
//! struct. A hook here costs a couple increments, staying clear of the 40ms frame budget.
//!
//! Rendering happens on the reader's thread into the reader's buffer, so a slow/stuck HTTP
//! client can't hold anything the engine needs.
const std = @import("std");
const GameCtx = @import("../../engine/ctx.zig").GameCtx;
const t = @import("../../engine/d2/types.zig");
const fns = @import("../../engine/d2/functions.zig");
const poolstat = @import("../poolstat.zig");
const d2cs = @import("../../realmclient/d2cs.zig");

extern "kernel32" fn GetTickCount() callconv(.winapi) u32;

// D2GameStrc fields read straight off the pointer (see srvtrace.zig for the same map):
// nToken@0, szGameName@0x2A, nClientsCount@140, dwSpawnedPlayers@144, dwGameFrame@168.
const GAME_CLIENTS = 140;
const GAME_FRAME = 168;

fn readU32(base: usize, off: usize) u32 {
    return @as(*align(1) const u32, @ptrFromInt(base + off)).*;
}

// counters

var boot_ms: u32 = 0;
var ticks: u32 = 0;
/// Ticks per second, times 100 (so a rate is reported without floats crossing threads).
var tick_rate_x100: u32 = 0;
var rate_last_ms: u32 = 0;
var rate_last_ticks: u32 = 0;

var games_created: u32 = 0;
var games_destroyed: u32 = 0;
var players_joined: u32 = 0;
var players_left: u32 = 0;

var items_rolled: u32 = 0;
/// Indexed by eD2ItemQuality (1=low … 8=crafted); slot 0 counts anything unrecognised.
var items_by_quality: [9]u32 = .{0} ** 9;

/// Per item-code tallies. A fixed table with a linear probe: Items.txt has ~600 codes but
/// one game touches a few dozen, and a scan of this many aligned words costs less than the
/// allocation a map would need on a path the engine calls inside a drop loop.
const CODE_SLOTS = 128;
var code_key: [CODE_SLOTS]u32 = .{0} ** CODE_SLOTS; // packed 4-char code, 0 = free
var code_hits: [CODE_SLOTS]u32 = .{0} ** CODE_SLOTS;

// live game table
// `game` is only ever touched on the engine thread; every other field is a copy so the
// health thread has nothing to dereference.

const MAX_GAMES = 32;

const Slot = struct {
    used: u32 = 0,
    game: usize = 0,
    token: u32 = 0,
    name: [16]u8 = .{0} ** 16,
    name_len: u32 = 0,
    difficulty: u32 = 0,
    clients: u32 = 0,
    frame: u32 = 0,
    created_ms: u32 = 0,
};

var slots: [MAX_GAMES]Slot = [_]Slot{.{}} ** MAX_GAMES;

fn slotOf(game: usize) ?*Slot {
    for (&slots) |*s| {
        if (s.used != 0 and s.game == game) return s;
    }
    return null;
}

// hooks

pub fn install() void {
    boot_ms = GetTickCount();
    rate_last_ms = boot_ms;
}

pub fn gameCreate(ctx: *const GameCtx) void {
    games_created +%= 1;
    const pg = @intFromPtr(ctx.game);
    if (slotOf(pg) != null) return; // already known — a second create for one game
    for (&slots) |*s| {
        if (s.used != 0) continue;
        const nm = ctx.game.name();
        const n = @min(nm.len, s.name.len);
        @memcpy(s.name[0..n], nm[0..n]);
        s.name_len = @intCast(n);
        s.game = pg;
        s.token = ctx.game.nToken;
        s.difficulty = ctx.game.nDifficulty;
        s.clients = 0;
        s.frame = 0;
        s.created_ms = GetTickCount();
        s.used = 1; // last: a reader that sees `used` sees a fully-filled slot
        return;
    }
}

pub fn gameDestroy(ctx: *const GameCtx) void {
    games_destroyed +%= 1;
    if (slotOf(@intFromPtr(ctx.game))) |s| {
        s.used = 0; // first: stop readers before the fields go stale
        s.game = 0;
    }
}

pub fn playerJoin(ctx: *const GameCtx, client: u32) void {
    _ = client;
    players_joined +%= 1;
    refresh(@intFromPtr(ctx.game));
}

pub fn playerLeave(ctx: *const GameCtx, client: u32) void {
    _ = client;
    players_left +%= 1;
    refresh(@intFromPtr(ctx.game));
}

/// An item finished generating — quality and affixes are final (see runtime/itemroll.zig).
pub fn itemRoll(ctx: *const GameCtx, item: *anyopaque) void {
    _ = ctx;
    items_rolled +%= 1;
    const u: *const t.UnitAny = @ptrCast(@alignCast(item));
    if (u.dwType != @intFromEnum(t.UnitType.item)) return;
    if (u.pUnitData) |pd| {
        const q = @as(*const t.ItemData, @ptrCast(@alignCast(pd))).dwQuality;
        items_by_quality[if (q < items_by_quality.len) q else 0] +%= 1;
    }
    countCode(u.dwTxtFileNo);
}

/// Tally the item's Items.txt code (szCode @0x80 of the record, e.g. "hp1"/"rin").
fn countCode(class_id: u32) void {
    const rec = fns.GetItemText.call(class_id) orelse return;
    const key = @as(*align(1) const u32, @ptrFromInt(@intFromPtr(rec) + 0x80)).*;
    if (key == 0) return;
    var free: ?usize = null;
    for (code_key, 0..) |k, i| {
        if (k == key) {
            code_hits[i] +%= 1;
            return;
        }
        if (k == 0 and free == null) free = i;
    }
    const i = free orelse return; // table full — the tail of a long session goes untallied
    code_hits[i] = 1;
    code_key[i] = key; // last, so a reader never sees a key with a zero count
}

/// Refresh one game's copied scalars from the live engine struct. Engine thread only.
fn refresh(pg: usize) void {
    const s = slotOf(pg) orelse return;
    s.clients = readU32(pg, GAME_CLIENTS);
    s.frame = readU32(pg, GAME_FRAME);
}

/// Sampling every tick would read 32 games' worth of engine memory at ~100 Hz for numbers
/// nobody looks at that often; once a second is plenty for a dashboard.
const REFRESH_EVERY: u32 = 100;

pub fn serverTick() void {
    ticks +%= 1;
    if (ticks % REFRESH_EVERY != 0) return;
    for (&slots) |*s| {
        if (s.used == 0 or s.game == 0) continue;
        s.clients = readU32(s.game, GAME_CLIENTS);
        s.frame = readU32(s.game, GAME_FRAME);
    }
    const now = GetTickCount();
    const dt = now -% rate_last_ms;
    if (dt >= 1000) {
        const dticks = ticks -% rate_last_ticks;
        tick_rate_x100 = @intCast((@as(u64, dticks) * 100_000) / dt);
        rate_last_ms = now;
        rate_last_ticks = ticks;
    }
}

// rendering (reader's thread, reader's buffer, no allocation)

/// eD2ItemQuality names, indexed the way the engine numbers them.
const quality_name = [9][]const u8{
    "unknown", "low", "normal", "superior", "magic", "set", "rare", "unique", "crafted",
};

fn uptimeMs() u32 {
    return GetTickCount() -% boot_ms;
}

fn liveGames() u32 {
    var n: u32 = 0;
    for (slots) |s| {
        if (s.used != 0) n += 1;
    }
    return n;
}

fn playersInGame() u32 {
    var n: u32 = 0;
    for (slots) |s| {
        if (s.used != 0) n +%= s.clients;
    }
    return n;
}

/// Trim a packed 4-char item code to its printable prefix ("ssd " -> "ssd").
fn codeText(key: u32, out: *[4]u8) []const u8 {
    out.* = @bitCast(key);
    var n: usize = 4;
    while (n > 0 and (out[n - 1] == ' ' or out[n - 1] == 0)) : (n -= 1) {}
    return out[0..n];
}

/// Render the whole census as JSON into `buf`. Returns what was written; a buffer too
/// small truncates the OPTIONAL tail (per-game and per-code lists) rather than emitting
/// half an object, so the response always parses.
pub fn writeJson(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };
    w.put("{\"uptime_ms\":");
    w.num(uptimeMs());
    w.put(",\"ticks\":");
    w.num(ticks);
    w.put(",\"tick_rate\":");
    w.fixed2(tick_rate_x100);
    w.put(",\"tick_period_ms\":");
    // Also carried in hundredths: 100 * (1000 ms / rate), and rate is itself x100.
    w.fixed2(if (tick_rate_x100 != 0) @intCast(10_000_000 / @as(u64, tick_rate_x100)) else 0);
    w.put(",\"registered\":");
    w.put(if (d2cs.registered) "true" else "false");
    w.put(",\"games\":{\"created\":");
    w.num(games_created);
    w.put(",\"destroyed\":");
    w.num(games_destroyed);
    w.put(",\"live\":");
    w.num(liveGames());
    w.put(",\"realm_live\":");
    w.num(d2cs.liveGames());
    w.put("},\"players\":{\"joined\":");
    w.num(players_joined);
    w.put(",\"left\":");
    w.num(players_left);
    w.put(",\"in_game\":");
    w.num(playersInGame());
    w.put("},\"pools\":{\"in_use\":");
    w.num(poolstat.inUse());
    w.put(",\"free\":");
    w.num(poolstat.freeManagers());
    w.put("},\"items\":{\"rolled\":");
    w.num(items_rolled);
    w.put(",\"by_quality\":{");
    var first = true;
    for (items_by_quality, 0..) |n, q| {
        if (n == 0) continue;
        if (!first) w.put(",");
        first = false;
        w.put("\"");
        w.put(quality_name[q]);
        w.put("\":");
        w.num(n);
    }
    w.put("},\"by_code\":{");
    first = true;
    for (code_key, 0..) |k, i| {
        if (k == 0 or code_hits[i] == 0) continue;
        if (!first) w.put(",");
        first = false;
        var cb: [4]u8 = undefined;
        w.put("\"");
        w.put(codeText(k, &cb));
        w.put("\":");
        w.num(code_hits[i]);
    }
    w.put("}},\"live_games\":[");
    first = true;
    const now = GetTickCount();
    for (slots) |s| {
        if (s.used == 0) continue;
        if (!first) w.put(",");
        first = false;
        w.put("{\"token\":");
        w.num(s.token);
        w.put(",\"name\":\"");
        w.put(s.name[0..s.name_len]);
        w.put("\",\"difficulty\":");
        w.num(s.difficulty);
        w.put(",\"clients\":");
        w.num(s.clients);
        w.put(",\"frame\":");
        w.num(s.frame);
        w.put(",\"age_ms\":");
        w.num(now -% s.created_ms);
        w.put("}");
    }
    w.put("]}\n");
    return w.done();
}

/// Prometheus text exposition of the same numbers. One HELP/TYPE pair per metric family.
pub fn writeMetrics(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };
    w.metric("d2gs_uptime_seconds", "gauge", "Seconds since the stats feature installed", uptimeMs() / 1000);
    w.metric("d2gs_ticks_total", "counter", "Server ticks executed", ticks);

    w.put("# HELP d2gs_tick_rate Server ticks per second, sampled each second\n# TYPE d2gs_tick_rate gauge\nd2gs_tick_rate ");
    w.fixed2(tick_rate_x100);
    w.put("\n");

    w.metric("d2gs_ready", "gauge", "1 when this GS is registered with the realm", @intFromBool(d2cs.registered));
    w.metric("d2gs_games_created_total", "counter", "Games created on this GS", games_created);
    w.metric("d2gs_games_destroyed_total", "counter", "Games destroyed on this GS", games_destroyed);
    w.metric("d2gs_games_live", "gauge", "Games currently hosted", liveGames());
    w.metric("d2gs_players_joined_total", "counter", "Player joins seen", players_joined);
    w.metric("d2gs_players_left_total", "counter", "Player leaves seen", players_left);
    w.metric("d2gs_players_in_game", "gauge", "Clients currently in a game", playersInGame());
    w.metric("d2gs_pool_managers_in_use", "gauge", "Fog memory-pool managers held", poolstat.inUse());
    w.metric("d2gs_pool_managers_free", "gauge", "Fog memory-pool managers still available", poolstat.freeManagers());
    w.metric("d2gs_items_rolled_total", "counter", "Items generated by the engine", items_rolled);

    w.put("# HELP d2gs_items_by_quality_total Items generated, by rolled quality\n# TYPE d2gs_items_by_quality_total counter\n");
    for (items_by_quality, 0..) |n, q| {
        if (n == 0) continue;
        w.put("d2gs_items_by_quality_total{quality=\"");
        w.put(quality_name[q]);
        w.put("\"} ");
        w.num(n);
        w.put("\n");
    }
    w.put("# HELP d2gs_items_by_code_total Items generated, by Items.txt code\n# TYPE d2gs_items_by_code_total counter\n");
    for (code_key, 0..) |k, i| {
        if (k == 0 or code_hits[i] == 0) continue;
        var cb: [4]u8 = undefined;
        w.put("d2gs_items_by_code_total{code=\"");
        w.put(codeText(k, &cb));
        w.put("\"} ");
        w.num(code_hits[i]);
        w.put("\n");
    }
    w.put("# HELP d2gs_game_clients Clients in each live game\n# TYPE d2gs_game_clients gauge\n");
    for (slots) |s| {
        if (s.used == 0) continue;
        w.put("d2gs_game_clients{game=\"");
        w.put(s.name[0..s.name_len]);
        w.put("\",token=\"");
        w.num(s.token);
        w.put("\"} ");
        w.num(s.clients);
        w.put("\n");
    }
    return w.done();
}

/// Append-only writer over a caller-supplied buffer. Once full it drops the rest instead
/// of failing: the head of the document is the part that matters, and both formats are
/// written head-first (totals before the unbounded per-game/per-code lists).
const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn put(self: *Writer, s: []const u8) void {
        const room = self.buf.len - self.n;
        const k = @min(room, s.len);
        @memcpy(self.buf[self.n..][0..k], s[0..k]);
        self.n += k;
    }

    fn num(self: *Writer, v: u32) void {
        var tmp: [12]u8 = undefined;
        self.put(std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return);
    }

    /// A value carried as hundredths, printed as a decimal ("2543" -> "25.43").
    fn fixed2(self: *Writer, v: u32) void {
        var tmp: [16]u8 = undefined;
        self.put(std.fmt.bufPrint(&tmp, "{d}.{d:0>2}", .{ v / 100, v % 100 }) catch return);
    }

    fn metric(self: *Writer, name: []const u8, kind: []const u8, help: []const u8, v: u32) void {
        self.put("# HELP ");
        self.put(name);
        self.put(" ");
        self.put(help);
        self.put("\n# TYPE ");
        self.put(name);
        self.put(" ");
        self.put(kind);
        self.put("\n");
        self.put(name);
        self.put(" ");
        self.num(v);
        self.put("\n");
    }

    fn done(self: *Writer) []const u8 {
        return self.buf[0..self.n];
    }
};
