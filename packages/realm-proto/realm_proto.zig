//! Shared realm definitions — the package both sides of the realm link depend on:
//! the GS-side client (`realm/client`) and the realm server (`realm/server`). Imported
//! as the `realm_proto` module (see build.zig) so it crosses module boundaries cleanly.
//!
//! Holds the wire contracts (and any enums/types) that MUST agree on both ends.
pub const protocol = @import("protocol.zig");

/// The cut "Guild Halls" data model (reconstructed from the beta/1.00 binaries).
/// Authoritative state lives in realmd; the GS + client read it for display.
pub const guild = @import("guild.zig");

/// Players one game holds. The engine's CreateClient refuses a client past this
/// (`pGame->nClientsCount < 8`, D2Game/Game/Clients.cpp @0x539a30); the game-info packet carries
/// class and level for exactly this many, and every realm-side seat count derives from it.
pub const max_players_per_game: u16 = 8;

/// The cap a created game gets from the "max players" the client sent in its create request. The
/// client keeps the box to 1..8; a byte outside that (a modified client, zero) gets the full game
/// rather than an unjoinable or an unplayable one.
pub fn gameMaxPlayers(requested: u8) u8 {
    if (requested == 0 or requested > max_players_per_game) return @intCast(max_players_per_game);
    return requested;
}

test "a game's cap is what the creator asked for, within 1..8" {
    const t = @import("std").testing;
    try t.expectEqual(@as(u8, 1), gameMaxPlayers(1));
    try t.expectEqual(@as(u8, 4), gameMaxPlayers(4));
    try t.expectEqual(@as(u8, 8), gameMaxPlayers(8));
    try t.expectEqual(@as(u8, 8), gameMaxPlayers(0));
    try t.expectEqual(@as(u8, 8), gameMaxPlayers(9));
    try t.expectEqual(@as(u8, 8), gameMaxPlayers(255));
}
