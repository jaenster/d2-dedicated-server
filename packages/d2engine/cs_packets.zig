//! The client-to-server packet vocabulary of a specific engine build.
//!
//! A TCP read is not a packet: the server has to frame the stream before D2Game ever sees it. The
//! real D2Net did that in `SERVER_ValidateClientPacket` @0x6FC01FE0 via `SERVER_GetClientPacketSize`
//! @0x6FC01E60, which indexes a table at **0x6FC08418** by the leading opcode. Replacing D2Net means
//! replacing that, and anything that speaks to the server — a test client included — needs the same
//! table, which is why it lives in a package rather than inside the DLL.

const std = @import("std");
const version = @import("version.zig");

/// Total wire size per C->S opcode, including the opcode byte. Read out of 1.10f's own D2Net at
/// 0x6FC08418, not transcribed from another version: 0 means the opcode is unused and framing
/// fails, -1 means variable-length and the packet has to be scanned.
///
/// It is worth knowing how close the versions are here, and where they are not. Against 1.14d's
/// equivalent (libd2 `net.cs.OUTGOING_SIZE`) 102 of 112 entries are identical — every gameplay
/// opcode 0x00-0x63 matches byte for byte. All ten differences fall in 0x64-0x6F, the join and
/// handshake range, and one of them is decisive: 0x68, the client's very first packet, is 1 byte
/// here and 37 in 1.14d. So a stock 1.14d client cannot speak to this server — it desyncs on the
/// first packet — while a 1.10f-era client shares the entire gameplay vocabulary.
pub const packet_size_110f = [0x70]i32{
      0,   5,   9,   5,   9,   5,   9,   9, // 0x00-0x07
      5,   9,   9,   1,   5,   9,   9,   5, // 0x08-0x0F
      9,   9,   1,   9,  -1,  -1,  13,   5, // 0x10-0x17
     17,   5,   9,   9,   3,   9,   9,  17, // 0x18-0x1F
     13,   9,   5,   9,   5,   9,  13,   9, // 0x20-0x27
      9,   9,   9,   0,   0,   1,   3,   9, // 0x28-0x2F
      9,   9,  17,  17,   5,  17,   9,   5, // 0x30-0x37
     13,   5,   3,   3,   9,   5,   5,   3, // 0x38-0x3F
      1,   1,   1,   1,  17,   9,  13,  13, // 0x40-0x47
      1,   9,   0,   9,   5,   3,   0,   7, // 0x48-0x4F
      9,   9,   5,   1,   1,   0,   0,   0, // 0x50-0x57
      3,  17,   0,   0,   0,   7,   6,   5, // 0x58-0x5F
      1,   3,   5,   5,   9,  17,  46,  29, // 0x60-0x67
      1,   1,   1,  -1,   9,   1,   0,   1, // 0x68-0x6F
};

/// The engine's own bound, from the `cmp ax, 0x204` in `SERVER_ValidateClientPacket`.
pub const max_packet = 0x204;

/// How many bytes at the front of `buf` form one packet: null when more is needed, 0 when the
/// opcode cannot be framed at all (a desync — the caller drops the client rather than guessing).
/// 1.07's table, read out of its own `D2Net.dll`. It is NOT 1.10f's with a different join
/// opcode: 1.10f **inserted two opcodes** at 0x64 and 0x65 (sizes 9 and 17), which shifts every
/// later opcode by two. The 46/29 pair that is 0x66/0x67 on 1.10f is 0x64/0x65 here, so 1.07's
/// join is **0x65**, and its table ends at 0x6E rather than 0x70.
///
/// Below 0x64 the two agree except for five opcodes 1.10f retired to 0 — 0x2B, 0x55, 0x56, 0x5A
/// and 0x5B — which 1.07 still accepts.
pub const packet_size_107 = [0x6e]i32{
      0,   5,   9,   5,   9,   5,   9,   9, // 0x00-0x07
      5,   9,   9,   1,   5,   9,   9,   5, // 0x08-0x0F
      9,   9,   1,   9,  -1,  -1,  13,   5, // 0x10-0x17
     17,   5,   9,   9,   3,   9,   9,  17, // 0x18-0x1F
     13,   9,   5,   9,   5,   9,  13,   9, // 0x20-0x27
      9,   9,   9,   5,   0,   1,   3,   9, // 0x28-0x2F
      9,   9,  17,  17,   5,  17,   9,   5, // 0x30-0x37
     13,   5,   3,   3,   9,   5,   5,   3, // 0x38-0x3F
      1,   1,   1,   1,  17,   9,  13,  13, // 0x40-0x47
      1,   9,   0,   9,   5,   3,   0,   7, // 0x48-0x4F
      9,   9,   5,   1,   1,   8,  12,   0, // 0x50-0x57
      3,  17, 260,   4,   0,   7,   6,   5, // 0x58-0x5F
      1,   3,   5,   5,  46,  29,   1,   1, // 0x60-0x67
      1,  -1,   9,   1,   0,   1,           // 0x68-0x6D
};

/// 1.08's, read out of its own `D2Net.dll`. Below 0x64 it is 1.10f's table exactly — 1.08 had
/// already retired the five opcodes 1.07 still accepts — while the join block above it is 1.07's,
/// so the join is 0x65 and the table ends at 0x6E. Two different versions' worth of drift in one
/// table, which is why it is read per version rather than derived from a neighbour.
pub const packet_size_108 = [0x6e]i32{
      0,   5,   9,   5,   9,   5,   9,   9, // 0x00-0x07
      5,   9,   9,   1,   5,   9,   9,   5, // 0x08-0x0F
      9,   9,   1,   9,  -1,  -1,  13,   5, // 0x10-0x17
     17,   5,   9,   9,   3,   9,   9,  17, // 0x18-0x1F
     13,   9,   5,   9,   5,   9,  13,   9, // 0x20-0x27
      9,   9,   9,   0,   0,   1,   3,   9, // 0x28-0x2F
      9,   9,  17,  17,   5,  17,   9,   5, // 0x30-0x37
     13,   5,   3,   3,   9,   5,   5,   3, // 0x38-0x3F
      1,   1,   1,   1,  17,   9,  13,  13, // 0x40-0x47
      1,   9,   0,   9,   5,   3,   0,   7, // 0x48-0x4F
      9,   9,   5,   1,   1,   0,   0,   0, // 0x50-0x57
      3,  17,   0,   0,   0,   7,   6,   5, // 0x58-0x5F
      1,   3,   5,   5,  46,  29,   1,   1, // 0x60-0x67
      1,  -1,   9,   1,   0,   1, // 0x68-0x6D
};

/// 1.06b, classic. Read straight off the instruction stream rather than matched by pattern:
/// SERVER_GetClientPacketSize bounds the opcode against 0x6a and indexes this array, so both the
/// base and the length are the engine's own. Classic's join is a byte shorter than LoD's — a
/// 15-byte name field, not 16 — so the tell-tale pair is 45/28 where later versions read 46/29.
pub const packet_size_106b = [0x6a]i32{
    0,   5,   9,   5,   9,   5,   9,   9, // 0x00-0x07
    5,   9,   9,   1,   5,   9,   9,   5, // 0x08-0x0F
    9,   9,   1,   9,  -1,  -1,  13,   5, // 0x10-0x17
    17,  5,   9,   9,   3,   9,   9,  17, // 0x18-0x1F
    13,  9,   5,   9,   5,   9,  13,   9, // 0x20-0x27
    9,   9,   9,   5,   0,   1,   3,   9, // 0x28-0x2F
    9,   9,  17,  17,   5,  17,   9,   5, // 0x30-0x37
    13,  5,   3,   3,   5,   5,   5,   3, // 0x38-0x3F
    1,   1,   1,   1,  17,   9,  13,  13, // 0x40-0x47
    1,   9,   0,   9,   5,   3,   0,   7, // 0x48-0x4F
    9,   7,   5,   1,   1,   8,  12,   0, // 0x50-0x57
    3,   17, 260, 4,   0,   7,   6,   5, // 0x58-0x5F
    45,  28,  1,   1,   1,  -1,   9,   1, // 0x60-0x67
    0,   1, // 0x68-0x69
};

/// The table `v` frames with. Null means nobody has read that version's out of its D2Net.
pub fn packetSizes(v: version.Version) ?[]const i32 {
    return switch (v) {
        .v106b => &packet_size_106b,
        .v107 => &packet_size_107,
        .v108 => &packet_size_108,
        .v109b, .v109d => &packet_size_107, // 1.09 is 1.07-shaped; 1.10 is where it moved
        .v110f => &packet_size_110f,
        else => null,
    };
}

/// The C->S opcodes the engine's system-message processor owns — the block the join lives in,
/// which the transport must route to message list 0. It shifts with the join for the same reason:
/// 1.10f inserted two opcodes ahead of it, so 1.07's block is 0x64-0x6D where 1.10f's is 0x66-0x6F.
/// Route a join to the wrong list and the engine never sees it: no reply, no callback, no error.
pub fn systemRange(v: version.Version) ?struct { lo: u8, hi: u8 } {
    return switch (v) {
        .v106b => .{ .lo = 0x60, .hi = 0x69 },
        .v107, .v108, .v109b, .v109d => .{ .lo = 0x64, .hi = 0x6d },
        .v110f => .{ .lo = 0x66, .hi = 0x6f },
        else => null,
    };
}

test "the system-message block shifts with the join" {
    const a = systemRange(.v107).?;
    const b = systemRange(.v110f).?;
    try std.testing.expect(joinPacket(.v107).?.op >= a.lo and joinPacket(.v107).?.op <= a.hi);
    try std.testing.expect(joinPacket(.v110f).?.op >= b.lo and joinPacket(.v110f).?.op <= b.hi);
    try std.testing.expectEqual(b.lo - a.lo, b.hi - a.hi); // the same two-opcode shift

    // Classic sits six below 1.10f, and its join is the shorter 28-byte one.
    // 1.09 sits with 1.07/1.08, not with 1.10f — the shift is a 1.10 change.
    try std.testing.expectEqual(@as(u8, 0x65), joinPacket(.v109d).?.op);
    try std.testing.expectEqual(@as(u8, 0x65), joinPacket(.v109b).?.op);
    try std.testing.expectEqual(@as(u8, 0x64), systemRange(.v109d).?.lo);

    const c = systemRange(.v106b).?;
    try std.testing.expect(joinPacket(.v106b).?.op >= c.lo and joinPacket(.v106b).?.op <= c.hi);
    try std.testing.expectEqual(@as(u8, 6), b.lo - c.lo);
    try std.testing.expectEqual(@as(usize, 28), joinPacket(.v106b).?.len);
    try std.testing.expectEqual(@as(i32, 28), packetSizes(.v106b).?[joinPacket(.v106b).?.op]);
}

/// The opcode and length a join arrives as on `v`.
pub fn joinPacket(v: version.Version) ?struct { op: u8, len: usize } {
    return switch (v) {
        .v106b => .{ .op = 0x61, .len = 28 },
        // Read from each build's own table rather than grouped by era: the 46/29 pair sits at
        // 0x64/0x65 on 1.07, 1.08, 1.09b AND 1.09d, and only moves to 0x66/0x67 at 1.10. Grouping
        // 1.09d with 1.10f sent it a join it does not recognise, and the engine answered with an
        // unrelated 0xAA packet on the system list instead of ever binding the client to a game.
        .v107, .v108, .v109b, .v109d => .{ .op = 0x65, .len = 29 },
        .v110f => .{ .op = join_110f, .len = join_110f_len },
        .v114d => .{ .op = join_114d, .len = join_114d_len },
        else => null,
    };
}

/// Frame `buf` against an explicit table, so a caller can pick the version's own.
pub fn packetLenWith(sizes: []const i32, buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    if (op >= sizes.len) return 0;
    const entry = sizes[op];
    if (entry > 0) return if (buf.len >= @as(usize, @intCast(entry))) @intCast(entry) else null;
    if (entry == 0) return 0;
    // -1 means the length is carried in the packet. The rule is the same one `packetLen` uses
    // against live 1.10f and 1.14d clients: a u16 after the opcode, covering the three bytes it
    // sits behind. This previously read a bare byte at offset 1, which disagreed with the proven
    // path — and every pre-1.10 version frames through here, so the two must not diverge.
    //
    // Known gap, stated rather than hidden: -1 is not one rule for every opcode. Reading 1.06b's
    // own size function shows its 0x14/0x15 walk embedded strings while 0x65 is byte[1] plus seven.
    // This applies the u16 rule uniformly, so those three are wrong on 1.06b and must be measured
    // per opcode before a classic client is trusted on the wire — framing one wrong desynchronises
    // the stream for good rather than dropping a single packet.
    if (buf.len < 3) return null;
    const n = 3 + @as(usize, std.mem.readInt(u16, buf[1..3], .little));
    if (n > max_packet) return 0;
    return if (buf.len >= n) n else null;
}

pub fn packetLen(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    // 0xFF is the fixed-size control packet the table does not cover.
    if (op == 0xFF) return if (buf.len < 16) null else 16;
    if (op >= packet_size_110f.len) return 0;
    const entry = packet_size_110f[op];
    if (entry == 0) return 0;
    if (entry > 0) {
        const n: usize = @intCast(entry);
        if (n > max_packet) return 0;
        return if (buf.len < n) null else n;
    }
    // Variable-length: a u16 length follows the opcode. 0x14/0x15/0x6b are the three here.
    if (buf.len < 3) return null;
    const n = 3 + @as(usize, std.mem.readInt(u16, buf[1..3], .little));
    if (n > max_packet) return 0;
    return if (buf.len < n) null else n;
}


test "1.10f inserted two opcodes ahead of the join, so 1.07's sits two lower" {
    // The 46/29 pair is the fingerprint: same two packets, two slots apart.
    try std.testing.expectEqual(@as(i32, 46), packet_size_110f[0x66]);
    try std.testing.expectEqual(@as(i32, 29), packet_size_110f[0x67]);
    try std.testing.expectEqual(@as(i32, 46), packet_size_107[0x64]);
    try std.testing.expectEqual(@as(i32, 29), packet_size_107[0x65]);
    try std.testing.expectEqual(@as(u8, 0x65), joinPacket(.v107).?.op);
    try std.testing.expectEqual(@as(u8, 0x67), joinPacket(.v110f).?.op);
    // and 1.07 accepts five opcodes 1.10f retired
    try std.testing.expectEqual(@as(i32, 5), packet_size_107[0x2b]);
    try std.testing.expectEqual(@as(i32, 0), packet_size_110f[0x2b]);
    // 1.08 sits between them: 1.10f's opcodes below the join block, 1.07's join position above it.
    try std.testing.expectEqual(@as(i32, 0), packet_size_108[0x2b]);
    try std.testing.expectEqual(@as(u8, 0x65), joinPacket(.v108).?.op);
    try std.testing.expectEqual(@as(u8, 0x64), systemRange(.v108).?.lo);
}

test "the same field surgery serves both join opcodes" {
    var src: [join_114d_len]u8 = @splat(0);
    src[0] = join_114d;
    src[20] = 5;
    @memcpy(src[21..25], "Tenf");
    var a: [64]u8 = @splat(0);
    var b: [64]u8 = @splat(0);
    _ = translateJoin114dTo(&src, &a, 0x65).?;
    _ = translateJoin114dTo(&src, &b, 0x67).?;
    try std.testing.expectEqual(@as(u8, 0x65), a[0]);
    try std.testing.expectEqual(@as(u8, 0x67), b[0]);
    try std.testing.expectEqualSlices(u8, a[1..29], b[1..29]);
}

test "the join is 0x67 and 29 bytes on 1.10f" {
    // 1.14d joins with 0x68 at 37; here 0x68 is a one-byte end-game. Getting this backwards is
    // what makes a 1.14d client desynchronise on its opening packet.
    try std.testing.expectEqual(@as(i32, 29), packet_size_110f[0x67]);
    try std.testing.expectEqual(@as(i32, 1), packet_size_110f[0x68]);
}

test "framing splits a coalesced read and waits for a partial one" {
    const three = [_]u8{ 0x68, 0x6d, 0x40 };
    try std.testing.expectEqual(@as(?usize, 1), packetLen(&three));
    const partial = [_]u8{ 0x01, 0xaa };
    try std.testing.expectEqual(@as(?usize, null), packetLen(&partial));
    const whole = [_]u8{ 0x01, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(?usize, 5), packetLen(&whole));
}

test "an unframeable opcode is reported, not guessed" {
    const bad = [_]u8{0x00};
    try std.testing.expectEqual(@as(?usize, 0), packetLen(&bad));
}

// ── speaking to an older server with a newer client ──────────────────────────
//
// The join is the only packet that stands between a 1.14d client and a 1.10f server. Everything
// else it will send during a session — every opcode 0x00-0x63 — is byte-identical between the two,
// measured against 1.14d's own table: 102 of 112 entries match, and all ten differences sit in
// 0x64-0x6F, the session block Blizzard renumbered.
//
// The two joins are the same fields with one insertion:
//
//     1.14d  0x68, 37 bytes:  op | u32 hash | u16 token | u8 | u32 | u64 extra | u8 class | name[16]
//     1.10f  0x67, 29 bytes:  op | u32 hash | u16 gameId| u8 | u32 |             u8 class | name[16]
//
// so translating is dropping bytes 12..20 and renumbering the opcode. The leading fields line up
// exactly, which matters because d2ingress rewrites the token at byte 5 into the engine's game id
// and that lands on 1.10f's gameId field unchanged.

/// 1.14d's join opcode and length. `join_110f` is what the 1.10f engine expects.
pub const join_114d: u8 = 0x68;
pub const join_114d_len: usize = 37;
pub const join_110f: u8 = 0x67;
pub const join_110f_len: usize = 29;

/// Rewrite a 1.14d join in `src` into the 1.10f form in `dst`, returning its length. Null when
/// `src` is not a 1.14d join, so a caller can pass every packet through and only pay for the one.
/// Rewrite a 1.14d join into `target_op`'s 29-byte pre-1.14 shape. The payload is identical on
/// every pre-1.14 build measured — only the opcode moved, because 1.10f inserted two opcodes ahead
/// of it — so the same field surgery serves 1.07's 0x65 and 1.10f's 0x67.
pub fn translateJoin114dTo(src: []const u8, dst: []u8, target_op: u8) ?usize {
    if (src.len != join_114d_len or src[0] != join_114d) return null;
    if (dst.len < join_110f_len) return null;
    dst[0] = target_op;
    @memcpy(dst[1..12], src[1..12]); // hash, token/gameId, and the two fields after it
    @memcpy(dst[12..join_110f_len], src[20..join_114d_len]); // class + name, past the 8 dropped bytes
    return join_110f_len;
}

pub fn translateJoin114dTo110f(src: []const u8, dst: []u8) ?usize {
    return translateJoin114dTo(src, dst, join_110f);
}

test "a 1.14d join becomes a 1.10f join, field for field" {
    var src: [join_114d_len]u8 = @splat(0);
    src[0] = join_114d;
    std.mem.writeInt(u16, src[5..7], 0x1234, .little); // the game id d2ingress writes here
    src[7] = 3;
    @memcpy(src[12..20], &[_]u8{ 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4 }); // the block that is dropped
    src[20] = 5; // class
    @memcpy(src[21..25], "Tenf");

    var dst: [64]u8 = @splat(0);
    const n = translateJoin114dTo110f(&src, &dst).?;
    try std.testing.expectEqual(join_110f_len, n);
    try std.testing.expectEqual(join_110f, dst[0]);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, dst[5..7], .little));
    try std.testing.expectEqual(@as(u8, 3), dst[7]);
    try std.testing.expectEqual(@as(u8, 5), dst[12]); // class survived the shift
    try std.testing.expectEqualStrings("Tenf", dst[13..17]);
    // and the translated packet is exactly what the framer will accept
    try std.testing.expectEqual(@as(?usize, join_110f_len), packetLen(dst[0..n]));
}

test "anything that is not a 1.14d join is left alone" {
    var dst: [64]u8 = @splat(0);
    try std.testing.expect(translateJoin114dTo110f(&[_]u8{0x67}, &dst) == null);
    const wrong_len = [_]u8{join_114d} ** 20;
    try std.testing.expect(translateJoin114dTo110f(&wrong_len, &dst) == null);
}
