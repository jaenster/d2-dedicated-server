//! Classic-era Fog ordinals, and what they are called in the LoD numbering.
//!
//! Fog renumbered exactly once, at the LoD boundary (see `version.FogFamily`). We implement the
//! LoD numbering, so a classic-era D2Game/D2Common has to have its Fog imports rewritten before it
//! loads — an ordinal import is a bare `0x80000000 | n` in the thunk array, so retargeting one is a
//! u32 write.
//!
//! **Sharing an ordinal number across the boundary does not mean sharing a function.** 1.06b and
//! 1.10f both import 10102-10105, and they are not the same calls: classic 10102 is a *string*
//! function (its asserts name `Fog\Src\BitManip\String`) that became LoD 10134, while the file I/O
//! our Fog answers at 10102-10105 is classic **10075-10078**. Passing a "coinciding" ordinal
//! through unrewritten would call FOpenFile where the engine asked for a string operation.
//!
//! Derived by fingerprinting each classic export against the LoD ones — the strings it references
//! (Fog is dense with asserts carrying source paths and messages), the Storm ordinals it calls
//! (Storm's numbering is stable across the whole range, so it is a version-proof anchor), and its
//! instruction mnemonics — and then resolving the whole set under one structural constraint: the
//! renumbering inserted, it never reordered, so the map must be strictly increasing.

const std = @import("std");

/// How well a row is established. The distinction is load-bearing: a wrong row is not a missing
/// import, it is a silently wrong call, so a host must refuse an unconfirmed one rather than let
/// it through.
pub const Confidence = enum {
    /// The fingerprint picked this target on its own, decisively.
    measured,
    /// The fingerprint's own best pick and the order-constrained pick agree.
    corroborated,
    /// Only the monotonic constraint puts it here; the fingerprint was not decisive. Structurally
    /// plausible (these fall into contiguous blocks with their neighbours) but NOT established.
    inferred,
};

pub const Row = struct { classic: u16, lod: u16, how: Confidence };

/// Every Fog ordinal 1.06b's D2Game and D2Common import, in ordinal order.
pub const classic_to_lod = [_]Row{
    .{ .classic = 10016, .lod = 10018, .how = .corroborated },
    .{ .classic = 10021, .lod = 10023, .how = .inferred },
    .{ .classic = 10022, .lod = 10024, .how = .inferred },
    .{ .classic = 10023, .lod = 10025, .how = .corroborated },
    .{ .classic = 10024, .lod = 10026, .how = .inferred },
    .{ .classic = 10026, .lod = 10029, .how = .measured }, // LogManager.cpp on both sides
    .{ .classic = 10033, .lod = 10042, .how = .corroborated },
    .{ .classic = 10034, .lod = 10043, .how = .corroborated },
    .{ .classic = 10036, .lod = 10055, .how = .corroborated },
    .{ .classic = 10061, .lod = 10083, .how = .corroborated },
    .{ .classic = 10062, .lod = 10084, .how = .corroborated },
    .{ .classic = 10064, .lod = 10086, .how = .corroborated },
    .{ .classic = 10075, .lod = 10102, .how = .measured }, // the file I/O block, margin 3.00
    .{ .classic = 10076, .lod = 10103, .how = .measured },
    .{ .classic = 10077, .lod = 10104, .how = .measured },
    .{ .classic = 10078, .lod = 10105, .how = .measured },
    .{ .classic = 10086, .lod = 10115, .how = .measured }, // strongest row in the set, score 7.78
    .{ .classic = 10087, .lod = 10118, .how = .corroborated },
    .{ .classic = 10088, .lod = 10119, .how = .corroborated },
    .{ .classic = 10089, .lod = 10120, .how = .corroborated },
    .{ .classic = 10095, .lod = 10126, .how = .measured }, // BitManip.cpp on both sides
    .{ .classic = 10096, .lod = 10127, .how = .corroborated },
    .{ .classic = 10097, .lod = 10128, .how = .inferred },
    .{ .classic = 10098, .lod = 10132, .how = .inferred },
    .{ .classic = 10099, .lod = 10133, .how = .inferred },
    .{ .classic = 10102, .lod = 10134, .how = .measured }, // NOT file I/O — String, margin 2.78
    .{ .classic = 10103, .lod = 10135, .how = .measured },
    .{ .classic = 10104, .lod = 10136, .how = .measured },
    .{ .classic = 10105, .lod = 10137, .how = .corroborated },
    .{ .classic = 10109, .lod = 10143, .how = .inferred },
    .{ .classic = 10110, .lod = 10144, .how = .inferred },
    .{ .classic = 10140, .lod = 10170, .how = .inferred },
    .{ .classic = 10141, .lod = 10171, .how = .inferred },
    .{ .classic = 10142, .lod = 10172, .how = .inferred },
    .{ .classic = 10152, .lod = 10175, .how = .inferred },
    .{ .classic = 10175, .lod = 10180, .how = .inferred },
    .{ .classic = 10200, .lod = 10207, .how = .measured }, // Excel.cpp, margin 5.12
    .{ .classic = 10201, .lod = 10208, .how = .measured }, // "*data == SYM_EOL"
    .{ .classic = 10202, .lod = 10209, .how = .corroborated },
    .{ .classic = 10203, .lod = 10210, .how = .corroborated },
};

/// The LoD ordinal a classic import should be rewritten to, or null when there is no row good
/// enough to act on. Null is the point: an ordinal with no entry must be refused, not passed
/// through, because passing it through calls a different function of the same number.
pub fn lodFor(classic: u16, accept_inferred: bool) ?u16 {
    for (classic_to_lod) |row| {
        if (row.classic != classic) continue;
        if (row.how == .inferred and !accept_inferred) return null;
        return row.lod;
    }
    return null;
}

pub fn countBy(how: Confidence) usize {
    var n: usize = 0;
    for (classic_to_lod) |row| {
        if (row.how == how) n += 1;
    }
    return n;
}

test "the map is strictly increasing, which is what pinned half of it" {
    var prev_c: u16 = 0;
    var prev_l: u16 = 0;
    for (classic_to_lod) |row| {
        try std.testing.expect(row.classic > prev_c);
        try std.testing.expect(row.lod > prev_l);
        prev_c = row.classic;
        prev_l = row.lod;
    }
}

test "a shared ordinal number is not a shared function" {
    // Both families import 10102-10105. They are different calls, and this is the whole reason a
    // classic build cannot simply be loaded against a LoD-numbered Fog.
    try std.testing.expectEqual(@as(u16, 10134), lodFor(10102, false).?);
    try std.testing.expectEqual(@as(u16, 10102), lodFor(10075, false).?);
}

test "an unconfirmed row is refused rather than guessed" {
    try std.testing.expect(lodFor(10097, false) == null); // inferred only
    try std.testing.expectEqual(@as(u16, 10128), lodFor(10097, true).?);
    try std.testing.expect(lodFor(9999, true) == null); // not imported at all
}

test "how much of the set is actually established" {
    try std.testing.expectEqual(@as(usize, 40), classic_to_lod.len);
    try std.testing.expectEqual(@as(usize, 12), countBy(.measured));
    try std.testing.expectEqual(@as(usize, 15), countBy(.corroborated));
    try std.testing.expectEqual(@as(usize, 13), countBy(.inferred));
}
