//! Battle.net "Broken SHA-1" (xSHA-1) — mirror of src/realm/server/xsha1.zig so
//! the clientless harness computes the SAME OLS password hashes the server does
//! (create/verify round-trip is internally consistent). See that file for the
//! deviations from standard SHA-1 (little-endian words; mangled expansion
//! w[i]=rotl(1,(xor)&0x1f); RE'd from Game.exe, verified vs a real client login).
const std = @import("std");

/// xSHA-1 of a single block; `data` must be <= 64 bytes.
pub fn xsha1(data: []const u8) [20]u8 {
    std.debug.assert(data.len <= 64);
    var block: [64]u8 = [_]u8{0} ** 64;
    @memcpy(block[0..data.len], data);

    var w: [80]u32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
    while (i < 80) : (i += 1) w[i] = std.math.rotl(u32, 1, @as(u5, @intCast((w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]) & 0x1f)));

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
        const t = std.math.rotl(u32, a, 5) +% f +% e +% k +% w[i];
        e = d;
        d = c;
        c = std.math.rotl(u32, b, 30);
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

/// xsha1 of the lowercased password (the account hash used by CREATEACCOUNT2).
pub fn passwordHash(password: []const u8) [20]u8 {
    var lc: [64]u8 = undefined;
    const n = @min(password.len, lc.len);
    for (password[0..n], 0..) |ch, i| lc[i] = std.ascii.toLower(ch);
    return xsha1(lc[0..n]);
}
