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

/// The status bits a board is decided by, and the value they have on it: ladder, and the board's
/// hardcore and expansion. What `onBoard` tests, as the store's index filters on it.
pub const kind_mask: u8 = status_ladder | status_expansion | status_hardcore;

pub fn kindOf(b: Board) u8 {
    return status_ladder | (if (b.hardcore) status_hardcore else 0) | (if (b.expansion) status_expansion else 0);
}

/// The rows a request for rank `first` is answered with: the page of 16 the client asks for
/// (CHATDLG_UpdateChatRoomList @0x4402a0 asks for the 16-aligned page holding the first line
/// still showing its "-" placeholder), cut at the 200 it draws. Null past the end: the client
/// has no page there to fill.
pub const page_rows = 16;
pub fn pageSpan(first: u32) ?usize {
    if (first >= max_entries) return null;
    return @min(page_rows, max_entries - first);
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

/// A board's best `max_entries` rows, kept ranked as characters are offered one at a time.
///
/// Streaming rather than collect-then-sort, because the realm has no bound on how many characters
/// it holds: a fixed collection buffer decides who can rank by whichever characters happen to be
/// listed first, and a sort over only the first `max_entries` found drops better ones found later.
pub const Top = struct {
    board: Board,
    rows: [max_entries]Entry = undefined,
    n: usize = 0,

    pub fn offer(t: *Top, e: Entry) void {
        if (!onBoard(t.board, e)) return;
        var i: usize = t.n;
        if (t.n == t.rows.len) {
            // Full: only a row that outranks the last one gets in, in its place.
            if (!rankDesc({}, e, t.rows[t.n - 1])) return;
            i = t.n - 1;
        } else {
            t.n += 1;
        }
        while (i > 0 and rankDesc({}, e, t.rows[i - 1])) : (i -= 1) t.rows[i] = t.rows[i - 1];
        t.rows[i] = e;
    }

    pub fn slice(t: *const Top) []const Entry {
        return t.rows[0..t.n];
    }
};

/// The board's rows, ranked, into `out`. Returns how many.
pub fn standings(b: Board, all: []const Entry, out: []Entry) usize {
    var top = Top{ .board = b };
    for (all) |e| top.offer(e);
    const n = @min(top.n, out.len);
    @memcpy(out[0..n], top.rows[0..n]);
    return n;
}

/// The client reads the realm into a 1024-byte buffer (NET_MCP_CLIENT_ReadAndParsePacket
/// @0x449b70), and the queue it reads from DROPS any packet bigger than that and latches its error
/// flag (D2QSQUEUE_Dequeue @0x6c2090). So a board goes out as chunks, each its own MCP packet,
/// which NET_MCP_CLIENT_Incoming0x11 @0x44afc0 reassembles by the write offset each carries. The
/// whole packet, length and opcode included, stays within that buffer.
pub const max_packet = 0x400;
const mcp_header = 3; // u16 length + opcode
const chunk_header = 7; // type, total, chunk length, write offset
pub const max_chunk = max_packet - mcp_header - chunk_header;

/// The largest reassembled buffer a board makes: everything it ranks.
pub const max_payload = 12 + max_entries * (12 + name_width);

/// The reassembled buffer: `rows` shown from rank `first_rank` (zero-based) on.
/// Callers must not pass zero rows: the client reads a zero count as "that character is not on
/// the ladder" and puts up an error, which is what `writeNotOnLadder` is for.
pub fn writePayload(w: *proto.Writer, first_rank: u32, rows: []const Entry) void {
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

/// One chunk's body after the opcode: as much of `payload` from `offset` on as fits. Returns how
/// many payload bytes that was; call again from the running sum until the payload is used up.
pub fn writeChunk(w: *proto.Writer, ladder_type: u8, payload: []const u8, offset: usize) usize {
    const len = @min(payload.len - offset, max_chunk);
    w.putU8(ladder_type); // the client draws the rows only if this is the board on screen
    w.putU16(@intCast(payload.len)); // whole-buffer size
    w.putU16(@intCast(len)); // this chunk's length
    w.putU16(@intCast(offset)); // where the client writes it
    w.putBytes(payload[offset..][0..len]);
    return len;
}

const opcode_ladderdata: u8 = 0x11;

/// Room for the largest reply `writeReply` makes.
pub const max_reply = max_payload + (max_payload / max_chunk + 1) * (mcp_header + chunk_header);

/// The whole answer, as the MCP packets that carry it: the rows in chunks, or the
/// not-on-the-ladder form when there are none.
pub fn writeReply(buf: *[max_reply]u8, ladder_type: u8, first_rank: u32, rows: []const Entry) []const u8 {
    var w = proto.Writer.init(buf);
    if (rows.len == 0) {
        const start = w.pos;
        w.putU16(0);
        w.putU8(opcode_ladderdata);
        writeNotOnLadder(&w);
        w.patchU16(start, @intCast(w.pos - start));
        return w.slice();
    }
    var pbuf: [max_payload]u8 = undefined;
    var pw = proto.Writer.init(&pbuf);
    writePayload(&pw, first_rank, rows[0..@min(rows.len, max_entries)]);
    const payload = pw.slice();
    var offset: usize = 0;
    while (offset < payload.len) {
        const start = w.pos;
        w.putU16(0); // length, patched below
        w.putU8(opcode_ladderdata);
        offset += writeChunk(&w, ladder_type, payload, offset);
        w.patchU16(start, @intCast(w.pos - start));
    }
    return w.slice();
}

/// The all-zero form: the client clears its buffer and reports "Player '<name>' is not on the
/// ladder." It is the answer to a rank search that found nothing, never to a board request.
pub fn writeNotOnLadder(w: *proto.Writer) void {
    w.zeros(14);
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

/// Decode a reply the way the client does - each MCP packet read into its 1024-byte buffer,
/// NET_MCP_CLIENT_Incoming0x11 reassembling the chunks, CHATDLG_HandleChatListClick reading the
/// rows - and render the board as text, so a snapshot reads as what the player would see.
fn renderBoard(packets: []const u8, out: []u8) ![]const u8 {
    var s = std.Io.Writer.fixed(out);
    var whole: [max_payload]u8 = undefined;
    var whole_len: usize = 0;
    var filled: usize = 0;
    var pos: usize = 0;
    while (pos < packets.len) {
        const len = std.mem.readInt(u16, packets[pos..][0..2], .little);
        // Anything bigger is dropped by the client's queue before it is ever parsed.
        try testing.expect(len <= max_packet);
        try testing.expectEqual(opcode_ladderdata, packets[pos + 2]);
        var r = proto.Reader.init(packets[pos + 3 .. pos + len]);
        pos += len;
        const ladder_type = r.getU8();
        const total = r.getU16();
        const chunk = r.getU16();
        const offset = r.getU16();
        try s.print("packet {d}: type=0x{x:0>2} total={d} chunk={d} offset={d}\n", .{ len, ladder_type, total, chunk, offset });
        if (total == 0 and chunk == 0 and offset == 0) {
            try s.print("(not on the ladder)\n", .{});
            return s.buffered();
        }
        try testing.expect(offset + chunk <= total);
        for (0..chunk) |i| whole[offset + i] = r.getU8();
        try testing.expectEqual(@as(usize, 0), r.remaining());
        whole_len = total;
        filled = offset + chunk;
    }
    try testing.expectEqual(whole_len, filled);
    var r = proto.Reader.init(whole[0..whole_len]);
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
    var buf: [max_reply]u8 = undefined;
    return renderBoard(writeReply(&buf, ladder_type, 0, rows[0..k]), text);
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
        \\packet 106: type=0x1b total=96 chunk=96 offset=0
        \\1 ExpScLadAma ama lvl=90 title=15 exp=0 exp
        \\2 ExpScLadSorc sor lvl=85 title=10 exp=0 exp
        \\3 ExpScLadAsn asn lvl=60 title=0 exp=0 exp
        \\
    , try boardSnapshot(0x1b, &text));
}

test "expansion hardcore overall board, a dead character grey and ranked" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\packet 78: type=0x13 total=68 chunk=68 offset=0
        \\1 ExpHcLadNec nec lvl=80 title=10 exp=0 hc exp
        \\2 ExpHcLadDead bar lvl=75 title=5 exp=0 hc exp GREY
        \\
    , try boardSnapshot(0x13, &text));
}

test "classic boards hold only classic characters" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\packet 50: type=0x09 total=40 chunk=40 offset=0
        \\1 ClsScLadPal pal lvl=70 title=4 exp=0
        \\
    , try boardSnapshot(0x09, &text));
    try testing.expectEqualStrings(
        \\packet 50: type=0x00 total=40 chunk=40 offset=0
        \\1 ClsHcLadBar bar lvl=65 title=0 exp=0 hc
        \\
    , try boardSnapshot(0x00, &text));
}

test "a class board holds only that class" {
    var text: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\packet 50: type=0x1d total=40 chunk=40 offset=0
        \\1 ExpScLadSorc sor lvl=85 title=10 exp=0 exp
        \\
    , try boardSnapshot(0x1d, &text)); // expansion softcore sorceress
    try testing.expectEqualStrings(
        \\packet 50: type=0x18 total=40 chunk=40 offset=0
        \\1 ExpHcLadDead bar lvl=75 title=5 exp=0 hc exp GREY
        \\
    , try boardSnapshot(0x18, &text)); // expansion hardcore barbarian
}

test "the reply's bytes, header and one row" {
    var all: [roster.len]Entry = undefined;
    const n = try buildRoster(&all);
    var rows: [max_entries]Entry = undefined;
    const k = standings(board(0x0d).?, all[0..n], &rows); // classic softcore paladin
    var buf: [max_reply]u8 = undefined;
    try testing.expectEqualSlices(u8, &[_]u8{
        0x32, 0x00, 0x11, // MCP length 50, MCP_LADDERDATA
        0x0d, 0x28, 0x00, 0x28, 0x00, 0x00, 0x00, // type, total 40, chunk 40, offset 0
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, // first 0, count 1, width 16
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // experience
        0x03, 0x04, 0x46, 0x00, // paladin, title 4, level 70, no flags
        'C', 'l', 's', 'S', 'c', 'L', 'a', 'd', 'P', 'a', 'l', 0, 0, 0, 0, 0,
    }, writeReply(&buf, 0x0d, 0, rows[0..k]));
}

/// A board of `n` expansion softcore ladder characters, best first.
fn fullBoard(rows: []Entry) void {
    for (rows, 0..) |*e, i| {
        e.* = .{ .status = 0x20 | 0x40, .experience = @intCast((rows.len - i) * 1000), .stats = flag_expansion | (80 << 16) };
        _ = std.fmt.bufPrint(&e.name, "Row{d}", .{i + 1}) catch unreachable;
    }
}

test "a full board goes out in chunks that each fit the client's receive buffer" {
    var rows: [max_entries]Entry = undefined;
    fullBoard(&rows);
    var buf: [max_reply]u8 = undefined;
    var text: [16384]u8 = undefined;
    const board_text = try renderBoard(writeReply(&buf, 0x1b, 0, &rows), &text);
    // The chunk headers, whole; then the reassembled rows' ends, which prove every chunk landed.
    const header_end = std.mem.indexOf(u8, board_text, "\n1 ").?;
    try testing.expectEqualStrings(
        \\packet 1024: type=0x1b total=5612 chunk=1014 offset=0
        \\packet 1024: type=0x1b total=5612 chunk=1014 offset=1014
        \\packet 1024: type=0x1b total=5612 chunk=1014 offset=2028
        \\packet 1024: type=0x1b total=5612 chunk=1014 offset=3042
        \\packet 1024: type=0x1b total=5612 chunk=1014 offset=4056
        \\packet 552: type=0x1b total=5612 chunk=542 offset=5070
    , board_text[0..header_end]);
    try testing.expect(std.mem.startsWith(u8, board_text[header_end + 1 ..], "1 Row1 ama lvl=80 title=0 exp=200000 exp\n2 Row2 "));
    try testing.expect(std.mem.endsWith(u8, board_text, "200 Row200 ama lvl=80 title=0 exp=1000 exp\n"));
}

test "a board that just fits one packet is one chunk, one row more is two" {
    // 36 rows: 12 + 36 * 28 = 1020 bytes of payload, over the 1014 a packet carries.
    var rows: [36]Entry = undefined;
    fullBoard(&rows);
    var buf: [max_reply]u8 = undefined;
    var text: [8192]u8 = undefined;
    const t36 = try renderBoard(writeReply(&buf, 0x1b, 0, &rows), &text);
    try testing.expectEqualStrings(
        \\packet 1024: type=0x1b total=1020 chunk=1014 offset=0
        \\packet 16: type=0x1b total=1020 chunk=6 offset=1014
    , t36[0..std.mem.indexOf(u8, t36, "\n1 ").?]);
    const t35 = try renderBoard(writeReply(&buf, 0x1b, 0, rows[0..35]), &text);
    try testing.expectEqualStrings(
        \\packet 1002: type=0x1b total=992 chunk=992 offset=0
    , t35[0..std.mem.indexOf(u8, t35, "\n1 ").?]);
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
        \\packet 17: type=0x00 total=0 chunk=0 offset=0
        \\(not on the ladder)
        \\
    , try boardSnapshot(0x01, &text)); // classic hardcore amazon: nobody
}

test "a page is 16 rows from the rank asked for, cut at the 200 the client draws" {
    try testing.expectEqual(@as(?usize, 16), pageSpan(0));
    try testing.expectEqual(@as(?usize, 16), pageSpan(176));
    try testing.expectEqual(@as(?usize, 8), pageSpan(192));
    try testing.expectEqual(@as(?usize, null), pageSpan(200));
    try testing.expectEqual(@as(u8, 0x64), kindOf(board(0x13).?)); // expansion hardcore
    try testing.expectEqual(@as(u8, 0x40), kindOf(board(0x0a).?)); // classic softcore amazon
}

test "the second page of a board says where its rows go" {
    var board_rows: [40]Entry = undefined;
    fullBoard(&board_rows);
    var buf: [max_reply]u8 = undefined;
    var text: [4096]u8 = undefined;
    // The client drew the first page already; it asks for rank 16 when its "-" lines come into view.
    try testing.expectEqualStrings(
        \\packet 470: type=0x1b total=460 chunk=460 offset=0
        \\17 Row17 ama lvl=80 title=0 exp=24000 exp
        \\18 Row18 ama lvl=80 title=0 exp=23000 exp
        \\19 Row19 ama lvl=80 title=0 exp=22000 exp
        \\20 Row20 ama lvl=80 title=0 exp=21000 exp
        \\21 Row21 ama lvl=80 title=0 exp=20000 exp
        \\22 Row22 ama lvl=80 title=0 exp=19000 exp
        \\23 Row23 ama lvl=80 title=0 exp=18000 exp
        \\24 Row24 ama lvl=80 title=0 exp=17000 exp
        \\25 Row25 ama lvl=80 title=0 exp=16000 exp
        \\26 Row26 ama lvl=80 title=0 exp=15000 exp
        \\27 Row27 ama lvl=80 title=0 exp=14000 exp
        \\28 Row28 ama lvl=80 title=0 exp=13000 exp
        \\29 Row29 ama lvl=80 title=0 exp=12000 exp
        \\30 Row30 ama lvl=80 title=0 exp=11000 exp
        \\31 Row31 ama lvl=80 title=0 exp=10000 exp
        \\32 Row32 ama lvl=80 title=0 exp=9000 exp
        \\
    , try renderBoard(writeReply(&buf, 0x1b, 16, board_rows[16..32]), &text));
    // The last, short page.
    try testing.expectEqualStrings(
        \\packet 246: type=0x1b total=236 chunk=236 offset=0
        \\33 Row33 ama lvl=80 title=0 exp=8000 exp
        \\34 Row34 ama lvl=80 title=0 exp=7000 exp
        \\35 Row35 ama lvl=80 title=0 exp=6000 exp
        \\36 Row36 ama lvl=80 title=0 exp=5000 exp
        \\37 Row37 ama lvl=80 title=0 exp=4000 exp
        \\38 Row38 ama lvl=80 title=0 exp=3000 exp
        \\39 Row39 ama lvl=80 title=0 exp=2000 exp
        \\40 Row40 ama lvl=80 title=0 exp=1000 exp
        \\
    , try renderBoard(writeReply(&buf, 0x1b, 32, board_rows[32..40]), &text));
}

test "a board with more ladder characters than it shows keeps the best ones" {
    // 250 ladder characters, listed worst first: the order an account listing happens to give.
    var all: [250]Entry = undefined;
    for (&all, 0..) |*e, i| {
        e.* = .{ .status = 0x20 | 0x40, .experience = @intCast(i * 1000) };
        _ = std.fmt.bufPrint(&e.name, "Rank{d}", .{250 - i}) catch unreachable;
    }
    var rows: [max_entries]Entry = undefined;
    const n = standings(board(0x1b).?, &all, &rows);
    try testing.expectEqual(@as(usize, max_entries), n);
    try testing.expectEqualStrings("Rank1", rows[0].nameSlice());
    try testing.expectEqualStrings("Rank2", rows[1].nameSlice());
    try testing.expectEqualStrings("Rank200", rows[max_entries - 1].nameSlice());
}
