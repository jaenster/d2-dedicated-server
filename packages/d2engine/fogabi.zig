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
        .v107, .v108, .v109d => .{ .alloc_linker = 0 },
        else => null,
    };
}

/// What a host should use when it has no measurement: 1.10f's shape, which is also what
/// `packages/d2fog` is written against. A wrong guess here is a slow stack leak, so a host that
/// knows its version should always pass one.
pub const default: OrdinalArgs = .{ .alloc_linker = 2 };

test "the LoD family shares ordinals but not arities" {
    try std.testing.expectEqual(@as(u8, 2), ordinalArgs(.v110f).?.alloc_linker);
    try std.testing.expectEqual(@as(u8, 0), ordinalArgs(.v109d).?.alloc_linker);
    try std.testing.expectEqual(@as(u8, 0), ordinalArgs(.v107).?.alloc_linker);
    // 1.06b is a different Fog numbering entirely and has not been measured.
    try std.testing.expect(ordinalArgs(.v106b) == null);
}
