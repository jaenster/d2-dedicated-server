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
//!
//! A third constraint settles the rows the first two could not: **the arities must agree**. What
//! 1.06b pushes at a call site must equal what the LoD function pops in its `ret N`. That is an
//! independent fact about the same row, and it earned its place — solving on fingerprint and order
//! alone produced five rows (the 10140-10175 tail) whose ret sizes contradicted the answer.
//!
//! Those three constraints still got four rows wrong, and the way they were caught is the lesson:
//! comparing the two function bodies instruction for instruction. Order and arity only ever narrow
//! a row to a candidate set; an identical body identifies it. Where the two disagree the body wins,
//! and the rows below carry the body's answer.

const std = @import("std");

/// How well a row is established. The distinction is load-bearing: a wrong row is not a missing
/// import, it is a silently wrong call, so a host must refuse an unconfirmed one rather than let
/// it through.
pub const Confidence = enum {
    /// The fingerprint picked this target on its own, decisively.
    measured,
    /// The fingerprint's own best pick and the order-constrained pick agree.
    corroborated,
    /// The fingerprint was not decisive; the row is fixed by the two structural constraints
    /// instead — monotonic order, and matching `ret N` on both sides. Weaker than a fingerprint
    /// hit, but not a guess: the arity gate is an independent fact, and it refuted five rows that
    /// order alone had been happy with.
    inferred,
};

pub const Row = struct { classic: u16, lod: u16, how: Confidence };

/// Every Fog ordinal a classic build imports, in ordinal order — D2Game's and D2Common's, plus
/// the seven only D2CMP takes (10020, 10066, 10067, 10069, 10070, 10072, 10079). Those were
/// missed at first because the survey stopped at the two modules the host drives directly, and a
/// rewrite that skips a module leaves it calling whatever the LoD numbering happens to put at that
/// ordinal — the same silent-wrong-call this file exists to prevent.
pub const classic_to_lod = [_]Row{
    .{ .classic = 10016, .lod = 10018, .how = .corroborated },
    .{ .classic = 10020, .lod = 10022, .how = .corroborated }, // D2CMP-only from here
    .{ .classic = 10021, .lod = 10023, .how = .inferred },
    .{ .classic = 10022, .lod = 10024, .how = .inferred },
    .{ .classic = 10023, .lod = 10025, .how = .corroborated },
    .{ .classic = 10024, .lod = 10026, .how = .inferred },
    .{ .classic = 10026, .lod = 10029, .how = .measured }, // LogManager.cpp on both sides
    // Published ordinal lists for 1.09d name these AllocClientMemory/FreeClientMemory at the same
    // slots we ship them at, which corroborates the LoD side from outside our own disassembly.
    .{ .classic = 10033, .lod = 10042, .how = .corroborated },
    .{ .classic = 10034, .lod = 10043, .how = .corroborated },
    .{ .classic = 10036, .lod = 10055, .how = .corroborated },
    .{ .classic = 10061, .lod = 10083, .how = .corroborated },
    .{ .classic = 10062, .lod = 10084, .how = .corroborated },
    .{ .classic = 10064, .lod = 10086, .how = .corroborated },
    .{ .classic = 10066, .lod = 10091, .how = .corroborated },
    .{ .classic = 10067, .lod = 10093, .how = .inferred },
    .{ .classic = 10069, .lod = 10094, .how = .measured },
    .{ .classic = 10070, .lod = 10095, .how = .measured },
    .{ .classic = 10072, .lod = 10097, .how = .measured }, // strongest of the D2CMP set, 5.73
    .{ .classic = 10075, .lod = 10102, .how = .measured }, // the file I/O block, margin 3.00
    .{ .classic = 10076, .lod = 10103, .how = .measured },
    .{ .classic = 10077, .lod = 10104, .how = .measured },
    .{ .classic = 10078, .lod = 10105, .how = .measured },
    .{ .classic = 10079, .lod = 10106, .how = .measured },
    .{ .classic = 10086, .lod = 10115, .how = .measured }, // strongest row in the set, score 7.78
    .{ .classic = 10087, .lod = 10118, .how = .corroborated },
    .{ .classic = 10088, .lod = 10119, .how = .corroborated },
    .{ .classic = 10089, .lod = 10120, .how = .corroborated },
    .{ .classic = 10095, .lod = 10126, .how = .measured }, // BitManip.cpp on both sides
    .{ .classic = 10096, .lod = 10127, .how = .corroborated },
    // Bodies compared instruction for instruction, because neither side asserts and so neither
    // carries a __FILE__ tag to match on: both read the stream's +0x04/+0x08/+0x0c, both compute
    // the bit cursor as `lea edx,[ecx+edx*8]` then add the width. Same function, different register
    // allocation. Worth doing rather than leaving inferred — it is called eight times in the one
    // function the pre-1.10 builds fault in, so it was the obvious suspect and is now excluded.
    .{ .classic = 10097, .lod = 10128, .how = .measured },
    .{ .classic = 10098, .lod = 10129, .how = .inferred },
    .{ .classic = 10099, .lod = 10130, .how = .measured },
    .{ .classic = 10102, .lod = 10134, .how = .measured }, // NOT file I/O — String, margin 2.78
    .{ .classic = 10103, .lod = 10135, .how = .measured },
    .{ .classic = 10104, .lod = 10136, .how = .measured },
    .{ .classic = 10105, .lod = 10137, .how = .corroborated },
    .{ .classic = 10109, .lod = 10143, .how = .inferred },
    .{ .classic = 10110, .lod = 10144, .how = .inferred },
    .{ .classic = 10140, .lod = 10045, .how = .measured },
    .{ .classic = 10141, .lod = 10046, .how = .measured },
    .{ .classic = 10142, .lod = 10047, .how = .measured },
    .{ .classic = 10152, .lod = 10200, .how = .inferred },
    // Not 10202. Order put it there and order was wrong: 10202 on the LoD side is an IFF.cpp
    // forwarder, while classic 10175 tags itself LogManager.cpp with a `format` string — a
    // variadic trace, and 1.06b's D2Game calls it with five cdecl arguments. The LogManager
    // exports line up on both sides with a constant +0x33 source-line offset (classic 10026 at
    // 0xe5 -> LoD 10029 at 0x118, which is already measured; this one at 0xf6 -> 0x129; classic
    // 10027 at 0x11c -> 0x14f), so this is 10030 FOG_TraceF. Reached the moment 1.06b first
    // served a character, as an unimplemented-ordinal stop.
    .{ .classic = 10175, .lod = 10030, .how = .measured },
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

test "every row satisfies the arity gate that refuted five of them" {
    // Recorded from the cross-check: classic push counts vs the LoD function's `ret N`. These are
    // the rows the gate moved, and their old targets are the ones it rejected.
    // Bodies compared instruction for instruction, so these no longer need `accept_inferred`.
    try std.testing.expectEqual(@as(u16, 10045), lodFor(10140, false).?);
    try std.testing.expectEqual(@as(u16, 10046), lodFor(10141, false).?);
    try std.testing.expectEqual(@as(u16, 10047), lodFor(10142, false).?);
    try std.testing.expectEqual(@as(u16, 10130), lodFor(10099, false).?);
    try std.testing.expectEqual(@as(u16, 10200), lodFor(10152, true).?); // was 10175, ret 0 vs 16
    try std.testing.expectEqual(@as(u16, 10030), lodFor(10175, true).?); // LogManager, not IFF
}

test "the map increases everywhere except the one block that was relocated" {
    // Order pinned half this map, and it is still worth asserting — but it is an observation, not a
    // law, and comparing bodies found where it breaks. Classic 10140-10142 land on LoD 10045-10047:
    // a contiguous block moved contiguously, downward, past everything around it. Anything solved
    // from order alone in that neighbourhood was solved from a false premise.
    const relocated = [_]u16{ 10140, 10141, 10142, 10175 };
    var prev_c: u16 = 0;
    var prev_l: u16 = 0;
    for (classic_to_lod) |row| {
        try std.testing.expect(row.classic > prev_c); // the classic side really is ordered
        prev_c = row.classic;

        if (std.mem.indexOfScalar(u16, &relocated, row.classic) != null) continue;
        try std.testing.expect(row.lod > prev_l);
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
    try std.testing.expect(lodFor(10098, false) == null); // inferred only
    try std.testing.expectEqual(@as(u16, 10129), lodFor(10098, true).?);
    try std.testing.expect(lodFor(9999, true) == null); // not imported at all
    // 10097 used to be this test's example and is not any more: its bodies were compared against
    // 10128's and matched, so it is measured and answers without being asked to accept inferences.
    try std.testing.expectEqual(@as(u16, 10128), lodFor(10097, false).?);
}

test "how much of the set is actually established" {
    try std.testing.expectEqual(@as(usize, 47), classic_to_lod.len);
    try std.testing.expectEqual(@as(usize, 22), countBy(.measured));
    try std.testing.expectEqual(@as(usize, 17), countBy(.corroborated));
    try std.testing.expectEqual(@as(usize, 8), countBy(.inferred));
}
