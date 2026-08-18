//! Which game version a host is driving, and everything that actually differs between them.
//!
//! Measured from the export and import tables of the real DLLs (1.00, 1.06b, 1.07, 1.09d, 1.10f),
//! not assumed. Two findings shape this file:
//!
//! Ordinals are a hand-maintained ABI, not linker output. D2Game has holes at 10030/10031/10032 in
//! every version from 1.00 to 1.10f, and D2Common's export table has 137 holes by 1.10f against
//! none in 1.06b — retired numbers, never reused, new work appended. So the host-facing D2Game
//! entry points below are the same numbers everywhere, and D2Net/D2Lang/D2CMP/Storm never move.
//!
//! Fog renumbered exactly once, at the LoD boundary. Of the Fog ordinals D2Game+D2Common import,
//! 1.06b and 1.07 share 9 of 40, while 1.07 -> 1.09d shares 46/49 and 1.09d -> 1.10f is an exact
//! subset (49/49, plus 4 additions at 10252-10255). Hence two families, not one map per version.

const std = @import("std");
const callbacks = @import("callbacks.zig");

pub const Version = enum {
    v100,
    v106b,
    v107,
    v108,
    v109d,
    v110f,
    v113c,
    v114d,

    pub fn parse(s: []const u8) ?Version {
        inline for (@typeInfo(Version).@"enum".fields) |f| {
            // accept both "v109d" and the "1.09d" spelling the install dirs use
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
            if (s.len == f.name.len and s[1] == '.' and s[0] == f.name[1] and
                std.mem.eql(u8, s[2..], f.name[2..])) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Which Fog numbering a version's DLLs were linked against — i.e. which rosetta column their
/// import tables speak. The only module whose numbers changed, and it changed once: classic covers
/// 1.00-1.06b, lod covers 1.07 onward.
///
/// We do not ship a Fog per family. `lod` is canonical (it is the numbering we implemented and
/// named), and a classic version's imports are rewritten to it before load — an ordinal import is
/// a bare `0x80000000 | n` in the thunk array, so retargeting one is a u32 write.
pub const FogFamily = enum { classic, lod };

/// D2Game's host-facing entry points. Identical 1.00 -> 1.10f, so these are defaults rather than
/// per-version data; a version that ever disagrees overrides the one field.
pub const GameOrdinals = struct {
    /// Module init. Must run first: it initialises the game-list critical section D2Game takes on
    /// the first line of CreateNewEmptyGame, so skipping it hangs on an unowned lock.
    init_server_module: u16 = 10046,
    /// Takes the host's game-data table and game-list handle; asserts both non-null.
    init_game_data_table: u16 = 10002,
    /// Stores (does not copy) the callback table pointer, so the table must outlive the process.
    set_server_callbacks: u16 = 10023,
    init_clock: u16 = 10039,
    process_game: u16 = 10043,
    create_empty_game: u16 = 10047,
    set_init_seed: u16 = 10010,
    shutdown: u16 = 10050,
};

pub const Spec = struct {
    /// As the install directories spell it.
    name: []const u8,
    fog: FogFamily,
    expansion: bool,
    /// Load order. D2Game and D2Common cannot both sit at their link addresses (D2Game overruns
    /// D2Common by 92 KB in 1.10f), so this order is the one that costs a single relocation.
    modules: []const [:0]const u8,
    game: GameOrdinals = .{},
    /// Stack args per callback slot. Counted at the call sites in that version's D2Game; asking
    /// for an uncounted slot is a compile error rather than a guess.
    stack_args: callbacks.StackArgs,
};

const classic_modules = [_][:0]const u8{ "Storm.dll", "Fog.dll", "D2Lang.dll", "D2CMP.dll", "D2Common.dll", "D2Net.dll", "D2Game.dll" };
const lod_modules = classic_modules;

pub fn spec(comptime v: Version) Spec {
    return switch (v) {
        .v100 => .{ .name = "1.00", .fog = .classic, .expansion = false, .modules = &classic_modules, .stack_args = .{} },
        .v106b => .{ .name = "1.06b", .fog = .classic, .expansion = false, .modules = &classic_modules, .stack_args = callbacks.v106b },
        .v107 => .{ .name = "1.07", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = .{} },
        .v108 => .{ .name = "1.08", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = .{} },
        .v109d => .{ .name = "1.09d", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v109d },
        .v110f => .{ .name = "1.10f", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v110f },
        .v113c => .{ .name = "1.13c", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = .{} },
        // 1.14d is the monolith: no DLLs to load, and it grew the callback table past 0x40.
        .v114d => .{ .name = "1.14d", .fog = .lod, .expansion = true, .modules = &.{}, .stack_args = callbacks.v114d },
    };
}

test "version spelling round-trips both ways" {
    try std.testing.expectEqual(Version.v109d, Version.parse("1.09d").?);
    try std.testing.expectEqual(Version.v109d, Version.parse("v109d").?);
    try std.testing.expectEqual(Version.v110f, Version.parse("1.10f").?);
    try std.testing.expect(Version.parse("1.11") == null);
}

test "the LoD boundary is where Fog renumbered" {
    try std.testing.expectEqual(FogFamily.classic, spec(.v106b).fog);
    try std.testing.expectEqual(FogFamily.lod, spec(.v107).fog);
}

test "host-facing D2Game ordinals are shared across the DLL era" {
    inline for (.{ .v100, .v106b, .v109d, .v110f }) |v| {
        try std.testing.expectEqual(10046, spec(v).game.init_server_module);
        try std.testing.expectEqual(10023, spec(v).game.set_server_callbacks);
    }
}
