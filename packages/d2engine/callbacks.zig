//! D2Game's server callback table — the contract a host implements so the engine can reach the
//! realm (join tokens, character load/save, game lifecycle).
//!
//! The 16-slot, 0x40-byte layout did not change across the DLL era: it is the same table in 1.10f's
//! D2Game.dll (stored, not copied, by GAME_SetServerCallbackFunctions @10023) and in 1.14d's
//! monolith (SetupAsBnetServer @0x0052c0e0). Two independent derivations agreeing is why the layout
//! lives here once instead of per host.
//!
//! What is NOT shared is per-version: the stack-arg count of each slot, and the slots past 0x40.
//! Both are parameters here — `StackArgs` per version, `Extended` for the tail — because guessing
//! either one corrupts the engine's stack or dispatches through a wrong offset.
//!
//! A third-party 1.13c host's published `EVENTCALLBACKTABLE` agrees with all sixteen slots derived
//! here, which is a third independent derivation. It also declares `void* fpReservedDebug[10]`
//! after them — so the tail `Extended` models is not a 1.14d invention, it was already there in the
//! DLL era, and 1.14d's `fpGetDatabaseFileTime` at 0x54 lands inside it.
//!
//! Slots are __fastcall (ECX/EDX + stack, callee-cleanup) except 0x10 fpServerLogMessage (cdecl
//! varargs) and 0x3C fpLoadComplete (stdcall). Zig's x86 fastcall callconv is buggy
//! (ziglang/zig#10363), so the fastcall ones go through the naked-asm shims in `fastcall`.

const std = @import("std");
// The shim builder still lives with the injected DLL that has always used it; it is imported as a
// module so this package does not reach into apps/.
const fastcall = @import("fastcall");

/// A slot, named by its byte offset in the table — which is how the engine indexes it.
pub const Slot = enum(u8) {
    fpCloseGame = 0x00,
    fpLeaveGame = 0x04,
    fpGetDatabaseCharacter = 0x08,
    fpSaveDatabaseCharacter = 0x0C,
    fpServerLogMessage = 0x10,
    fpEnterGame = 0x14,
    fpFindPlayerToken = 0x18,
    fpSaveDatabaseGuild = 0x1C,
    fpUnlockDatabaseCharacter = 0x20,
    fpReserved0x24 = 0x24, // "fpReserved1" to a third-party host; nothing has been seen calling it
    fpUpdateCharacterLadder = 0x28,
    fpUpdateGameInformation = 0x2C,
    fpHandlePacket = 0x30, // "fpReserved2" to a third-party host, but the engine does call it
    fpSetGameData = 0x34,
    fpRelockDatabaseCharacter = 0x38,
    fpLoadComplete = 0x3C,
};

/// The table every DLL-era version shares: 16 pointers, 0x40 bytes, pointer-packed. All-null is
/// safe on 1.14d — the engine null-guards each slot before calling it.
pub const D2ServerCallbackFunctions = extern struct {
    fpCloseGame: ?*const anyopaque = null, // (gameId, product, spawnedPlayers, frame)
    fpLeaveGame: ?*const anyopaque = null, // ends with the save timestamp
    fpGetDatabaseCharacter: ?*const anyopaque = null, // (client*, charName, clientId, accountName)
    fpSaveDatabaseCharacter: ?*const anyopaque = null, // (client*, charName, accountName, save, size, token)
    fpServerLogMessage: ?*const anyopaque = null, // cdecl varargs, see ServerLogMessageFn
    fpEnterGame: ?*const anyopaque = null, // (gameId, charName, classId, level, flags)
    fpFindPlayerToken: ?*const anyopaque = null, // validate the join token the realm issued
    fpSaveDatabaseGuild: ?*const anyopaque = null,
    fpUnlockDatabaseCharacter: ?*const anyopaque = null, // (gameData*, charName, accountName)
    fpReserved0x24: ?*const anyopaque = null,
    fpUpdateCharacterLadder: ?*const anyopaque = null,
    fpUpdateGameInformation: ?*const anyopaque = null, // (gameId, charName, classId, level)
    fpHandlePacket: ?*const anyopaque = null, // (packet*, size)
    fpSetGameData: ?*const anyopaque = null,
    fpRelockDatabaseCharacter: ?*const anyopaque = null, // (client*, charName, accountName)
    fpLoadComplete: ?*const anyopaque = null, // stdcall, see LoadCompleteFn
};

/// One slot. Four bytes in the x86 image the engine runs in — where the table is the literal 0x40
/// bytes; wider when this file is compiled for a 64-bit host (the layout tests), so the asserts
/// below scale by it instead of pretending the host is the engine.
pub const slot_size = @sizeOf(?*const anyopaque);

/// The byte offset the engine indexes `slot` at, in this compilation's pointer width.
pub fn offsetOf(comptime slot: Slot) usize {
    return @intFromEnum(slot) / 4 * slot_size;
}

comptime {
    // The engine indexes by offset, so a silent layout change corrupts dispatch. Every slot is
    // pinned, including 0x08/0x0C/0x14/0x18/0x3C — the ones both hosts depend on by name.
    for (@typeInfo(Slot).@"enum".fields) |f| {
        std.debug.assert(@offsetOf(D2ServerCallbackFunctions, f.name) == f.value / 4 * slot_size);
    }
    std.debug.assert(@sizeOf(D2ServerCallbackFunctions) == 16 * slot_size);
    if (slot_size == 4) std.debug.assert(@sizeOf(D2ServerCallbackFunctions) == 0x40);
}

/// Slot 0x10: the engine's own logger, cdecl varargs rather than fastcall.
pub const ServerLogMessageFn = fn (level: i32, fmt: [*:0]const u8, ...) callconv(.c) void;

/// Slot 0x3C: stdcall, one argument.
pub const LoadCompleteFn = fn (i32) callconv(.winapi) i32;

/// A version's full table: the shared 16 slots, then whatever that version appended past 0x40.
/// `Ext` is an extern struct of pointer-sized slots laid out from 0x40 up. A version that appended
/// nothing uses `D2ServerCallbackFunctions` directly.
pub fn Extended(comptime Ext: type) type {
    return extern struct {
        base: D2ServerCallbackFunctions = .{},
        ext: Ext = .{},

        comptime {
            std.debug.assert(@offsetOf(@This(), "ext") == 16 * slot_size); // 0x40 on x86
        }
    };
}

/// What a host knows about one slot on one version. Three states, not two: a slot the engine
/// dispatches with a counted number of stack args, a slot that version's engine never dispatches
/// at all, and (as `null`) a slot nobody has looked at yet. Collapsing the middle case into the
/// first is what produces a guessed `ret n` for a call that never comes; collapsing it into the
/// last makes a finished version look unfinished forever.
pub const Arity = union(enum) {
    /// Stack args past ECX/EDX — i.e. what the shim must pop on return. Counted by raw pushes at
    /// a dispatch site, never from a decompiler's rendered prototype: the decompiler drops
    /// arguments it cannot type, which is how this file carried a 12 for a slot the engine pushes
    /// 13 arguments to.
    args: u8,
    /// Two independent sweeps of that version's `D2Game.dll` — every reference to the callback
    /// table global, and the decompiler's own rendering of each function that holds one — found
    /// nothing that calls this slot.
    ///
    /// It is deliberately *not* called "never dispatched", because that claim has already been
    /// wrong once: the first sweep missed `fpHandlePacket` (the register holding the table was
    /// clobbered across a switch, so a linear walk lost it) on a version where the engine
    /// demonstrably calls it. What the host does with this state is what makes the weaker claim
    /// safe — it leaves the pointer null, and every dispatch site found on any version tests the
    /// slot before calling it, so a missed site costs a skipped feature. A guessed `ret n` in the
    /// same position costs a corrupted engine stack, and nothing checks it.
    no_site_found,
};

// `@as(?Arity, null)` and not a bare `null`: the default-value parameter is itself optional, so a
// bare null reads as "no default" and every version would have to spell out all sixteen slots.
pub const StackArgs = std.enums.EnumFieldStruct(Slot, ?Arity, @as(?Arity, null));

/// The stack-arg count for a slot this version dispatches. Both other states are compile errors,
/// and deliberately different ones — "nobody measured it" is a to-do, "the engine never calls it"
/// is an answer, and a host that confuses them builds the wrong thing.
pub fn stackArgs(comptime version: StackArgs, comptime slot: Slot) usize {
    const arity = @field(version, @tagName(slot)) orelse @compileError(
        "no stack-arg count for " ++ @tagName(slot) ++ " on this version — count it at the call site first",
    );
    return switch (arity) {
        .args => |n| n,
        .no_site_found => @compileError(
            @tagName(slot) ++ " has no known dispatch site on this version — leave the slot null rather " ++
                "than building a stub whose stack cleanup nothing can check",
        ),
    };
}

/// Whether this version's engine has a dispatch site for `slot` — i.e. whether the host should
/// build anything for it at all.
pub fn dispatches(comptime version: StackArgs, comptime slot: Slot) bool {
    const arity = @field(version, @tagName(slot)) orelse @compileError(
        @tagName(slot) ++ " is unaccounted for on this version — scan its dispatch sites first",
    );
    return switch (arity) {
        .args => true,
        .no_site_found => false,
    };
}

/// Every slot a host has to have an answer for before it can build a table — either a counted
/// arity or `no_site_found`. It is all sixteen minus the two convention exceptions: 0x10 is
/// cdecl varargs and 0x3C is stdcall, both with fixed signatures a host writes out directly
/// instead of counting pushes for.
///
/// Note that this is deliberately *not* "the slots the engine calls". Which slots a version
/// dispatches is a per-version fact that belongs in that version's `StackArgs` — 1.10f dispatches
/// `fpUnlockDatabaseCharacter` and no 1.09d site for it was found, and that difference is recorded
/// rather than assumed.
pub const accounted_slots = [_]Slot{
    .fpCloseGame,
    .fpLeaveGame,
    .fpGetDatabaseCharacter,
    .fpSaveDatabaseCharacter,
    .fpEnterGame,
    .fpFindPlayerToken,
    .fpSaveDatabaseGuild,
    .fpUnlockDatabaseCharacter,
    .fpReserved0x24,
    .fpUpdateCharacterLadder,
    .fpUpdateGameInformation,
    .fpHandlePacket,
    .fpSetGameData,
    .fpRelockDatabaseCharacter,
};

/// Whether every accounted slot has an answer for this version. The whole point of a version
/// being "just a suggestion" to a host is that the host can ask this *before* trying to build a
/// callback table, rather than a build failing on whichever slot happens to be missing.
pub fn isComplete(comptime version: StackArgs) bool {
    inline for (accounted_slots) |slot| {
        if (@field(version, @tagName(slot)) == null) return false;
    }
    return true;
}

/// The slots this version has no answer for yet, formatted for a human. Empty string when
/// `isComplete` is true. Comptime because it walks `accounted_slots` at compile time; a runtime
/// caller gets the resulting string back as ordinary data.
pub fn missingSlots(comptime version: StackArgs) []const u8 {
    var out: []const u8 = "";
    var first = true;
    for (accounted_slots) |slot| {
        if (@field(version, @tagName(slot)) != null) continue;
        if (!first) out = out ++ ", ";
        out = out ++ @tagName(slot);
        first = false;
    }
    return out;
}

/// 1.14d, counted at the call sites in the monolith (ret 0x8 / 0x10 / 0x48 / 0x1c) and load-bearing
/// in a running server. NOT interchangeable with v110f: fpFindPlayerToken takes 7 here and 5 there.
///
/// Only the four the injected 1.14d server actually installs are here; the monolith's remaining
/// slots have never been scanned, so they stay `null` (a to-do) rather than being declared
/// `no_site_found` on the strength of not having looked — that state means a sweep ran and came
/// back empty, not that nobody swept.
pub const v114d: StackArgs = .{
    .fpLeaveGame = .{ .args = 18 }, // CleanUpClient, ret 0x48
    .fpGetDatabaseCharacter = .{ .args = 2 }, // ret 0x8
    .fpSaveDatabaseCharacter = .{ .args = 4 }, // ret 0x10
    .fpFindPlayerToken = .{ .args = 7 }, // ret 0x1c
};

/// 1.10f, counted at every dispatch site in `D2Game.dll`. The method is mechanical and worth
/// stating because the numbers it replaced were not: walk all 41 references to the callback-table
/// global (0x6fd45830), follow the register that receives it — through `LEA reg,[table+n]` and
/// `ADD reg,n`, which is how the engine reaches the higher slots — and count the raw `PUSH`es in
/// the dispatch's own basic block. 28 of those references are `if (server)` guards, 2 are the
/// writes in `GAME_SetServerCallbackFunctions`, and 11 are dispatches.
///
/// Four of these disagree with the prototype-derived numbers this file used to carry, and the
/// prototypes were the ones that were wrong:
///
///   - `fpLeaveGame` 12 -> 13. `CLIENTS_RemoveClientFromGame` pushes thirteen at both of its call
///     sites (0x6fc32e3a and 0x6fc32eec), in one straight-line block each.
///   - `fpEnterGame` 3 -> 2. `GAME_UpdateAllClients` @0x6fc38d74 pushes EAX then EDI, and the four
///     pushes before those belong to the `0x6fd1b692` call between them.
///   - `fpUpdateCharacterLadder` 5 -> 0. `GAME_TriggerClientSave` reaches it as `CALL [EBP]` after
///     `ADD EBP,0x28`, with only ECX/EDX set since the preceding call.
///   - `fpUpdateGameInformation` 2 -> 0. Same shape in `PLAYERSTATS_LevelUp` @0x6fc7edc7.
///
/// Every one of those is a stub whose `ret n*4` would have unbalanced the engine's stack the first
/// time that path ran.
pub const v110f: StackArgs = .{
    .fpCloseGame = .{ .args = 2 }, // GAME_CloseGame @0x6fc396ec
    .fpLeaveGame = .{ .args = 13 }, // CLIENTS_RemoveClientFromGame, two sites, both 13
    .fpGetDatabaseCharacter = .{ .args = 2 }, // GAME_JoinGame @0x6fc3741b
    .fpSaveDatabaseCharacter = .{ .args = 4 }, // the realm save path @0x6fc8a4d7
    .fpEnterGame = .{ .args = 2 }, // GAME_UpdateAllClients @0x6fc38d74
    .fpFindPlayerToken = .{ .args = 5 }, // GAME_VerifyJoinGame @0x6fc37073
    .fpSaveDatabaseGuild = .no_site_found, // cut Guild Halls
    .fpUnlockDatabaseCharacter = .{ .args = 1 }, // GAME_JoinGame @0x6fc372fc
    .fpReserved0x24 = .no_site_found,
    .fpUpdateCharacterLadder = .{ .args = 0 }, // GAME_TriggerClientSave @0x6fc37670, via ADD EBP,0x28
    .fpUpdateGameInformation = .{ .args = 0 }, // PLAYERSTATS_LevelUp @0x6fc7edc7, via LEA EBX,[EAX+0x2c]
    .fpHandlePacket = .{ .args = 0 }, // FUN_6fc38140 @0x6fc38232, the client-message processor
    .fpSetGameData = .{ .args = 0 }, // CLIENTS_SetGameData @0x6fc32801 (its one PUSH is the ESI prologue)
    .fpRelockDatabaseCharacter = .{ .args = 1 }, // the realm save path @0x6fc8a48f
};

/// 1.07, the first LoD build, swept from table global 0x6fd4d73c. Complete, and the closest thing
/// we have to a version whose *data* we also hold — the 1.07 `d2exp.mpq` ships 70 compiled `.bin`
/// tables, and a `.bin` is a raw struct dump, so only its own era's engine can read it.
///
/// It sits with 1.06b rather than with the later LoD builds on the two arities that matter:
/// `fpGetDatabaseCharacter` takes **1** stack arg (1.09d and 1.10f take 2) and `fpLeaveGame` takes
/// 12 (they take 13). Like 1.06b it also dispatches `fpSaveDatabaseGuild` and the unnamed 0x24,
/// which the later builds never reach.
pub const v107: StackArgs = .{
    .fpCloseGame = .{ .args = 0 }, // @0x6fc6916d
    .fpLeaveGame = .{ .args = 12 }, // two sites @0x6fc62b25 and @0x6fc62bd0
    .fpGetDatabaseCharacter = .{ .args = 1 }, // two sites @0x6fc664d9 and @0x6fc66fe7, both push one
    .fpSaveDatabaseCharacter = .{ .args = 4 }, // @0x6fcac1af
    .fpEnterGame = .{ .args = 2 }, // @0x6fc68631
    .fpFindPlayerToken = .{ .args = 3 }, // @0x6fc66bd3, same shape as 1.10f's with two fewer pushes
    .fpSaveDatabaseGuild = .{ .args = 1 }, // @0x6fd00851
    .fpUnlockDatabaseCharacter = .{ .args = 0 }, // @0x6fc66e64
    .fpReserved0x24 = .{ .args = 0 }, // two sites @0x6fca9dda and @0x6fca9ea5
    .fpUpdateCharacterLadder = .{ .args = 0 }, // three sites, all 0
    .fpUpdateGameInformation = .{ .args = 0 }, // @0x6fc9ede3
    .fpHandlePacket = .no_site_found,
    .fpSetGameData = .{ .args = 0 }, // @0x6fc6257b (the function opens with the ESI prologue push)
    .fpRelockDatabaseCharacter = .{ .args = 0 }, // @0x6fcac0a8
};

/// 1.09d, counted the same way against the rebuilt 1.09d-lod `D2Game.dll` (table global
/// 0x6fd24174, 203 references, 122 dispatches — the count is high only because this build kept its
/// assert/log calls, and all but 14 of the dispatches are slot 0x10).
///
/// Not a subset of 1.10f's, which is the whole reason it is measured rather than inherited:
///
///   - `fpFindPlayerToken` takes 3 where 1.10f takes 5 (`GAME_VerifyJoinGame` @0x6fc36e85 pushes
///     esi, ebp, eax; 1.10f's pushes two more).
///   - `fpCloseGame` takes 0 where 1.10f takes 2 — @0x6fc3942f sets only ECX/EDX, so the two extra
///     arguments 1.10f passes did not exist yet.
///   - `fpUnlockDatabaseCharacter` has no dispatch site at all. 1.10f calls it from
///     `GAME_JoinGame`; 1.09d's join path only *asserts* the table's slot 0x08 is a valid code
///     pointer (@0x6fc371fa) and never reaches 0x20.
///
/// Everything else agrees with 1.10f, including the 13 of `fpLeaveGame`.
pub const v109d: StackArgs = .{
    .fpCloseGame = .{ .args = 0 }, // @0x6fc3942f
    .fpLeaveGame = .{ .args = 13 }, // two sites @0x6fc32c2f and @0x6fc32cef, both 13
    .fpGetDatabaseCharacter = .{ .args = 2 }, // the join path @0x6fc37232
    .fpSaveDatabaseCharacter = .{ .args = 4 }, // @0x6fc7e1af
    .fpEnterGame = .{ .args = 2 }, // @0x6fc388e6
    .fpFindPlayerToken = .{ .args = 3 }, // GAME_VerifyJoinGame @0x6fc36e85
    .fpSaveDatabaseGuild = .no_site_found,
    .fpUnlockDatabaseCharacter = .no_site_found, // 1.10f dispatches this; no 1.09d site found
    .fpReserved0x24 = .no_site_found,
    .fpUpdateCharacterLadder = .{ .args = 0 }, // three sites, all 0
    .fpUpdateGameInformation = .{ .args = 0 }, // @0x6fc726b3
    .fpHandlePacket = .{ .args = 0 }, // FUN_6fc37f50, the client-message processor
    .fpSetGameData = .{ .args = 0 }, // @0x6fc32681 (its one PUSH is the ESI prologue)
    .fpRelockDatabaseCharacter = .{ .args = 1 }, // @0x6fc7e091
};

/// 1.06b, swept the same way against the rebuilt 1.06b-classic `D2Game.dll` (table global
/// 0x6fd74aa4, whose setter @10023 is a bare one-line store — no ready flag, no forwarding, unlike
/// 1.10f's).
///
/// The widest dispatch set of any build measured, and the only one that reaches two slots the LoD
/// versions never do:
///
///   - `fpSaveDatabaseGuild` (0x1C) is genuinely called here, @0x6fd383b1 with one stack arg. The
///     Guild Halls feature was cut later, which is why 1.09d and 1.10f have no site for it.
///   - The unnamed 0x24 is called too, @0x6fcf9b52 with none.
///
/// Several arities are narrower than LoD's, which is the direction you would expect from the older
/// ABI: `fpGetDatabaseCharacter` takes 1 where LoD takes 2, `fpUnlockDatabaseCharacter` and
/// `fpRelockDatabaseCharacter` take 0 where 1.10f takes 1.
///
/// `fpLeaveGame` is 12 here against 13 on both LoD builds — worth stating because 12 is exactly the
/// number this file used to carry for 1.10f. The old value was not invented, it was the right
/// number for the wrong version.
///
/// Not runnable yet: 1.06b is the classic Fog family, and the 31 classic-era Fog ordinals have no
/// rosetta row. `hostapi.clientFields` has no 1.06b entry either, so `d2host`'s readiness gate
/// still refuses it — this records the ABI half of the work, not a claim that it boots.
pub const v106b: StackArgs = .{
    .fpCloseGame = .{ .args = 0 }, // @0x6fcb8a4d
    .fpLeaveGame = .{ .args = 12 }, // two sites @0x6fcb2787 and @0x6fcb2832, both 12
    .fpGetDatabaseCharacter = .{ .args = 1 }, // two sites @0x6fcb5fea and @0x6fcb6a8e, both 1
    .fpSaveDatabaseCharacter = .{ .args = 4 }, // @0x6fcf74ef
    .fpEnterGame = .{ .args = 2 }, // @0x6fcb7fda
    .fpFindPlayerToken = .{ .args = 3 }, // @0x6fcb667c, same as 1.09d
    .fpSaveDatabaseGuild = .{ .args = 1 }, // @0x6fd383b1 — the only build that calls it
    .fpUnlockDatabaseCharacter = .{ .args = 0 }, // @0x6fcb690a
    .fpReserved0x24 = .{ .args = 0 }, // @0x6fcf9b52 — likewise the only build that calls it
    .fpUpdateCharacterLadder = .{ .args = 0 }, // two sites, both 0
    .fpUpdateGameInformation = .{ .args = 0 }, // @0x6fceb3a1
    .fpHandlePacket = .no_site_found,
    .fpSetGameData = .{ .args = 0 }, // @0x6fcb21db (its one PUSH is the ESI prologue)
    .fpRelockDatabaseCharacter = .{ .args = 0 }, // @0x6fcf73e8
};

/// 1.14d grew the table past 0x40. fpGetDatabaseFileTime is the only appended slot known to be
/// called — CalculateGetFlags @0x569d80 calls it with no IsBadCodePtr guard, so null is a
/// call-to-zero during the character load. Pre-1.14 has no equivalent.
pub const Ext114d = extern struct {
    reserved_0x40: [5]?*const anyopaque = @splat(null),
    fpGetDatabaseFileTime: ?*const anyopaque = null, // 0x54 — char save timestamp for conflict checks
    reserved_0x58: [3]?*const anyopaque = @splat(null),
};

pub const Table114d = Extended(Ext114d);

comptime {
    const file_time = @offsetOf(Table114d, "ext") + @offsetOf(Ext114d, "fpGetDatabaseFileTime");
    std.debug.assert(file_time == 0x54 / 4 * slot_size);
}

/// The __fastcall shim for one slot, built with `version`'s stack-arg count. `impl` is a plain
/// cdecl handler `fn (ecx, edx, s1..sN) callconv(.c) T`; take `&Shim(...).shim` as the table entry.
pub fn Shim(comptime version: StackArgs, comptime slot: Slot, comptime impl: anytype) type {
    return fastcall.Callback2(stackArgs(version, slot), impl);
}

/// A slot that does nothing but balance the stack (`ret n*4`). For slots the engine
/// IsBadCodePtr-checks — a null there reads as a bad code pointer and halts — but whose result it
/// ignores.
pub fn BalancedStub(comptime version: StackArgs, comptime slot: Slot) type {
    return struct {
        pub fn shim() callconv(.naked) void {
            asm volatile (std.fmt.comptimePrint("ret ${d}", .{stackArgs(version, slot) * 4}));
        }
    };
}

// Offsets are stated in engine bytes and scaled to this compilation's pointer width, so the same
// assertions hold when the package is tested on a 64-bit host and when it is built for x86.
test "layout is the one the engine indexes" {
    const T = D2ServerCallbackFunctions;
    try std.testing.expectEqual(16 * slot_size, @sizeOf(T));
    try std.testing.expectEqual(offsetOf(.fpGetDatabaseCharacter), @offsetOf(T, "fpGetDatabaseCharacter"));
    try std.testing.expectEqual(offsetOf(.fpSaveDatabaseCharacter), @offsetOf(T, "fpSaveDatabaseCharacter"));
    try std.testing.expectEqual(offsetOf(.fpEnterGame), @offsetOf(T, "fpEnterGame"));
    try std.testing.expectEqual(offsetOf(.fpFindPlayerToken), @offsetOf(T, "fpFindPlayerToken"));
    try std.testing.expectEqual(offsetOf(.fpLoadComplete), @offsetOf(T, "fpLoadComplete"));
    try std.testing.expectEqual(
        0x54 / 4 * slot_size,
        @offsetOf(Table114d, "ext") + @offsetOf(Ext114d, "fpGetDatabaseFileTime"),
    );
}

test "stack-arg counts are per version, not shared" {
    try std.testing.expectEqual(7, stackArgs(v114d, .fpFindPlayerToken));
    try std.testing.expectEqual(5, stackArgs(v110f, .fpFindPlayerToken));
    try std.testing.expectEqual(3, stackArgs(v109d, .fpFindPlayerToken));
    try std.testing.expectEqual(18, stackArgs(v114d, .fpLeaveGame));
    try std.testing.expectEqual(13, stackArgs(v110f, .fpLeaveGame));
    // fpCloseGame grew two arguments between these two builds, so a shared count would corrupt
    // one of them.
    try std.testing.expectEqual(2, stackArgs(v110f, .fpCloseGame));
    try std.testing.expectEqual(0, stackArgs(v109d, .fpCloseGame));
}

test "the cut Guild Halls slot was real once" {
    // 0x1C and 0x24 have no dispatch site on either LoD build, and both are genuinely called on
    // 1.06b — so "no site found" is a fact about a version, not about the slot.
    try std.testing.expectEqual(1, stackArgs(v106b, .fpSaveDatabaseGuild));
    try std.testing.expectEqual(0, stackArgs(v106b, .fpReserved0x24));
    try std.testing.expect(!dispatches(v110f, .fpSaveDatabaseGuild));
    try std.testing.expect(!dispatches(v109d, .fpSaveDatabaseGuild));
    // And 12 was the right number all along — for the wrong version.
    try std.testing.expectEqual(12, stackArgs(v106b, .fpLeaveGame));
    try std.testing.expectEqual(13, stackArgs(v110f, .fpLeaveGame));
}

test "a slot with no dispatch site is an answer, not a gap" {
    // Both are fully accounted for even though neither counts all fourteen slots: the difference
    // is recorded as no_site_found, which is what lets the host leave the pointer null.
    try std.testing.expect(isComplete(v110f));
    try std.testing.expect(isComplete(v109d));
    try std.testing.expect(!dispatches(v110f, .fpSaveDatabaseGuild));
    try std.testing.expect(!dispatches(v110f, .fpReserved0x24));
    // The one slot the two versions disagree about: 1.10f calls it from GAME_JoinGame, and no
    // 1.09d site turned up under either sweep.
    try std.testing.expect(dispatches(v110f, .fpUnlockDatabaseCharacter));
    try std.testing.expect(!dispatches(v109d, .fpUnlockDatabaseCharacter));
    // fpHandlePacket is the reason this state is "no site found" and not "never dispatched": the
    // engine does call it, on both versions, and the first sweep said otherwise.
    try std.testing.expectEqual(0, stackArgs(v110f, .fpHandlePacket));
    try std.testing.expectEqual(0, stackArgs(v109d, .fpHandlePacket));
}

test "completeness is checkable before a build fails on it" {
    try std.testing.expect(isComplete(v110f));
    try std.testing.expect(isComplete(v109d));
    // The monolith's table was only ever scanned for the four slots the injected server installs.
    try std.testing.expect(!isComplete(v114d));
}

test "missingSlots names exactly what a version still needs" {
    try std.testing.expectEqualStrings("", comptime missingSlots(v110f));
    try std.testing.expectEqualStrings("", comptime missingSlots(v109d));
    const m114 = comptime missingSlots(v114d);
    try std.testing.expect(std.mem.indexOf(u8, m114, "fpCloseGame") != null);
    try std.testing.expect(std.mem.indexOf(u8, m114, "fpLeaveGame") == null);
}
