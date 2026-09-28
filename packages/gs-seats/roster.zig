//! Who has actually arrived in each game this server hosts, so the realm can be told by NAME.
//!
//! The realm holds a join's character claim as pending until the game server reports that
//! character entering, and only then is a stale pending claim safe to withdraw. A server that
//! reports head counts alone never confirms anyone, so a player whose join was abandoned stays
//! locked out until the game closes. This table turns whatever a host can observe (engine
//! callbacks, or a walk of the game's client list) into the ENTER/LEAVE events that fix that.
//!
//! Engine-thread only on both hosts that use it, so it has no lock.

const std = @import("std");

pub const max_players = 8;
pub const max_games = 16;

pub const Kind = enum { enter, leave };

/// One arrival or departure. `players` is the game's count AFTER it, which is what the realm
/// overwrites its own count with.
pub const Event = struct {
    kind: Kind,
    gameid: u32,
    class: u8,
    level: u8,
    players: u32,
    name_buf: [16]u8,
    name_len: u8,

    pub fn name(e: *const Event) []const u8 {
        return e.name_buf[0..e.name_len];
    }
};

/// A character a host currently sees in a game.
pub const Seen = struct {
    name: []const u8,
    class: u8 = 0,
    level: u8 = 0,
};

const Member = struct {
    name: [16]u8 = @splat(0),
    len: u8 = 0,
    class: u8 = 0,
    level: u8 = 0,

    fn slice(m: *const Member) []const u8 {
        return m.name[0..m.len];
    }
};

const Roster = struct {
    gameid: u32 = 0,
    in_use: bool = false,
    members: [max_players]Member = @splat(.{}),
    n: u8 = 0,

    fn find(r: *const Roster, name: []const u8) ?usize {
        for (r.members[0..r.n], 0..) |*m, i| {
            if (std.ascii.eqlIgnoreCase(m.slice(), name)) return i;
        }
        return null;
    }
};

pub const Table = struct {
    games: [max_games]Roster = @splat(.{}),

    fn find(t: *Table, gameid: u32) ?*Roster {
        for (&t.games) |*g| {
            if (g.in_use and g.gameid == gameid) return g;
        }
        return null;
    }

    fn claim(t: *Table, gameid: u32) ?*Roster {
        if (t.find(gameid)) |g| return g;
        for (&t.games) |*g| {
            if (!g.in_use) {
                g.* = .{ .gameid = gameid, .in_use = true };
                return g;
            }
        }
        return null;
    }

    /// How many characters have arrived in `gameid`.
    pub fn count(t: *Table, gameid: u32) u32 {
        const g = t.find(gameid) orelse return 0;
        return g.n;
    }

    /// A character arrived. Emits ENTER once; a repeat for a character already in is ignored.
    pub fn enter(t: *Table, gameid: u32, who: Seen, ctx: anytype, emit: fn (@TypeOf(ctx), Event) void) void {
        if (who.name.len == 0 or who.name.len > 15) return;
        const g = t.claim(gameid) orelse return;
        if (g.find(who.name) != null or g.n == max_players) return;
        var m = Member{ .len = @intCast(who.name.len), .class = who.class, .level = who.level };
        @memcpy(m.name[0..who.name.len], who.name);
        g.members[g.n] = m;
        g.n += 1;
        emit(ctx, event(.enter, gameid, &m, g.n));
    }

    /// A character left. Emitted even for one that never arrived: the realm still holds its join
    /// claim, and a LEAVE is what releases that at once instead of after the pending grace.
    pub fn leave(t: *Table, gameid: u32, who: Seen, ctx: anytype, emit: fn (@TypeOf(ctx), Event) void) void {
        if (who.name.len == 0 or who.name.len > 15) return;
        var m = Member{ .len = @intCast(who.name.len), .class = who.class, .level = who.level };
        @memcpy(m.name[0..who.name.len], who.name);
        const g = t.find(gameid) orelse {
            emit(ctx, event(.leave, gameid, &m, 0));
            return;
        };
        if (g.find(who.name)) |i| {
            m = g.members[i];
            g.members[i] = g.members[g.n - 1];
            g.n -= 1;
        }
        emit(ctx, event(.leave, gameid, &m, g.n));
    }

    /// Bring `gameid` in line with what the host sees in it now: LEAVE for everyone gone first,
    /// then ENTER for everyone new, so the count in each event is one the game really had.
    pub fn reconcile(t: *Table, gameid: u32, seen: []const Seen, ctx: anytype, emit: fn (@TypeOf(ctx), Event) void) void {
        if (t.find(gameid)) |g| {
            var i: usize = 0;
            while (i < g.n) {
                const still = for (seen) |s| {
                    if (std.ascii.eqlIgnoreCase(s.name, g.members[i].slice())) break true;
                } else false;
                if (still) {
                    i += 1;
                    continue;
                }
                const m = g.members[i];
                g.members[i] = g.members[g.n - 1];
                g.n -= 1;
                emit(ctx, event(.leave, gameid, &m, g.n));
            }
        }
        for (seen) |s| t.enter(gameid, s, ctx, emit);
    }

    /// The game is over: LEAVE for everyone still in it, and forget it.
    pub fn close(t: *Table, gameid: u32, ctx: anytype, emit: fn (@TypeOf(ctx), Event) void) void {
        const g = t.find(gameid) orelse return;
        while (g.n > 0) {
            g.n -= 1;
            emit(ctx, event(.leave, gameid, &g.members[g.n], g.n));
        }
        g.* = .{};
    }
};

fn event(kind: Kind, gameid: u32, m: *const Member, players: u32) Event {
    return .{
        .kind = kind,
        .gameid = gameid,
        .class = m.class,
        .level = m.level,
        .players = players,
        .name_buf = m.name,
        .name_len = m.len,
    };
}

const Log = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn add(l: *Log, e: Event) void {
        const s = std.fmt.bufPrint(l.buf[l.len..], "{s} {d} {s} L{d} C{d} n={d}\n", .{
            @tagName(e.kind), e.gameid, e.name(), e.level, e.class, e.players,
        }) catch unreachable;
        l.len += s.len;
    }

    fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }
};

test "an arrival is reported once, a departure with the count after it" {
    var t = Table{};
    var log = Log{};
    t.enter(5, .{ .name = "Bob", .class = 1, .level = 12 }, &log, Log.add);
    t.enter(5, .{ .name = "bob", .class = 1, .level = 12 }, &log, Log.add);
    t.enter(5, .{ .name = "Amy", .class = 3, .level = 40 }, &log, Log.add);
    t.leave(5, .{ .name = "BOB" }, &log, Log.add);
    try std.testing.expectEqualStrings(
        \\enter 5 Bob L12 C1 n=1
        \\enter 5 Amy L40 C3 n=2
        \\leave 5 Bob L12 C1 n=1
        \\
    , log.text());
    try std.testing.expectEqual(@as(u32, 1), t.count(5));
}

test "a character that never arrived still gets its LEAVE, and the count does not move" {
    var t = Table{};
    var log = Log{};
    t.enter(5, .{ .name = "Amy" }, &log, Log.add);
    t.leave(5, .{ .name = "Ghost", .class = 2 }, &log, Log.add);
    t.leave(9, .{ .name = "Nobody" }, &log, Log.add);
    try std.testing.expectEqualStrings(
        \\enter 5 Amy L0 C0 n=1
        \\leave 5 Ghost L0 C2 n=1
        \\leave 9 Nobody L0 C0 n=0
        \\
    , log.text());
}

test "a snapshot of the game becomes leaves first, then enters" {
    var t = Table{};
    var log = Log{};
    t.reconcile(3, &.{ .{ .name = "Amy", .level = 5 }, .{ .name = "Bob", .level = 7 } }, &log, Log.add);
    t.reconcile(3, &.{ .{ .name = "Bob", .level = 7 }, .{ .name = "Cid", .level = 9 } }, &log, Log.add);
    t.reconcile(3, &.{ .{ .name = "Bob", .level = 7 }, .{ .name = "Cid", .level = 9 } }, &log, Log.add);
    t.reconcile(3, &.{}, &log, Log.add);
    try std.testing.expectEqualStrings(
        \\enter 3 Amy L5 C0 n=1
        \\enter 3 Bob L7 C0 n=2
        \\leave 3 Amy L5 C0 n=1
        \\enter 3 Cid L9 C0 n=2
        \\leave 3 Bob L7 C0 n=1
        \\leave 3 Cid L9 C0 n=0
        \\
    , log.text());
}

test "closing a game releases everyone still in it and frees its slot" {
    var t = Table{};
    var log = Log{};
    t.enter(1, .{ .name = "Amy" }, &log, Log.add);
    t.enter(1, .{ .name = "Bob" }, &log, Log.add);
    t.enter(2, .{ .name = "Cid" }, &log, Log.add);
    t.close(1, &log, Log.add);
    t.close(1, &log, Log.add);
    try std.testing.expectEqualStrings(
        \\enter 1 Amy L0 C0 n=1
        \\enter 1 Bob L0 C0 n=2
        \\enter 2 Cid L0 C0 n=1
        \\leave 1 Bob L0 C0 n=1
        \\leave 1 Amy L0 C0 n=0
        \\
    , log.text());
    try std.testing.expectEqual(@as(u32, 0), t.count(1));
    try std.testing.expectEqual(@as(u32, 1), t.count(2));
}

test "names D2 cannot have are ignored rather than truncated into someone else's" {
    var t = Table{};
    var log = Log{};
    t.enter(1, .{ .name = "" }, &log, Log.add);
    t.enter(1, .{ .name = "ABCDEFGHIJKLMNOP" }, &log, Log.add);
    t.leave(1, .{ .name = "" }, &log, Log.add);
    try std.testing.expectEqualStrings("", log.text());
}

test "a full game takes no ninth player" {
    var t = Table{};
    var log = Log{};
    const names = [_][]const u8{ "Aa", "Bb", "Cc", "Dd", "Ee", "Ff", "Gg", "Hh", "Ii" };
    for (names) |n| t.enter(1, .{ .name = n }, &log, Log.add);
    try std.testing.expectEqual(@as(u32, max_players), t.count(1));
}
