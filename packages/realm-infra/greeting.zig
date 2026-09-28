//! The greeting an ingress sends a game client on accept, before it knows which game server the
//! client belongs to.
//!
//! The client will not send GAMELOGON until it has seen one, and the ingress cannot route until
//! it has read GAMELOGON, so the ingress speaks first on the server's behalf. The engine's own is
//! a 0xAF frame whose 2nd byte is the client's phase flag: `af 00` picks the raw, unframed
//! receive path and `af 01` the length-framed Huffman one (ThreadClientToServer @0x52ab30).
//! The bytes are sent verbatim and not checked against that, so any value can be tried against
//! a client. Because it goes out before routing, it is one value per ingress: every engine
//! behind it sees the client in whatever mode this greeting put it in.
const std = @import("std");

/// Largest greeting accepted, so a pasted blob is refused rather than sent.
pub const max_len = 64;

pub const Greeting = struct {
    buf: [max_len]u8 = .{ 0xaf, 0x00 } ++ .{0} ** (max_len - 2),
    len: u8 = 2,

    pub fn bytes(g: *const Greeting) []const u8 {
        return g.buf[0..g.len];
    }
};

pub const ParseError = error{ Empty, BadHex, TooLong };

/// Parse a greeting written as hex ("af00", "af01", case-insensitive).
pub fn parse(hex: []const u8) ParseError!Greeting {
    if (hex.len == 0) return error.Empty;
    if (hex.len % 2 != 0) return error.BadHex;
    if (hex.len / 2 > max_len) return error.TooLong;
    var g = Greeting{};
    const out = std.fmt.hexToBytes(&g.buf, hex) catch return error.BadHex;
    g.len = @intCast(out.len);
    return g;
}

/// What a bad value means, for the startup error.
pub fn describe(e: ParseError) []const u8 {
    return switch (e) {
        error.Empty => "is empty",
        error.BadHex => "is not hex (an even number of 0-9, a-f digits)",
        error.TooLong => std.fmt.comptimePrint("is longer than {d} bytes", .{max_len}),
    };
}

test "parse: the default is af00" {
    const t = std.testing;
    try t.expectEqualSlices(u8, &.{ 0xaf, 0x00 }, (Greeting{}).bytes());
    try t.expectEqualSlices(u8, &.{ 0xaf, 0x00 }, (try parse("af00")).bytes());
    try t.expectEqualSlices(u8, &.{ 0xaf, 0x00 }, (try parse("AF00")).bytes());
}

test "parse: any bytes go through, framed or not" {
    const t = std.testing;
    try t.expectEqualSlices(u8, &.{ 0xaf, 0x01 }, (try parse("af01")).bytes());
    try t.expectEqualSlices(u8, &.{ 0xaf, 0x12 }, (try parse("af12")).bytes());
    try t.expectEqualSlices(u8, &.{ 0xaf, 0x03, 0x11, 0x22 }, (try parse("af031122")).bytes());
    try t.expectEqualSlices(u8, &.{0x6b}, (try parse("6b")).bytes());
    try t.expectEqual(@as(usize, max_len), (try parse("00" ** max_len)).bytes().len);
}

test "parse: refuses what is not hex bytes" {
    const t = std.testing;
    try t.expectError(error.Empty, parse(""));
    try t.expectError(error.BadHex, parse("af0"));
    try t.expectError(error.BadHex, parse("afzz"));
    try t.expectError(error.BadHex, parse("af 00"));
    try t.expectError(error.TooLong, parse("00" ** (max_len + 1)));
}
