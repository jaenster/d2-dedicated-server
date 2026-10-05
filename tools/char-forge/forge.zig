//! char-forge: a .d2s of a given class and level, written the way the engine would have saved a
//! character that earned them.
//!
//! The realm creates a character as the 335-byte header alone and leaves the engine to fill the rest in on
//! first play, so nothing here writes the stats section yet. This does, with libd2's d2-save (the same
//! sections reader the rest of the repo decodes saves with), so a character can arrive past level 1.
//!
//! Every number comes from the game's own tables, handed in as the text of experience.txt and charstats.txt:
//!   - experience is the row for the level in experience.txt. Row N is what it takes to REACH level N+1, so
//!     level L starts at row L-1 (the file has a row 0 for the level-1 start);
//!   - the base stats, starting life and stamina are charstats.txt (starting life is vit + hpadd, mana is energy);
//!   - each level gives LifePerLevel / StaminaPerLevel / ManaPerLevel quarters ("in fourths", per the file's own
//!     comment), kept in the save's 8.8 fixed point so a half point is not rounded away, and StatPerLevel stat
//!     points plus one skill point, all left unspent.
//!
//! The body (quests, waypoints, NPC intros) is copied from a character the engine itself wrote (fresh.d2s, a
//! level-1 save), so what is not a stat is the engine's own. The items are an empty list: libd2 has no item writer.
const std = @import("std");
const libd2 = @import("libd2");
const save = libd2.save;
const d2s = libd2.formats.d2s;
const realm_d2s = @import("realm_d2s");

pub const fresh = @embedFile("fresh.d2s");

pub const class_names = [_][]const u8{ "Amazon", "Sorceress", "Necromancer", "Paladin", "Barbarian", "Druid", "Assassin" };

pub const Error = error{
    BadClass,
    BadLevel,
    BadName,
    BadTable,
    /// The class starts with a skill the header must name as its right-hand skill; this writer has no skill table.
    ClassHasStartSkill,
    BufferTooSmall,
};

pub const Spec = struct {
    name: []const u8,
    class: u8,
    level: u8,
    hardcore: bool,
    expansion: bool,
    created: u32,
};

/// A row of a tab-separated game table, looked up by column name.
const Table = struct {
    header: []const u8,
    body: []const u8,

    fn init(src: []const u8) Table {
        const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
        return .{ .header = std.mem.trimEnd(u8, src[0..nl], "\r"), .body = if (nl < src.len) src[nl + 1 ..] else "" };
    }

    fn column(self: Table, name: []const u8) ?usize {
        var it = std.mem.splitScalar(u8, self.header, '\t');
        var i: usize = 0;
        while (it.next()) |c| : (i += 1) if (std.mem.eql(u8, c, name)) return i;
        return null;
    }

    fn cell(line: []const u8, col: usize) ?[]const u8 {
        var it = std.mem.splitScalar(u8, line, '\t');
        var i: usize = 0;
        while (it.next()) |c| : (i += 1) if (i == col) return std.mem.trimEnd(u8, c, "\r");
        return null;
    }

    /// The line whose first cell is `key`.
    fn row(self: Table, key: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, self.body, '\n');
        while (lines.next()) |line| {
            const first = cell(line, 0) orelse continue;
            if (std.mem.eql(u8, first, key)) return line;
        }
        return null;
    }

    fn number(self: Table, key: []const u8, col_name: []const u8) Error!u64 {
        const c = self.column(col_name) orelse return error.BadTable;
        const line = self.row(key) orelse return error.BadTable;
        const text = cell(line, c) orelse return error.BadTable;
        return std.fmt.parseInt(u64, text, 10) catch error.BadTable;
    }

    fn textOf(self: Table, key: []const u8, col_name: []const u8) Error![]const u8 {
        const c = self.column(col_name) orelse return error.BadTable;
        const line = self.row(key) orelse return error.BadTable;
        return cell(line, c) orelse error.BadTable;
    }
};

/// What a class is at a level, in the units the save stores: whole stats, and life/mana/stamina in 8.8.
pub const Stats = struct {
    strength: u32,
    dexterity: u32,
    energy: u32,
    vitality: u32,
    stat_points: u32,
    skill_points: u32,
    life: u32,
    mana: u32,
    stamina: u32,
    experience: u32,
};

pub fn stats(experience_txt: []const u8, charstats_txt: []const u8, class: u8, level: u8) Error!Stats {
    if (class >= class_names.len) return error.BadClass;
    if (level < 1 or level > 99) return error.BadLevel;
    const name = class_names[class];
    const cs = Table.init(charstats_txt);
    const xp = Table.init(experience_txt);

    const gained: u64 = level - 1;
    const vit = try cs.number(name, "vit");
    const energy = try cs.number(name, "int");
    const life = ((vit + try cs.number(name, "hpadd")) << 8) + gained * try cs.number(name, "LifePerLevel") * 64;
    const mana = (energy << 8) + gained * try cs.number(name, "ManaPerLevel") * 64;
    const stamina = ((try cs.number(name, "stamina")) << 8) + gained * try cs.number(name, "StaminaPerLevel") * 64;

    var level_key: [4]u8 = undefined;
    const key = std.fmt.bufPrint(&level_key, "{d}", .{level - 1}) catch unreachable;
    const exp = try xp.number(key, name);

    return .{
        .strength = @intCast(try cs.number(name, "str")),
        .dexterity = @intCast(try cs.number(name, "dex")),
        .energy = @intCast(energy),
        .vitality = @intCast(vit),
        .stat_points = @intCast(gained * try cs.number(name, "StatPerLevel")),
        .skill_points = @intCast(gained),
        .life = @intCast(life),
        .mana = @intCast(mana),
        .stamina = @intCast(stamina),
        .experience = @intCast(exp),
    };
}

/// The player's item list, empty, then the corpse list, empty. An expansion character carries the mercenary
/// ("jf") and iron golem ("kf") blocks after those, both empty.
fn emptyItems(expansion: bool) []const u8 {
    return if (expansion) "JM\x00\x00JM\x00\x00jfkf\x00" else "JM\x00\x00JM\x00\x00";
}

/// Write the save into `out`; returns the slice written.
pub fn forge(out: []u8, experience_txt: []const u8, charstats_txt: []const u8, spec: Spec) Error![]u8 {
    if (spec.name.len == 0 or spec.name.len > d2s.name_max) return error.BadName;
    const st = try stats(experience_txt, charstats_txt, spec.class, spec.level);
    const start = try Table.init(charstats_txt).textOf(class_names[spec.class], "StartSkill");
    if (start.len != 0) return error.ClassHasStartSkill;

    var s = save.parse(fresh) catch unreachable; // the embedded save is checked by a test
    const h = &s.header;
    h.name = [_]u8{0} ** 16;
    @memcpy(h.name[0..spec.name.len], spec.name);
    // The same status byte the realm's own character creation writes: mandatory bit, plus hardcore and expansion.
    h.status = 0x01 | (if (spec.hardcore) @as(u8, 0x04) else 0) | (if (spec.expansion or spec.class >= 5) @as(u8, 0x20) else 0);
    h.class = spec.class;
    h.level = spec.level;
    h.created = spec.created;
    h.last_played = spec.created;
    // No start skill for these classes, so the skills a fresh engine-written header names are the sorceress's own.
    h.left_skill = 0;
    h.right_skill = 0;
    h.alt_left_skill = 0;
    h.alt_right_skill = 0;

    var a = save.attributes.Section{};
    a.setRaw(0, st.strength);
    a.setRaw(1, st.energy);
    a.setRaw(2, st.dexterity);
    a.setRaw(3, st.vitality);
    a.setRaw(4, st.stat_points);
    a.setRaw(5, st.skill_points);
    a.setRaw(6, st.life);
    a.setRaw(7, st.life);
    a.setRaw(8, st.mana);
    a.setRaw(9, st.mana);
    a.setRaw(10, st.stamina);
    a.setRaw(11, st.stamina);
    a.setRaw(12, spec.level);
    a.setRaw(13, st.experience);
    s.attributes = a;
    s.skills = .{}; // nothing spent
    s.items = .{ .bytes = emptyItems(h.status & 0x20 != 0) };

    return s.writeInto(out) catch error.BufferTooSmall;
}

// A trimmed copy of the game's tables: the rows this test names, with the real values.
const t_experience =
    "Level\tAmazon\tSorceress\tNecromancer\tPaladin\tBarbarian\tDruid\tAssassin\tExpRatio\r\n" ++
    "MaxLvl\t99\t99\t99\t99\t99\t99\t99\t10\r\n" ++
    "0\t0\t0\t0\t0\t0\t0\t0\t1024\r\n" ++
    "1\t500\t500\t500\t500\t500\t500\t500\t1024\r\n" ++
    "7\t32886\t32886\t32886\t32886\t32886\t32886\t32886\t1024\r\n" ++
    "8\t44396\t44396\t44396\t44396\t44396\t44396\t44396\t1024\r\n" ++
    "9\t57715\t57715\t57715\t57715\t57715\t57715\t57715\t1024\r\n";

const t_charstats =
    "class\tstr\tdex\tint\tvit\ttot\tstamina\thpadd\tLifePerLevel\tStaminaPerLevel\tManaPerLevel\tStatPerLevel\tStartSkill\r\n" ++
    "Sorceress\t10\t25\t35\t10\t80\t74\t30\t4\t4\t8\t5\tfire bolt\r\n" ++
    "Paladin\t25\t20\t15\t25\t85\t89\t30\t8\t4\t6\t5\t\r\n" ++
    "Barbarian\t30\t20\t10\t25\t85\t92\t30\t8\t4\t4\t5\t\r\n";

test "the embedded fresh save is a valid engine save the sections reader takes" {
    try std.testing.expect(d2s.verifyChecksum(fresh));
    const s = try save.parse(fresh);
    try std.testing.expectEqual(@as(u8, 1), s.header.level);
    // what a level-1 sorceress is, so the stats() numbers can be checked against the engine's own
    const a = s.attributes.attributes();
    try std.testing.expectEqual(@as(u32, 10), a.strength);
    try std.testing.expectEqual(@as(u32, 40), a.maxhp);
    try std.testing.expectEqual(@as(u32, 35), a.maxmana);
    try std.testing.expectEqual(@as(u32, 74), a.maxstamina);
}

test "stats of a level-1 sorceress are exactly what the engine saved" {
    const eng = (try save.parse(fresh)).attributes;
    const st = try stats(t_experience, t_charstats, 1, 1);
    try std.testing.expectEqual(eng.raw(0), st.strength);
    try std.testing.expectEqual(eng.raw(1), st.energy);
    try std.testing.expectEqual(eng.raw(2), st.dexterity);
    try std.testing.expectEqual(eng.raw(3), st.vitality);
    try std.testing.expectEqual(eng.raw(7), st.life);
    try std.testing.expectEqual(eng.raw(9), st.mana);
    try std.testing.expectEqual(eng.raw(11), st.stamina);
    try std.testing.expectEqual(eng.raw(13), st.experience);
}

test "level 9 stats come from the tables: 8 levels of gains, the level-9 experience row" {
    const pal = try stats(t_experience, t_charstats, 3, 9);
    try std.testing.expectEqual(@as(u32, 44396), pal.experience);
    try std.testing.expectEqual(@as(u32, 40), pal.stat_points);
    try std.testing.expectEqual(@as(u32, 8), pal.skill_points);
    try std.testing.expectEqual(@as(u32, (55 + 16) << 8), pal.life); // 8 x 8/4
    try std.testing.expectEqual(@as(u32, (15 + 12) << 8), pal.mana); // 8 x 6/4
    try std.testing.expectEqual(@as(u32, (89 + 8) << 8), pal.stamina); // 8 x 4/4
    const bar = try stats(t_experience, t_charstats, 4, 9);
    try std.testing.expectEqual(@as(u32, (10 + 8) << 8), bar.mana); // 8 x 4/4
    try std.testing.expectEqual(@as(u32, (92 + 8) << 8), bar.stamina);
}

test "a forged level-9 hardcore expansion save reads back as written, by two readers" {
    var buf: [1024]u8 = undefined;
    const out = try forge(&buf, t_experience, t_charstats, .{ .name = "PwnMeHC", .class = 3, .level = 9, .hardcore = true, .expansion = true, .created = 1_700_000_000 });

    // the whole-file view
    try std.testing.expect(d2s.verifyChecksum(out));
    const h = d2s.parseHeader(out).?;
    try std.testing.expectEqual(@as(u32, @intCast(out.len)), h.file_size);
    try std.testing.expectEqualStrings("PwnMeHC", h.nameSlice());
    try std.testing.expectEqual(@as(u8, 3), h.class);
    try std.testing.expectEqual(@as(u8, 9), h.level);
    try std.testing.expect(h.hardcore());
    try std.testing.expect(h.expansion());
    try std.testing.expect(!h.died());
    try std.testing.expect(d2s.validate(out));

    // the sections reader: every section parses, the stats are the table's
    const s = try save.parse(out);
    const a = s.attributes.attributes();
    try std.testing.expectEqual(@as(u32, 9), a.level);
    try std.testing.expectEqual(@as(u32, 44396), a.experience);
    try std.testing.expectEqual(@as(u32, 40), a.statpts);
    try std.testing.expectEqual(@as(u32, 8), a.newskills);
    try std.testing.expectEqual(@as(u32, 25), a.strength);
    try std.testing.expectEqual(@as(u32, 71), a.maxhp);
    try std.testing.expectEqual(@as(u32, 71), a.hp);
    try std.testing.expectEqual(@as(u32, 27), a.maxmana);
    try std.testing.expectEqual(@as(u32, 97), a.maxstamina);
    try std.testing.expectEqual(@as(u16, 0), s.items.playerCount());

    // and the realm's own narrow reader, which is what the ladder reads, finds the same numbers
    try std.testing.expectEqual(@as(?u32, 9), realm_d2s.attribute(out, realm_d2s.stat_level));
    try std.testing.expectEqual(@as(?u32, 44396), realm_d2s.attribute(out, realm_d2s.stat_experience));
    try std.testing.expectEqual(@as(?u8, 0x25), realm_d2s.status(out));

    // the body is the engine's: the sections are byte-identical to the engine-written template
    const t = try save.parse(fresh);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&t.quests.blocks), std.mem.asBytes(&s.quests.blocks));
    try std.testing.expectEqualSlices(u8, &t.npcs.body, &s.npcs.body);
}

test "classic and start-skill classes, bad names and levels are refused" {
    var buf: [1024]u8 = undefined;
    const base = Spec{ .name = "X", .class = 4, .level = 9, .hardcore = false, .expansion = false, .created = 1 };
    const classic = try forge(&buf, t_experience, t_charstats, base);
    try std.testing.expect(!d2s.parseHeader(classic).?.expansion());
    try std.testing.expect(!d2s.parseHeader(classic).?.hardcore());

    var sorc = base;
    sorc.class = 1;
    try std.testing.expectError(error.ClassHasStartSkill, forge(&buf, t_experience, t_charstats, sorc));
    var lvl = base;
    lvl.level = 0;
    try std.testing.expectError(error.BadLevel, forge(&buf, t_experience, t_charstats, lvl));
    var nm = base;
    nm.name = "SixteenCharsName";
    try std.testing.expectError(error.BadName, forge(&buf, t_experience, t_charstats, nm));
}
