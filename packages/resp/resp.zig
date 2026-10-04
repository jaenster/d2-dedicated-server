//! RESP — the Redis wire format, as a codec and nothing else.
//!
//! No sockets, no allocator, no libc: encoding writes into a caller's buffer, parsing reads from
//! one. The game server is an x86-windows DLL with only `realm_proto` (no `realm_infra`, so no
//! libc sockets), while realmd/ingress are native with both — an IO-free codec lets one
//! implementation serve both, same reasoning as `realm_proto`.
//!
//! A command is an array of bulk strings (`*<n>\r\n` then `$<len>\r\n<bytes>\r\n` per arg).
//! Replies: `+status`, `-error`, `:int`, `$bulk`, `*array`. Bulk strings are BINARY-SAFE — a .d2s
//! save contains NULs and stray \n, so a bulk value is read by declared length, never scanned.
const std = @import("std");

pub const Reply = union(enum) {
    status: []const u8,
    int: i64,
    /// `$-1` — the key does not exist. Distinct from an empty string.
    bulk: ?[]const u8,
    /// Header only; the caller reads that many replies after it.
    array_len: i64,
    err: []const u8,
};

/// Whether an error reply says this node is no longer the master we meant to talk to: a replica
/// refuses writes (`READONLY`) and one cut off from its master refuses everything (`MASTERDOWN`).
/// Retrying on the same connection cannot succeed; it has to be dropped and dialled again.
pub fn isWrongNode(err: []const u8) bool {
    return std.mem.startsWith(u8, err, "READONLY") or std.mem.startsWith(u8, err, "MASTERDOWN");
}

/// What a parse attempt produced.
pub const Parsed = union(enum) {
    /// A complete reply, and how many bytes of the input it consumed.
    ok: struct { reply: Reply, consumed: usize },
    /// The input holds a valid but incomplete reply — read more and try again.
    need_more,
    /// The input cannot be RESP. The connection is desynced and must be dropped: once framing
    /// is lost there is no way to find the start of the next reply.
    invalid,
};

/// Longest decimal a length or integer header may carry. RESP has no limit; this bounds how far
/// a malformed reply can make us scan.
const max_header_digits = 20;

/// Parse one reply from the front of `in`.
///
/// Slices in the result point INTO `in` — they are valid exactly as long as it is, so a caller
/// that compacts or refills its buffer must copy first.
pub fn parse(in: []const u8) Parsed {
    if (in.len == 0) return .need_more;
    const nl = std.mem.indexOfScalar(u8, in, '\n') orelse {
        // No terminator yet. Only keep waiting while the prefix could still become one.
        return if (in.len > max_header_digits + 2) .invalid else .need_more;
    };
    // Tolerate a bare \n as well as \r\n: the framing is defined with \r\n, but accepting both
    // costs nothing and a reply is never ambiguous either way.
    const end = if (nl > 0 and in[nl - 1] == '\r') nl - 1 else nl;
    // The type byte must sit before the terminator. A bare "\n" or "\r\n" has none; slicing past
    // the type byte would then run start > end.
    if (end < 1) return .invalid;
    const line = in[1..end]; // past the type byte
    const after = nl + 1;

    return switch (in[0]) {
        '+' => .{ .ok = .{ .reply = .{ .status = line }, .consumed = after } },
        '-' => .{ .ok = .{ .reply = .{ .err = line }, .consumed = after } },
        ':' => blk: {
            const v = std.fmt.parseInt(i64, line, 10) catch break :blk .invalid;
            break :blk .{ .ok = .{ .reply = .{ .int = v }, .consumed = after } };
        },
        '$' => blk: {
            const n = std.fmt.parseInt(i64, line, 10) catch break :blk .invalid;
            if (n < 0) break :blk .{ .ok = .{ .reply = .{ .bulk = null }, .consumed = after } };
            // A declared length near maxInt would overflow the sums below.
            if (n > std.math.maxInt(u32)) break :blk .invalid;
            const len: usize = @intCast(n);
            // The payload plus its own CRLF must all be present before this reply is complete.
            if (in.len < after + len + 1) break :blk .need_more;
            // +2 for the trailing CRLF, or +1 if the peer sent a bare \n. A lone \r at the very
            // end is the first half of a CRLF: wait for the rest rather than claim a byte that
            // is not there.
            const tail: usize = if (in[after + len] == '\r') 2 else 1;
            if (in.len < after + len + tail) break :blk .need_more;
            break :blk .{ .ok = .{
                .reply = .{ .bulk = in[after..][0..len] },
                .consumed = after + len + tail,
            } };
        },
        '*' => blk: {
            const v = std.fmt.parseInt(i64, line, 10) catch break :blk .invalid;
            break :blk .{ .ok = .{ .reply = .{ .array_len = v }, .consumed = after } };
        },
        else => .invalid,
    };
}

/// Bytes needed to encode `args` as a command. Exact, so a caller can size or reject up front.
pub fn encodedLen(args: []const []const u8) usize {
    var n: usize = 1 + decimalLen(args.len) + 2;
    for (args) |a| n += 1 + decimalLen(a.len) + 2 + a.len + 2;
    return n;
}

/// Encode `args` as a RESP command into `buf`. Null if it does not fit — never a partial command,
/// since half a command on the wire desyncs the connection.
pub fn encode(buf: []u8, args: []const []const u8) ?[]const u8 {
    if (encodedLen(args) > buf.len) return null;
    var n: usize = 0;
    buf[n] = '*';
    n += 1;
    n += writeDecimal(buf[n..], args.len);
    n += writeCrlf(buf[n..]);
    for (args) |a| {
        buf[n] = '$';
        n += 1;
        n += writeDecimal(buf[n..], a.len);
        n += writeCrlf(buf[n..]);
        @memcpy(buf[n..][0..a.len], a);
        n += a.len;
        n += writeCrlf(buf[n..]);
    }
    return buf[0..n];
}

fn decimalLen(v: usize) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

fn writeDecimal(buf: []u8, v: usize) usize {
    const s = std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
    return s.len;
}

fn writeCrlf(buf: []u8) usize {
    buf[0] = '\r';
    buf[1] = '\n';
    return 2;
}

// tests

test "parse never slices past the input" {
    try std.testing.expectEqual(Parsed.need_more, parse(""));
    try std.testing.expectEqual(Parsed.invalid, parse("\n"));
    try std.testing.expectEqual(Parsed.invalid, parse("\r\n"));
    try std.testing.expectEqual(Parsed.invalid, parse("\r\n+OK\r\n"));
    try std.testing.expectEqual(Parsed.need_more, parse("+"));
    try std.testing.expectEqual(Parsed.need_more, parse("$"));
    try std.testing.expectEqual(Parsed.need_more, parse("+OK"));
    try std.testing.expectEqual(Parsed.need_more, parse("+OK\r"));
    try std.testing.expectEqual(Parsed.need_more, parse("$5\r\nhel"));
    try std.testing.expectEqual(Parsed.need_more, parse("$5\r\nhello"));
    try std.testing.expectEqual(Parsed.need_more, parse("$5\r\nhello\r"));
    try std.testing.expectEqual(Parsed.invalid, parse("$99999999999999\r\n"));
    try std.testing.expectEqual(Parsed.invalid, parse("$9223372036854775807\r\n"));
    // A truncated array: the header parses, the elements are the caller's next reads.
    switch (parse("*3\r\n$1\r\na\r\n")) {
        .ok => |o| try std.testing.expectEqual(@as(i64, 3), o.reply.array_len),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Parsed.need_more, parse("*3"));
    // Every prefix of a valid reply is need_more or ok, never a panic.
    const full = "$5\r\nhello\r\n";
    for (0..full.len) |i| _ = parse(full[0..i]);
}

test "encode is the exact length it promises" {
    var buf: [64]u8 = undefined;
    const args = [_][]const u8{ "GET", "realmd:x" };
    const out = encode(&buf, &args).?;
    try std.testing.expectEqual(encodedLen(&args), out.len);
    try std.testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$8\r\nrealmd:x\r\n", out);
}

test "encode refuses rather than truncating" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), encode(&buf, &.{ "GET", "a-long-key" }));
}

test "parse classifies each reply type" {
    switch (parse("+OK\r\n")) {
        .ok => |o| {
            try std.testing.expectEqualStrings("OK", o.reply.status);
            try std.testing.expectEqual(@as(usize, 5), o.consumed);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (parse(":42\r\n")) {
        .ok => |o| try std.testing.expectEqual(@as(i64, 42), o.reply.int),
        else => return error.TestUnexpectedResult,
    }
    switch (parse("*3\r\n")) {
        .ok => |o| try std.testing.expectEqual(@as(i64, 3), o.reply.array_len),
        else => return error.TestUnexpectedResult,
    }
    switch (parse("-ERR nope\r\n")) {
        .ok => |o| try std.testing.expectEqualStrings("ERR nope", o.reply.err),
        else => return error.TestUnexpectedResult,
    }
}

test "a missing key is null, not empty" {
    switch (parse("$-1\r\n")) {
        .ok => |o| try std.testing.expectEqual(@as(?[]const u8, null), o.reply.bulk),
        else => return error.TestUnexpectedResult,
    }
    switch (parse("$0\r\n\r\n")) {
        .ok => |o| try std.testing.expectEqualStrings("", o.reply.bulk.?),
        else => return error.TestUnexpectedResult,
    }
}

test "bulk values are binary safe" {
    // The bytes a .d2s save is made of: NULs, a stray \n, and a lone \r.
    const payload = "\x00\x01\nabc\r\x00";
    var buf: [64]u8 = undefined;
    const wire = std.fmt.bufPrint(&buf, "${d}\r\n{s}\r\n", .{ payload.len, payload }) catch unreachable;
    switch (parse(wire)) {
        .ok => |o| {
            try std.testing.expectEqualStrings(payload, o.reply.bulk.?);
            try std.testing.expectEqual(wire.len, o.consumed);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "an incomplete reply asks for more rather than guessing" {
    try std.testing.expectEqual(Parsed.need_more, parse("+OK"));
    try std.testing.expectEqual(Parsed.need_more, parse("$5\r\nabc"));
    try std.testing.expectEqual(Parsed.need_more, parse("$5\r\nabcde")); // payload but no CRLF
    try std.testing.expectEqual(Parsed.need_more, parse(""));
}

test "garbage is rejected instead of scanned forever" {
    try std.testing.expectEqual(Parsed.invalid, parse("nonsense\r\n"));
    try std.testing.expectEqual(Parsed.invalid, parse(":notanumber\r\n"));
    // A long run with no terminator cannot become a valid header.
    try std.testing.expectEqual(Parsed.invalid, parse("+" ++ ("x" ** 40)));
}

test "consumed lets replies be read back to back" {
    const wire = "+OK\r\n:7\r\n$3\r\nabc\r\n";
    var off: usize = 0;
    var seen: usize = 0;
    while (off < wire.len) {
        switch (parse(wire[off..])) {
            .ok => |o| {
                off += o.consumed;
                seen += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(wire.len, off);
}

test "only the replies of a node that is not the master are wrong-node errors" {
    try std.testing.expect(isWrongNode("READONLY You can't write against a read only replica."));
    try std.testing.expect(isWrongNode("MASTERDOWN Link with MASTER is down"));
    try std.testing.expect(!isWrongNode("ERR unknown command"));
    try std.testing.expect(!isWrongNode("WRONGTYPE Operation against a key"));
    try std.testing.expect(!isWrongNode(""));
}
