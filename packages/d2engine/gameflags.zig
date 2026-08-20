//! The flags a game is created with (`eD2ArenaFlags`), shared because both servers create games and
//! the engine is unforgiving about one of them.
//!
//! `ARENAFLAG_ClientUpdate` is not optional. `ARENA_NeedsClientUpdate` @0x6fc31690 reads it back as
//! `(*(u8*)(pGame[0x1d28] + 8) >> 2) & 1`, and `D2GAME_UpdateAllClients` @0x6fc389c0 — the function
//! that drains every client's queued packets to the network — **halts the process** when it is
//! clear: `This should never happen! [sUpdateClients]`. A game created with flags 0 therefore takes
//! the whole server down the first time its task runs, and nothing in the message points at the
//! flags.

const std = @import("std");

/// Difficulty occupies bits 12-14.
pub const difficulty_shift: u5 = 12;

/// Bit 2. See the file comment: without it the engine halts as soon as a game is processed.
pub const client_update: u32 = 0x04;
pub const hardcore: u32 = 0x800;
pub const expansion: u32 = 0x10_0000;

/// Bit 21. Deliberately NOT set: it moves Deckard Cain, but also routes the character load into a
/// branch that refuses joins with `nReason 0x19` — verified live on 1.14d, where setting it refused
/// every join and clearing it let them through.
pub const multiplayer: u32 = 0x20_0000;

pub fn gameFlags(diff: u3, is_expansion: bool, is_hardcore: bool) u32 {
    var f: u32 = @as(u32, diff) << difficulty_shift;
    f |= client_update;
    if (is_expansion) f |= expansion;
    if (is_hardcore) f |= hardcore;
    return f;
}

test "client update is the bit the engine reads back" {
    // ARENA_NeedsClientUpdate does (flags >> 2) & 1, so this bit and that shift must agree.
    try std.testing.expectEqual(@as(u32, 1), (gameFlags(0, false, false) >> 2) & 1);
}

test "difficulty lands in bits 12-14" {
    try std.testing.expectEqual(@as(u32, 2 << 12), gameFlags(2, false, false) & (0x7 << 12));
    try std.testing.expectEqual(@as(u32, 0x10_0000 | 0x800), gameFlags(0, true, true) & ~client_update);
}
