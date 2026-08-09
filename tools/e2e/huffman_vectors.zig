//! The D2GS wire Huffman codec, checked against frames captured off a real 1.14d server.
//!
//! The CODEC is libd2's (`d2-util`). This file used to carry a second implementation of
//! it — the static length table, the tree reconstruction, the bit loops — which is exactly
//! the kind of duplication that rots: two copies of a wire format, one of them the one
//! nobody remembers to fix.
//!
//! What is worth keeping is the EVIDENCE. These vectors are a real frame off a live GS, so
//! pointing them at the library turns a duplicate implementation into a cross-check: if
//! libd2's codec ever stops agreeing with a packet the game actually sent, this fails.
const std = @import("std");
const huffman = @import("d2_util").huffman;

// A REAL frame captured off a live 1.14d GS (the 0x01 GameFlags packet):
// 4 compressed bytes -> the 9-byte plaintext packet.
const real_compressed = [_]u8{ 0x7a, 0x09, 0xa5, 0xf0 };
const real_decoded = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0x10, 0x00, 0x01, 0x00, 0x00 };

test "libd2 decodes a real GS-captured frame" {
    var out: [64]u8 = undefined;
    const n = huffman.decompress(&out, &real_compressed) orelse return error.DecodeFailed;
    try std.testing.expectEqualSlices(u8, &real_decoded, out[0..n]);
}

test "libd2 re-encodes to the same real GS frame" {
    var out: [64]u8 = undefined;
    const n = huffman.compress(&out, &real_decoded) orelse return error.EncodeFailed;
    try std.testing.expectEqualSlices(u8, &real_compressed, out[0..n]);
}

test "libd2 round-trips arbitrary payloads" {
    var prng = std.Random.DefaultPrng.init(0xD2D2D2);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var orig: [256]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 1, 256);
        rand.bytes(orig[0..len]);
        var comp: [512]u8 = undefined;
        var deco: [512]u8 = undefined;
        const cn = huffman.compress(&comp, orig[0..len]) orelse return error.EncodeFailed;
        const dn = huffman.decompress(&deco, comp[0..cn]) orelse return error.DecodeFailed;
        try std.testing.expectEqualSlices(u8, orig[0..len], deco[0..dn]);
    }
}
