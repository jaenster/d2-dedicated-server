//! Portable, OS-independent core of the D2 (2020) CheckRevision algorithm.
//! No Win32, no libc — usable by native realmd to compute/validate a response.
//!   response = base64( SHA1( first4(b64decode(challenge)) + ":"+version+":" + sigOk ) )
const std = @import("std");

pub fn b64Decode(s: []const u8, out: []u8) usize {
    var dec = [_]i8{-1} ** 256;
    const al = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (al, 0..) |c, i| dec[c] = @intCast(i);
    var acc: u32 = 0; var bits: u5 = 0; var n: usize = 0;
    for (s) |c| {
        if (c == '=') break;
        const v = dec[c]; if (v < 0) continue;
        acc = (acc << 6) | @as(u32, @intCast(v)); bits +%= 6;
        if (bits >= 8) { bits -= 8; if (n < out.len) { out[n] = @intCast((acc >> bits) & 0xFF); n += 1; } }
    }
    return n;
}
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
pub fn b64Encode(data: []const u8, out: []u8) usize {
    var n: usize = 0; var i: usize = 0;
    while (i + 3 <= data.len) : (i += 3) {
        const x = (@as(u32, data[i]) << 16) | (@as(u32, data[i+1]) << 8) | data[i+2];
        out[n]=B64[(x>>18)&63]; out[n+1]=B64[(x>>12)&63]; out[n+2]=B64[(x>>6)&63]; out[n+3]=B64[x&63]; n+=4;
    }
    const rem = data.len - i;
    if (rem == 1) { const x=@as(u32,data[i])<<16; out[n]=B64[(x>>18)&63];out[n+1]=B64[(x>>12)&63];out[n+2]='=';out[n+3]='=';n+=4; }
    else if (rem == 2) { const x=(@as(u32,data[i])<<16)|(@as(u32,data[i+1])<<8); out[n]=B64[(x>>18)&63];out[n+1]=B64[(x>>12)&63];out[n+2]=B64[(x>>6)&63];out[n+3]='=';n+=4; }
    return n;
}

/// Compute the full base64 CheckRevision response into `out` (>= 28 bytes).
/// `challenge` is the server's base64 versionString. `version` is "a.b.c.d".
/// Returns the response slice, or null if the decoded challenge is < 4 bytes.
pub fn response(challenge: []const u8, version: []const u8, sig_ok: u8, out: []u8) ?[]const u8 {
    var dec: [256]u8 = undefined;
    const dn = b64Decode(challenge, &dec);
    if (dn < 4) return null;
    var input: [128]u8 = undefined;
    var il: usize = 0;
    @memcpy(input[0..4], dec[0..4]); il = 4;
    input[il] = ':'; il += 1;
    @memcpy(input[il..il+version.len], version); il += version.len;
    input[il] = ':'; il += 1;
    input[il] = sig_ok; il += 1;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input[0..il], &digest, .{});
    const fl = b64Encode(&digest, out);
    return out[0..fl];
}

/// True if the decoded challenge would trigger the localized legal-disclaimer MessageBox.
pub fn disclaimerTriggered(challenge: []const u8) bool {
    var dec: [256]u8 = undefined;
    const dn = b64Decode(challenge, &dec);
    return dn >= 5 and dec[dn-1] != 0;
}

// Vectors captured from the genuine Blizzard CheckRevision.dll (md5 d47c1bf9, 2020)
// loaded in-process under wine (host version 0.0.0.0, sigOk 0). See CHECKREVISION.md.
test "matches genuine DLL output" {
    var buf: [64]u8 = undefined;
    const vectors = .{
        .{ "ESIzRA==", "Gn4N/dAMHL/2ArqtmYpRoTjBy2M=" },
        .{ "3q2+7w==", "Bt+bKU5tubd8diRHXEMyjuPO/IU=" },
        .{ "/////w==", "7VN57zb1e9bTJUPqq5SfP0F6a6U=" },
        .{ "AAAAAA==", "C4iHoKEgbKl1ywe3pQKcik9MfOQ=" },
        .{ "AQIDBAUA", "++fQGF7klfGW9aFaayows9NrjSg=" }, // 6 bytes, trailing 0 -> first4 only
    };
    inline for (vectors) |v| {
        const r = response(v[0], "0.0.0.0", 0, &buf).?;
        try std.testing.expectEqualStrings(v[1], r);
    }
    // extra challenge bytes past the first 4 are ignored (matches genuine)
    const a = response("AQIDBAUA", "0.0.0.0", 0, &buf).?;
    var buf2: [64]u8 = undefined;
    const b = response("AQIDBP8A", "0.0.0.0", 0, &buf2).?;
    try std.testing.expectEqualStrings(a, b);
    // < 4 decoded bytes -> no response
    try std.testing.expect(response("AAA=", "0.0.0.0", 0, &buf) == null);
}
