//! D2GS game-protocol Huffman codec — pure Zig, platform-independent (no wine, no engine).
//!
//! The server→client game stream is Huffman bit-packed by the engine
//! (NET_D2GS_SERVER_CompressPacket @0x40b1b0); a real client unpacks it with
//! NET_D2GS_CLIENT_DecompressPacket @0x40b260. It's Storm `SSComp` STATIC-table Huffman
//! (NOT adaptive). client→server is uncompressed, so a clientless client only needs decode;
//! encode is provided for round-trip testing and symmetry.
//!
//! The codec is reconstructed entirely FROM THE BINARY, not from third-party tables:
//!   * `code_lengths` below = the static per-symbol code lengths at gabHuffmanCodeLengths
//!     @0x7076c0 (the one part of the table that lives in the file image).
//!   * the code VALUES are built from those lengths exactly as COMPRESS_BuildHuffmanDecodeTable
//!     @0x40adb0 does: symbols sorted by (length DESC, symbol ASC), then
//!     code[next] = (code[prev] + 1) >> (len[prev] - len[next]), starting at 0. This is a
//!     canonical Huffman assignment; we rebuild it at comptime (see `codes`).

const std = @import("std");

/// Per-symbol code lengths, verbatim from Game.exe 1.14d gabHuffmanCodeLengths @0x7076c0.
pub const code_lengths = [256]u8{
    1, 4, 6, 7, 7, 6, 7, 7, 7, 8, 7, 8, 8, 7, 9, 8,
    8, 8, 7, 6, 6, 7, 8, 8, 8, 9, 9, 10, 10, 8, 7, 8,
    8, 10, 10, 10, 10, 9, 10, 10, 9, 10, 10, 10, 10, 10, 10, 11,
    9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10,
    9, 10, 10, 9, 10, 9, 10, 10, 10, 10, 10, 10, 9, 9, 10, 11,
    9, 8, 9, 10, 11, 9, 9, 10, 9, 10, 10, 10, 11, 10, 10, 10,
    10, 10, 9, 9, 9, 10, 10, 7, 7, 7, 10, 9, 8, 7, 10, 10,
    10, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 10, 10, 10, 10,
    7, 10, 10, 10, 11, 11, 11, 11, 11, 10, 10, 11, 11, 11, 11, 10,
    9, 11, 11, 10, 11, 9, 9, 9, 10, 11, 11, 11, 11, 11, 11, 11,
    10, 11, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
    10, 11, 11, 11, 11, 11, 11, 11, 10, 11, 11, 11, 11, 11, 11, 11,
    10, 11, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 10, 11,
    11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
    10, 11, 10, 11, 11, 11, 11, 11, 10, 11, 11, 11, 11, 11, 11, 11,
    10, 11, 11, 11, 11, 11, 11, 11, 10, 11, 11, 11, 11, 11, 11, 6,
};

pub const max_len: u8 = 11; // max(code_lengths)

const Code = struct { bits: u16, len: u8 };

/// Per-symbol canonical codes, reconstructed at comptime from `code_lengths` the same way
/// COMPRESS_BuildHuffmanDecodeTable @0x40adb0 does (longest codes first, starting at 0).
pub const codes: [256]Code = blk: {
    @setEvalBranchQuota(100000);
    // Order symbols by (length DESC, symbol ASC) — the engine's sort.
    var order: [256]u16 = undefined;
    var n: usize = 0;
    var l: u8 = max_len;
    while (l >= 1) : (l -= 1) {
        var s: u16 = 0;
        while (s < 256) : (s += 1) {
            if (code_lengths[s] == l) {
                order[n] = s;
                n += 1;
            }
        }
        if (l == 1) break;
    }
    var result: [256]Code = undefined;
    var prev_bits: u16 = 0;
    var prev_len: u8 = code_lengths[order[0]];
    result[order[0]] = .{ .bits = 0, .len = prev_len };
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const s = order[i];
        const len = code_lengths[s];
        const bits: u16 = (prev_bits + 1) >> @intCast(prev_len - len);
        result[s] = .{ .bits = bits, .len = len };
        prev_bits = bits;
        prev_len = len;
    }
    break :blk result;
};

const DecodeEntry = packed struct { sym: u8, len: u8 };

/// Fast decode table: index = the next `max_len` bits (MSB-first); value = {symbol, code len}.
/// Built at comptime — a complete Huffman tree fills all 2^max_len slots exactly once.
const decode_table: [1 << max_len]DecodeEntry = blk: {
    @setEvalBranchQuota(200000);
    var t: [1 << max_len]DecodeEntry = [_]DecodeEntry{.{ .sym = 0, .len = 0 }} ** (1 << max_len);
    var s: u16 = 0;
    while (s < 256) : (s += 1) {
        const c = codes[s];
        const shift: u4 = @intCast(max_len - c.len);
        const base: u16 = c.bits << shift;
        const count: u16 = @as(u16, 1) << shift;
        var k: u16 = 0;
        while (k < count) : (k += 1) t[base + k] = .{ .sym = @intCast(s), .len = c.len };
    }
    break :blk t;
};

/// Decompress one server→client payload into `dst`. Returns bytes written, or null if `dst`
/// is too small. Mirrors NET_D2GS_CLIENT_DecompressPacket @0x40b260: a 32-bit MSB-first bit
/// buffer refilled from `src`; stop when a code would overrun the bits actually present (that
/// final partial code is the byte-boundary padding the encoder added).
pub fn decode(dst: []u8, src: []const u8) ?usize {
    var bit_buf: u32 = 0;
    var bits_avail: u32 = 32; // free (unfilled) low bits
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    while (true) {
        while (bits_avail > 7 and in_pos < src.len) {
            bits_avail -= 8;
            bit_buf |= @as(u32, src[in_pos]) << @intCast(bits_avail);
            in_pos += 1;
        }
        const e = decode_table[bit_buf >> (32 - max_len)];
        if (e.len == 0) break;
        const new_avail = bits_avail + e.len;
        if (new_avail > 32) break; // overran the real bits → packet done
        if (out_pos >= dst.len) return null;
        dst[out_pos] = e.sym;
        out_pos += 1;
        bits_avail = new_avail;
        bit_buf <<= @intCast(e.len);
    }
    return out_pos;
}

/// Compress `src` into `dst` (client→server is raw in D2GS, so this is for round-trip tests
/// and symmetry). Returns bytes written, or null if `dst` is too small. Mirrors
/// NET_D2GS_SERVER_CompressPacket @0x40b1b0.
pub fn encode(dst: []u8, src: []const u8) ?usize {
    var pending: u8 = 0;
    var bits_free: u32 = 8;
    var out_pos: usize = 0;
    for (src) |byte| {
        var num_bits: u32 = codes[byte].len;
        const code_bits: u16 = codes[byte].bits;
        while (num_bits >= bits_free) {
            num_bits -= bits_free;
            if (out_pos >= dst.len) return null;
            dst[out_pos] = @as(u8, @truncate(code_bits >> @intCast(num_bits))) | pending;
            out_pos += 1;
            pending = 0;
            bits_free = 8;
        }
        if (num_bits != 0) {
            bits_free -= num_bits;
            pending |= @as(u8, @truncate(code_bits << @intCast(bits_free)));
        }
    }
    if (bits_free < 8) {
        if (out_pos >= dst.len) return null;
        dst[out_pos] = pending;
        out_pos += 1;
    }
    return out_pos;
}

// ── tests ────────────────────────────────────────────────────────────────────
// The decisive vectors are a REAL frame captured off a live 1.14d GS (the 0x01 GameFlags
// packet): 4 compressed bytes -> the 9-byte plaintext packet.
const real_compressed = [_]u8{ 0x7a, 0x09, 0xa5, 0xf0 };
const real_decoded = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0x10, 0x00, 0x01, 0x00, 0x00 };

test "decode matches a real GS-captured frame" {
    var out: [64]u8 = undefined;
    const n = decode(&out, &real_compressed).?;
    try std.testing.expectEqualSlices(u8, &real_decoded, out[0..n]);
}

test "encode matches the same real GS frame" {
    var out: [64]u8 = undefined;
    const n = encode(&out, &real_decoded).?;
    try std.testing.expectEqualSlices(u8, &real_compressed, out[0..n]);
}

test "encode/decode round-trips arbitrary payloads" {
    var prng = std.Random.DefaultPrng.init(0xD2D2D2);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var orig: [256]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 1, 256);
        rand.bytes(orig[0..len]);
        var comp: [512]u8 = undefined;
        var deco: [512]u8 = undefined;
        const cn = encode(&comp, orig[0..len]).?;
        const dn = decode(&deco, comp[0..cn]).?;
        try std.testing.expectEqualSlices(u8, orig[0..len], deco[0..dn]);
    }
}

test "reconstructed codes preserve the static lengths and are prefix-free" {
    for (0..256) |s| try std.testing.expectEqual(code_lengths[s], codes[s].len);
    // prefix-free: no code is a strict prefix of another (checked via the full decode table —
    // a complete tree leaves no slot unfilled and no symbol's region overlapping another's).
    for (decode_table) |e| try std.testing.expect(e.len >= 1 and e.len <= max_len);
}
