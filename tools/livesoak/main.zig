//! livesoak — the join and game lifecycle against a RUNNING realm and a REAL game server.
//!
//! tools/e2e proves the realm's bookkeeping against a FakeGS that says whatever the scenario needs.
//! This drives the same paths through a real engine, where the timing and the events are the
//! engine's own: which of them the server reports, in what order, and what a player sees when one
//! never comes.
//!
//!   livesoak abandon <silent|drop|noconnect> [--retry other|same|relogin] [--watch <sec>]
//!       Three characters seated in one game, and a fourth whose join is authorised but never
//!       completes: GAMELOGON then silence, GAMELOGON then a hang-up, or no connection at all.
//!       Reports the list count over time, whether the fourth can play elsewhere, and whether the
//!       three seated players noticed anything.
//!   livesoak newchar
//!       Create a character and create+join a game as it straight away, with no CHARLOGON between.
//!   livesoak fill [--clients N]
//!       N clients into ONE game. The engine seats eight; the ninth must be told, not left hanging.
//!   livesoak cap [--clients N] [--hold <sec>]
//!       N clients each create their own game at once and hold it: the per-server game ceiling.
//!   livesoak soak [--clients N] [--runs R] [--dwell <ms>] [--same-game]
//!       N logins each playing R games back to back on one realm connection.
//!   livesoak hold [--clients N] [--hold <sec>] [--recover <sec>]
//!       N clients in the world for <sec>, reporting when and how each session ended; then each
//!       retries until it plays again or <recover> runs out. For killing things mid-game.
//!
//! Every run makes fresh accounts and characters (letters only: the engine refuses a character
//! name with a digit in it, silently), so runs do not trip over each other's seats.
//! Exit status: 0 when every expectation of the scenario held, 1 otherwise.

const std = @import("std");
const rc = @import("realmclient");
const session = @import("d2-session");

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const gpa = std.heap.page_allocator;
const MAX = 32;

var gs_port: u16 = 4000;

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

var t0: i64 = 0;
fn since() f64 {
    return @as(f64, @floatFromInt(session.nowMs() - t0)) / 1000.0;
}

/// A letters-only tag unique to this run, so names never collide with an earlier run's seats.
var tag_buf: [6]u8 = undefined;
fn runTag() []const u8 {
    var v: u64 = @intCast(@mod(session.nowMs(), 26 * 26 * 26 * 26 * 26 * 26));
    for (&tag_buf) |*c| {
        c.* = 'a' + @as(u8, @intCast(v % 26));
        v /= 26;
    }
    return &tag_buf;
}

const Who = struct {
    acct_buf: [24]u8 = undefined,
    acct_len: usize = 0,
    char_buf: [16]u8 = undefined,
    char_len: usize = 0,
    class: u8 = 1,

    fn acct(self: *const Who) []const u8 {
        return self.acct_buf[0..self.acct_len];
    }
    fn char(self: *const Who) []const u8 {
        return self.char_buf[0..self.char_len];
    }
    fn make(role: []const u8, i: usize, tag: []const u8) Who {
        var w = Who{};
        const letter: u8 = 'a' + @as(u8, @intCast(i % 26));
        const a = std.fmt.bufPrint(&w.acct_buf, "ls{s}{s}{c}", .{ tag, role, letter }) catch unreachable;
        w.acct_len = a.len;
        // Character names: letters only, at most 15.
        const c = std.fmt.bufPrint(&w.char_buf, "{s}{s}{c}", .{ role, tag[0..@min(tag.len, 15 - role.len - 1)], letter }) catch unreachable;
        w.char_buf[0] = std.ascii.toUpper(w.char_buf[0]);
        w.char_len = c.len;
        return w;
    }
};

/// Log in, enter the realm, create the character if it is not there, and log on as it.
fn enter(c: *rc.RealmClient, who: *const Who) !void {
    try c.connectBnet();
    try c.auth();
    try c.login(who.acct());
    try c.enterRealm();
    try c.connectD2cs();
    if ((try c.startup()) != 0) return error.StartupRefused;
    // Existing characters are kept, as a returning player's are: 0x14 is "already there".
    const made = try c.charCreate(who.class, 0x20, who.char());
    if (made != 0 and made != 0x14) return error.CharCreateFailed;
    if ((try c.charLogon(who.char())) != 0) return error.CharLogonFailed;
}

fn listed(c: *rc.RealmClient, game: []const u8) ?u8 {
    var rows: [64]rc.GameEntry = undefined;
    var dst: [8192]u8 = undefined;
    const n = c.gameList(&rows, &dst) catch return null;
    for (rows[0..n]) |g| if (std.mem.eql(u8, g.name, game)) return g.players;
    return null;
}

fn openSession(who: *const Who, j: rc.JoinResult) !session.Session {
    var hb: [16]u8 = undefined;
    const host = std.fmt.bufPrint(&hb, "{d}.{d}.{d}.{d}", .{ j.ip[0], j.ip[1], j.ip[2], j.ip[3] }) catch unreachable;
    return session.Session.open(gpa, .{
        .host = host,
        .port = gs_port,
        .game_id = j.token,
        .game_hash = j.game_hash,
        .character = who.char(),
        .char_class = who.class,
    });
}

/// A player in the world, pumping until told to stop, and remembering how it ended.
const Seat = struct {
    who: Who,
    game: []const u8 = "",
    create: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    /// 0 not yet, 1 in the world, 2 failed to get in, 3 dropped while in the world
    state: std.atomic.Value(u8) = .init(0),
    ended_at: f64 = 0,
    why: [96]u8 = [_]u8{0} ** 96,
    realm: rc.RealmClient = .{},

    fn note(self: *Seat, comptime fmt: []const u8, args: anytype) void {
        _ = std.fmt.bufPrint(&self.why, fmt, args) catch {};
    }

    fn run(self: *Seat) void {
        enter(&self.realm, &self.who) catch |e| {
            self.note("realm: {s}", .{@errorName(e)});
            self.state.store(2, .release);
            return;
        };
        if (self.create) {
            const cg = self.realm.createGame(self.game, "soak") catch |e| {
                self.note("create: {s}", .{@errorName(e)});
                self.state.store(2, .release);
                return;
            };
            if (cg.result != 0) {
                self.note("create result 0x{x}", .{cg.result});
                self.state.store(2, .release);
                return;
            }
        }
        const j = self.realm.joinGame(self.game) catch |e| {
            self.note("join: {s}", .{@errorName(e)});
            self.state.store(2, .release);
            return;
        };
        if (j.result != 0) {
            self.note("join result 0x{x}", .{j.result});
            self.state.store(2, .release);
            return;
        }
        var s = openSession(&self.who, j) catch |e| {
            self.note("gs: {s}", .{@errorName(e)});
            self.state.store(2, .release);
            return;
        };
        defer s.deinit();
        s.waitUntilInGame(20000) catch |e| {
            if (s.refused) |r| self.note("refused: {s}", .{r.describe()}) else self.note("never entered: {s}", .{@errorName(e)});
            self.state.store(2, .release);
            return;
        };
        self.state.store(1, .release);
        while (!self.stop.load(.acquire)) {
            const t = s.pump(50) catch |e| {
                self.note("pump: {s}", .{@errorName(e)});
                break;
            };
            if (t.eof) {
                if (s.refused) |r| self.note("server ended it: {s}", .{r.describe()}) else self.note("server closed the connection", .{});
                break;
            }
        }
        if (!self.stop.load(.acquire)) {
            self.ended_at = since();
            self.state.store(3, .release);
            return;
        }
        s.leave();
    }
};

fn awaitSeated(seats: []Seat, timeout_ms: i64) bool {
    const deadline = session.nowMs() + timeout_ms;
    while (session.nowMs() < deadline) {
        var done: usize = 0;
        for (seats) |*s| if (s.state.load(.acquire) != 0) {
            done += 1;
        };
        if (done == seats.len) break;
        _ = usleep(50_000);
    }
    var ok = true;
    for (seats) |*s| if (s.state.load(.acquire) != 1) {
        ok = false;
    };
    return ok;
}

/// Play one game as an already-logged-on realm client: join, reach the world, leave.
fn playOnce(c: *rc.RealmClient, who: *const Who, game: []const u8, create: bool, dwell_ms: i64) ![]const u8 {
    if (create) {
        const cg = try c.createGame(game, "soak");
        if (cg.result != 0) return switch (cg.result) {
            0x1f => "create: name taken",
            0x20 => "create: servers down",
            else => "create: refused",
        };
    }
    const j = try c.joinGame(game);
    if (j.result != 0) return switch (j.result) {
        0x2b => "join: game full, or the character is in a game (0x2b)",
        0x2e => "join: game full (0x2e)",
        0x2a => "join: no such game (0x2a)",
        else => "join: refused",
    };
    var s = try openSession(who, j);
    defer s.deinit();
    s.waitUntilInGame(20000) catch {
        if (s.refused) |r| return r.describe();
        return "gs: never entered";
    };
    const until = session.nowMs() + dwell_ms;
    while (session.nowMs() < until) {
        const t = s.pump(50) catch break;
        if (t.eof) return "gs: dropped during dwell";
    }
    s.leave();
    return "ok";
}

// ---------------------------------------------------------------------------------------------

const Retry = enum { other, same, relogin };

fn scAbandon(mode: []const u8, retry: Retry, watch_s: u32) bool {
    const tag = runTag();
    var gname_buf: [16]u8 = undefined;
    const game = std.fmt.bufPrint(&gname_buf, "ab{s}", .{tag}) catch unreachable;
    say("==> abandon/{s} retry={s} game={s}", .{ mode, @tagName(retry), game });

    var seats: [3]Seat = undefined;
    for (&seats, 0..) |*s, i| s.* = .{ .who = Who.make("seat", i, tag), .game = game, .create = i == 0 };
    var threads: [3]std.Thread = undefined;
    threads[0] = std.Thread.spawn(.{}, Seat.run, .{&seats[0]}) catch return false;
    if (!awaitSeated(seats[0..1], 30000)) {
        say("  host never got in: {s}", .{std.mem.sliceTo(&seats[0].why, 0)});
        return false;
    }
    for (1..3) |i| threads[i] = std.Thread.spawn(.{}, Seat.run, .{&seats[i]}) catch return false;
    if (!awaitSeated(&seats, 30000)) {
        for (&seats) |*s| say("  {s}: state={d} {s}", .{ s.who.char(), s.state.load(.acquire), std.mem.sliceTo(&s.why, 0) });
        return false;
    }
    say("  [{d:.1}s] 3 seated", .{since()});

    var obs = rc.RealmClient{};
    defer obs.close();
    const obs_who = Who.make("obs", 0, tag);
    enter(&obs, &obs_who) catch |e| {
        say("  observer: {s}", .{@errorName(e)});
        return false;
    };
    var ok = true;
    // The engine reports each arrival; wait for all three before judging anything against them.
    {
        const deadline = session.nowMs() + 5000;
        while (session.nowMs() < deadline and listed(&obs, game) != 3) _ = usleep(100_000);
    }
    const before = listed(&obs, game);
    say("  list shows {?d} before the fourth joins", .{before});
    if (before != 3) ok = false;

    const late_who = Who.make("late", 0, tag);
    var late = rc.RealmClient{};
    defer late.close();
    enter(&late, &late_who) catch |e| {
        say("  late: {s}", .{@errorName(e)});
        return false;
    };
    const j = late.joinGame(game) catch |e| {
        say("  late join: {s}", .{@errorName(e)});
        return false;
    };
    say("  [{d:.1}s] late JOINGAME -> 0x{x} token={d}", .{ since(), j.result, j.token });
    if (j.result != 0) return false;

    var sess: ?session.Session = null;
    if (std.mem.eql(u8, mode, "silent") or std.mem.eql(u8, mode, "drop")) {
        sess = openSession(&late_who, j) catch |e| {
            say("  late gs: {s}", .{@errorName(e)});
            return false;
        };
        if (std.mem.eql(u8, mode, "drop")) {
            _ = usleep(300_000);
            sess.?.deinit();
            sess = null;
            say("  [{d:.1}s] late sent GAMELOGON and hung up", .{since()});
        } else say("  [{d:.1}s] late sent GAMELOGON and went silent (socket held open)", .{since()});
    } else say("  [{d:.1}s] late never dials the game server", .{since()});

    // What a player browsing the list sees while the fourth is in limbo.
    const watch_end = session.nowMs() + @as(i64, watch_s) * 1000;
    var last: ?u8 = 255;
    while (session.nowMs() < watch_end) {
        const n = listed(&obs, game);
        if (n != last) {
            say("  [{d:.1}s] list count {?d}", .{ since(), n });
            last = n;
        }
        _ = usleep(250_000);
    }
    if (sess) |*s| {
        // Did the engine ever say anything to the silent client?
        var got: usize = 0;
        var eof = false;
        const until = session.nowMs() + 200;
        while (session.nowMs() < until) {
            var pfd = session.pollfd{ .fd = s.fd, .events = session.POLLIN, .revents = 0 };
            if (session.poll(@ptrCast(&pfd), 1, 50) <= 0) continue;
            var sink: [4096]u8 = undefined;
            const r = std.c.read(s.fd, &sink, sink.len);
            if (r <= 0) {
                eof = true;
                break;
            }
            got += @intCast(r);
        }
        say("  silent client: {d} bytes pending from the GS, closed by server={}", .{ got, eof });
    }

    // The player gives up and tries again. Giving up closes the stalled connection, as the real
    // client does when its join times out; a connection that is still open is somebody playing,
    // and the game server rightly refuses a second login of the character while it lives.
    if (sess) |*s| {
        s.deinit();
        sess = null;
        _ = usleep(300_000);
    }
    var outcome: []const u8 = "";
    switch (retry) {
        .other => {
            var ob: [16]u8 = undefined;
            const own = std.fmt.bufPrint(&ob, "ow{s}", .{tag}) catch unreachable;
            outcome = playOnce(&late, &late_who, own, true, 1000) catch |e| @errorName(e);
        },
        .same => outcome = playOnce(&late, &late_who, game, false, 1000) catch |e| @errorName(e),
        .relogin => {
            // A new login may not take a pending join at once (that is what a second login of
            // the same character looks like); once the join is past the grace it is abandoned.
            late.close();
            var again = rc.RealmClient{};
            defer again.close();
            enter(&again, &late_who) catch |e| {
                say("  relogin: {s}", .{@errorName(e)});
                return false;
            };
            const deadline = session.nowMs() + 150_000;
            var attempt: u32 = 0;
            while (true) : (attempt += 1) {
                var ob: [16]u8 = undefined;
                const own = std.fmt.bufPrint(&ob, "ow{s}{d}", .{ tag, attempt % 10 }) catch unreachable;
                outcome = playOnce(&again, &late_who, own, true, 1000) catch |e| @errorName(e);
                if (attempt == 0 or std.mem.eql(u8, outcome, "ok")) say("  [{d:.1}s] relogin attempt {d} -> {s}", .{ since(), attempt, outcome });
                if (std.mem.eql(u8, outcome, "ok") or session.nowMs() > deadline) break;
                _ = usleep(5_000_000);
            }
        },
    }
    say("  [{d:.1}s] retry ({s}) -> {s}", .{ since(), @tagName(retry), outcome });
    if (!std.mem.eql(u8, outcome, "ok")) ok = false;

    // After the retry the abandoned game should list its three real players.
    {
        const deadline = session.nowMs() + 5000;
        while (session.nowMs() < deadline and listed(&obs, game) != 3) _ = usleep(100_000);
        const after = listed(&obs, game);
        say("  [{d:.1}s] list count after retry: {?d} (want 3)", .{ since(), after });
        if (after != 3) ok = false;
    }

    for (&seats) |*s| {
        const st = s.state.load(.acquire);
        if (st != 1) {
            ok = false;
            say("  SEATED PLAYER {s} lost the game at {d:.1}s: {s}", .{ s.who.char(), s.ended_at, std.mem.sliceTo(&s.why, 0) });
        }
        s.stop.store(true, .release);
    }
    for (&threads) |t| t.join();
    for (&seats) |*s| s.realm.close();
    say("==> abandon/{s}/{s}: {s}", .{ mode, @tagName(retry), if (ok) "PASS" else "FAIL" });
    return ok;
}

/// A player whose client dies in the world: no LEAVEGAME, the socket simply closes. Then the same
/// login makes a new game and plays it, as a player restarting the client would.
fn scVanish(timeout_s: u32) bool {
    const tag = runTag();
    say("==> vanish", .{});
    const who = Who.make("gone", 0, tag);
    var c = rc.RealmClient{};
    defer c.close();
    enter(&c, &who) catch |e| {
        say("  enter: {s}", .{@errorName(e)});
        return false;
    };
    var gb: [16]u8 = undefined;
    const game = std.fmt.bufPrint(&gb, "va{s}", .{tag}) catch unreachable;
    if ((c.createGame(game, "soak") catch return false).result != 0) return false;
    const j = c.joinGame(game) catch return false;
    if (j.result != 0) return false;
    var s = openSession(&who, j) catch return false;
    s.waitUntilInGame(20000) catch {
        s.deinit();
        say("  never entered", .{});
        return false;
    };
    s.deinit(); // no 0x69: the client just goes away
    say("  [{d:.1}s] in the world, then the socket closed without LEAVEGAME", .{since()});
    const deadline = session.nowMs() + @as(i64, timeout_s) * 1000;
    var attempt: u32 = 0;
    while (session.nowMs() < deadline) : (attempt += 1) {
        var ob: [16]u8 = undefined;
        const own = std.fmt.bufPrint(&ob, "vb{s}{d}", .{ tag, attempt % 10 }) catch unreachable;
        const r = playOnce(&c, &who, own, true, 500) catch |e| @errorName(e);
        say("  [{d:.1}s] play again -> {s}", .{ since(), r });
        if (std.mem.eql(u8, r, "ok")) {
            say("==> vanish: PASS", .{});
            return true;
        }
    }
    say("==> vanish: FAIL", .{});
    return false;
}

/// Play a game, leave it properly, log out, log in again and play at once. The realm frees the
/// character when the game server reports the departure, so the second login must not be told
/// the character is still in a game. Names are full length on purpose: the report carries the
/// character and the account, and a server that cut the account short matched no seat, so the
/// character stayed held.
fn scRelog() bool {
    const tag = runTag();
    say("==> relog", .{});
    var who = Who.make("relog", 0, tag);
    // As long as the realm allows: 15-letter character, 15-letter account.
    const long_char = std.fmt.bufPrint(&who.char_buf, "Relogger{s}x", .{tag}) catch unreachable;
    who.char_len = long_char.len;
    const long_acct = std.fmt.bufPrint(&who.acct_buf, "relogacct{s}", .{tag}) catch unreachable;
    who.acct_len = long_acct.len;
    var ok = true;
    for (0..2) |round| {
        var c = rc.RealmClient{};
        defer c.close();
        enter(&c, &who) catch |e| {
            say("  login {d}: {s}", .{ round, @errorName(e) });
            return false;
        };
        var gb: [16]u8 = undefined;
        const game = std.fmt.bufPrint(&gb, "rl{s}{d}", .{ tag, round }) catch unreachable;
        const r = playOnce(&c, &who, game, true, 800) catch |e| @errorName(e);
        say("  [{d:.1}s] login {d} as {s}/{s}: play -> {s}", .{ since(), round, who.acct(), who.char(), r });
        if (!std.mem.eql(u8, r, "ok")) ok = false;
        _ = usleep(300_000);
    }
    say("==> relog: {s}", .{if (ok) "PASS" else "FAIL"});
    return ok;
}

fn scNewChar() bool {
    const tag = runTag();
    say("==> newchar", .{});
    var old = Who.make("olds", 0, tag);
    var c = rc.RealmClient{};
    defer c.close();
    enter(&c, &old) catch |e| {
        say("  enter: {s}", .{@errorName(e)});
        return false;
    };
    var fresh = Who.make("fresh", 0, tag);
    fresh.acct_len = old.acct_len;
    @memcpy(fresh.acct_buf[0..old.acct_len], old.acct());
    fresh.class = 0;
    const made = c.charCreate(fresh.class, 0x20, fresh.char()) catch |e| {
        say("  create char: {s}", .{@errorName(e)});
        return false;
    };
    if (made != 0) {
        say("  create char -> 0x{x}", .{made});
        return false;
    }
    var gb: [16]u8 = undefined;
    const game = std.fmt.bufPrint(&gb, "nc{s}", .{tag}) catch unreachable;
    const out = playOnce(&c, &fresh, game, true, 1500) catch |e| @errorName(e);
    say("  create+join as the new character {s} at once -> {s}", .{ fresh.char(), out });
    // And the one before it must still be playable from the same login.
    const out2 = playOnce(&c, &fresh, game, false, 500) catch |e| @errorName(e);
    say("  rejoin the same game as {s} -> {s}", .{ fresh.char(), out2 });
    const ok = std.mem.eql(u8, out, "ok") and std.mem.eql(u8, out2, "ok");
    say("==> newchar: {s}", .{if (ok) "PASS" else "FAIL"});
    return ok;
}

fn scFill(n: usize) bool {
    const tag = runTag();
    var gb: [16]u8 = undefined;
    const game = std.fmt.bufPrint(&gb, "fl{s}", .{tag}) catch unreachable;
    say("==> fill {d} clients into {s}", .{ n, game });
    var seats: [MAX]Seat = undefined;
    var threads: [MAX]std.Thread = undefined;
    for (0..n) |i| seats[i] = .{ .who = Who.make("fill", i, tag), .game = game, .create = i == 0 };
    threads[0] = std.Thread.spawn(.{}, Seat.run, .{&seats[0]}) catch return false;
    _ = awaitSeated(seats[0..1], 30000);
    for (1..n) |i| {
        threads[i] = std.Thread.spawn(.{}, Seat.run, .{&seats[i]}) catch return false;
        // One at a time, the way a game fills: a joiner races nobody but the ones already in.
        const deadline = session.nowMs() + 25000;
        while (session.nowMs() < deadline and seats[i].state.load(.acquire) == 0) _ = usleep(50_000);
    }
    var in: usize = 0;
    for (seats[0..n]) |*s| {
        const st = s.state.load(.acquire);
        if (st == 1) in += 1;
        say("  {s}: {s} {s}", .{ s.who.char(), switch (st) {
            1 => "in the world",
            2 => "not seated:",
            3 => "dropped:",
            else => "still waiting",
        }, std.mem.sliceTo(&s.why, 0) });
    }
    var obs = rc.RealmClient{};
    defer obs.close();
    const ow = Who.make("obs", 1, tag);
    enter(&obs, &ow) catch {};
    _ = usleep(1_000_000);
    const shown = listed(&obs, game);
    say("  in the world: {d}/{d}; list shows {?d}", .{ in, n, shown });
    for (seats[0..n]) |*s| s.stop.store(true, .release);
    for (threads[0..n]) |t| t.join();
    for (seats[0..n]) |*s| s.realm.close();
    const want: usize = @min(n, 8);
    const ok = in == want and shown != null and shown.? == want;
    say("==> fill: {s}", .{if (ok) "PASS" else "FAIL"});
    return ok;
}

fn scCap(n: usize, hold_s: u32) bool {
    const tag = runTag();
    say("==> cap: {d} clients, one game each, held {d}s", .{ n, hold_s });
    var seats: [MAX]Seat = undefined;
    var threads: [MAX]std.Thread = undefined;
    var names: [MAX][16]u8 = undefined;
    for (0..n) |i| {
        const g = std.fmt.bufPrint(&names[i], "cp{s}{c}", .{ tag, 'a' + @as(u8, @intCast(i)) }) catch unreachable;
        seats[i] = .{ .who = Who.make("cap", i, tag), .game = g, .create = true };
    }
    for (0..n) |i| threads[i] = std.Thread.spawn(.{}, Seat.run, .{&seats[i]}) catch return false;
    _ = awaitSeated(seats[0..n], 40000);
    var in: usize = 0;
    for (seats[0..n]) |*s| {
        const st = s.state.load(.acquire);
        if (st == 1) in += 1 else say("  {s}: state={d} {s}", .{ s.who.char(), st, std.mem.sliceTo(&s.why, 0) });
    }
    say("  [{d:.1}s] {d}/{d} games playing", .{ since(), in, n });
    _ = usleep(hold_s * 1_000_000);
    var dropped: usize = 0;
    for (seats[0..n]) |*s| if (s.state.load(.acquire) == 3) {
        dropped += 1;
        say("  {s} DROPPED at {d:.1}s: {s}", .{ s.who.char(), s.ended_at, std.mem.sliceTo(&s.why, 0) });
    };
    for (seats[0..n]) |*s| s.stop.store(true, .release);
    for (threads[0..n]) |t| t.join();
    for (seats[0..n]) |*s| s.realm.close();
    const ok = in == @min(n, 7) and dropped == 0;
    say("==> cap: {d} playing, {d} dropped: {s}", .{ in, dropped, if (ok) "PASS" else "FAIL" });
    return ok;
}

const SoakCfg = struct { runs: u32, dwell_ms: i64, same_game: bool };
const SoakOut = struct { ok: u32 = 0, fail: u32 = 0, waits: u32 = 0 };

fn soakClient(who: Who, tag: []const u8, idx: usize, cfg: SoakCfg, out: *SoakOut) void {
    var c = rc.RealmClient{};
    defer c.close();
    enter(&c, &who) catch |e| {
        out.fail += cfg.runs;
        say("  {s}: realm {s}", .{ who.char(), @errorName(e) });
        return;
    };
    var run: u32 = 0;
    while (run < cfg.runs) : (run += 1) {
        var gb: [16]u8 = undefined;
        const game = if (cfg.same_game)
            std.fmt.bufPrint(&gb, "sg{s}{c}", .{ tag, 'a' + @as(u8, @intCast(idx)) }) catch unreachable
        else
            std.fmt.bufPrint(&gb, "sk{s}{c}{d}", .{ tag, 'a' + @as(u8, @intCast(idx)), run }) catch unreachable;
        const create = !cfg.same_game or run == 0;
        // A full server is capacity, not a fault: a finished game holds its slot for the reap
        // window. Retry the way a player would, and count only what never succeeds.
        var r: []const u8 = "";
        const give_up = session.nowMs() + 30_000;
        while (true) {
            r = playOnce(&c, &who, game, create, cfg.dwell_ms) catch |e| @errorName(e);
            if (!std.mem.eql(u8, r, "create: servers down") or session.nowMs() > give_up) break;
            out.waits += 1;
            _ = usleep(1_000_000);
        }
        if (std.mem.eql(u8, r, "ok")) {
            out.ok += 1;
        } else {
            out.fail += 1;
            say("  [{d:.1}s] {s} run {d} {s}: {s}", .{ since(), who.char(), run, game, r });
        }
    }
}

fn scSoak(n: usize, cfg: SoakCfg) bool {
    const tag = runTag();
    say("==> soak: {d} logins x {d} games, dwell {d}ms{s}", .{ n, cfg.runs, cfg.dwell_ms, if (cfg.same_game) ", same game" else "" });
    var outs: [MAX]SoakOut = [_]SoakOut{.{}} ** MAX;
    var threads: [MAX]std.Thread = undefined;
    for (0..n) |i| threads[i] = std.Thread.spawn(.{}, soakClient, .{ Who.make("soak", i, tag), tag, i, cfg, &outs[i] }) catch return false;
    for (threads[0..n]) |t| t.join();
    var ok: u32 = 0;
    var fail: u32 = 0;
    var waits: u32 = 0;
    for (outs[0..n]) |o| {
        ok += o.ok;
        fail += o.fail;
        waits += o.waits;
    }
    say("==> soak: {d} played, {d} failed, {d} waits on a full server ({d:.1}s): {s}", .{ ok, fail, waits, since(), if (fail == 0) "PASS" else "FAIL" });
    return fail == 0;
}

fn holdClient(seat: *Seat, recover_s: u32, recovered_at: *f64) void {
    seat.run();
    if (seat.state.load(.acquire) != 3) return;
    // Dropped mid-game. Keep trying to play again, as a player would, from a fresh login each time
    // (the realm connection may be what went away).
    const deadline = session.nowMs() + @as(i64, recover_s) * 1000;
    var attempt: u32 = 0;
    var last: [64]u8 = [_]u8{0} ** 64;
    while (session.nowMs() < deadline) : (attempt += 1) {
        var c = rc.RealmClient{};
        defer c.close();
        var gb: [16]u8 = undefined;
        const game = std.fmt.bufPrint(&gb, "{s}r{d}", .{ seat.game[0..@min(seat.game.len, 10)], attempt % 10 }) catch unreachable;
        const r: []const u8 = blk: {
            enter(&c, &seat.who) catch |e| break :blk @errorName(e);
            break :blk playOnce(&c, &seat.who, game, true, 500) catch |e| @errorName(e);
        };
        if (std.mem.eql(u8, r, "ok")) {
            recovered_at.* = since();
            return;
        }
        if (!std.mem.eql(u8, r, std.mem.sliceTo(&last, 0))) {
            say("  [{d:.1}s] {s} retry: {s}", .{ since(), seat.who.char(), r });
            @memset(&last, 0);
            @memcpy(last[0..@min(r.len, 63)], r[0..@min(r.len, 63)]);
        }
        _ = usleep(2_000_000);
    }
}

fn scHold(n: usize, hold_s: u32, recover_s: u32) bool {
    const tag = runTag();
    say("==> hold: {d} clients for {d}s, recover within {d}s", .{ n, hold_s, recover_s });
    var seats: [MAX]Seat = undefined;
    var threads: [MAX]std.Thread = undefined;
    var names: [MAX][16]u8 = undefined;
    var rec: [MAX]f64 = [_]f64{0} ** MAX;
    for (0..n) |i| {
        const g = std.fmt.bufPrint(&names[i], "hd{s}{c}", .{ tag, 'a' + @as(u8, @intCast(i)) }) catch unreachable;
        seats[i] = .{ .who = Who.make("hold", i, tag), .game = g, .create = true };
    }
    for (0..n) |i| threads[i] = std.Thread.spawn(.{}, holdClient, .{ &seats[i], recover_s, &rec[i] }) catch return false;
    _ = awaitSeated(seats[0..n], 40000);
    say("  [{d:.1}s] seated; holding (kill something now)", .{since()});
    const end = session.nowMs() + @as(i64, hold_s) * 1000;
    while (session.nowMs() < end) {
        var all_done = true;
        for (seats[0..n]) |*s| if (s.state.load(.acquire) == 1) {
            all_done = false;
        };
        _ = usleep(250_000);
        if (all_done) break;
    }
    for (seats[0..n]) |*s| s.stop.store(true, .release);
    for (threads[0..n]) |t| t.join();
    var ok = true;
    for (seats[0..n], 0..) |*s, i| {
        const st = s.state.load(.acquire);
        switch (st) {
            1 => say("  {s}: played through", .{s.who.char()}),
            3 => {
                if (rec[i] > 0) say("  {s}: dropped at {d:.1}s ({s}); playing again at {d:.1}s", .{ s.who.char(), s.ended_at, std.mem.sliceTo(&s.why, 0), rec[i] }) else {
                    ok = false;
                    say("  {s}: dropped at {d:.1}s ({s}); NEVER RECOVERED", .{ s.who.char(), s.ended_at, std.mem.sliceTo(&s.why, 0) });
                }
            },
            else => {
                ok = false;
                say("  {s}: never seated: {s}", .{ s.who.char(), std.mem.sliceTo(&s.why, 0) });
            },
        }
        s.realm.close();
    }
    say("==> hold: {s}", .{if (ok) "PASS" else "FAIL"});
    return ok;
}

fn num(args: []const [:0]const u8, flag: []const u8, def: u32) u32 {
    for (args, 0..) |a, i| if (std.mem.eql(u8, a, flag) and i + 1 < args.len) return std.fmt.parseInt(u32, args[i + 1], 10) catch def;
    return def;
}
fn has(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}
fn str(args: []const [:0]const u8, flag: []const u8, def: []const u8) []const u8 {
    for (args, 0..) |a, i| if (std.mem.eql(u8, a, flag) and i + 1 < args.len) return args[i + 1];
    return def;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var list: [32][:0]const u8 = undefined;
    var n: usize = 0;
    var it = std.process.Args.Iterator.init(init.args);
    while (it.next()) |a| : (n += 1) {
        if (n >= list.len) break;
        list[n] = a;
    }
    const args = list[0..n];
    if (args.len < 2) {
        say("usage: livesoak <abandon|newchar|fill|cap|soak|hold> [...]  (see the header of tools/livesoak/main.zig)", .{});
        std.process.exit(2);
    }
    if (getenv("E2E_PORT_BASE")) |b| {
        const base = std.fmt.parseInt(u16, std.mem.span(b), 10) catch 0;
        if (base != 0) rc.setPortBase(base);
    }
    gs_port = @intCast(num(args, "--gs-port", 4000));
    t0 = session.nowMs();

    const cmd = args[1];
    const ok = if (std.mem.eql(u8, cmd, "abandon")) blk: {
        const mode = if (args.len > 2) args[2] else "silent";
        const retry = std.meta.stringToEnum(Retry, str(args, "--retry", "other")) orelse .other;
        break :blk scAbandon(mode, retry, num(args, "--watch", 5));
    } else if (std.mem.eql(u8, cmd, "relog"))
        scRelog()
    else if (std.mem.eql(u8, cmd, "vanish"))
        scVanish(num(args, "--timeout", 60))
    else if (std.mem.eql(u8, cmd, "newchar"))
        scNewChar()
    else if (std.mem.eql(u8, cmd, "fill"))
        scFill(@min(num(args, "--clients", 9), MAX))
    else if (std.mem.eql(u8, cmd, "cap"))
        scCap(@min(num(args, "--clients", 8), 26), num(args, "--hold", 5))
    else if (std.mem.eql(u8, cmd, "soak"))
        scSoak(@min(num(args, "--clients", 4), 26), .{
            .runs = num(args, "--runs", 5),
            .dwell_ms = num(args, "--dwell", 1000),
            .same_game = has(args, "--same-game"),
        })
    else if (std.mem.eql(u8, cmd, "hold"))
        scHold(@min(num(args, "--clients", 3), 26), num(args, "--hold", 60), num(args, "--recover", 120))
    else {
        say("unknown scenario {s}", .{cmd});
        std.process.exit(2);
    };
    std.process.exit(if (ok) 0 else 1);
}
