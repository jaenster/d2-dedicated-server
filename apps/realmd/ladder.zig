//! The ladder board: which characters an MCP_LADDERDATA (0x11) request is answered with, and
//! the bytes that answer is made of. IO-free so the whole of it is testable; d2cs.zig reads the
//! saves and puts the reply on the wire.
//!
//! Request: [u8 type][u16 first rank]. The type is one of four bases plus an offset:
//!
//!     0x00 classic hardcore    0x09 classic softcore    0x13 expansion hardcore    0x1b expansion softcore
//!
//! Offset 0 is the overall board, offset 1 + n the board of class n (amazon 0 .. assassin 6).
//! From the client: CHATDLG_GetLadderStringOffset @0x43f150 folds a type back onto its base, the
//! class buttons add their offset to it, and CHATDLG_RequestLadderRank @0x43ec60 picks the overall
//! boards (`hardcore ? 0 : 9`, `hardcore ? 0x13 : 0x1b`).
//!
//! Reply, after the opcode (NET_MCP_CLIENT_Incoming0x11 @0x44afc0): [u8 type][u16 total][u16 chunk]
//! [u16 write offset] then the chunk. The reassembled buffer is [u32 first rank][u32 count]
//! [u32 name width] and `count` entries of [u32 exp lo][u32 exp hi][u32 stats][name width bytes].
//! The client refuses count > 0x100 and a name width > 16.
//!
//! The stats dword, as CHATDLG_HandleChatListClick @0x4403f0 reads it:
//!   & 0x0f   class (indexes the class-name column)
//!   & 0x10   dead: the row is drawn in colour 5 (grey) instead of 4 (gold)
//!   & 0x20   hardcore: D2WINSMACK_GetTitlePrefixIndexFromClass @0x5068a0 adds 3 to the title
//!            rank, which D2COMP_GetTitlePrefix @0x505640 turns into Count/Duke/King
//!   & 0x40   expansion: the same function switches to the 5/10/15 title thresholds and the
//!            Slayer/Champion/... names
//!   >> 8 & 0x1f   title progression (.d2s 0x25)
//!   >> 16 & 0xff  level
//! Hardcore and expansion are NOT the .d2s status bits (0x04 / 0x20); they have to be translated.
const std = @import("std");
const proto = @import("proto.zig");
const d2s = @import("d2s.zig");

pub const name_width = 16;
/// The most rows the realm ranks. The client caps what it will draw at 200 once a board has been
/// picked (CHATDLG_ChangeLadderFilter), and would refuse more than 0x100 in one reply anyway.
pub const max_entries = 200;

/// .d2s status (offset 0x24) bits the board is decided by.
const status_hardcore = d2s.status_hardcore;
const status_died = d2s.status_died;
const status_expansion = d2s.status_expansion;
const status_ladder: u8 = 0x40;

/// Stats-dword bits the client reads.
pub const flag_dead: u32 = 0x10;
pub const flag_hardcore: u32 = 0x20;
pub const flag_expansion: u32 = 0x40;

const base_classic_hardcore: u8 = 0x00;
const base_classic_softcore: u8 = 0x09;
const base_expansion_hardcore: u8 = 0x13;
const base_expansion_softcore: u8 = 0x1b;
const classic_classes = 5;
const expansion_classes = 7;

pub const Board = struct {
    hardcore: bool,
    expansion: bool,
    /// null for the overall board.
    class: ?u8,
};

/// The board a request type names, or null for a type the client never sends.
pub fn board(ladder_type: u8) ?Board {
    const bases = [_]struct { base: u8, hardcore: bool, expansion: bool, classes: u8 }{
        .{ .base = base_classic_hardcore, .hardcore = true, .expansion = false, .classes = classic_classes },
        .{ .base = base_classic_softcore, .hardcore = false, .expansion = false, .classes = classic_classes },
        .{ .base = base_expansion_hardcore, .hardcore = true, .expansion = true, .classes = expansion_classes },
        .{ .base = base_expansion_softcore, .hardcore = false, .expansion = true, .classes = expansion_classes },
    };
    for (bases) |b| {
        if (ladder_type < b.base or ladder_type > b.base + b.classes) continue;
        const off = ladder_type - b.base;
        return .{
            .hardcore = b.hardcore,
            .expansion = b.expansion,
            .class = if (off == 0) null else off - 1,
        };
    }
    return null;
}

/// The overall board's type for a character kind: what MCP_CHARRANK's two flags pick.
pub fn overallType(hardcore: bool, expansion: bool) u8 {
    if (expansion) return if (hardcore) base_expansion_hardcore else base_expansion_softcore;
    return if (hardcore) base_classic_hardcore else base_classic_softcore;
}

pub const Entry = struct {
    name: [name_width]u8 = .{0} ** name_width,
    stats: u32 = 0,
    experience: u32 = 0,
    /// The .d2s status byte, kept to decide which boards the character is on.
    status: u8 = 0,

    pub fn nameSlice(e: *const Entry) []const u8 {
        return std.mem.sliceTo(&e.name, 0);
    }
};

/// A ladder row from a character's save, or null when the save is too short to have a header.
pub fn entryFromSave(name: []const u8, save: []const u8) ?Entry {
    if (save.len <= 0x2b) return null;
    const status = save[0x24];
    const progression: u32 = save[0x25];
    const hardcore = status & status_hardcore != 0;
    var stats: u32 = save[0x28] & 0xf; // class
    // The status byte's died bit is set by any death, softcore ones included. Only a hardcore
    // death is final, and only that one is what the grey row means.
    if (hardcore and status & status_died != 0) stats |= flag_dead;
    if (hardcore) stats |= flag_hardcore;
    if (status & status_expansion != 0) stats |= flag_expansion;
    stats |= (progression & 0x1f) << 8;
    stats |= @as(u32, save[0x2b]) << 16; // level
    var e = Entry{
        .stats = stats,
        .experience = d2s.attribute(save, d2s.stat_experience) orelse 0,
        .status = status,
    };
    const n = @min(name.len, name_width - 1);
    @memcpy(e.name[0..n], name[0..n]);
    return e;
}

/// Whether a character belongs on a board. The ladder is the ladder characters: a non-ladder
/// character has no standing on it, the same as on the retail realms.
pub fn onBoard(b: Board, e: Entry) bool {
    if (e.status & status_ladder == 0) return false;
    if ((e.status & status_hardcore != 0) != b.hardcore) return false;
    if ((e.status & status_expansion != 0) != b.expansion) return false;
    if (b.class) |cls| if (e.stats & 0xf != cls) return false;
    return true;
}

/// Highest experience first, falling back to level for characters whose save has no
/// attribute section yet - a character created but never played has no experience to
/// compare, and should not outrank one that has some. Names break the last tie, so the
/// order does not depend on which account the realm happened to list first.
fn rankDesc(_: void, a: Entry, b: Entry) bool {
    if (a.experience != b.experience) return a.experience > b.experience;
    if ((a.stats >> 16) != (b.stats >> 16)) return (a.stats >> 16) > (b.stats >> 16);
    return std.mem.order(u8, a.nameSlice(), b.nameSlice()) == .lt;
}

/// The board's rows, ranked, into `out`. Returns how many.
pub fn standings(b: Board, all: []const Entry, out: []Entry) usize {
    var n: usize = 0;
    for (all) |e| {
        if (n >= out.len) break;
        if (!onBoard(b, e)) continue;
        out[n] = e;
        n += 1;
    }
    std.sort.pdq(Entry, out[0..n], {}, rankDesc);
    return n;
}

/// The reply body after the opcode: `rows` shown from rank `first_rank` (zero-based) on.
/// Callers must not pass zero rows: the client reads a zero count as "that character is not on
/// the ladder" and puts up an error, which is what `writeNotOnLadder` is for.
pub fn writeRows(w: *proto.Writer, ladder_type: u8, first_rank: u32, rows: []const Entry) void {
    const total: u16 = @intCast(12 + rows.len * (12 + name_width));
    w.putU8(ladder_type); // the client draws the rows only if this is the board on screen
    w.putU16(total); // whole-buffer size
    w.putU16(total); // this chunk's length (single chunk)
    w.putU16(0); // write offset
    w.putU32(first_rank);
    w.putU32(@intCast(rows.len));
    w.putU32(name_width);
    for (rows) |e| {
        w.putU32(e.experience); // experience low
        w.putU32(0); // experience high: D2 experience is a u32, so this is always 0
        w.putU32(e.stats);
        w.putBytes(&e.name);
    }
}

/// The all-zero form: the client clears its buffer and reports "Player '<name>' is not on the
/// ladder." It is the answer to a rank search that found nothing, never to a board request.
pub fn writeNotOnLadder(w: *proto.Writer) void {
    w.zeros(14);
}

/// Where a rank search lands: the page of 16 holding the character, as the retail client pages.
pub fn pageOf(rows: []const Entry, name: []const u8) ?u32 {
    for (rows, 0..) |e, i| {
        if (std.ascii.eqlIgnoreCase(e.nameSlice(), name)) return @intCast(i - i % 16);
    }
    return null;
}

// tests

const testing = std.testing;

const Fixture = struct { name: []const u8, class: u8, level: u8, status: u8, progression: u8 = 0 };

/// A roster covering every kind of character the boards have to tell apart.
const roster = [_]Fixture{
    .{ .name = "ExpScLadAma", .class = 0, .level = 90, .status = 0x20 | 0x40, .progression = 15 },
    .{ .name = "ExpScLadSorc", .class = 1, .level = 85, .status = 0x20 | 0x40 | 0x08, .progression = 10 }, // died once, softcore
    .{ .name = "ExpHcLadNec", .class = 2, .level = 80, .status = 0x20 | 0x40 | 0x04, .progression = 10 },
    .{ .name = "ExpHcLadDead", .class = 4, .level = 75, .status = 0x20 | 0x40 | 0x04 | 0x08, .progression = 5 },
    .{ .name = "ClsScLadPal", .class = 3, .level = 70, .status = 0x40, .progression = 4 },
    .{ .name = "ClsHcLadBar", .class = 4, .level = 65, .status = 0x40 | 0x04 },
    .{ .name = "ExpScNonLad", .class = 5, .level = 99, .status = 0x20 },
    .{ .name = "ExpScLadAsn", .class = 6, .level = 60, .status = 0x20 | 0x40 },
};

fn buildRoster(out: []Entry) !usize {
    for (roster, 0..) |f, i| {
        var save: [d2s.new_save_size]u8 = undefined;
        try testing.expect(d2s.newSave(&save, f.name, f.class, 0x20, 0x1234));
        save[0x24] = f.status;
        save[0x25] = f.progression;
        save[0x28] = f.class;
        save[0x2b] = f.level;
        out[i] = entryFromSave(f.name, &save) orelse return error.NoEntry;
    }
    return roster.len;
}

const class_names = [_][]const u8{ "ama", "sor", "nec", "pal", "bar", "dru", "asn", "???" };

/// Decode a reply the way NET_MCP_CLIENT_Incoming0x11 + CHATDLG_HandleChatListClick do and
/// render the board as text, so a snapshot reads as what the player would see.
fn renderBoard(body: []const u8, out: []u8) ![]const u8 {
    var s = std.Io.Writer.fixed(out);
    var r = proto.Reader.init(body);
    const ladder_type = r.getU8();
    const total = r.getU16();
    const chunk = r.getU16();
    const offset = r.getU16();
    try s.print("type=0x{x:0>2} total={d} chunk={d} offset={d}\n", .{ ladder_type, total, chunk, offset });
    if (total == 0) {
        try s.print("(not on the ladder)\n", .{});
        return s.buffered();
    }
    const first = r.getU32();
    const count = r.getU32();
    const width = r.getU32();
    try testing.expect(count <= 0x100 and width <= 16);
    for (0..count) |i| {
        const exp_lo = r.getU32();
        _ = r.getU32();
        const st = r.getU32();
        var nm: [16]u8 = undefined;
        for (&nm) |*b| b.* = r.getU8();
        try s.print("{d} {s} {s} lvl={d} title={d} exp={d}{s}{s}{s}\n", .{
            first + i + 1,
            std.mem.sliceTo(&nm, 0),
            class_names[st & 0x7],
            (st >> 16) & 0xff,
            (st >> 8) & 0x1f,
            exp_lo,
            if (st & flag_hardcore != 0) " hc" else "",
            if (st & flag_expansion != 0) " exp" else "",
            if (st & flag_dead != 0) " GREY" else "",
        });
    }
    try testing.expectEqual(@as(usize, 0), r.remaining());
    return s.buffered();
}

fn boardSnapshot(ladder_type: u8, text: []u8) ![]const u8 {
    var all: [roster.len]Entry = undefined;
    const n = try buildRoster(&all);
    var rows: [max_entries]Entry = undefined;
    const k = standings(board(ladder_type).?, all[0..n], &rows);
    var buf: [4096]u8 = undefined;
    var w = proto.Writer.init(&buf);
    if (k == 0) writeNotOnLadder(&w) else writeRows(&w, ladder_type, 0, rows[0..k]);
    try testing.expect(!w.overflowed);
    return renderBoard(w.slice(), text);
}

test "the client's ladder types name the boards bnetdocs and the client agree on" {
    try testing.expectEqual(Board{ .hardcore = true, .expansion = false, .class = null }, board(0x00).?);
    try testing.expectEqual(Board{ .hardcore = true, .expansion = false, .class = 4 }, board(0x05).?);
    try testing.expectEqual(Board{ .hardcore = false, .expansion = false, .class = null }, board(0x09).?);
    try testing.expectEqual(Board{ .hardcore = false, .expansion = false, .class = 0 }, board(0x0a).?);
    try testing.expectEqual(Board{ .hardcore = true, .expansion = true, .class = null }, board(0x13).?);
    try testing.expectEqual(Board{ .hardcore = true, .expansion = true, .class = 6 }, board(0x1a).?);
    try testing.expectEqual(Board{ .hardcore = false, .expansion = true, .class = null }, board(0x1b).?);
    try testing.expectEqual(Board{ .hardcore = false, .expansion = true, .class = 5 }, board(0x21).?);
    try testing.expectEqual(Board{ .hardcore = false, .expansion = true, .class = 6 }, board(0x22).?);
    try testing.expectEqual(@as(?Board, null), board(0x23));
    try testing.expectEqual(@as(u8, 0x00), overallType(true, false));
    try testing.expectEqual(@as(u8, 0x09), overallType(false, false));
    try testing.expectEqual(@as(u8, 0x13), overallType(true, true));
    try testing.expectEqual(@as(u8, 0x1b), overallType(false, true));
}

test "expansion softcore overall board" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\type=0x1b total=96 chunk=96 offset=0
        \\1 ExpScLadAma ama lvl=90 title=15 exp=0 exp
        \\2 ExpScLadSorc sor lvl=85 title=10 exp=0 exp
        \\3 ExpScLadAsn asn lvl=60 title=0 exp=0 exp
        \\
    , try boardSnapshot(0x1b, &text));
}

test "expansion hardcore overall board, a dead character grey and ranked" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\type=0x13 total=68 chunk=68 offset=0
        \\1 ExpHcLadNec nec lvl=80 title=10 exp=0 hc exp
        \\2 ExpHcLadDead bar lvl=75 title=5 exp=0 hc exp GREY
        \\
    , try boardSnapshot(0x13, &text));
}

test "classic boards hold only classic characters" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\type=0x09 total=40 chunk=40 offset=0
        \\1 ClsScLadPal pal lvl=70 title=4 exp=0
        \\
    , try boardSnapshot(0x09, &text));
    try testing.expectEqualStrings(
        \\type=0x00 total=40 chunk=40 offset=0
        \\1 ClsHcLadBar bar lvl=65 title=0 exp=0 hc
        \\
    , try boardSnapshot(0x00, &text));
}

test "a class board holds only that class" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\type=0x1d total=40 chunk=40 offset=0
        \\1 ExpScLadSorc sor lvl=85 title=10 exp=0 exp
        \\
    , try boardSnapshot(0x1d, &text)); // expansion softcore sorceress
    try testing.expectEqualStrings(
        \\type=0x18 total=40 chunk=40 offset=0
        \\1 ExpHcLadDead bar lvl=75 title=5 exp=0 hc exp GREY
        \\
    , try boardSnapshot(0x18, &text)); // expansion hardcore barbarian
}

test "the reply's bytes, header and one row" {
    var all: [roster.len]Entry = undefined;
    const n = try buildRoster(&all);
    var rows: [max_entries]Entry = undefined;
    const k = standings(board(0x0d).?, all[0..n], &rows); // classic softcore paladin
    var buf: [256]u8 = undefined;
    var w = proto.Writer.init(&buf);
    writeRows(&w, 0x0d, 0, rows[0..k]);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x0d, 0x28, 0x00, 0x28, 0x00, 0x00, 0x00, // type, total 40, chunk 40, offset 0
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, // first 0, count 1, width 16
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // experience
        0x03, 0x04, 0x46, 0x00, // paladin, title 4, level 70, no flags
        'C', 'l', 's', 'S', 'c', 'L', 'a', 'd', 'P', 'a', 'l', 0, 0, 0, 0, 0,
    }, w.slice());
}

test "a softcore death does not grey the row" {
    var save: [d2s.new_save_size]u8 = undefined;
    try testing.expect(d2s.newSave(&save, "Survivor", 1, 0x20, 1));
    save[0x24] = 0x20 | 0x40 | 0x08; // expansion ladder, has died
    const e = entryFromSave("Survivor", &save).?;
    try testing.expectEqual(@as(u32, 0), e.stats & flag_dead);
    try testing.expectEqual(@as(u32, 0), e.stats & flag_hardcore);
    try testing.expectEqual(flag_expansion, e.stats & flag_expansion);
}

test "an empty board is the not-on-the-ladder form only when asked for" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\type=0x00 total=0 chunk=0 offset=0
        \\(not on the ladder)
        \\
    , try boardSnapshot(0x01, &text)); // classic hardcore amazon: nobody
}

test "a rank search lands on the character's page" {
    var rows: [40]Entry = undefined;
    for (&rows, 0..) |*e, i| {
        e.* = .{};
        _ = std.fmt.bufPrint(&e.name, "Char{d}", .{i}) catch unreachable;
    }
    try testing.expectEqual(@as(?u32, 0), pageOf(&rows, "char3"));
    try testing.expectEqual(@as(?u32, 16), pageOf(&rows, "Char16"));
    try testing.expectEqual(@as(?u32, 32), pageOf(&rows, "Char39"));
    try testing.expectEqual(@as(?u32, null), pageOf(&rows, "Nobody"));
}
