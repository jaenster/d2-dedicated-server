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
    v109b,
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
    /// Per-frame "process net messages". No arguments.
    net_messages: u16 = 10003,
    /// Acquires the worker context the loop below is driven with. No arguments; returns a pointer.
    /// A zero here is the tell that the number does not mean on this build what it means on 1.10f.
    worker_context: u16 = 10041,
    process_game: u16 = 10043,
    /// Drains one game's queued packets to D2Net, and re-arms the game's scheduler task. Skipping
    /// it once drops that game out of the scheduler permanently, so it is not optional.
    flush_game: u16 = 10045,
    create_empty_game: u16 = 10047,
    set_init_seed: u16 = 10010,
    shutdown: u16 = 10050,
};

/// D2Common's host-facing entry points. Unlike D2Game's, these did NOT stay put: classic's export
/// table stops at 11152 where the LoD builds run past 11242, and the numbers moved with it.
pub const CommonOrdinals = struct {
    /// `DATATBLS_LoadAllTxts(a, lang, flags)`. Recognisable by shape rather than by number — a run
    /// of ~50 direct calls ending in `ret 0xC`, one call per table group.
    load_all_txts: u16 = 10576,
    /// Sets the flag `CompileTxt` reads to decide whether to consume `.bin` or generate it. The
    /// argument is inverted: zero turns compilation ON. Null where the export does not exist.
    set_compile_tables: ?u16 = 11242,
};

/// D2Lang's host-facing entry points. Its NAMED exports are the `Unicode::` C++ methods and they
/// did not move; the NONAME block 10000-10013 did, and 1.13c permuted all fourteen of them.
pub const LangOrdinals = struct {
    /// `STRTABLE_Init(hArchive, szLanguage, bExpansion)`, __fastcall, `ret 4`. hArchive is ignored —
    /// 1.13c's own callers reach it through D2Win @10016, which is literally `xor eax,eax; ret`.
    /// Skipping this leaves sghStringTable null and D2Common's charstats load asserts in strtable.cpp.
    strtable_init: u16 = 10000,
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
    common: CommonOrdinals = .{},
    lang: LangOrdinals = .{},
    /// Stack args per callback slot. Counted at the call sites in that version's D2Game; asking
    /// for an uncounted slot is a compile error rather than a guess.
    stack_args: callbacks.StackArgs,
};

const classic_modules = [_][:0]const u8{ "Storm.dll", "Fog.dll", "D2Lang.dll", "D2CMP.dll", "D2Common.dll", "D2Net.dll", "D2Game.dll" };
const lod_modules = classic_modules;

pub fn spec(comptime v: Version) Spec {
    return switch (v) {
        .v100 => .{ .name = "1.00", .fog = .classic, .expansion = false, .modules = &classic_modules, .stack_args = .{} },
        // 1.06b's table loader is @10554, not @10576 — @10576 there is an unrelated bounds check,
        // and calling it returns without reading a single table. It has no compile-tables setter at
        // all, which costs nothing: 1.06b reads .txt directly and never wants compiled tables.
        .v106b => .{
            .name = "1.06b",
            .fog = .classic,
            .expansion = false,
            .modules = &classic_modules,
            .common = .{ .load_all_txts = 10554, .set_compile_tables = null },
            .stack_args = callbacks.v106b,
        },
        // 1.09b is a hybrid, not an early 1.09d: it keeps 1.06b-through-1.08's 12-argument
        // fpLeaveGame and dispatches 0x20, which 1.09d never reaches, while 1.09d added 0x3C.
        .v109b => .{ .name = "1.09b", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v109b },
        .v107 => .{ .name = "1.07", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v107 },
        .v108 => .{ .name = "1.08", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v108 },
        .v109d => .{ .name = "1.09d", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v109d },
        .v110f => .{ .name = "1.10f", .fog = .lod, .expansion = true, .modules = &lod_modules, .stack_args = callbacks.v110f },
        // 1.13c renumbered its whole export table — every entry point we call moved, in D2Game and
        // D2Common alike, and 10023 there is a bare `ret 4` rather than the callback setter. Each
        // number below was matched as a byte-level structural twin of its 1.10f counterpart, not by
        // position. It reads .bin at runtime: the selector takes .txt only when the flag is
        // non-zero, and the flag defaults to zero.
        .v113c => .{
            .name = "1.13c",
            .fog = .lod,
            .expansion = true,
            .modules = &lod_modules,
            // Confirmed against Marsgod's 1.13c D2Server.dll, which imports these by number:
            // 10048 takes the callback table, 10037 the game-data table, 10038 initialises, 10040
            // pumps the network, 10044 creates a game, 10047 shuts down.
            //
            // UNVERIFIED, and the reference never calls them, so nothing corroborates the
            // structural match: init_clock, set_init_seed, process_game. Treat them as suspect —
            // worker_context was structurally matched to 10021 the same way and 10021 turned out to
            // be a FOG ordinal, not a D2Game one at all. It is left wrong-but-named here only
            // because 1.13c does not reach the tick loop yet; fix it before it does.
            .game = .{
                .init_server_module = 10038,
                .init_game_data_table = 10037,
                .set_server_callbacks = 10048,
                .init_clock = 10016, // unverified
                .net_messages = 10040,
                .worker_context = 10021, // WRONG — 10021 is a Fog ordinal; the real one is unknown
                .process_game = 10056, // unverified
                .flush_game = 10002,
                .create_empty_game = 10044,
                .set_init_seed = 10017, // unverified
                .shutdown = 10047,
            },
            .common = .{ .load_all_txts = 10943, .set_compile_tables = 10563 },
            // 1.13c permuted D2Lang's whole NONAME block: its 10000 is a string hash taking
            // (const char*, u32) by stdcall, so calling THAT as the fastcall init dereferences the
            // expansion flag as a pointer and faults on address 1.
            .lang = .{ .strtable_init = 10008 },
            .stack_args = callbacks.v113c,
        },
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

test "D2Common's ordinals did not stay put the way D2Game's did" {
    try std.testing.expectEqual(@as(u16, 10576), spec(.v109d).common.load_all_txts);
    try std.testing.expectEqual(@as(u16, 10554), spec(.v106b).common.load_all_txts);
    try std.testing.expect(spec(.v106b).common.set_compile_tables == null);
    try std.testing.expectEqual(@as(u16, 11242), spec(.v110f).common.set_compile_tables.?);
}

test "host-facing D2Game ordinals are shared across the DLL era" {
    inline for (.{ .v100, .v106b, .v109d, .v110f }) |v| {
        try std.testing.expectEqual(10046, spec(v).game.init_server_module);
        try std.testing.expectEqual(10023, spec(v).game.set_server_callbacks);
    }
}
