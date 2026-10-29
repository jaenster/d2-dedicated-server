//! Where an entry hook's shim reads each value at the hooked function's entry, the assembly that
//! pushes it, and each hooked 1.14d function's register contract. Pure comptime data, testable on the host.
const std = @import("std");

/// Where a captured value comes from at function entry. `.stack` is the original [esp+k] BEFORE the
/// shim pushed anything (corrected for pushal/pushfl and our own pushes). `.eax` is read from the
/// pushal save slot, so a scratch use of EAX by an earlier push cannot change it. `.deref_*` captures
/// the byte at [reg].
pub const Src = union(enum) {
    none,
    eax,
    ecx,
    edx,
    esi,
    edi,
    ebx,
    deref_ecx,
    deref_edx,
    stack: usize,
};

/// Bytes the shim's `pushal` + `pushfl` put on the stack before any argument push.
pub const saved_bytes = 36;
/// Offset of EAX's pushal save slot from ESP right after `pushfl` (pushal stores EAX first, at the top
/// of its 32 bytes).
const eax_slot = 4 + 28;

/// The push of one captured value, `pushed` bytes of arguments already on the stack.
pub fn pushAsm(comptime s: Src, comptime pushed: usize) []const u8 {
    return switch (s) {
        .none => "pushl $0\n",
        .eax => std.fmt.comptimePrint("pushl {d}(%esp)\n", .{eax_slot + pushed}),
        .ecx => "push %ecx\n",
        .edx => "push %edx\n",
        .esi => "push %esi\n",
        .edi => "push %edi\n",
        .ebx => "push %ebx\n",
        .deref_ecx => "movzbl (%ecx), %eax\npush %eax\n",
        .deref_edx => "movzbl (%edx), %eax\npush %eax\n",
        .stack => |k| std.fmt.comptimePrint("pushl {d}(%esp)\n", .{saved_bytes + pushed + k}),
    };
}

/// PLRTRADE_ExecuteTrade @0x567C70, `__stdcall` with one extra register: pGame [esp+4], pUnit [esp+8],
/// the two players' trade data [esp+0xC]/[esp+0x10], and the other player pUnit2 in EAX (`ret 0x10`).
/// ECX and EDX carry nothing: its only caller loads ECX with the trade state 4 just before the call.
pub const trade_commit = struct {
    pub const game: Src = .{ .stack = 4 };
    pub const player: Src = .{ .stack = 8 };
    pub const other: Src = .eax;
};

/// What a hooked 1.14d function receives at entry: the registers that carry an argument, and how many
/// bytes of stack arguments it pops (`ret N`). Recorded from Ghidra's parameter storage and checked
/// against each function's `ret`.
pub const Contract = struct {
    addr: usize,
    regs: []const Src,
    stack_bytes: usize,
};

pub const contracts = [_]Contract{
    .{ .addr = 0x451000, .regs = &.{ .ecx }, .stack_bytes = 12 }, // InternalNew
    .{ .addr = 0x52C410, .regs = &.{ .ecx, .edx }, .stack_bytes = 0 }, // BroadcastPlayerJoin
    .{ .addr = 0x52C500, .regs = &.{ .ecx, .edx }, .stack_bytes = 0 }, // BroadcastPlayerLeave
    .{ .addr = 0x52C7F0, .regs = &.{ .ecx, .edx }, .stack_bytes = 0 }, // GAME_DestroyGame
    .{ .addr = 0x52CA10, .regs = &.{ .ecx }, .stack_bytes = 0 }, // SaveAllPlayers
    .{ .addr = 0x532400, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SaveGameAllGameTypes
    .{ .addr = 0x535AB0, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // PLAYER_HandleDeathPenalties
    .{ .addr = 0x53B260, .regs = &.{ .ecx, .edx }, .stack_bytes = 0 }, // NET_D2GS_SERVER_Send_0xB4_ConnectionRefused
    .{ .addr = 0x53FF00, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // ChangeGoldForPlayer
    .{ .addr = 0x541470, .regs = &.{ .ecx }, .stack_bytes = 0 }, // EVENT_AllocTimerQueue
    .{ .addr = 0x544720, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // QUEST_SetQuestRecordState
    .{ .addr = 0x549D80, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x06_LeftSkillOnEntity
    .{ .addr = 0x549FC0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x0C_RightSkillOnLocation
    .{ .addr = 0x54A040, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x0D_RightSkillOnEntity
    .{ .addr = 0x54A290, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x14_OverheadMessage
    .{ .addr = 0x54A5D0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x15_ChatMessage
    .{ .addr = 0x54AA90, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x13_InteractWithEntity
    .{ .addr = 0x54AAD0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x16_InteractWithEntityEx
    .{ .addr = 0x54AB40, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x17_DropItem
    .{ .addr = 0x54ABB0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x18_ItemToInventory
    .{ .addr = 0x54ACD0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x19_PickUpToCursor
    .{ .addr = 0x54AD90, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x1A_EquipItem
    .{ .addr = 0x54AE30, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x1B_EquipToSwapSlot
    .{ .addr = 0x54AEC0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x1C_UnequipToInventory
    .{ .addr = 0x54AF50, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x1D_SwapBodyItem
    .{ .addr = 0x54B030, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x1E_EquipToWeaponSwap
    .{ .addr = 0x54B0F0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x1F_UseItem
    .{ .addr = 0x54B1E0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x20_UseItemAtLocation
    .{ .addr = 0x54B280, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x27_UseItemOnItem
    .{ .addr = 0x54B300, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x21_MergeStackables
    .{ .addr = 0x54B3E0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x23_ItemToBelt
    .{ .addr = 0x54B450, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x24_ItemFromBelt
    .{ .addr = 0x54B4E0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x25_SwapBeltItem
    .{ .addr = 0x54B560, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x26_UseItemAtPlayerCoords
    .{ .addr = 0x54B650, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x28_SocketItem
    .{ .addr = 0x54B710, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x29_ScrollIntoBook
    .{ .addr = 0x54B790, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x2A_ItemToCube
    .{ .addr = 0x54B930, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x2F_NpcInteract
    .{ .addr = 0x54BAC0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x32_NpcBuyConfirm
    .{ .addr = 0x54BB20, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x33_NpcSell
    .{ .addr = 0x54BB60, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x35_NpcGamble
    .{ .addr = 0x54BC30, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x37_GambleConfirm
    .{ .addr = 0x54BCA0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x38_NpcMenuSelect
    .{ .addr = 0x54C300, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x5E_CubeApply
    .{ .addr = 0x54C5D0, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x49_TakeWaypoint
    .{ .addr = 0x54D520, .regs = &.{ .ecx, .edx }, .stack_bytes = 8 }, // SCMD_0x63_ItemToBeltAuto
    .{ .addr = 0x5550B0, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // TakeStairs
    .{ .addr = 0x558D90, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // ITEM_CreateItemInstance
    .{ .addr = 0x55FE80, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // ITEMMODE_HandleCursorItem
    .{ .addr = 0x560200, .regs = &.{ .ecx, .edx }, .stack_bytes = 32 }, // SERVER_ItemToInventory
    .{ .addr = 0x560420, .regs = &.{ .ecx, .edx }, .stack_bytes = 24 }, // SERVER_TakeItemToCursor
    .{ .addr = 0x561E70, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // ITEMMODE_ConsumeItemAndRemove
    .{ .addr = 0x562660, .regs = &.{ .ecx, .edx }, .stack_bytes = 28 }, // PutItemInItem
    .{ .addr = 0x563C00, .regs = &.{ .ecx, .edx }, .stack_bytes = 4 }, // SERVER_DropItemFromPlayer
    .{ .addr = 0x5665F0, .regs = &.{ .esi }, .stack_bytes = 4 }, // CUBE_MatchAndExecuteRecipe
    .{ .addr = 0x567C70, .regs = &.{ .eax }, .stack_bytes = 16 }, // PLRTRADE_ExecuteTrade
    .{ .addr = 0x56D130, .regs = &.{ .ecx, .edx }, .stack_bytes = 28 }, // SERVER_SpawnPortal
    .{ .addr = 0x576330, .regs = &.{ .ecx, .edx }, .stack_bytes = 20 }, // SUNITNPC_GenerateNpcItems
    .{ .addr = 0x57C6C0, .regs = &.{ .ecx, .edx }, .stack_bytes = 12 }, // DAMAGE_ApplyDamageToUnit
    .{ .addr = 0x5A4440, .regs = &.{ .ecx, .edx }, .stack_bytes = 36 }, // SERVER_SpawnMonster
    .{ .addr = 0x5A5BE0, .regs = &.{ .ecx, .edx }, .stack_bytes = 12 }, // PARTYSCREEN_SendPartyInvite
    .{ .addr = 0x5A5E50, .regs = &.{ .ecx, .edx }, .stack_bytes = 12 }, // PARTYSCREEN_ToggleHostile
    .{ .addr = 0x5BE290, .regs = &.{ .ecx, .edx }, .stack_bytes = 20 }, // SKILLITEM_TownPortalScrollSpell
    .{ .addr = 0x642390, .regs = &.{ .edx }, .stack_bytes = 0 }, // DRLG_ApplyRoomExStateFlags
    .{ .addr = 0x66DDE0, .regs = &.{ .ecx, .edx }, .stack_bytes = 16 }, // DRLGROOMTILE_FillTileData
};

pub fn contractOf(comptime addr: usize) ?Contract {
    for (contracts) |c| if (c.addr == addr) return c;
    return null;
}

/// Whether a hook may read `s` at the entry of a function with contract `c`: a register only when it
/// carries an argument, a stack slot only inside the arguments (or 0, the return address).
pub fn readsArgument(c: Contract, s: Src) bool {
    const reg: Src = switch (s) {
        .none => return true,
        .stack => |k| return k == 0 or (k % 4 == 0 and k <= c.stack_bytes),
        .deref_ecx => .ecx,
        .deref_edx => .edx,
        else => s,
    };
    for (c.regs) |r| if (std.meta.eql(r, reg)) return true;
    return false;
}

/// A compile error naming the hook when it reads anything its function does not receive.
pub fn checkHook(comptime label: []const u8, comptime addr: usize, comptime srcs: []const Src) void {
    const c = contractOf(addr) orelse @compileError("hook " ++ label ++ " has no register contract in hook_contract.zig");
    for (srcs) |s| if (!readsArgument(c, s)) @compileError("hook " ++ label ++ " reads " ++ @tagName(s) ++ ", which its function does not receive");
}
test "a stack source skips the saved registers and the pushes before it" {
    try std.testing.expectEqualStrings("pushl 40(%esp)\n", pushAsm(.{ .stack = 4 }, 0));
    try std.testing.expectEqualStrings("pushl 52(%esp)\n", pushAsm(.{ .stack = 8 }, 8));
}

test "eax is read from its pushal slot, not the live register" {
    try std.testing.expectEqualStrings("pushl 32(%esp)\n", pushAsm(.eax, 0));
    try std.testing.expectEqualStrings("pushl 36(%esp)\n", pushAsm(.eax, 4));
}

// The 1.14d bytes from PLRTRADE_ExecuteTrade's only call site (0x568549..0x568564) and its first
// instructions. A hook that read pGame from ECX got the constant 4 and faulted reading [4], taking the
// whole game server down the moment both players accepted a trade.
const call_site = [_]u8{
    0xB9, 0x04, 0x00, 0x00, 0x00, // mov ecx, 4
    0x89, 0x4B, 0x50, // mov [ebx+0x50], ecx
    0x39, 0x48, 0x50, // cmp [eax+0x50], ecx
    0x75, 0xA7, // jne
    0x50, // push eax          (arg 4)
    0x8B, 0x45, 0xE0, // mov eax, [ebp-0x20]
    0x53, // push ebx          (arg 3)
    0x57, // push edi          (arg 2: pUnit)
    0x50, // push eax          (arg 1: pGame)
    0x8B, 0xC6, // mov eax, esi       (pUnit2)
    0xE8, // call PLRTRADE_ExecuteTrade
};

test "the trade commit contract matches the engine's call site" {
    // ECX holds a constant at the call: nothing may be read from it.
    try std.testing.expectEqualSlices(u8, &.{ 0xB9, 0x04, 0x00, 0x00, 0x00 }, call_site[0..5]);
    inline for (.{ trade_commit.game, trade_commit.player, trade_commit.other }) |s| {
        try std.testing.expect(s != .ecx and s != .edx);
    }
    // Four stack arguments, pGame pushed last so it is [esp+4], pUnit [esp+8]; pUnit2 is moved into
    // EAX after the pushes, right before the call.
    var pushes: usize = 0;
    for (call_site[13..]) |b| {
        if (b == 0x50 or b == 0x53 or b == 0x57) pushes += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), pushes);
    try std.testing.expectEqual(@as(usize, 4), trade_commit.game.stack);
    try std.testing.expectEqual(@as(usize, 8), trade_commit.player.stack);
    try std.testing.expectEqualSlices(u8, &.{ 0x8B, 0xC6, 0xE8 }, call_site[call_site.len - 3 ..]);
    try std.testing.expect(trade_commit.other == .eax);
}

test "the trade commit hook reads only what PLRTRADE_ExecuteTrade receives" {
    const c = contractOf(0x567C70).?;
    try std.testing.expect(readsArgument(c, trade_commit.game));
    try std.testing.expect(readsArgument(c, trade_commit.player));
    try std.testing.expect(readsArgument(c, trade_commit.other));
    // The contract the hook had before: the game in ECX, the player in EDX, and a fifth stack slot.
    try std.testing.expect(!readsArgument(c, .ecx));
    try std.testing.expect(!readsArgument(c, .edx));
    try std.testing.expect(!readsArgument(c, .{ .stack = 0x14 }));
}

test "fastcall packet handlers take ECX, EDX and two stack arguments" {
    const c = contractOf(0x54BB20).?; // SCMD_0x33_NpcSell
    try std.testing.expect(readsArgument(c, .ecx) and readsArgument(c, .edx) and readsArgument(c, .deref_edx));
    try std.testing.expect(readsArgument(c, .{ .stack = 4 }) and readsArgument(c, .{ .stack = 8 }));
    try std.testing.expect(readsArgument(c, .{ .stack = 0 }));
    try std.testing.expect(!readsArgument(c, .{ .stack = 0xC }));
    try std.testing.expect(!readsArgument(c, .eax) and !readsArgument(c, .esi));
}

test "every contract is listed once" {
    for (contracts, 0..) |a, i| for (contracts[i + 1 ..]) |b| try std.testing.expect(a.addr != b.addr);
}
