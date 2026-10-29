//! The realm's ladder: which characters are on it, in what order, and how the 1.14d client is
//! sent a piece of it.
//!
//! One ranking serves every reader. The client's ladder screen asks over MCP (0x11 for a page,
//! 0x16 to find a character, both in d2cs.zig), and anything outside the game (an extension serving
//! it over HTTP, say) can have it as `json` from the same board. Both read `view`, so the list a
//! website shows and the list in game are the same list.
//!
//! A character is on the ladder when its save says it is a ladder character (status 0x40). Each of
//! the client's lists is one of four groups (classic or expansion, softcore or hardcore) and
//! either everyone in it or one class, which is what the mode byte of a request names:
//!
//!   0x00 classic hardcore, 0x09 classic softcore, 0x13 expansion hardcore, 0x1b expansion
//!   softcore; plus 1..7 for one class (class id + 1), as CHATDLG_GetLadderStringOffset @0x43f150
//!   groups them.
//!
//! Order is by experience, highest first, then level, then name, so two readers never see a tie
//! broken two ways.
const std = @import("std");
const Lock = @import("realm_infra").lock.Lock;
const d2s = @import("d2s.zig");
const store = @import("store.zig");

extern "c" fn time(t: ?*c_long) c_long;

/// The client's name field width. Names are at most 15 characters, so a name always ends in a NUL.
pub const name_width: u32 = 16;
/// One entry on the wire: [u32 expLo][u32 expHi][u32 stats][16-byte name].
pub const wire_entry: u32 = 12 + name_width;
/// The most the client takes in one block (Incoming0x11 @0x44afc0 refuses a count above 0x100).
pub const block_max: usize = 256;
/// The overall lists are 1000 rows long, the class lists 200 (gnChatRoomListScrollPos, set by the
/// tab handlers in ChatDlg); a rank past that has no row to go in.
pub const overall_rows: usize = 1000;
pub const class_rows: usize = 200;
/// Every ladder character the board keeps. Far more than any list shows; it only bounds memory.
pub const board_max: usize = 8192;

/// One character on the ladder.
pub const Entry = struct {
    name: [16]u8 = @splat(0),
    experience: u32 = 0,
    level: u8 = 0,
    class: u8 = 0,
    /// The save's status byte: hardcore 0x04, died 0x08, expansion 0x20, ladder 0x40.
    status: u8 = 0,
    /// The save's progression byte: how many acts' bosses are behind it, which is the title.
    progression: u8 = 0,

    pub fn nameSlice(e: *const Entry) []const u8 {
        return std.mem.sliceTo(&e.name, 0);
    }
    pub fn hardcore(e: Entry) bool {
        return e.status & 0x04 != 0;
    }
    pub fn died(e: Entry) bool {
        return e.status & 0x08 != 0;
    }
    /// Dead on the ladder: a hardcore character that died. The save sets the died bit for a
    /// softcore character too, the first time it dies, and it stays set; Battle.net showed those as
    /// alive, so only a hardcore death counts.
    pub fn dead(e: Entry) bool {
        return e.hardcore() and e.died();
    }
    pub fn expansion(e: Entry) bool {
        return e.status & 0x20 != 0;
    }
    pub fn ladder(e: Entry) bool {
        return e.status & 0x40 != 0;
    }

    /// The u32 the client unpacks for a row (CHATDLG_HandleChatListClick @0x4403f0): class in the
    /// low nibble, dead 0x10 (the row is drawn grey instead of gold, colour (stats & 0x10 | 0x40) >> 4,
    /// whatever the group), progression from bit 8, level
    /// from bit 16, and the two bits that pick the title: 0x20 is HARDCORE and 0x40 EXPANSION, the
    /// other way round from the save's status byte. The row passes them to
    /// D2WINSMACK_GetTitlePrefixIndexFromClass @0x5068a0 as (..., hardcore, expansion): the last
    /// picks the five-act thresholds, the one before adds the hardcore titles (Count, Duke, King
    /// in D2COMP_GetTitlePrefix @0x505640).
    pub fn stats(e: Entry) u32 {
        var s: u32 = e.class & 0xf;
        if (e.dead()) s |= 0x10;
        if (e.hardcore()) s |= 0x20;
        if (e.expansion()) s |= 0x40;
        s |= @as(u32, e.progression & 0x1f) << 8;
        s |= @as(u32, e.level) << 16;
        return s;
    }
};

/// Read a character's ladder row out of its save. Null when the save is too short to have a header.
pub fn fromSave(name: []const u8, save: []const u8) ?Entry {
    if (save.len <= 0x2b or name.len == 0) return null;
    var e: Entry = .{
        .status = save[0x24],
        .progression = save[0x25],
        .class = save[0x28],
        .level = save[0x2b],
        // A character that has never been saved by a game has no attribute section yet, and so
        // no experience; it ranks by level among the others that have none.
        .experience = d2s.attribute(save, d2s.stat_experience) orelse 0,
    };
    const n = @min(name.len, e.name.len - 1);
    @memcpy(e.name[0..n], name[0..n]);
    return e;
}

/// Highest experience first, then level, then name.
pub fn before(_: void, a: Entry, b: Entry) bool {
    if (a.experience != b.experience) return a.experience > b.experience;
    if (a.level != b.level) return a.level > b.level;
    return std.ascii.lessThanIgnoreCase(a.nameSlice(), b.nameSlice());
}

// ---- which list ----------------------------------------------------------------------------

pub const Mode = struct {
    hardcore: bool,
    expansion: bool,
    /// One class's list, or null for everyone.
    class: ?u8 = null,

    /// The mode byte the client sends and expects back.
    pub fn byte(m: Mode) u8 {
        const base: u8 = if (m.expansion)
            (if (m.hardcore) 0x13 else 0x1b)
        else
            (if (m.hardcore) 0x00 else 0x09);
        return base + if (m.class) |c| c + 1 else 0;
    }

    pub fn rows(m: Mode) usize {
        return if (m.class == null) overall_rows else class_rows;
    }

    pub fn admits(m: Mode, e: Entry) bool {
        if (!e.ladder()) return false;
        if (e.hardcore() != m.hardcore or e.expansion() != m.expansion) return false;
        if (m.class) |c| return e.class == c;
        return true;
    }
};

/// What a mode byte names, or null for one the client never sends.
pub fn decodeMode(b: u8) ?Mode {
    const groups = [_]struct { base: u8, hc: bool, xp: bool }{
        .{ .base = 0x00, .hc = true, .xp = false },
        .{ .base = 0x09, .hc = false, .xp = false },
        .{ .base = 0x13, .hc = true, .xp = true },
        .{ .base = 0x1b, .hc = false, .xp = true },
    };
    for (groups) |g| {
        if (b < g.base or b - g.base >= 8) continue;
        const off = b - g.base;
        // Classic has five classes; the client's classic tabs stop at the Barbarian.
        if (!g.xp and off > 5) return null;
        return .{ .hardcore = g.hc, .expansion = g.xp, .class = if (off == 0) null else off - 1 };
    }
    return null;
}

/// The ranked list `m` names, from an already ranked board, cut to the rows the client has.
pub fn filter(ranked: []const Entry, m: Mode, out: []Entry) usize {
    var n: usize = 0;
    const cap = @min(out.len, m.rows());
    for (ranked) |e| {
        if (n >= cap) break;
        if (!m.admits(e)) continue;
        out[n] = e;
        n += 1;
    }
    return n;
}

/// Where `name` stands in a ranked list (0 = first), ignoring case as names are.
pub fn rankOf(list: []const Entry, name: []const u8) ?usize {
    for (list, 0..) |*e, i| if (std.ascii.eqlIgnoreCase(e.nameSlice(), name)) return i;
    return null;
}

// ---- the board -----------------------------------------------------------------------------

/// How long a ranking is reused before the saves are read again. The client asks again every
/// time the list is scrolled past sixteen rows, and every reader of every list shares the board,
/// so without this each scroll would read every save on the realm.
pub const refresh_s: i64 = 10;

var lock: Lock = .{};
var board: [board_max]Entry = undefined;
var board_len: usize = 0;
var built_at: i64 = 0;
var refreshing = std.atomic.Value(bool).init(false);

/// Put a ranked board in place. Exposed for the tests, which have no store to read.
pub fn install(entries: []const Entry, at: i64) void {
    lock.lock();
    defer lock.unlock();
    const n = @min(entries.len, board.len);
    @memcpy(board[0..n], entries[0..n]);
    board_len = n;
    built_at = at;
}

/// Read every character's save and rank the ladder ones. Slow: one save read per character.
fn collect(out: []Entry) usize {
    const gpa = std.heap.page_allocator;
    const max_accounts = 16384;
    const accts = gpa.alloc([32]u8, max_accounts) catch return 0;
    defer gpa.free(accts);
    const save = gpa.alloc(u8, 8192) catch return 0;
    defer gpa.free(save);

    var n: usize = 0;
    const na = store.listAccounts(accts);
    for (accts[0..na]) |*acct_buf| {
        const acct = std.mem.sliceTo(acct_buf, 0);
        if (acct.len == 0) continue;
        var names: [store.max_chars]store.Name = @splat(.{});
        const nc = store.listChars(acct, &names);
        for (names[0..nc]) |nm| {
            if (n >= out.len) break;
            // Big enough to reach the attribute section of a played save; the header alone
            // would give the level but never the experience.
            const sz = store.getCharD2s(acct, nm.slice(), save);
            const e = fromSave(nm.slice(), save[0..sz]) orelse continue;
            if (!e.ladder()) continue;
            out[n] = e;
            n += 1;
        }
    }
    std.sort.pdq(Entry, out[0..n], {}, before);
    return n;
}

fn now() i64 {
    return @intCast(time(null));
}

/// Rebuild the board when it is older than `refresh_s`. One reader rebuilds while the others keep
/// answering from the board they have; the very first build is waited for, there being nothing yet.
fn ensureFresh() void {
    const t = now();
    lock.lock();
    const fresh = built_at != 0 and t - built_at < refresh_s;
    const empty = built_at == 0;
    lock.unlock();
    if (fresh) return;
    if (refreshing.swap(true, .acq_rel)) {
        if (!empty) return;
        while (refreshing.load(.acquire)) std.Thread.yield() catch {};
        return;
    }
    defer refreshing.store(false, .release);
    const tmp = std.heap.page_allocator.alloc(Entry, board_max) catch return;
    defer std.heap.page_allocator.free(tmp);
    const n = collect(tmp);
    install(tmp[0..n], t);
}

/// The ranked list `m` names, as of the last build (at most `refresh_s` old).
pub fn view(m: Mode, out: []Entry) usize {
    ensureFresh();
    lock.lock();
    defer lock.unlock();
    return filter(board[0..board_len], m, out);
}

// ---- the wire ------------------------------------------------------------------------------

/// The most ladder data one 0x11 packet carries. The client reads a realm packet into a 1024-byte
/// buffer (NET_MCP_CLIENT_ReadAndParsePacket @0x449b70) and D2QSQUEUE_Dequeue @0x6c2090 DROPS a
/// packet longer than that without a word; the packet's own header (length, id, mode, total,
/// chunk, offset) takes 10 of the 1024. Bigger replies go in pieces the client puts back together.
pub const chunk_max: usize = 1000;

/// One block of a list as the client parses it: [u32 rankBase][u32 count][u32 entrySize], then the
/// rows. `rank_base` is the rank of `rows[0]` (0 = first place); the client shows it at that row.
pub fn writeBlock(buf: []u8, rank_base: u32, rows: []const Entry) []u8 {
    const n = @min(rows.len, block_max);
    const need = 12 + n * wire_entry;
    std.debug.assert(buf.len >= need);
    std.mem.writeInt(u32, buf[0..4], rank_base, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(n), .little);
    std.mem.writeInt(u32, buf[8..12], name_width, .little);
    var at: usize = 12;
    for (rows[0..n]) |e| {
        std.mem.writeInt(u32, buf[at..][0..4], e.experience, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 0, .little); // D2 experience is a u32
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], e.stats(), .little);
        @memcpy(buf[at + 12 ..][0..name_width], &e.name);
        at += wire_entry;
    }
    return buf[0..need];
}

/// The largest block `writeBlock` makes.
pub const block_bytes_max: usize = 12 + block_max * wire_entry;

/// The page of a list a request for rank `start` gets: up to `block_max` rows from there. A start
/// past the end gets nothing.
pub fn page(list: []const Entry, start: usize) []const Entry {
    if (start >= list.len) return list[0..0];
    return list[start..@min(list.len, start + block_max)];
}

/// The first row of the page that shows rank `r`: the client asks in steps of sixteen rows.
pub fn pageStart(r: usize) usize {
    return r - r % 16;
}

// ---- outside the game ----------------------------------------------------------------------

pub const class_names = [_][]const u8{ "Amazon", "Sorceress", "Necromancer", "Paladin", "Barbarian", "Druid", "Assassin" };

/// A ranked list as JSON for readers outside the game:
/// `{"mode":27,"hardcore":false,"expansion":true,"class":null,"rows":1000,"entries":[{"rank":1,"name":"...",
/// "class":1,"level":99,"experience":3520485254,"died":false,"progression":15}]}`. Names are
/// letters, digits, `-` and `_`, so they need no escaping.
pub fn json(w: *std.Io.Writer, m: Mode, list: []const Entry) std.Io.Writer.Error!void {
    try w.print("{{\"mode\":{d},\"hardcore\":{},\"expansion\":{},\"class\":", .{ m.byte(), m.hardcore, m.expansion });
    if (m.class) |c| try w.print("{d}", .{c}) else try w.writeAll("null");
    try w.print(",\"rows\":{d},\"entries\":[", .{m.rows()});
    for (list, 0..) |*e, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"rank\":");
        try w.print("{d}", .{i + 1});
        try w.writeAll(",\"name\":\"");
        for (e.nameSlice()) |ch| {
            if (ch == '"' or ch == '\\' or ch < 0x20) continue;
            try w.writeByte(ch);
        }
        try w.print("\",\"class\":{d},\"level\":{d},\"experience\":{d},\"died\":{},\"progression\":{d}}}", .{
            e.class, e.level, e.experience, e.dead(), e.progression,
        });
    }
    try w.writeAll("]}");
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn mk(name: []const u8, class: u8, level: u8, exp: u32, status: u8) Entry {
    var e: Entry = .{ .class = class, .level = level, .experience = exp, .status = status };
    @memcpy(e.name[0..name.len], name);
    return e;
}

test "a mode byte names a group and maybe a class, and makes the same byte again" {
    var b: u16 = 0;
    var seen: usize = 0;
    while (b < 256) : (b += 1) {
        const m = decodeMode(@intCast(b)) orelse continue;
        try testing.expectEqual(@as(u8, @intCast(b)), m.byte());
        seen += 1;
    }
    // classic: 2 groups x (overall + 5 classes), expansion: 2 x (overall + 7)
    try testing.expectEqual(@as(usize, 2 * 6 + 2 * 8), seen);
    const xs = decodeMode(0x1b).?;
    try testing.expect(xs.expansion and !xs.hardcore and xs.class == null);
    const druid = decodeMode(0x13 + 6).?;
    try testing.expect(druid.expansion and druid.hardcore and druid.class.? == 5);
    try testing.expect(decodeMode(0x08) == null);
    try testing.expect(decodeMode(0x23) == null);
}

test "a list holds only ladder characters of its group and class, best first" {
    const ladder_xp: u8 = 0x40 | 0x20;
    var board_in = [_]Entry{
        mk("NonLadder", 1, 99, 4_000_000_000, 0x20), // not a ladder character
        mk("SoftSorc", 1, 90, 2_000_000_000, ladder_xp),
        mk("HardBarb", 4, 95, 3_000_000_000, ladder_xp | 0x04),
        mk("ClassicSorc", 1, 80, 1_000_000_000, 0x40),
        mk("SoftAma", 0, 92, 2_500_000_000, ladder_xp),
        mk("Fresh", 0, 1, 0, ladder_xp),
    };
    std.sort.pdq(Entry, &board_in, {}, before);
    var out: [16]Entry = undefined;

    const n = filter(&board_in, decodeMode(0x1b).?, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("SoftAma", out[0].nameSlice());
    try testing.expectEqualStrings("SoftSorc", out[1].nameSlice());
    try testing.expectEqualStrings("Fresh", out[2].nameSlice());

    const sorcs = filter(&board_in, decodeMode(0x1b + 2).?, &out);
    try testing.expectEqual(@as(usize, 1), sorcs);
    try testing.expectEqualStrings("SoftSorc", out[0].nameSlice());

    try testing.expectEqual(@as(usize, 1), filter(&board_in, decodeMode(0x13).?, &out));
    try testing.expectEqualStrings("HardBarb", out[0].nameSlice());
    try testing.expectEqual(@as(usize, 1), filter(&board_in, decodeMode(0x09).?, &out));
    try testing.expectEqualStrings("ClassicSorc", out[0].nameSlice());
    try testing.expectEqual(@as(?usize, 0), rankOf(out[0..1], "classicsorc"));
    try testing.expectEqual(@as(?usize, null), rankOf(out[0..1], "nobody"));
}

test "equal experience falls to level, then name" {
    const a = mk("Bee", 0, 50, 100, 0x60);
    const b = mk("Ant", 0, 50, 100, 0x60);
    const c = mk("Cat", 0, 51, 100, 0x60);
    try testing.expect(before({}, c, a));
    try testing.expect(before({}, b, a));
    try testing.expect(!before({}, a, b));
}

test "the stats word is what the ladder screen unpacks" {
    const e = mk("Dead", 6, 87, 1, 0x40 | 0x20 | 0x04 | 0x08);
    var x = e;
    x.progression = 10;
    const s = x.stats();
    try testing.expectEqual(@as(u32, 6), s & 0xf);
    try testing.expect(s & 0x10 != 0); // died: drawn grey
    try testing.expect(s & 0x20 != 0); // hardcore
    try testing.expect(s & 0x40 != 0); // expansion
    // A softcore expansion character has only the expansion bit, so its title is Slayer and not a
    // hardcore one.
    const soft = mk("Soft", 1, 80, 1, 0x40 | 0x20).stats();
    try testing.expectEqual(@as(u32, 0x40), soft & 0x60);
    try testing.expectEqual(@as(u32, 10), (s >> 8) & 0x1f);
    try testing.expectEqual(@as(u32, 87), (s >> 16) & 0xff);
}

test "only a hardcore death marks the row dead" {
    // A softcore character that has died keeps the save's died bit; its row stays gold.
    const soft_died = mk("SoftDied", 1, 80, 1, 0x40 | 0x20 | 0x08);
    try testing.expect(!soft_died.dead());
    try testing.expectEqual(@as(u32, 0), soft_died.stats() & 0x10);
    const soft_classic_died = mk("ClassicDied", 3, 50, 1, 0x40 | 0x08);
    try testing.expectEqual(@as(u32, 0), soft_classic_died.stats() & 0x10);
    // A hardcore character that died is grey; one that lives is not.
    const hc_died = mk("HcDied", 2, 70, 1, 0x40 | 0x20 | 0x04 | 0x08);
    try testing.expect(hc_died.dead());
    try testing.expectEqual(@as(u32, 0x10), hc_died.stats() & 0x10);
    const hc_alive = mk("HcAlive", 2, 70, 1, 0x40 | 0x20 | 0x04);
    try testing.expectEqual(@as(u32, 0), hc_alive.stats() & 0x10);
    // The JSON says the same.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json(&w, .{ .hardcore = false, .expansion = true, .class = null }, &.{soft_died});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"died\":false") != null);
}

test "the JSON lists the rows with their ranks" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const rows = [_]Entry{ mk("Top", 1, 99, 3_520_485_254, 0x60), mk("Next", 4, 80, 5, 0x68) };
    try json(&w, decodeMode(0x1b).?, &rows);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "\"rank\":1,\"name\":\"Top\",\"class\":1,\"level\":99,\"experience\":3520485254,\"died\":false") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"rank\":2,\"name\":\"Next\"") != null);
    // Next is softcore with the save's died bit: not dead on the ladder.
    try testing.expect(std.mem.indexOf(u8, s, "\"died\":true") == null);
    try testing.expect(std.mem.startsWith(u8, s, "{\"mode\":27,\"hardcore\":false,\"expansion\":true,\"class\":null,\"rows\":1000,"));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
    defer parsed.deinit();
}

test "a page starts where the client asked and never runs past the block limit" {
    var many: [600]Entry = undefined;
    for (&many, 0..) |*e, i| e.* = mk("X", 0, 1, @intCast(1000 - i), 0x60);
    try testing.expectEqual(@as(usize, 256), page(&many, 0).len);
    try testing.expectEqual(@as(usize, 600 - 512), page(&many, 512).len);
    try testing.expectEqual(@as(usize, 0), page(&many, 600).len);
    try testing.expectEqual(@as(usize, 32), pageStart(47));
}

test "the board answers views until it is rebuilt" {
    const rows = [_]Entry{ mk("One", 0, 9, 9, 0x60), mk("Two", 0, 8, 8, 0x64) };
    install(&rows, now()); // fresh, so view does not go to the store
    var out: [4]Entry = undefined;
    try testing.expectEqual(@as(usize, 1), view(decodeMode(0x1b).?, &out));
    try testing.expectEqualStrings("One", out[0].nameSlice());
    try testing.expectEqual(@as(usize, 1), view(decodeMode(0x13).?, &out));
}
