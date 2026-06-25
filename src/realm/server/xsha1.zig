//! Battle.net's "Broken SHA-1" (xSHA-1) — the OLS account-password hash. It is NOT
//! standard SHA-1. REVERSE-ENGINEERED from Game.exe 1.14d D2Client::_net_sid::SHA1
//! (@0x5209d0) + SHA1_Hashing (@0x5206b0), and VERIFIED bit-for-bit against a real
//! 1.14d client login (see tests). Deviations from FIPS SHA-1:
//!   * the 16 message words are read LITTLE-ENDIAN (standard SHA-1 is big-endian);
//!   * the message expansion is MANGLED — instead of rotl(xor,1) it sets a single bit:
//!       w[i] = rotl(1, (w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16]) & 0x1f)
//!   * output is h0..h4 written LITTLE-ENDIAN -> 20 bytes.
//! The 80-round compression and the four f/k groups are otherwise standard.
//!
//! Padding: zero-fill to a multiple of 64 bytes — NO 0x80 terminator, NO length
//! suffix. For OLS the hashed inputs are always short (<= 64 bytes), so we hash
//! exactly ONE 64-byte block. CheckRevision and the CD-key hash use STANDARD SHA-1
//! (D2's SBig SHA1), NOT this — only passwords use the broken variant.
const std = @import("std");

fn rotl(comptime T: type, x: T, n: u5) T {
    return std.math.rotl(T, x, n);
}

/// xSHA-1 of a single block. `data` must be <= 64 bytes.
pub fn xsha1(data: []const u8) [20]u8 {
    std.debug.assert(data.len <= 64);

    var block: [64]u8 = [_]u8{0} ** 64;
    @memcpy(block[0..data.len], data);

    var w: [80]u32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
    }
    // Mangled expansion: w[i] = rotl(1, (xor) & 0x1f) — a single set bit, NOT rotl(xor,1).
    while (i < 80) : (i += 1) {
        const amt: u5 = @intCast((w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]) & 0x1f);
        w[i] = rotl(u32, 1, amt);
    }

    var h0: u32 = 0x67452301;
    var h1: u32 = 0xEFCDAB89;
    var h2: u32 = 0x98BADCFE;
    var h3: u32 = 0x10325476;
    var h4: u32 = 0xC3D2E1F0;

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;

    i = 0;
    while (i < 80) : (i += 1) {
        var f: u32 = undefined;
        var k: u32 = undefined;
        if (i < 20) {
            f = (b & c) | (~b & d);
            k = 0x5A827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }
        const t = rotl(u32, a, 5) +% f +% e +% k +% w[i];
        e = d;
        d = c;
        c = rotl(u32, b, 30);
        b = a;
        a = t;
    }

    h0 +%= a;
    h1 +%= b;
    h2 +%= c;
    h3 +%= d;
    h4 +%= e;

    var out: [20]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], h0, .little);
    std.mem.writeInt(u32, out[4..8], h1, .little);
    std.mem.writeInt(u32, out[8..12], h2, .little);
    std.mem.writeInt(u32, out[12..16], h3, .little);
    std.mem.writeInt(u32, out[16..20], h4, .little);
    return out;
}

/// OLS login double-hash: xsha1(clientToken_le ++ serverToken_le ++ pwhash).
pub fn doubleHash(client_token: u32, server_token: u32, pwhash: [20]u8) [20]u8 {
    var buf: [28]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], client_token, .little);
    std.mem.writeInt(u32, buf[4..8], server_token, .little);
    @memcpy(buf[8..28], &pwhash);
    return xsha1(&buf);
}

const testing = std.testing;

test "xsha1 known vector" {
    // brokenSha1("1234567890") == 99f0fab8b5b4523e0d58e5efe126fa5f12633b4b (state words, LE bytes)
    const h = xsha1("1234567890");
    try testing.expectEqualSlices(u8, &[_]u8{
        0xb8, 0xfa, 0xf0, 0x99, 0x3e, 0x52, 0xb4, 0xb5, 0xef, 0xe5,
        0x58, 0x0d, 0x5f, 0xfa, 0x26, 0xe1, 0x4b, 0x3b, 0x63, 0x12,
    }, &h);
}

test "doubleHash matches a real 1.14d client login" {
    // Captured from a live SID_LOGONRESPONSE2: password "secret",
    // clientToken=0xe56678a5, serverToken=0x1234abcd -> hash begins 40 3e 27 44...
    const inner = xsha1("secret");
    const got = doubleHash(0xe56678a5, 0x1234abcd, inner);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x40, 0x3e, 0x27, 0x44, 0xef, 0x8b, 0x9c, 0x7d, 0x34, 0x91,
        0x12, 0xf6, 0x54, 0x3e, 0x0b, 0x6c, 0x81, 0xfa, 0xd6, 0xc6,
    }, &got);
}
