//! D2 CD-key decode + SID_AUTH_CHECK key-block hashing, clientless.
//! Reverse-engineered from Game.exe 1.14d:
//!   - 16-char decode: BNSEND_DecodeCDKeyString @0x51ddd0
//!   - AUTH_CHECK hash: BNSEND_HashCDKeyData @0x51dc80 = STANDARD SHA-1 (D2 "SBig SHA1",
//!     decompiled in full: textbook FIPS SHA-1 — NOT the broken password hash in xsha1.zig)
//!   - packet layout / hash input: NET_SID_CLIENT_Send_0x51_AuthCheck @0x521dc0
//!       per key {keyLen, product, public, 0, SHA1(clientToken, serverToken, product, public, private)}
//!
//! Verification: realmd bncs.zig onAuthCheck hexdumps the real client's key block; feed
//! decode16 the SAME key the client uses and the {product, public, hash} must match (the
//! oracle method). 26-char keys use a DIFFERENT decode (TransformCdKeyToken, base5/bignum) —
//! not yet ported; the hash step is identical (standard SHA-1).
const std = @import("std");

pub const Decoded = struct { product: u32, public: u32, private: u32 };

fn parseHexWindow(buf: []const u8) u32 {
    var v: u32 = 0;
    for (buf) |ch| {
        const d: u32 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => break, // strtoul stops at the first non-hex char
        };
        v = v *% 16 +% d;
    }
    return v;
}

/// Decode a 16-character D2 CD-key into its product/public/private values.
/// Faithful port of BNSEND_DecodeCDKeyString (the checksum-validity GATE is omitted —
/// callers supply a real key; product/public/private don't depend on the checksum).
pub fn decode16(key: []const u8) ?Decoded {
    if (key.len < 16) return null;
    var buf: [16]u8 = undefined;
    @memcpy(&buf, key[0..16]);

    // permutation: for i = 15..0 swap buf[i] <-> buf[(i+7) & 0xF]
    var i: isize = 15;
    while (i >= 0) : (i -= 1) {
        const ui: usize = @intCast(i);
        const j = (ui + 7) & 0xf;
        const tmp = buf[ui];
        buf[ui] = buf[j];
        buf[j] = tmp;
    }

    // bitstream XOR transform (toupper, then conditional munge)
    var bs: u32 = 0x13ac9741;
    i = 15;
    while (i >= 0) : (i -= 1) {
        const ui: usize = @intCast(i);
        const c = std.ascii.toUpper(buf[ui]);
        if (c < '8') {
            buf[ui] = @intCast((bs & 7) ^ c);
            bs >>= 3;
        } else if (c < 'A') {
            buf[ui] = @intCast((@as(u32, @intCast(ui)) & 1) ^ c);
        } else {
            buf[ui] = c;
        }
    }

    // overlapping hex windows: product=[0..3], public=[2..9], private=[8..16]
    return .{
        .product = parseHexWindow(buf[0..3]),
        .public = parseHexWindow(buf[2..9]),
        .private = parseHexWindow(buf[8..16]),
    };
}

/// SID_AUTH_CHECK per-key hash = STANDARD SHA-1(clientToken, serverToken, product, public, private),
/// each a little-endian u32. Returns the 20-byte digest (standard big-endian SHA-1 output, as D2 sends it).
pub fn authCheckHash(client_token: u32, server_token: u32, d: Decoded) [20]u8 {
    var in: [20]u8 = undefined;
    std.mem.writeInt(u32, in[0..4], client_token, .little);
    std.mem.writeInt(u32, in[4..8], server_token, .little);
    std.mem.writeInt(u32, in[8..12], d.product, .little);
    std.mem.writeInt(u32, in[12..16], d.public, .little);
    std.mem.writeInt(u32, in[16..20], d.private, .little);
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&in, &out, .{});
    return out;
}

/// One SID_AUTH_CHECK key block, ready to serialize: keyLen, product, public, 0, hash[20].
pub const KeyBlock = struct {
    key_len: u32,
    product: u32,
    public: u32,
    reserved: u32 = 0,
    hash: [20]u8,

    /// Serialize to the 36-byte on-wire layout: 4 u32 (little-endian) + the 20-byte hash.
    pub fn writeWire(self: KeyBlock, out: *[36]u8) void {
        std.mem.writeInt(u32, out[0..4], self.key_len, .little);
        std.mem.writeInt(u32, out[4..8], self.product, .little);
        std.mem.writeInt(u32, out[8..12], self.public, .little);
        std.mem.writeInt(u32, out[12..16], self.reserved, .little);
        @memcpy(out[16..36], &self.hash);
    }
};

// ── 26-char key decode (WC3-style; D2 LoD expansion key) ──────────────────────
// Faithful port of BNNEWS_DecodeCDKey26Char @0x51df90 -> NET_SID_CLIENT_TransformCdKeyToken
// @0x522ae0 and helpers (ExpandCdKeyToBase5 @0x522650, BigNumMultiplyAccumulate @0x5225e0,
// SubstitutionBoxShuffle @0x522980, PermuteBitsLFSR @0x5226d0). Tables read from Game.exe:
// the char->digit map @0x6e0100 and the 30x16 S-box @0x6dff20.
// UNVERIFIED: no public 26-char key vector exists; confirm via a real LoD-client AUTH_CHECK
// capture at realmd (the oracle), same as decode16.

// char (ASCII) -> base-25 digit (0..24); 0xFF = invalid. Alphabet 246789BCDEFGHJKMNPRTVWXZY (+lowercase).
const CHARTBL = [128]u8{
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 0,   255, 1,   255, 2,   3,   4,   5,   255, 255, 255, 255, 255, 255,
    255, 255, 6,   7,   8,   9,   10,  11,  12,  255, 13,  14,  255, 15,  16,  255,
    17,  255, 18,  255, 19,  255, 20,  21,  22,  23,  24,  255, 255, 255, 255, 255,
    255, 255, 6,   7,   8,   9,   10,  11,  12,  255, 13,  14,  255, 15,  16,  255,
    17,  255, 18,  255, 19,  255, 20,  21,  22,  23,  24,  255, 255, 255, 255, 255,
};
// 30 rows x 16 nibbles, S-box for the substitution shuffle.
const SBOX = [480]u8{
    9,  4,  7,  15, 13, 10, 3,  11, 1,  2,  12, 8,  6,  14, 5,  0,  9,  11, 5,  4,  8,  15, 1,  14, 7,  0,  3,  2,  10, 6,  13, 12,
    12, 14, 1,  4,  9,  15, 10, 11, 13, 6,  0,  8,  7,  2,  5,  3,  11, 2,  5,  14, 13, 3,  9,  0,  1,  15, 7,  12, 10, 6,  4,  8,
    6,  2,  4,  5,  11, 8,  12, 14, 13, 15, 7,  1,  10, 0,  3,  9,  5,  4,  14, 12, 7,  6,  13, 10, 15, 2,  9,  1,  0,  11, 8,  3,
    12, 7,  8,  15, 11, 0,  5,  9,  13, 10, 6,  14, 2,  4,  3,  1,  3,  10, 14, 8,  1,  11, 5,  4,  2,  15, 13, 12, 6,  7,  9,  0,
    12, 13, 1,  15, 8,  14, 5,  11, 3,  10, 9,  0,  7,  2,  4,  6,  13, 10, 7,  14, 1,  6,  11, 8,  15, 12, 5,  2,  3,  0,  4,  9,
    3,  14, 7,  5,  11, 15, 8,  12, 1,  10, 4,  13, 0,  6,  9,  2,  11, 6,  9,  4,  1,  8,  10, 13, 7,  14, 0,  12, 15, 2,  3,  5,
    12, 7,  8,  13, 3,  11, 0,  14, 6,  15, 9,  4,  10, 1,  5,  2,  12, 6,  13, 9,  11, 0,  1,  2,  15, 7,  3,  4,  10, 14, 8,  5,
    3,  6,  1,  5,  11, 12, 8,  0,  15, 14, 9,  4,  7,  10, 13, 2,  10, 7,  11, 15, 2,  8,  0,  13, 14, 12, 1,  6,  9,  3,  5,  4,
    10, 11, 13, 4,  3,  8,  5,  9,  1,  0,  15, 12, 7,  14, 2,  6,  11, 4,  13, 15, 1,  6,  3,  14, 7,  10, 12, 8,  9,  2,  5,  0,
    9,  6,  7,  0,  1,  10, 13, 2,  3,  14, 15, 12, 5,  11, 4,  8,  13, 14, 5,  6,  1,  9,  8,  12, 2,  15, 3,  7,  11, 4,  0,  10,
    9,  15, 4,  0,  1,  6,  10, 14, 2,  3,  7,  13, 5,  11, 8,  12, 3,  14, 1,  10, 2,  12, 8,  4,  11, 7,  13, 0,  15, 6,  9,  5,
    7,  2,  12, 6,  10, 8,  11, 0,  15, 4,  3,  14, 9,  1,  13, 5,  12, 4,  5,  9,  10, 2,  8,  13, 3,  15, 1,  14, 6,  7,  11, 0,
    10, 8,  14, 13, 9,  15, 3,  0,  4,  6,  1,  12, 7,  11, 2,  5,  3,  12, 4,  10, 2,  15, 13, 14, 7,  0,  5,  8,  1,  6,  11, 9,
    10, 12, 1,  0,  9,  14, 13, 11, 3,  7,  15, 8,  5,  2,  4,  6,  14, 10, 1,  8,  7,  6,  5,  12, 2,  15, 0,  13, 3,  11, 4,  9,
    3,  8,  14, 0,  7,  9,  15, 12, 1,  6,  13, 2,  5,  10, 11, 4,  3,  10, 12, 4,  13, 11, 9,  14, 15, 6,  1,  7,  2,  0,  5,  8,
};

fn getNib(token: *const [4]u32, n: usize) u8 {
    const shift: u5 = @intCast((n & 7) * 4);
    return @intCast((token[3 - (n >> 3)] >> shift) & 0xf);
}
fn setNib(token: *[4]u32, n: usize, v: u8) void {
    const shift: u5 = @intCast((n & 7) * 4);
    const w = 3 - (n >> 3);
    token[w] = (@as(u32, v & 0xf) << shift) | (token[w] & ~(@as(u32, 0xf) << shift));
}
fn getBit(token: *const [4]u32, b: usize) u32 {
    const shift: u5 = @intCast(b & 31);
    return (token[3 - (b >> 5)] >> shift) & 1;
}
fn setBit(token: *[4]u32, b: usize, v: u32) void {
    const shift: u5 = @intCast(b & 31);
    const w = 3 - (b >> 5);
    token[w] = ((v & 1) << shift) | (token[w] & ~(@as(u32, 1) << shift));
}

pub const Decoded26 = struct { product: u32, public: u32, value3: [10]u8 };

pub fn decode26(key: []const u8) ?Decoded26 {
    if (key.len < 26) return null;

    // 1) char -> base-5 digit pairs, placed at a +49-mod-52 stride
    var base5 = [_]u8{0} ** 52;
    var out2: usize = 0x21;
    for (0..26) |in_idx| {
        const out1 = (out2 + 0x7b5) % 52;
        out2 = (out1 + 0x7b5) % 52;
        const dv = CHARTBL[key[in_idx] & 0x7f];
        if (dv == 0xff) return null; // invalid key char
        base5[out1] = dv / 5;
        base5[out2] = dv % 5;
    }

    // 2) base-5 -> 128-bit bignum (token[0]=MSW .. token[3]=LSW): token = token*5 + digit
    var token = [4]u32{ 0, 0, 0, 0 };
    var di: usize = 52;
    while (di > 0) : (di -= 1) {
        var carry: u64 = base5[di - 1];
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            const p = @as(u64, token[i - 1]) * 5 + carry;
            token[i - 1] = @truncate(p);
            carry = p >> 32;
        }
    }

    // 3) S-box substitution shuffle (30 nibbles, row = nibble index)
    var n: isize = 29;
    while (n >= 0) : (n -= 1) {
        const un: usize = @intCast(n);
        const row = un * 16;
        var acc: u8 = getNib(&token, un);
        var k: isize = 29;
        while (k > n) : (k -= 1) acc = SBOX[row + (getNib(&token, @intCast(k)) ^ SBOX[row + acc])];
        k = n - 1;
        while (k >= 0) : (k -= 1) acc = SBOX[row + (getNib(&token, @intCast(k)) ^ SBOX[row + acc])];
        setNib(&token, un, SBOX[row + acc] & 0xf);
    }

    // 4) LFSR bit permutation over 120 bits: dst bit i <- src bit (11*i mod 120)
    const src = token;
    var src_bit: usize = 0;
    for (0..120) |dst_bit| {
        setBit(&token, dst_bit, getBit(&src, src_bit));
        src_bit += 11;
        if (src_bit >= 120) src_bit -= 120;
    }

    // 5) extract
    var v3: [10]u8 = undefined;
    std.mem.writeInt(u16, v3[0..2], @truncate(token[1]), .little);
    std.mem.writeInt(u32, v3[2..6], token[2], .little);
    std.mem.writeInt(u32, v3[6..10], token[3], .little);
    // Field order matches the AUTH_CHECK key block (verified against a real client capture):
    // packet "product" = token[0]>>10; packet "public" = (token[0]&0x3ff)<<16 | token[1]>>16.
    return .{
        .product = token[0] >> 10,
        .public = (token[0] & 0x3ff) << 16 | token[1] >> 16,
        .value3 = v3,
    };
}

/// Build the AUTH_CHECK key block for a 16-char key. null if the key is malformed.
/// NOTE: 16-char hash is UNVERIFIED — per BNSEND_PrepareCDKeyHash @0x51dfc0 the 16-char
/// path uses the BROKEN SHA-1 (_net_sid::SHA1) over 24 bytes, not standard SHA-1. This
/// `authCheckHash` (standard) is a placeholder until a 16-char-key capture confirms the layout.
pub fn keyBlock16(key: []const u8, client_token: u32, server_token: u32) ?KeyBlock {
    const d = decode16(key) orelse return null;
    return .{
        .key_len = 16,
        .product = d.product,
        .public = d.public,
        .hash = authCheckHash(client_token, server_token, d),
    };
}

/// 26-char AUTH_CHECK per-key hash = standard SHA-1(clientToken ++ serverToken ++ product ++
/// public ++ value3), all little-endian. VERIFIED bit-for-bit against a real LoD client.
pub fn authCheckHash26(client_token: u32, server_token: u32, d: Decoded26) [20]u8 {
    var in: [26]u8 = undefined;
    std.mem.writeInt(u32, in[0..4], client_token, .little);
    std.mem.writeInt(u32, in[4..8], server_token, .little);
    std.mem.writeInt(u32, in[8..12], d.product, .little);
    std.mem.writeInt(u32, in[12..16], d.public, .little);
    @memcpy(in[16..26], &d.value3);
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&in, &out, .{});
    return out;
}

/// Build the AUTH_CHECK key block for a 26-char (LoD/expansion) key. VERIFIED against a real client.
pub fn keyBlock26(key: []const u8, client_token: u32, server_token: u32) ?KeyBlock {
    const d = decode26(key) orelse return null;
    return .{
        .key_len = 26,
        .product = d.product,
        .public = d.public,
        .hash = authCheckHash26(client_token, server_token, d),
    };
}

test "decode16 is deterministic and parses hex windows" {
    // No public real-key vector exists (keys are private); correctness is proven against a
    // real client's captured AUTH_CHECK block. This guards the port from regressions/crashes.
    const k = "0123456789ABCDEF";
    const a = decode16(k).?;
    const b = decode16(k).?;
    try std.testing.expectEqual(a.product, b.product);
    try std.testing.expectEqual(a.public, b.public);
    try std.testing.expectEqual(a.private, b.private);
    try std.testing.expect(decode16("tooshort") == null);
    // hash is a pure function of (tokens, decoded)
    const h1 = authCheckHash(0xCAFEBABE, 0x1234ABCD, a);
    const h2 = authCheckHash(0xCAFEBABE, 0x1234ABCD, a);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "decode26 + keyBlock26" {
    // decode26 and authCheckHash26 were VERIFIED bit-for-bit against a real 1.14d LoD client:
    // both keys' product/public AND the per-key SHA-1 in SID_AUTH_CHECK matched our output.
    // (The real key strings are private, so they're not committed; this test uses a synthetic
    // alphabet key — 246789BCDEFGHJKMNPRTVWXZY — for determinism + envelope structure.)
    const k = "246789BCDEFGHJKMNPRTVWXZY2";
    const a = decode26(k).?;
    const b = decode26(k).?;
    try std.testing.expectEqual(a.product, b.product);
    try std.testing.expectEqual(a.public, b.public);
    try std.testing.expectEqualSlices(u8, &a.value3, &b.value3);
    try std.testing.expect(decode26("short") == null);
    try std.testing.expect(decode26("1111111111111111111111111I") == null); // '1','I' invalid
    // keyBlock26 assembles a 36-byte wire block: keyLen(26) + product + public + 0 + hash[20]
    const blk = keyBlock26(k, 0xCAFEBABE, 0x1234ABCD).?;
    try std.testing.expectEqual(@as(u32, 26), blk.key_len);
    var wire: [36]u8 = undefined;
    blk.writeWire(&wire);
    try std.testing.expectEqual(@as(u32, 26), std.mem.readInt(u32, wire[0..4], .little));
}
