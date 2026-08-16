//! Guild service — the cut Guild Halls operations against persisted Guild records, with rank-based
//! permissions. Data model + upgrade economy live in realm_proto's guild.zig; this layer adds
//! permissions + persistence. The membership/lobby half never shipped (it ran on Blizzard's bnet
//! servers), so this side is fresh, wiki-guided.
const std = @import("std");
const guild = @import("realm_proto").guild;
const store = @import("store.zig");

pub const Guild = guild.Guild;
pub const Member = guild.Member;
pub const Rank = guild.Rank;

pub const Error = error{
    NotFound, // no such guild
    Exists, // guild name (or member) already exists
    Denied, // actor lacks the rank for this op
    Full, // member roster is full
    BadName,
    BadTag,
    AtMaxLevel, // hall already level 5
    Insufficient, // treasury can't fund the next upgrade
    NotMember, // actor isn't in the guild
    IoError, // persistence failed
};

// On-disk blob: 4-byte magic/version ++ raw Guild bytes. Round-trips within a
// realmd build; the magic guards against reading a stale/foreign blob. (A struct
// layout change across rebuilds invalidates old files — acceptable for now.)
const magic = [4]u8{ 'G', 'L', 'D', '1' };
const blob_len = magic.len + @sizeOf(Guild);

fn serialize(g: *const Guild, buf: *[blob_len]u8) void {
    @memcpy(buf[0..4], &magic);
    @memcpy(buf[4..], std.mem.asBytes(g));
}

fn deserialize(bytes: []const u8) ?Guild {
    if (bytes.len != blob_len) return null;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return null;
    var g: Guild = undefined;
    @memcpy(std.mem.asBytes(&g), bytes[4..]);
    return g;
}

/// Load a guild by name from the store, or null if absent/corrupt.
pub fn load(name: []const u8) ?Guild {
    var buf: [blob_len]u8 = undefined;
    const n = store.getGuild(name, &buf);
    if (n == 0) return null;
    return deserialize(buf[0..n]);
}

/// Persist a guild (keyed by its name).
pub fn save(g: *const Guild) Error!void {
    var buf: [blob_len]u8 = undefined;
    serialize(g, &buf);
    if (!store.saveGuild(g.nameSlice(), &buf)) return error.IoError;
}

fn requireRank(g: *Guild, actor: []const u8, min: Rank) Error!*Member {
    const m = g.findMember(actor) orelse return error.NotMember;
    if (@intFromEnum(m.rank) < @intFromEnum(min)) return error.Denied;
    return m;
}

fn removeMember(g: *Guild, who: []const u8) bool {
    var i: usize = 0;
    while (i < g.member_count) : (i += 1) {
        if (std.mem.eql(u8, g.members[i].nameSlice(), who)) {
            var j = i;
            while (j + 1 < g.member_count) : (j += 1) g.members[j] = g.members[j + 1];
            g.member_count -= 1;
            g.dirty = true;
            return true;
        }
    }
    return false;
}

// operations

/// Found a guild. `actor` becomes the Guildmaster. (The wiki's "char must have
/// completed the game once" gate is the caller's to enforce.)
pub fn create(actor: []const u8, tag: []const u8, name: []const u8) Error!void {
    if (!guild.tagValid(tag)) return error.BadTag;
    if (name.len == 0 or name.len > guild.name_max) return error.BadName;
    if (actor.len == 0 or actor.len > guild.member_name_max) return error.BadName;
    if (load(name) != null) return error.Exists;
    var g = Guild{};
    @memcpy(g.name[0..name.len], name);
    @memcpy(g.tag[0..tag.len], tag);
    g.addMember(actor, .guildmaster) catch return error.Full;
    try save(&g);
}

/// Steeg Stone deposit — Guildmaster only. Returns the new treasury total.
pub fn deposit(actor: []const u8, name: []const u8, gold: u64) Error!u64 {
    var g = load(name) orelse return error.NotFound;
    _ = try requireRank(&g, actor, .guildmaster);
    const total = g.deposit(gold);
    try save(&g);
    return total;
}

/// Spend the treasury to raise the Guild Hall level. Returns the new level.
pub fn upgrade(actor: []const u8, name: []const u8) Error!u8 {
    var g = load(name) orelse return error.NotFound;
    _ = try requireRank(&g, actor, .guildmaster);
    if (g.hall_level >= guild.max_hall_level) return error.AtMaxLevel;
    if (!g.upgrade()) return error.Insufficient;
    try save(&g);
    return g.hall_level;
}

/// Add a member to the approved list — Guildmaster or Lieutenant.
pub fn invite(actor: []const u8, name: []const u8, who: []const u8) Error!void {
    var g = load(name) orelse return error.NotFound;
    _ = try requireRank(&g, actor, .lieutenant);
    g.addMember(who, .member) catch |e| return switch (e) {
        error.Full => error.Full,
        error.Duplicate => error.Exists,
        error.NameTooLong => error.BadName,
    };
    try save(&g);
}

/// Remove a member — Guildmaster or Lieutenant; can't kick the Guildmaster.
pub fn kick(actor: []const u8, name: []const u8, who: []const u8) Error!void {
    var g = load(name) orelse return error.NotFound;
    _ = try requireRank(&g, actor, .lieutenant);
    const target = g.findMember(who) orelse return error.NotMember;
    if (target.rank == .guildmaster) return error.Denied;
    _ = removeMember(&g, who);
    try save(&g);
}

/// Set a member's rank (member ↔ lieutenant) — Guildmaster only. Can't change
/// the Guildmaster's own rank here.
pub fn promote(actor: []const u8, name: []const u8, who: []const u8, rank: Rank) Error!void {
    if (rank == .guildmaster) return error.Denied; // transfer is a separate op
    var g = load(name) orelse return error.NotFound;
    _ = try requireRank(&g, actor, .guildmaster);
    const target = g.findMember(who) orelse return error.NotMember;
    if (target.rank == .guildmaster) return error.Denied;
    target.rank = rank;
    g.dirty = true;
    try save(&g);
}

/// Dissolve the guild — Guildmaster only.
pub fn disband(actor: []const u8, name: []const u8) Error!void {
    var g = load(name) orelse return error.NotFound;
    _ = try requireRank(&g, actor, .guildmaster);
    if (!store.deleteGuild(name)) return error.IoError;
}

/// Find the name of the guild the actor belongs to (scans the store; a player is
/// in at most one guild). Writes the name into `out`, returns the slice, or null.
pub fn guildNameOf(actor: []const u8, out: []u8) ?[]const u8 {
    var names: [128]store.Name = undefined;
    const n = store.listGuilds(&names);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var g = load(names[i].slice()) orelse continue;
        if (g.findMember(actor) != null) {
            const name = g.nameSlice();
            if (name.len > out.len) return null;
            @memcpy(out[0..name.len], name);
            return out[0..name.len];
        }
    }
    return null;
}

/// The guild tag for the account's guild, written into `out`, or "" if they're in
/// no guild. Used by the d2cs JOINGAME path to tell the GS a joining player's guild.
pub fn tagOf(account: []const u8, out: []u8) []const u8 {
    var nb: [guild.name_max]u8 = undefined;
    const gname = guildNameOf(account, &nb) orelse return "";
    var g = load(gname) orelse return "";
    const t = g.tagSlice();
    if (t.len > out.len) return "";
    @memcpy(out[0..t.len], t);
    return out[0..t.len];
}

test "guild blob round-trips" {
    var g = Guild{};
    @memcpy(g.name[0.."Honor Guard".len], "Honor Guard");
    @memcpy(g.tag[0..3], "HON");
    try g.addMember("Leader", .guildmaster);
    try g.addMember("Sidekick", .lieutenant);
    _ = g.deposit(123_456);
    g.hall_level = 3;

    var buf: [blob_len]u8 = undefined;
    serialize(&g, &buf);
    var g2 = deserialize(&buf) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("Honor Guard", g2.nameSlice());
    try std.testing.expectEqualStrings("HON", g2.tagSlice());
    try std.testing.expectEqual(@as(u64, 123_456), g2.treasury);
    try std.testing.expectEqual(@as(u8, 3), g2.hall_level);
    try std.testing.expectEqual(@as(usize, 2), g2.member_count);
    try std.testing.expect(g2.findMember("Sidekick").?.rank == .lieutenant);
}

test "deserialize rejects junk" {
    try std.testing.expect(deserialize("nope") == null);
    var buf: [blob_len]u8 = std.mem.zeroes([blob_len]u8);
    try std.testing.expect(deserialize(&buf) == null); // bad magic
}
