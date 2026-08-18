//! The client-to-server packet vocabulary of a specific engine build.
//!
//! A TCP read is not a packet: the server has to frame the stream before D2Game ever sees it. The
//! real D2Net did that in `SERVER_ValidateClientPacket` @0x6FC01FE0 via `SERVER_GetClientPacketSize`
//! @0x6FC01E60, which indexes a table at **0x6FC08418** by the leading opcode. Replacing D2Net means
//! replacing that, and anything that speaks to the server — a test client included — needs the same
//! table, which is why it lives in a package rather than inside the DLL.

const std = @import("std");

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
pub const packet_size = [0x70]i32{
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
pub fn packetLen(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    // 0xFF is the fixed-size control packet the table does not cover.
    if (op == 0xFF) return if (buf.len < 16) null else 16;
    if (op >= packet_size.len) return 0;
    const entry = packet_size[op];
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


test "the join is 0x67 and 29 bytes on 1.10f" {
    // 1.14d joins with 0x68 at 37; here 0x68 is a one-byte end-game. Getting this backwards is
    // what makes a 1.14d client desynchronise on its opening packet.
    try std.testing.expectEqual(@as(i32, 29), packet_size[0x67]);
    try std.testing.expectEqual(@as(i32, 1), packet_size[0x68]);
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
