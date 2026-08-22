//! Fog's own ABI drift between engine builds.
//!
//! `callbacks.zig` covers the table D2Game calls into. This is the other direction and the other
//! module: D2Common and D2Game call *Fog*, and a replacement Fog has to pop exactly what the
//! caller pushed. Fog is stdcall, so getting it wrong does not fail at the call — it shifts ESP and
//! the damage surfaces much later, when some unrelated function returns into the drift.
//!
//! Which ordinals a version imports did not change across the LoD family (1.07 -> 1.10f is 49/49).
//! Their *arities* did, which is a separate fact and is what this file records.

const std = @import("std");
const version = @import("version.zig");

/// Stack args for the Fog entry points that are not the same on every build. Everything absent
/// here is identical across the LoD family and is written out directly in `packages/d2fog`.
pub const OrdinalArgs = struct {
    /// Fog @10211 `AllocLinker`. 1.10f passes the `__FILE__`/`__LINE__` debug pair that Blizzard
    /// added to the allocator entry points; 1.09d passes nothing at all.
    ///
    /// Measured at the call sites rather than assumed: 1.10f's `DATATBLS_LoadStatesTxt` group
    /// pushes `0x6fdd6a60, 0x540` before `CALL Ordinal_10211` (@0x6fd4deac), while every 1.09d
    /// site — all fifteen, including the eleven in `DATATBLS_LoadExcelGroup` — is a bare
    /// `Ordinal_10211()` with an empty argument list.
    ///
    /// This one costs 8 bytes of ESP per call. `DATATBLS_LoadExcelGroup` calls it once per table
    /// for eleven tables, so a Fog built for 1.10f drifts 88 bytes through that one function and
    /// then returns to a null, which is what a 1.09d boot faulted on.
    alloc_linker: u8,
};

/// The `Version` enum, re-exported so a consumer can walk its tags without importing two files.
pub const version_enum = version.Version;

/// The Fog ABI `v` was linked against. Null means nobody has measured that build's Fog call sites,
/// which is a different statement from "it is the same as 1.10f's".
pub fn ordinalArgs(v: version.Version) ?OrdinalArgs {
    return switch (v) {
        .v110f, .v113c, .v114d => .{ .alloc_linker = 2 },
        // 1.07 and 1.09d agree, and both differ from 1.10f: the debug pair was added later. Swept
        // the same way over every Fog ordinal D2Common imports — AllocLinker is the *only* one of
        // the eighteen that moved, on either version.
        .v107, .v108, .v109b, .v109d => .{ .alloc_linker = 0 },
        // 1.06b was swept the same way, from the callee's own `ret N` rather than from push counts,
        // because its Fog.dll is on disk to read. All 47 ordinals it imports pop exactly what
        // 1.10f's equivalents pop — the classic/LoD boundary renumbered Fog without changing a
        // single arity. AllocLinker is not among those 47 at all: classic allocates through
        // 10045/10046/10047, so this field is inert here and 0 is the value that cannot leak if
        // that ever turns out to be wrong.
        .v106b => .{ .alloc_linker = 0 },
        else => null,
    };
}

/// Whether this build's `BitStream` carries the overflow flag at +0x10, and so whether
/// `BITMANIP_Initialize` @10126 clears four fields or five.
///
/// The struct grew at the 1.10 boundary and the callers grew with it. Measured from the real
/// `Fog.dll` where one is on disk and from the callers where one is not:
///
///   1.06b @10095, 1.07 @10126, 1.09d @10126   write +0x00/+0x04/+0x08/+0x0c and stop.
///   1.10f @10126 (0x6ff53650)                 writes those four AND `mov [eax+0x10], ecx`.
///
/// The callers say the same thing from the other side. D2Common's item serialiser opens
/// `sub esp, 0x10` on 1.07 through 1.09d and `sub esp, 0x14` on 1.10f and 1.13c — and on those two
/// it goes on to read the stream back at +0x10 to decide whether the item fit, byte for byte the
/// same code in both (1.10f @10881 0x6fda2bd3, 1.13c 0x6fd79d33).
///
/// Both halves of that matter, in opposite directions. Writing +0x10 on a pre-1.10 caller lands on
/// its own return address, because the struct sits at the bottom of a frame that reserved exactly
/// sixteen bytes. NOT writing it on 1.10f leaves the overflow test reading stack garbage, and the
/// engine reports a save that fit as one that did not — `"Character has too many items"`,
/// PlrSave.cpp:0x713, which is the engine faithfully relaying a flag we never cleared.
///
/// Null means unmeasured, which is not the same as "the same as 1.10f".
pub fn bitstreamHasOverflow(v: version.Version) ?bool {
    return switch (v) {
        .v110f, .v113c, .v114d => true,
        .v106b, .v107, .v108, .v109b, .v109d => false,
        else => null,
    };
}

/// What a host should use when it has no measurement: 1.10f's shape, which is also what
/// `packages/d2fog` is written against. A wrong guess here is a slow stack leak, so a host that
/// knows its version should always pass one.
pub const default: OrdinalArgs = .{ .alloc_linker = 2 };

/// The BitStream shape to match `default`: 1.10f's, the one this file's port was written against.
pub const default_bitstream_has_overflow = true;

test "the LoD family shares ordinals but not arities" {
    try std.testing.expectEqual(@as(u8, 2), ordinalArgs(.v110f).?.alloc_linker);
    try std.testing.expectEqual(@as(u8, 0), ordinalArgs(.v109d).?.alloc_linker);
    try std.testing.expectEqual(@as(u8, 0), ordinalArgs(.v107).?.alloc_linker);
    // 1.06b is a different Fog numbering entirely, and measuring it found no arity moved at all.
    try std.testing.expectEqual(@as(u8, 0), ordinalArgs(.v106b).?.alloc_linker);
    try std.testing.expect(ordinalArgs(.v100) == null); // still genuinely unmeasured
}

test "the BitStream grew its overflow flag at the 1.10 boundary" {
    try std.testing.expectEqual(false, bitstreamHasOverflow(.v109d).?);
    try std.testing.expectEqual(false, bitstreamHasOverflow(.v106b).?);
    try std.testing.expectEqual(true, bitstreamHasOverflow(.v110f).?);
    try std.testing.expectEqual(true, bitstreamHasOverflow(.v113c).?);
    // A build whose Fog nobody has read must not answer by resembling its neighbours.
    try std.testing.expect(bitstreamHasOverflow(.v100) == null);
}

test "a build measured in one table is measured in both" {
    // The hole this closes is a half-measurement: someone reads a new build's AllocLinker call
    // sites, does not read its Initialize, and the BitStream question silently falls back to
    // 1.10f's shape. Both tables answer for a build or neither does.
    inline for (@typeInfo(version.Version).@"enum".fields) |f| {
        const v: version.Version = @enumFromInt(f.value);
        try std.testing.expectEqual(ordinalArgs(v) == null, bitstreamHasOverflow(v) == null);
    }
}
