//! The decisions of the Pandemonium Event, kept apart from the engine calls so they can be tested
//! on the host. `ubers.zig` gathers the facts (a census, a roll, which portals are open) and does
//! what these functions say.
//!
//! These are the rules Blizzard's realm ran and 1.14d's Game.exe had removed (see ubers.zig). A roll
//! is the boss's own seed, `Roll(n)` in [0, n); the order the rolls are taken in is part of the
//! behaviour, because each one advances the seed, so the tests pin it.
const std = @import("std");

/// The buffer AI_CountNearbyMinionsByClass @0x5DD140 fills: one count per kind of unit near the centre,
/// and `max_dist`, which it reads and does not write.
pub const Census = extern struct {
    meph: i32 = 0, // 704 Uber Mephisto
    diablo: i32 = 0, // 705 Uber Diablo
    baal: i32 = 0, // 709 Uber Baal
    max_dist: i32 = std.math.maxInt(i32),
    other: i32 = 0, // every other living monster
    pits: i32 = 0, // 711 demon hole
    baal_adds: i32 = 0, // 731..733 vampire9, wraith9, willowisp8
    pit_lords: i32 = 0, // 712 megademon6

    comptime {
        std.debug.assert(@offsetOf(Census, "max_dist") == 12);
        std.debug.assert(@sizeOf(Census) == 32);
    }
};

/// Uber Mephisto lays a skeleton every think while the rooms around his target hold fewer than 30
/// monsters with neither Diablo nor Baal among them, or fewer than 15 otherwise. `near_self` is the
/// census taken a second time, centred on him with a reach of 0, when he is alone and has a target;
/// null when it is not taken.
pub fn mephistoSpawns(around_target: Census, near_self: ?Census) bool {
    var is_alone = around_target.diablo == 0 and around_target.baal == 0;
    if (near_self) |s| is_alone = s.diablo == 0 and s.baal == 0;
    return (is_alone and around_target.other < 30) or around_target.other < 15;
}

/// Whether Mephisto takes the second census: only when the first found him alone and he has a target.
pub fn mephistoSecondCensus(around_target: Census, has_target: bool) bool {
    return has_target and around_target.diablo == 0 and around_target.baal == 0;
}

pub const Boss = enum { diablo, baal };

/// Whether a census found neither of the boss's two partners.
pub fn aloneIn(c: Census, boss: Boss) bool {
    return switch (boss) {
        .diablo => c.meph == 0 and c.baal == 0,
        .baal => c.meph == 0 and c.diablo == 0,
    };
}

/// Uber Diablo and Uber Baal count as alone with no target at all; with one, only when neither the
/// census around the target nor the second one around themselves (taken only when the first found
/// no partner) holds a partner.
pub fn alone(has_target: bool, first: Census, second: ?Census, boss: Boss) bool {
    if (!has_target) return true;
    if (!aloneIn(first, boss)) return false;
    const s = second orelse return true;
    return aloneIn(s, boss);
}

/// Whether Diablo or Baal takes the second census.
pub fn secondCensus(has_target: bool, first: Census, boss: Boss) bool {
    return has_target and aloneIn(first, boss);
}

/// Uber Diablo opens a demon hole: alone, Roll(100) <= 32 while there is at most one hole and at most
/// nine pit lords; otherwise, with no hole and fewer than four pit lords, Roll(100) < 15. A roll is
/// only taken when the conditions before it hold. The counts are always the first census's.
pub fn diabloSpawns(c: Census, is_alone: bool, roller: anytype) bool {
    if (is_alone and roller.roll(100) <= 32 and c.pits <= 1 and c.pit_lords <= 9) return true;
    if (c.pits == 0 and c.pit_lords < 4 and roller.roll(100) < 15) return true;
    return false;
}

/// Uber Baal calls a wraith or a vampire: alone, Roll(100) <= 44 while there are at most 14 of them;
/// otherwise, with fewer than 7, Roll(100) < 30.
pub fn baalSpawns(c: Census, is_alone: bool, roller: anytype) bool {
    if (is_alone and roller.roll(100) <= 44 and c.baal_adds <= 14) return true;
    if (c.baal_adds < 7 and roller.roll(100) < 30) return true;
    return false;
}

pub const MATRONS_DEN: i32 = 133;
pub const FORGOTTEN_SANDS: i32 = 134;
pub const FURNACE_OF_PAIN: i32 = 135;
pub const UBER_TRISTRAM: i32 = 136;
pub const HARROGATH: i32 = 109;
pub const HELL: u8 = 2;

/// Which mini-uber level a set of keys opens. `r` is Roll(3); it names the level tried first, and the
/// next two follow in the order Den, Sands, Furnace, wrapping round. The first one this game has not
/// opened is the one. Null when all three are open.
pub fn keyPortalLevel(r: u32, opened: [3]bool) ?i32 {
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const slot = (r + i) % 3;
        if (!opened[slot]) return MATRONS_DEN + @as(i32, @intCast(slot));
    }
    return null;
}

// tests

/// Hands out scripted rolls and records each modulus asked for.
const Script = struct {
    rolls: []const u32,
    asked: [8]u32 = undefined,
    n: usize = 0,

    fn roll(self: *Script, m: u32) u32 {
        self.asked[self.n] = m;
        defer self.n += 1;
        return self.rolls[self.n];
    }
};

test "Mephisto: 30 near him when alone, 15 with a brother" {
    try std.testing.expect(mephistoSpawns(.{ .other = 29 }, null));
    try std.testing.expect(!mephistoSpawns(.{ .other = 30 }, null));
    try std.testing.expect(mephistoSpawns(.{ .other = 14, .diablo = 1 }, null));
    try std.testing.expect(!mephistoSpawns(.{ .other = 15, .baal = 1 }, null));
}

test "Mephisto: the second census decides whether he is alone" {
    const first: Census = .{ .other = 20 };
    try std.testing.expect(mephistoSecondCensus(first, true));
    try std.testing.expect(!mephistoSecondCensus(first, false));
    try std.testing.expect(!mephistoSecondCensus(.{ .diablo = 1 }, true));
    try std.testing.expect(mephistoSpawns(first, .{ .max_dist = 0 }));
    try std.testing.expect(!mephistoSpawns(first, .{ .max_dist = 0, .baal = 1 }));
}

test "Diablo: no roll when he is not alone and a hole is open" {
    var s: Script = .{ .rolls = &.{} };
    try std.testing.expect(!diabloSpawns(.{ .pits = 1 }, false, &s));
    try std.testing.expectEqual(@as(usize, 0), s.n);
}

test "Diablo: alone, the first roll decides when it passes" {
    var s: Script = .{ .rolls = &.{32} };
    try std.testing.expect(diabloSpawns(.{}, true, &s));
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqual(@as(u32, 100), s.asked[0]);
}

test "Diablo: a failed first roll falls through to the second" {
    var s: Script = .{ .rolls = &.{ 33, 14 } };
    try std.testing.expect(diabloSpawns(.{}, true, &s));
    try std.testing.expectEqual(@as(usize, 2), s.n);

    var t: Script = .{ .rolls = &.{ 33, 15 } };
    try std.testing.expect(!diabloSpawns(.{}, true, &t));
}

test "Diablo: the first rule's roll is taken before its counts are checked" {
    var s: Script = .{ .rolls = &.{ 0, 99 } };
    try std.testing.expect(!diabloSpawns(.{ .pits = 2 }, true, &s));
    try std.testing.expectEqual(@as(usize, 1), s.n); // two holes: the second rule takes no roll
}

test "Baal: alone 44 in 100 up to 14 adds, otherwise 30 in 100 below 7" {
    var a: Script = .{ .rolls = &.{44} };
    try std.testing.expect(baalSpawns(.{ .baal_adds = 14 }, true, &a));
    var b: Script = .{ .rolls = &.{ 10, 29 } };
    try std.testing.expect(baalSpawns(.{ .baal_adds = 15 }, true, &b) == false);
    try std.testing.expectEqual(@as(usize, 1), b.n);
    var c: Script = .{ .rolls = &.{29} };
    try std.testing.expect(baalSpawns(.{ .baal_adds = 6 }, false, &c));
    var d: Script = .{ .rolls = &.{} };
    try std.testing.expect(!baalSpawns(.{ .baal_adds = 7 }, false, &d));
    try std.testing.expectEqual(@as(usize, 0), d.n);
}

test "keys: the roll picks the first level, the rest follow in order" {
    const none = [3]bool{ false, false, false };
    try std.testing.expectEqual(@as(?i32, 133), keyPortalLevel(0, none));
    try std.testing.expectEqual(@as(?i32, 134), keyPortalLevel(1, none));
    try std.testing.expectEqual(@as(?i32, 135), keyPortalLevel(2, none));
    try std.testing.expectEqual(@as(?i32, 133), keyPortalLevel(2, .{ false, false, true }));
    try std.testing.expectEqual(@as(?i32, 135), keyPortalLevel(0, .{ true, true, false }));
    try std.testing.expectEqual(@as(?i32, null), keyPortalLevel(1, .{ true, true, true }));
}

test "Diablo and Baal: alone with no target, else neither census may hold a partner" {
    try std.testing.expect(alone(false, .{ .meph = 1 }, null, .diablo));
    try std.testing.expect(!alone(true, .{ .meph = 1 }, null, .diablo));
    try std.testing.expect(alone(true, .{ .diablo = 1 }, .{}, .diablo)); // his own kind is not a partner
    try std.testing.expect(!alone(true, .{}, .{ .baal = 1 }, .diablo));
    try std.testing.expect(!alone(true, .{ .diablo = 1 }, null, .baal));
    try std.testing.expect(secondCensus(true, .{}, .baal));
    try std.testing.expect(!secondCensus(true, .{ .meph = 1 }, .baal));
    try std.testing.expect(!secondCensus(false, .{}, .baal));
}
