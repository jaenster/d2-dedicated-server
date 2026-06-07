//! Battle.net's "Broken SHA-1" (xSHA-1) — the OLS password hash. It is NOT
//! standard SHA-1; Blizzard's implementation has two documented deviations:
//!   * the 16 message words are read LITTLE-ENDIAN (standard SHA-1 is big-endian);
//!   * the message expansion omits the `rotl(...,1)` (the actual bug):
//!       w[i] = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16]   (no rotate).
//! The 80-round compression and the four f/k groups are otherwise standard.
//!
//! For OLS the hashed inputs are always short (<= 64 bytes), so we hash exactly
//! ONE 64-byte block: the input zero-padded to 64 bytes, with NO 0x80 terminator
//! and NO length suffix (Blizzard's broken hash does not pad like real SHA-1).
//! Output is h0..h4 written LITTLE-ENDIAN -> 20 bytes.
//!
//! This targets Blizzard's documented broken-SHA1. Exact real-client bit-compat
//! should later be confirmed against a packet capture — but the SERVER and the
//! HARNESS share this impl, so the create/verify round-trip is internally
//! consistent and self-verifying today.
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
    // Broken expansion: no rotl(...,1).
    while (i < 80) : (i += 1) {
        w[i] = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
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
