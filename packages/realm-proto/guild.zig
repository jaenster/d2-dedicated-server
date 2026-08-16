//! Guild (Guild Hall) data model — the cut Diablo II "Guild Halls" feature, reconstructed from
//! the beta/1.00 binaries (D2Common\Guilds\Guilds.cpp + D2Client\UI\GuildStone.cpp) and the
//! diablowiki Guild Halls archive. 1.14d ships ZERO guild code, so this is a clean
//! reimplementation, NOT a binary-faithful port — fields are idiomatic, not original offsets.
//!
//! Authoritative state lives in realmd (create/membership/persistence never shipped publicly —
//! it ran on Blizzard's bnet servers); GS reads it for display, client renders Steeg Stone from it.
//!
//! RE provenance (original pGuild offsets): +0x123 name buffer, +0x225 3-byte tag, +0x22a hall
//! level (0..5), +0x22c flags (0x10=dirty), +0x230 u64 treasury, +0x654 member list; pMember:
//! name[16], +0x14 rank(bits5-7)+status(bits0-3).

const std = @import("std");

/// Guild tag: the up-to-3-letter [ABC] abbreviation shown after member names.
/// 26^3 = 17576 combos (the wiki notes this as the scarcity concern). First-come.
pub const tag_len: usize = 3;
/// Guild name: shown on the Steeg Stone panel. Original buffer was 256 bytes.
pub const name_max: usize = 24;
/// Account/character name of a member (original pMember name field was 16 bytes).
pub const member_name_max: usize = 15;
/// Wiki: "no set limit ... as many as one-hundred or more." Cap for a fixed roster.
pub const max_members: usize = 128;

/// Member rank — original pMember+0x14 bits 5-7 (a 0..2 value, see GUILDS_SetMemberRank).
/// The wiki's "Guild Lieutenants" sit between member and the single Guildmaster.
pub const Rank = enum(u8) {
    member = 0,
    lieutenant = 1, // elevated authority, below the master
    guildmaster = 2, // the founder/leader; only one; controls the treasury

    pub fn canManageMembers(self: Rank) bool {
        return self != .member;
    }
    pub fn canSpendTreasury(self: Rank) bool {
        return self == .guildmaster;
    }
};

/// Guild Hall upgrade level (original pGuild+0x22a, clamped 0..5 → indexes a
/// 6-entry table). Each tier costs gold deposited into the Steeg Stone and unlocks
/// space/features. Thresholds reconstructed from the wiki ("first upgrade ~35,000
/// gold"); higher tiers were "more, no figures given" — tune freely, this is the
/// part that was never finalized.
pub const max_hall_level: u8 = 5;
pub const hall_upgrade_cost = [max_hall_level + 1]u64{
    0, // level 0 — founding (free once the char has completed the game)
    35_000, // level 1 — first upgrade (public storage chest), per the wiki
    100_000, // level 2 — more size
    250_000, // level 3 — changing tile sets
    600_000, // level 4 — in-guild bulletin board
    1_500_000, // level 5 — direct Guild Hall access from a game
};

pub const Member = struct {
    name: [member_name_max:0]u8 = std.mem.zeroes([member_name_max:0]u8),
    rank: Rank = .member,
    /// Original pMember+0x14 low nibble — kept opaque (online/away/etc.).
    status: u8 = 0,

    pub fn nameSlice(self: *const Member) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const Guild = struct {
    name: [name_max:0]u8 = std.mem.zeroes([name_max:0]u8),
    tag: [tag_len:0]u8 = std.mem.zeroes([tag_len:0]u8),
    hall_level: u8 = 0,
    /// Steeg Stone treasury — the gold pool the Guildmaster grows to upgrade the
    /// hall (original was a 64-bit value at +0x230/+0x234).
    treasury: u64 = 0,
    members: [max_members]Member = undefined,
    member_count: usize = 0,
    /// Mirrors original flag bit 0x10 — needs persisting.
    dirty: bool = false,

    pub fn nameSlice(self: *const Guild) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    pub fn tagSlice(self: *const Guild) []const u8 {
        return std.mem.sliceTo(&self.tag, 0);
    }

    /// Steeg Stone deposit (= original GUILDS_AddGoldToTreasury). Guildmaster only;
    /// adds gold and marks dirty. Returns the new treasury total.
    pub fn deposit(self: *Guild, gold: u64) u64 {
        self.treasury +|= gold;
        self.dirty = true;
        return self.treasury;
    }

    /// Gold needed to reach the next hall tier (what the panel shows next to the
    /// treasury), or null if already at max level.
    pub fn nextUpgradeCost(self: *const Guild) ?u64 {
        if (self.hall_level >= max_hall_level) return null;
        return hall_upgrade_cost[self.hall_level + 1];
    }

    /// Whether the treasury can fund the next tier.
    pub fn canUpgrade(self: *const Guild) bool {
        const cost = self.nextUpgradeCost() orelse return false;
        return self.treasury >= cost;
    }

    /// Spend the next tier's cost and bump the hall level. Returns false if it
    /// can't (max level or insufficient treasury).
    pub fn upgrade(self: *Guild) bool {
        const cost = self.nextUpgradeCost() orelse return false;
        if (self.treasury < cost) return false;
        self.treasury -= cost;
        self.hall_level += 1;
        self.dirty = true;
        return true;
    }

    pub fn memberSlice(self: *Guild) []Member {
        return self.members[0..self.member_count];
    }

    pub fn findMember(self: *Guild, name: []const u8) ?*Member {
        for (self.memberSlice()) |*m| {
            if (std.mem.eql(u8, m.nameSlice(), name)) return m;
        }
        return null;
    }

    /// Add a member (Guildmaster action). Errors if full or already present.
    pub fn addMember(self: *Guild, name: []const u8, rank: Rank) error{ Full, Duplicate, NameTooLong }!void {
        if (name.len > member_name_max) return error.NameTooLong;
        if (self.findMember(name) != null) return error.Duplicate;
        if (self.member_count >= max_members) return error.Full;
        var m = Member{ .rank = rank };
        @memcpy(m.name[0..name.len], name);
        self.members[self.member_count] = m;
        self.member_count += 1;
        self.dirty = true;
    }
};

/// Validate a proposed guild tag: 1..3 chars, letters only (the [ABC] form).
pub fn tagValid(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > tag_len) return false;
    for (tag) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

/// Client→realm guild requests — the lobby/membership ops that ran on bnet. This
/// is the wire contract realmd will implement (fresh; nothing to port here).
pub const Op = enum(u8) {
    create = 1, // found a hall (requires the char has completed the game once)
    disband = 2, // guildmaster dissolves it
    invite = 3, // guildmaster adds a member to the approved list
    kick = 4, // guildmaster removes a member
    join = 5, // a player enters their hall (server checks the approved list)
    leave = 6,
    promote = 7, // set a member's rank (member/lieutenant)
    deposit = 8, // add gold to the Steeg Stone
    upgrade = 9, // spend the treasury to raise the hall level
};

test "hall upgrade economy" {
    var g = Guild{};
    try std.testing.expect(!g.canUpgrade());
    _ = g.deposit(40_000);
    try std.testing.expectEqual(@as(?u64, 35_000), g.nextUpgradeCost());
    try std.testing.expect(g.canUpgrade());
    try std.testing.expect(g.upgrade());
    try std.testing.expectEqual(@as(u8, 1), g.hall_level);
    try std.testing.expectEqual(@as(u64, 5_000), g.treasury);
}

test "members" {
    var g = Guild{};
    try g.addMember("Guildmaster", .guildmaster);
    try g.addMember("Grunt", .member);
    try std.testing.expectError(error.Duplicate, g.addMember("Grunt", .member));
    try std.testing.expect(g.findMember("Grunt").?.rank == .member);
    try std.testing.expect(g.findMember("Guildmaster").?.rank.canSpendTreasury());
}
