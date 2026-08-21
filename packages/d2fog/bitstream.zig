//! Fog's bit stream, ported from the real 1.10f `Fog.dll` (@10118 rva 0x3320 through @10131 rva
//! 0x3890; 1.13c's is the same code, and Ghidra has the 1.10f originals named).
//!
//! This is not a corner of the Fog API. D2Game and D2Common both import 10118/10119/10120 and
//! 10126..10130 (D2Common also 10131), and it is the codec the engine packs its world-state packets
//! with — so a replacement Fog that stubs it out leaves the server able to accept a join and unable
//! to send a world. The failure does not look like a missing function: the engine sits in
//! `BITMANIP_Write` forever and the client simply never enters.
//!
//! It lives here rather than in `fog.zig` because it is the one part of Fog that is pure logic, and
//! pure logic that the engine's correctness rests on should be asserted on the host rather than
//! only inside a Windows DLL.

const std = @import("std");

/// 20 bytes, laid out by the engine's callers — it is a local in the caller's frame, so this is a
/// contract rather than our choice. Bits pack LSB-first within each byte, low bits of the value
/// first. Verified against 1.10f @10126 (0x6ff53650).
pub const BitStream = extern struct {
    /// The byte being filled or drained — advanced past, never indexed from the start.
    cur: ?[*]u8 = null,
    /// Capacity in BITS: `nBytes << 3`. Every end test is against this, not against a byte count.
    cap_bits: i32 = 0,
    /// Whole bytes finished so far.
    bytes: i32 = 0,
    /// Bit position inside `cur`, 0..7.
    bit: i32 = 0,
    /// Latched once a read or a write ran past `cap_bits`. Nothing clears it but `init`.
    overflow: i32 = 0,
};

/// `(1 << n) - 1` for n in 0..8 — the engine's own table at 1.10f 0x6ff71408.
const low_mask = [9]u32{ 0, 1, 3, 7, 0xf, 0x1f, 0x3f, 0x7f, 0xff };
/// `0xff << b` for b in 0..7 — the engine's own table at 1.10f 0x6ff7142c.
const high_mask = [8]u8{ 0xff, 0xfe, 0xfc, 0xf8, 0xf0, 0xe0, 0xc0, 0x80 };

pub fn init(st: *BitStream, buf: ?[*]u8, n_bytes: u32) void {
    // FOUR fields, never five. The real @10126 writes +0x00, +0x04, +0x08 and +0x0c and stops;
    // `overflow` at +0x10 is only ever written by @10128, and only on the path where a write does
    // not fit — which for a correctly sized buffer never runs.
    //
    // That distinction is not cosmetic. Callers put this struct on the stack and reserve only what
    // Initialize touches: D2Common 1.09d @10881 opens `sub esp, 0x10`, sixteen bytes, and the whole
    // struct assignment this used to be wrote twenty — four bytes straight through the bottom of
    // the caller's frame, on every packet it built. Nothing fails at the write; the damage lands on
    // whatever that frame held, which is why it surfaced as a jump to a garbage address much later.
    st.cur = buf;
    st.cap_bits = @bitCast(n_bytes << 3);
    st.bytes = 0;
    st.bit = 0;
}

/// Bytes produced, rounded up: a byte with bits still in flight counts as one.
pub fn size(st: *const BitStream) u32 {
    var n: u32 = @bitCast(st.bytes);
    if (st.bit != 0) n +%= 1;
    return n;
}

/// Overflow is checked once, up front, against the whole write: the engine does not write a partial
/// value and then stop, it writes nothing at all and latches the flag.
pub fn write(st: *BitStream, value: u32, nbits: i32) void {
    if (st.cap_bits < st.bit + st.bytes * 8 + nbits) {
        st.overflow = 1;
        st.bit = 0;
        st.bytes = @divTrunc(st.cap_bits, 8);
        return;
    }
    var cur = st.cur orelse return;
    if (st.bit == 0) cur[0] = 0;
    var v: i32 = @bitCast(value);
    var n = nbits;
    while (n > 0) {
        var take = 8 - st.bit;
        if (n < take) take = n;
        cur = st.cur orelse return;
        cur[0] |= @truncate((low_mask[@intCast(take)] & @as(u32, @bitCast(v))) << @intCast(st.bit));
        st.bit += take;
        // Short of eight, `take` was the whole remainder — so this is the engine's early exit, not
        // a condition on the loop.
        if (st.bit != 8) return;
        st.cur = cur + 1;
        st.bytes += 1;
        st.bit = 0;
        // Only inside the buffer: the byte one past a full stream is left as the caller had it.
        if (st.bytes * 8 < st.cap_bits) (cur + 1)[0] = 0;
        n -= take;
        v >>= @intCast(take); // arithmetic, as the engine's SAR is
    }
}

/// Unlike `write`, an over-long read is CLAMPED rather than refused: it returns the bits that were
/// there and latches the flag.
pub fn read(st: *BitStream, nbits: i32) u32 {
    var over = st.bytes * 8 - st.cap_bits + nbits + st.bit;
    if (over < 0) over = 0;
    if (over != 0) st.overflow = 1;
    var n = nbits - over;
    var result: u32 = 0;
    var shift: i32 = 0;
    while (n > 0) {
        var take = 8 - st.bit;
        if (n < take) take = n;
        const bit = st.bit;
        const cur = st.cur orelse return result;
        n -= take;
        const byte: u32 = (high_mask[@intCast(bit)] & cur[0]) >> @intCast(bit);
        result +%= (byte & low_mask[@intCast(take)]) << @intCast(shift);
        shift += take;
        st.bit = bit + take;
        if (st.bit == 8) {
            st.cur = cur + 1;
            st.bit = 0;
            st.bytes += 1;
        }
    }
    return result;
}

/// Sign-extends from bit `nbits-1`. A 32-bit read comes back as-is.
pub fn readSigned(st: *BitStream, nbits: i32) i32 {
    const v: i32 = @bitCast(read(st, nbits));
    if (nbits >= 32 or nbits <= 0) return v;
    if (v & (@as(i32, 1) << @intCast(nbits - 1)) == 0) return v;
    return v | ~((@as(i32, 1) << @intCast(nbits)) - 1);
}

/// Aligns to the next byte boundary. An already-aligned stream is left completely alone, `cur`
/// included — which is why this cannot be written as an unconditional advance.
pub fn goToNextByte(st: *BitStream) void {
    if (st.bit == 0) return;
    const cur = st.cur orelse return;
    st.cur = cur + 1;
    st.bytes += 1;
    st.bit = 0;
    if (st.bytes * 8 < st.cap_bits) (cur + 1)[0] = 0;
}

// The three bit pokes address a plain byte array rather than a stream, and take (buffer, nBit).

pub fn setBit(p: [*]u8, bit: i32) void {
    p[@intCast(bit >> 3)] |= @as(u8, 1) << @intCast(bit & 7);
}

/// Returns the MASKED BYTE, not 0/1 — callers test it for zero. Narrowing it to a bool would change
/// behaviour for anything that stores the result.
pub fn getBit(p: [*]const u8, bit: i32) i32 {
    return @as(i32, p[@intCast(bit >> 3)]) & (@as(i32, 1) << @intCast(bit & 7));
}

/// Clears the bit, despite Fog's name for it (`BITMANIP_MaskBitstate`).
pub fn clearBit(p: [*]u8, bit: i32) void {
    p[@intCast(bit >> 3)] &= ~(@as(u8, 1) << @intCast(bit & 7));
}

test "bits land LSB-first, in the bytes the engine puts them in" {
    var buf = [_]u8{0xAA} ** 8;
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    write(&st, 0b101, 3);
    write(&st, 0b11, 2);
    write(&st, 0x1FF, 9); // straddles two byte boundaries
    // 3 + 2 + 9 = 14 bits: 0b101, then 0b11 above it, then nine ones.
    //   byte0 = 111_11_101 = 0xFD, byte1 = 0b00111111 = 0x3F
    try std.testing.expectEqualSlices(u8, &.{ 0xFD, 0x3F }, buf[0..2]);
    try std.testing.expectEqual(@as(u32, 2), size(&st)); // 14 bits -> two bytes, one part-filled
    try std.testing.expectEqual(@as(i32, 0), st.overflow);
}

test "a write clears the bytes it lands in, so a dirty buffer does not leak through" {
    var buf = [_]u8{0xFF} ** 4;
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    write(&st, 0, 16);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, buf[0..2]);
}

test "every width round-trips, signed and unsigned" {
    // 1+2+...+32 = 528 bits, so 66 bytes is the minimum — at 64 the writes overflow and the
    // stream stops taking them, which is what the first version of this test actually measured.
    var buf = [_]u8{0} ** 96;
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    var w: i32 = 1;
    while (w <= 32) : (w += 1) {
        const v: u32 = if (w == 32) 0xDEADBEEF else (0xDEADBEEF & ((@as(u32, 1) << @intCast(w)) - 1));
        write(&st, v, w);
    }
    var rd: BitStream = .{};
    init(&rd, &buf, buf.len);
    w = 1;
    while (w <= 32) : (w += 1) {
        const want: u32 = if (w == 32) 0xDEADBEEF else (0xDEADBEEF & ((@as(u32, 1) << @intCast(w)) - 1));
        try std.testing.expectEqual(want, read(&rd, w));
    }
    try std.testing.expectEqual(@as(i32, 0), rd.overflow);
}

test "readSigned sign-extends from the top bit of the field" {
    var buf = [_]u8{0} ** 4;
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    write(&st, 0b1011, 4); // -5 in four bits
    write(&st, 0b0101, 4); // +5 in four bits
    var rd: BitStream = .{};
    init(&rd, &buf, buf.len);
    try std.testing.expectEqual(@as(i32, -5), readSigned(&rd, 4));
    try std.testing.expectEqual(@as(i32, 5), readSigned(&rd, 4));
}

test "a write past the end writes NOTHING and latches overflow" {
    var buf = [_]u8{0} ** 2;
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    write(&st, 0xFF, 8);
    write(&st, 0xFF, 12); // 8 + 12 > 16
    try std.testing.expectEqual(@as(i32, 1), st.overflow);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x00 }, buf[0..2]);
    try std.testing.expectEqual(@as(i32, 2), st.bytes);
    try std.testing.expectEqual(@as(i32, 0), st.bit);
}

test "a read past the end is clamped to what is there, not refused" {
    var buf = [_]u8{ 0xFF, 0xFF };
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    _ = read(&st, 12);
    try std.testing.expectEqual(@as(u32, 0xF), read(&st, 8)); // only four bits remain
    try std.testing.expectEqual(@as(i32, 1), st.overflow);
}

test "goToNextByte aligns a partial byte and leaves an aligned one untouched" {
    var buf = [_]u8{0} ** 4;
    var st: BitStream = .{};
    init(&st, &buf, buf.len);
    write(&st, 1, 1);
    goToNextByte(&st);
    try std.testing.expectEqual(@as(i32, 1), st.bytes);
    try std.testing.expectEqual(@as(i32, 0), st.bit);
    const before = st.cur;
    goToNextByte(&st); // already aligned — must not advance
    try std.testing.expectEqual(before, st.cur);
    try std.testing.expectEqual(@as(i32, 1), st.bytes);
}

test "the bit pokes address the array the way the engine's do" {
    var buf = [_]u8{0} ** 4;
    setBit(&buf, 0);
    setBit(&buf, 9);
    setBit(&buf, 23);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x80, 0x00 }, &buf);
    try std.testing.expect(getBit(&buf, 9) != 0);
    try std.testing.expect(getBit(&buf, 10) == 0);
    clearBit(&buf, 9);
    try std.testing.expect(getBit(&buf, 9) == 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x80, 0x00 }, &buf);
}
