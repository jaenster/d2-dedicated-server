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

/// Laid out by the engine's callers — it is a local in the caller's frame, so this is a contract
/// rather than our choice. Bits pack LSB-first within each byte, low bits of the value first.
/// Verified against 1.10f @10126 (0x6ff53650).
///
/// SIXTEEN bytes before 1.10 and twenty from 1.10 on: `overflow` is the field that was added, and
/// `has_overflow` below decides whether this build's caller reserved room for it.
pub const BitStream = extern struct {
    /// The byte being filled or drained — advanced past, never indexed from the start.
    cur: ?[*]u8 = null,
    /// Capacity in BITS: `nBytes << 3`. Every end test is against this, not against a byte count.
    cap_bits: i32 = 0,
    /// Whole bytes finished so far.
    bytes: i32 = 0,
    /// Bit position inside `cur`, 0..7.
    bit: i32 = 0,
    /// Latched once a read or a write ran past `cap_bits`. Nothing clears it but `init`, and it
    /// only exists from 1.10 on — before that an over-long write is a Fog assert that exits, so
    /// there is no flag for anyone to read. See `has_overflow`.
    overflow: i32 = 0,
};

// The layout belongs to the ENGINE — it puts this on its own stack and reads the fields back by
// offset — so it is asserted where it is actually true rather than left to a test. No host test can
// check it: `cur` is eight bytes on a 64-bit host and everything after it moves, which is how the
// first attempt at a canary test for this ended up measuring `bit` and passing regardless.
comptime {
    if (@sizeOf(usize) == 4) {
        std.debug.assert(@offsetOf(BitStream, "cur") == 0x00);
        std.debug.assert(@offsetOf(BitStream, "cap_bits") == 0x04);
        std.debug.assert(@offsetOf(BitStream, "bytes") == 0x08);
        std.debug.assert(@offsetOf(BitStream, "bit") == 0x0c);
        std.debug.assert(@offsetOf(BitStream, "overflow") == 0x10);
        // Twenty from 1.10 on. Pre-1.10 callers reserve sixteen and `has_overflow` keeps us out of
        // the fifth word; the type stays one shape so there is one layout to get right.
        std.debug.assert(@sizeOf(BitStream) == 20);
    }
}

/// `(1 << n) - 1` for n in 0..8 — the engine's own table at 1.10f 0x6ff71408.
const low_mask = [9]u32{ 0, 1, 3, 7, 0xf, 0x1f, 0x3f, 0x7f, 0xff };
/// `0xff << b` for b in 0..7 — the engine's own table at 1.10f 0x6ff7142c.
const high_mask = [8]u8{ 0xff, 0xfe, 0xfc, 0xf8, 0xf0, 0xe0, 0xc0, 0x80 };

/// Whether the caller's stream has the `overflow` field at +0x10. The host sets this from the
/// engine version through `FOG_SetEngineVersion`, before any engine module is loaded; the default
/// is 1.10f's shape, which is what this file was ported from.
///
/// This is the one thing in here that cannot be decided from the arguments, and both ways of being
/// wrong cost a day. Writing +0x10 when the caller reserved sixteen bytes puts a zero on its return
/// address; leaving it alone when the caller reserved twenty leaves the engine testing uninitialised
/// stack. `fogabi.bitstreamHasOverflow` carries the measurement and the addresses it came from.
pub var has_overflow: bool = true;

pub fn init(st: *BitStream, buf: ?[*]u8, n_bytes: u32) void {
    st.cur = buf;
    st.cap_bits = @bitCast(n_bytes << 3);
    st.bytes = 0;
    st.bit = 0;
    // The fifth field, on the builds that have one. 1.10f's @10126 ends `mov [eax+0x10], ecx` with
    // ECX still zero; 1.09d's and 1.06b's end one instruction earlier.
    if (has_overflow) st.overflow = 0;
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
        // Pre-1.10 there is nowhere to put this: that Fog asserts and exits instead (1.09d @10128
        // 0x6ff520fe, BitManip.cpp:0x165), so the caller never reserved a flag to be told about it.
        if (has_overflow) st.overflow = 1;
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
    if (over != 0 and has_overflow) st.overflow = 1;
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

test "a pre-1.10 stream leaves the overflow field completely alone" {
    // On 1.09d that field is not the stream's to write: `sub esp, 0x10` puts a SIXTEEN-byte stream
    // at the bottom of the caller's frame, so the word our struct calls `overflow` is the caller's
    // own return address. So the property is simply that nothing here writes it — a sentinel that
    // survives says that, and it survives on any host, which a frame modelled in raw bytes would not
    // (`cur` is eight bytes off i386 and every offset after it moves).
    const sentinel: i32 = @bitCast(@as(u32, 0xC0FFEE));
    var buf = [_]u8{0} ** 4;
    var st: BitStream = .{ .overflow = sentinel };

    has_overflow = false;
    defer has_overflow = true;
    init(&st, &buf, buf.len);
    try std.testing.expectEqual(sentinel, st.overflow);
    write(&st, 0, 33 * 8); // far past four bytes: the latching path
    try std.testing.expectEqual(sentinel, st.overflow);
    _ = read(&st, 32); // and the reader, which latches it too
    try std.testing.expectEqual(sentinel, st.overflow);

    // From 1.10 on `init` MUST clear it, or the engine's own overflow test reads whatever the frame
    // happened to hold — which is how a save that fit got reported as "too many items".
    has_overflow = true;
    init(&st, &buf, buf.len);
    try std.testing.expectEqual(@as(i32, 0), st.overflow);
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
