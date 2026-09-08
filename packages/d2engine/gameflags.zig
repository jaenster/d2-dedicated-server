//! The flags a game is created with (`eD2ArenaFlags`), shared because both servers create games and
//! the engine is unforgiving about two of them.
//!
//! `ARENAFLAG_ClientUpdate` is not optional. `ARENA_NeedsClientUpdate` @0x6fc31690 reads it back as
//! `(*(u8*)(pGame[0x1d28] + 8) >> 2) & 1`, and `D2GAME_UpdateAllClients` @0x6fc389c0 — the function
//! that drains every client's queued packets to the network — **halts the process** when it is
//! clear: `This should never happen! [sUpdateClients]`. A game created with flags 0 therefore takes
//! the whole server down the first time its task runs, and nothing in the message points at the
//! flags.
//!
//! Bit 21 is the LADDER bit, and it must track the character's ladder status or joins are refused.
//! `GAME_CreateBattleNetGame` @0x530930 stores it as `pGame->eGameType = flags >> 0x15 & 1`, and
//! two things read it back:
//!   - `NET_D2GS_SERVER_Send_0x01_GameFlags` @0x53b340 sends `eGameType != 0` as byte 7, which the
//!     client feeds to `CLIENT_SetLadder` @0x44dc90 — that is what gates ladder-only content.
//!   - `CalculateGetFlags` @0x569d80 refuses the join outright on a mismatch: a ladder character
//!     (.d2s status 0x40) needs `eGameType != 0` or it returns nReason 0x19, and a non-ladder
//!     character needs `eGameType == 0` or it returns 0x1a.
//! The reference servers agree: pvpgn's 1.13c GS builds the same word and sets 0x200000 from the
//! request's `ladder` byte (handle_s2s.c), and 1.09d — which had no ladder — never sets it at all.

const std = @import("std");

/// Difficulty occupies bits 12-14.
pub const difficulty_shift: u5 = 12;

/// Bit 2. See the file comment: without it the engine halts as soon as a game is processed.
pub const client_update: u32 = 0x04;
pub const hardcore: u32 = 0x800;
pub const expansion: u32 = 0x10_0000;

/// Bit 21 — `pGame->eGameType`, which is the ladder flag. See the file comment.
pub const ladder: u32 = 0x20_0000;

pub fn gameFlags(diff: u3, is_expansion: bool, is_hardcore: bool, is_ladder: bool) u32 {
    var f: u32 = @as(u32, diff) << difficulty_shift;
    f |= client_update;
    if (is_expansion) f |= expansion;
    if (is_hardcore) f |= hardcore;
    if (is_ladder) f |= ladder;
    return f;
}

test "client update is the bit the engine reads back" {
    // ARENA_NeedsClientUpdate does (flags >> 2) & 1, so this bit and that shift must agree.
    try std.testing.expectEqual(@as(u32, 1), (gameFlags(0, false, false, false) >> 2) & 1);
}

test "difficulty lands in bits 12-14" {
    try std.testing.expectEqual(@as(u32, 2 << 12), gameFlags(2, false, false, false) & (0x7 << 12));
    try std.testing.expectEqual(@as(u32, 0x10_0000 | 0x800), gameFlags(0, true, true, false) & ~client_update);
}

test "ladder lands in bit 21, which the engine reads as eGameType" {
    // GAME_CreateBattleNetGame: pGame->eGameType = flags >> 0x15 & 1.
    try std.testing.expectEqual(@as(u32, 1), (gameFlags(0, true, false, true) >> 0x15) & 1);
    try std.testing.expectEqual(@as(u32, 0), (gameFlags(0, true, false, false) >> 0x15) & 1);
}

test "matches the word pvpgn's 1.13c GS builds" {
    // handle_s2s.c: 0x04 | expansion 0x100000 | ladder 0x200000 | hardcore 0x800 | difficulty << 12.
    try std.testing.expectEqual(@as(u32, 0x0030_2804), gameFlags(2, true, true, true));
    try std.testing.expectEqual(@as(u32, 0x0010_0004), gameFlags(0, true, false, false));
}
