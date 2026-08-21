//! The character record a pre-1.10 engine expects, which is not the save the realm stores.
//!
//! The realm keeps one format — a v0x60 `.d2s` — and hands it to every engine. From 1.10f on that
//! is what the engine wants. Before that it is not: the older builds read a **130-byte record**
//! whose fields sit at different offsets, and they refuse the character rather than misread it.
//!
//! Every one of those refusals arrives as the same opaque number, so the shape below was read out
//! of each build's own writer and checked against its parser rather than guessed:
//!
//!     0x00  magic 0xaa55aa55
//!     0x04  version — exact per build (1.06b 0x47, 1.07 0x57)
//!     0x08  name[16], compared with the client's by strcmp
//!     0x18  status/flags dword (the modern save keeps this at 0x24)
//!     0x1c  u16 content revision — per build, and the engine bounds it by its own value
//!     0x1e  u16 0x10, bounded the same way
//!     0x20  u16 0x82 — the record's own size
//!
//! The trap worth naming: the modern save's **checksum at 0x0C falls inside `name[16]` here**.
//! Writing one leaves the name without its terminator, the strcmp fails, and the engine reports the
//! same number it uses for a bad version — which reads as "the format is wrong" when the format was
//! right and one field had been stamped over. Cost a long afternoon; hence the test below.
const std = @import("std");
const version = @import("version.zig");

pub const size: usize = 0x82;

/// The offsets the modern save keeps these at, for the fields that move.
const modern_name = 0x14;
const modern_status = 0x24;

/// Not every build that refuses the modern save wants the same thing.
///
/// 1.06b through 1.08 want the record above, fields moved. 1.09 does not: its writer stamps a
/// version and nothing else of this shape — no size at 0x20, no revision at 0x1c — so it reads the
/// modern layout and only disagrees about the number in the version field. Rewriting its header
/// the 1.08 way would break a save it would otherwise have taken.
pub const Shape = enum {
    /// Name at 0x08, status at 0x18, revision, size. No checksum — 0x0C is inside the name.
    record,
    /// The modern layout, with a different number in the version field. The checksum still applies
    /// and must be recomputed, because here 0x0C really is the checksum.
    version_only,
};

pub const Layout = struct {
    /// The engine compares this exactly; it is not a minimum.
    version: u32,
    /// Bounded by the engine against its own value, so it must not exceed it. Unused by
    /// `version_only`.
    revision: u16 = 0,
    shape: Shape = .record,
};

/// What `v` wants handed to it, or null when it takes the realm's save unchanged.
///
/// Every number here is out of that build's own writer, not its neighbour's: 1.08 writes 0x59 where
/// 1.07 writes 0x57, and 1.09 writes 0x5c in a different shape entirely.
pub fn layout(v: version.Version) ?Layout {
    return switch (v) {
        .v106b => .{ .version = 0x47, .revision = 0xdd },
        .v107 => .{ .version = 0x57, .revision = 0x13f },
        .v108 => .{ .version = 0x59, .revision = 0x13f },
        .v109b, .v109d => .{ .version = 0x5c, .shape = .version_only },
        // 1.10f and later read the modern save as it is stored.
        else => null,
    };
}

/// The save checksum, over the whole buffer with its own field zeroed. Only `version_only` needs
/// it: the `record` shape has no checksum field, because 0x0C is inside the name there.
fn checksum(buf: []u8) u32 {
    @memset(buf[0x0c..0x10], 0);
    var sum: u32 = 0;
    for (buf) |b| {
        const carry: u32 = @intFromBool(sum & 0x8000_0000 != 0);
        sum = @as(u32, b) +% carry +% (sum *% 2);
    }
    return sum;
}

/// Rewrite the realm's `.d2s` into `l`'s record, in place, returning the length to send.
///
/// The tail of the save rides along untouched: only the header moves, and the engine reads its
/// record out of the front.
pub fn fromModern(buf: []u8, l: Layout) usize {
    if (buf.len < size) return buf.len;
    if (l.shape == .version_only) {
        std.mem.writeInt(u32, buf[4..8], l.version, .little);
        const c = checksum(buf);
        std.mem.writeInt(u32, buf[0x0c..0x10], c, .little);
        return buf.len;
    }
    const status = buf[modern_status];
    var name: [16]u8 = undefined;
    @memcpy(&name, buf[modern_name..][0..16]);

    std.mem.writeInt(u32, buf[4..8], l.version, .little);
    @memcpy(buf[8..24], &name); // name[16] at 0x08 — and nothing else may be written into it
    std.mem.writeInt(u32, buf[0x18..0x1c], status, .little);
    std.mem.writeInt(u16, buf[0x1c..0x1e], l.revision, .little);
    std.mem.writeInt(u16, buf[0x1e..0x20], 0x10, .little);
    std.mem.writeInt(u16, buf[0x20..0x22], @intCast(size), .little);
    return buf.len;
}

fn sample(name: []const u8, status: u8) [200]u8 {
    var b: [200]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], 0xaa55aa55, .little);
    std.mem.writeInt(u32, b[4..8], 0x60, .little);
    std.mem.writeInt(u32, b[8..12], 200, .little); // declared size
    std.mem.writeInt(u32, b[12..16], 0xdeadbeef, .little); // checksum — must not survive into the name
    @memcpy(b[modern_name..][0..name.len], name);
    b[modern_status] = status;
    return b;
}

test "the fields land where the engine reads them" {
    var b = sample("Zeta", 0x21);
    _ = fromModern(&b, layout(.v106b).?);
    try std.testing.expectEqual(@as(u32, 0x47), std.mem.readInt(u32, b[4..8], .little));
    try std.testing.expectEqualStrings("Zeta", std.mem.sliceTo(b[8..24], 0));
    try std.testing.expectEqual(@as(u32, 0x21), std.mem.readInt(u32, b[0x18..0x1c], .little));
    try std.testing.expectEqual(@as(u16, 0xdd), std.mem.readInt(u16, b[0x1c..0x1e], .little));
    try std.testing.expectEqual(@as(u16, 0x10), std.mem.readInt(u16, b[0x1e..0x20], .little));
    try std.testing.expectEqual(@as(u16, 0x82), std.mem.readInt(u16, b[0x20..0x22], .little));
}

test "no checksum survives inside the name, which is what broke this the first time" {
    // 0x0C is the modern save's checksum and this record's name[4..8]. If anything writes there the
    // name loses its terminator, the engine's strcmp fails, and it reports a bad-version number.
    var b = sample("Zeta", 0x21);
    _ = fromModern(&b, layout(.v106b).?);
    try std.testing.expectEqual(@as(u8, 0), b[0x0c]); // "Zeta" is 4 long, so this is its terminator
    try std.testing.expect(std.mem.readInt(u32, b[0x0c..0x10], .little) != 0xdeadbeef);
}

test "a full-length name still terminates inside the field" {
    var b = sample("Abcdefghijklmno", 0x21); // 15, the most the engine keeps
    _ = fromModern(&b, layout(.v107).?);
    try std.testing.expectEqualStrings("Abcdefghijklmno", std.mem.sliceTo(b[8..24], 0));
    try std.testing.expectEqual(@as(u32, 0x57), std.mem.readInt(u32, b[4..8], .little));
    try std.testing.expectEqual(@as(u16, 0x13f), std.mem.readInt(u16, b[0x1c..0x1e], .little));
}

test "1.10f and later are handed the save unchanged" {
    try std.testing.expect(layout(.v110f) == null);
    try std.testing.expect(layout(.v113c) == null);
    try std.testing.expect(layout(.v114d) == null);
}

test "1.08 is 1.07's shape with its own number, read from its own writer" {
    var b = sample("Zeta", 0x21);
    _ = fromModern(&b, layout(.v108).?);
    try std.testing.expectEqual(@as(u32, 0x59), std.mem.readInt(u32, b[4..8], .little));
    try std.testing.expectEqualStrings("Zeta", std.mem.sliceTo(b[8..24], 0));
}

test "1.09 keeps the modern layout and only its version differs" {
    var b = sample("Zeta", 0x21);
    const before_name = b[modern_name..][0..16].*;
    _ = fromModern(&b, layout(.v109d).?);
    try std.testing.expectEqual(@as(u32, 0x5c), std.mem.readInt(u32, b[4..8], .little));
    // The name stays where the modern save keeps it — moving it would break a save it would take.
    try std.testing.expectEqualSlices(u8, &before_name, b[modern_name..][0..16]);
    // And its checksum is real here, because 0x0C is the checksum in this shape.
    try std.testing.expect(std.mem.readInt(u32, b[0x0c..0x10], .little) != 0xdeadbeef);
}
