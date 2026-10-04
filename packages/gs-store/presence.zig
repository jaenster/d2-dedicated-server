//! Who this game server has in its games, so it can keep saying so.
//!
//! The realm learns that a player entered or left from one notice each, and a notice can be lost.
//! A lost enter leaves a seat nobody renews; a lost leave leaves a seat held for as long as the game
//! lives. So the server repeats what it knows: every `interval_ms` it names each player it still has,
//! and the realm lets go of a seat the server stopped naming.
//!
//! Pure: it holds the table and says when a pass is due. Sending is the caller's.

const std = @import("std");

pub const capacity = 128;
pub const interval_ms: u64 = 30_000;

const account_max = 32;
const name_max = 24;

pub const Entry = struct {
    used: bool = false,
    gameid: u32 = 0,
    account: [account_max]u8 = undefined,
    account_len: u8 = 0,
    char: [name_max]u8 = undefined,
    char_len: u8 = 0,
    level: u32 = 0,
    class: u32 = 0,

    pub fn accountName(e: *const Entry) []const u8 {
        return e.account[0..e.account_len];
    }
    pub fn charName(e: *const Entry) []const u8 {
        return e.char[0..e.char_len];
    }
};

pub const Table = struct {
    items: [capacity]Entry = @splat(.{}),
    last_pass: u64 = 0,
    started: bool = false,

    fn find(t: *Table, gameid: u32, char: []const u8) ?*Entry {
        for (&t.items) |*e| {
            if (e.used and e.gameid == gameid and std.mem.eql(u8, e.charName(), char)) return e;
        }
        return null;
    }

    /// A player is in `gameid`. Entering twice updates the entry. A full table drops the newcomer:
    /// the player is then simply not repeated, which is what a lost notice would have been anyway.
    pub fn enter(t: *Table, gameid: u32, account: []const u8, char: []const u8, level: u32, class: u32) void {
        if (char.len == 0 or char.len > name_max or account.len > account_max) return;
        const e = t.find(gameid, char) orelse blk: {
            for (&t.items) |*slot| if (!slot.used) break :blk slot;
            return;
        };
        e.* = .{ .used = true, .gameid = gameid, .level = level, .class = class };
        @memcpy(e.account[0..account.len], account);
        e.account_len = @intCast(account.len);
        @memcpy(e.char[0..char.len], char);
        e.char_len = @intCast(char.len);
    }

    pub fn leave(t: *Table, gameid: u32, char: []const u8) void {
        if (t.find(gameid, char)) |e| e.used = false;
    }

    pub fn dropGame(t: *Table, gameid: u32) void {
        for (&t.items) |*e| if (e.used and e.gameid == gameid) {
            e.used = false;
        };
    }

    pub fn countIn(t: *const Table, gameid: u32) u32 {
        var n: u32 = 0;
        for (&t.items) |*e| if (e.used and e.gameid == gameid) {
            n += 1;
        };
        return n;
    }

    /// Whether a pass is due at `now` (any monotonic millisecond clock). The first call starts the
    /// clock rather than firing, so a server that has just come up does not repeat at once.
    pub fn due(t: *Table, now: u64) bool {
        if (!t.started) {
            t.started = true;
            t.last_pass = now;
            return false;
        }
        if (now -% t.last_pass < interval_ms) return false;
        t.last_pass = now;
        return true;
    }
};

const testing = std.testing;

test "a player entered is counted until they leave" {
    var t = Table{};
    t.enter(1, "acct", "a", 10, 2);
    t.enter(1, "acct2", "b", 11, 3);
    t.enter(2, "acct", "a", 10, 2);
    try testing.expectEqual(@as(u32, 2), t.countIn(1));
    t.leave(1, "a");
    try testing.expectEqual(@as(u32, 1), t.countIn(1));
    try testing.expectEqual(@as(u32, 1), t.countIn(2));
}

test "entering twice is one entry" {
    var t = Table{};
    t.enter(1, "", "a", 1, 1);
    t.enter(1, "acct", "a", 2, 1);
    try testing.expectEqual(@as(u32, 1), t.countIn(1));
    try testing.expectEqualStrings("acct", t.items[0].accountName());
    try testing.expectEqual(@as(u32, 2), t.items[0].level);
}

test "a closed game takes its players with it" {
    var t = Table{};
    t.enter(1, "x", "a", 1, 1);
    t.enter(1, "x", "b", 1, 1);
    t.enter(2, "x", "c", 1, 1);
    t.dropGame(1);
    try testing.expectEqual(@as(u32, 0), t.countIn(1));
    try testing.expectEqual(@as(u32, 1), t.countIn(2));
}

test "a pass is due every interval, and not at once after start" {
    var t = Table{};
    try testing.expect(!t.due(1000));
    try testing.expect(!t.due(1000 + interval_ms - 1));
    try testing.expect(t.due(1000 + interval_ms));
    try testing.expect(!t.due(1000 + interval_ms + 1));
    try testing.expect(t.due(1000 + 2 * interval_ms));
}

test "a full table drops the newcomer and keeps the rest" {
    var t = Table{};
    var nb: [8]u8 = undefined;
    for (0..capacity) |i| {
        const nm = std.fmt.bufPrint(&nb, "p{d}", .{i}) catch unreachable;
        t.enter(1, "x", nm, 1, 1);
    }
    t.enter(1, "x", "late", 1, 1);
    try testing.expectEqual(@as(u32, capacity), t.countIn(1));
    t.leave(1, "p0");
    t.enter(1, "x", "late", 1, 1);
    try testing.expectEqual(@as(u32, capacity), t.countIn(1));
}
