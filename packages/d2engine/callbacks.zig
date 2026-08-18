//! D2Game's server callback table — the contract a host implements so the engine can reach the
//! realm (join tokens, character load/save, game lifecycle).
//!
//! The 16-slot, 0x40-byte layout did not change across the DLL era: it is the same table in 1.10f's
//! D2Game.dll (stored, not copied, by GAME_SetServerCallbackFunctions @10023) and in 1.14d's
//! monolith (SetupAsBnetServer @0x0052c0e0). Two independent derivations agreeing is why the layout
//! lives here once instead of per host.
//!
//! What is NOT shared is per-version: the stack-arg count of each slot, and the slots 1.14d added
//! past 0x40. Both are parameters here — `StackArgs` per version, `Extended` for the tail — because
//! guessing either one corrupts the engine's stack or dispatches through a wrong offset.
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
    fpUnknown0x24 = 0x24,
    fpUpdateCharacterLadder = 0x28,
    fpUpdateGameInformation = 0x2C,
    fpHandlePacket = 0x30,
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
    fpUnknown0x24: ?*const anyopaque = null,
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

/// Stack args past ECX/EDX for each slot — i.e. what the shim must pop on return. `null` means
/// nobody has counted it at a call site for that version yet; asking for it is a compile error
/// rather than a guess, because a wrong count corrupts the engine's stack.
// `@as(?u8, null)` and not a bare `null`: the default-value parameter is itself optional, so a bare
// null reads as "no default" and every version would have to spell out all sixteen slots.
pub const StackArgs = std.enums.EnumFieldStruct(Slot, ?u8, @as(?u8, null));

pub fn stackArgs(comptime version: StackArgs, comptime slot: Slot) usize {
    return @field(version, @tagName(slot)) orelse @compileError(
        "no stack-arg count for " ++ @tagName(slot) ++ " on this version — count it at the call site first",
    );
}

/// 1.14d, counted at the call sites in the monolith (ret 0x8 / 0x10 / 0x48 / 0x1c) and load-bearing
/// in a running server. NOT interchangeable with v110f: fpFindPlayerToken takes 7 here and 5 there.
pub const v114d: StackArgs = .{
    .fpLeaveGame = 18, // CleanUpClient, ret 0x48
    .fpGetDatabaseCharacter = 2, // ret 0x8
    .fpSaveDatabaseCharacter = 4, // ret 0x10
    .fpFindPlayerToken = 7, // ret 0x1c
};

/// 1.10f, derived from the prototypes in D2Game.dll (total params minus the two register args).
/// The three convention exceptions have no fastcall count: 0x10 is cdecl varargs, 0x3C is stdcall,
/// and 0x1C/0x24 are unused with no prototype to count.
pub const v110f: StackArgs = .{
    .fpCloseGame = 2,
    .fpLeaveGame = 12,
    .fpGetDatabaseCharacter = 2,
    .fpSaveDatabaseCharacter = 4,
    .fpEnterGame = 3,
    .fpFindPlayerToken = 5,
    .fpUnlockDatabaseCharacter = 1,
    .fpUpdateCharacterLadder = 5,
    .fpUpdateGameInformation = 2,
    .fpHandlePacket = 0,
    .fpSetGameData = 0,
    .fpRelockDatabaseCharacter = 1,
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
    try std.testing.expectEqual(18, stackArgs(v114d, .fpLeaveGame));
    try std.testing.expectEqual(12, stackArgs(v110f, .fpLeaveGame));
}
