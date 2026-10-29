//! How long an empty game stays open on a game server.
//!
//! Retail keeps a game whose last player left for five minutes (Game.exe 1.14d compares the idle
//! time against 300000 ms in QSERVER_DispatchAndCleanup), so the same players can come back to it
//! with its map, monsters and dropped items as they left them. A game holds one of the engine's
//! few memory pools until it is destroyed, so a server with every slot but one taken cannot afford
//! to hold empty ones: then they are reaped on a short window to make room for the next create.
//!
//! Retail has a second rule in the same check: an empty game whose frame counter is between
//! 1500 and 7500 (one to five minutes old at 25 frames a second) is destroyed at once, whatever
//! its idle time. Most runs end inside that span, so the five minutes never applied to them and a
//! player who left a run could not rejoin it. The server turns that rule off (`young_game_skip`),
//! which leaves the idle window as the only way an empty game closes.
//!
//! Pure policy, no engine access: the caller patches the engine with whatever `window` returns.

const std = @import("std");

/// Retail's idle time before an empty game is destroyed.
pub const retail_ms: u32 = 300_000;

/// The window while the server is short of slots: long enough for the engine's own cleanup to run
/// after a player's last save, short enough that a create is not refused for long.
pub const pressure_ms: u32 = 5_000;

/// Retail's young-game span, in game frames: `CMP EAX, 0x5dc; JLE keep; CMP EAX, 0x1d4c; JGE keep`.
pub const young_first_frame: u32 = 0x5dc;
pub const young_last_frame: u32 = 0x1d4c;

/// `JLE keep` (7E 21) at the start of the young-game test, and what replaces it: `JMP keep`, the
/// same displacement, so every empty game falls through to the idle window alone.
pub const young_game_retail = [2]u8{ 0x7e, 0x21 };
pub const young_game_skip = [2]u8{ 0xeb, 0x21 };

/// Whether the engine destroys an empty game this tick: `idle_ms` since its last client left,
/// `frame` its frame counter, `window_ms` the idle window, `young_rule` whether retail's
/// young-game rule is still in the code.
pub fn destroys(idle_ms: u32, frame: u32, window_ms: u32, young_rule: bool) bool {
    if (idle_ms > window_ms) return true;
    return young_rule and frame > young_first_frame and frame < young_last_frame;
}

/// Milliseconds an empty game may idle, given `live` games on a server that takes `max`.
///
/// A server keeps one slot free for the next create; once fewer are free, empty games go.
pub fn window(live: u32, max: u32, keep_ms: u32) u32 {
    if (max == 0 or live + 1 >= max) return @min(keep_ms, pressure_ms);
    return keep_ms;
}

test "a quiet server keeps an empty game for the configured time" {
    try std.testing.expectEqual(retail_ms, window(0, 7, retail_ms));
    try std.testing.expectEqual(retail_ms, window(5, 7, retail_ms));
}

test "a server with one slot left reaps empty games quickly" {
    try std.testing.expectEqual(pressure_ms, window(6, 7, retail_ms));
    try std.testing.expectEqual(pressure_ms, window(7, 7, retail_ms));
}

test "a window shorter than the pressure window is never lengthened" {
    try std.testing.expectEqual(@as(u32, 2000), window(7, 7, 2000));
}

test "no known capacity reaps quickly rather than risking the pool table" {
    try std.testing.expectEqual(pressure_ms, window(0, 0, retail_ms));
}

test "retail closes an empty game one to five minutes old at once" {
    try std.testing.expect(destroys(0, 1501, retail_ms, true));
    try std.testing.expect(destroys(0, 7499, retail_ms, true));
    try std.testing.expect(!destroys(0, 1500, retail_ms, true));
    try std.testing.expect(!destroys(0, 7500, retail_ms, true));
}

test "without the young-game rule an empty run stays open for the whole window" {
    // a two-minute run its player just left
    try std.testing.expect(!destroys(0, 3000, retail_ms, false));
    try std.testing.expect(!destroys(retail_ms, 3000, retail_ms, false));
    try std.testing.expect(destroys(retail_ms + 1, 3000, retail_ms, false));
    // a full server still reaps on the short window
    try std.testing.expect(destroys(pressure_ms + 1, 3000, window(6, 7, retail_ms), false));
}

test "the young-game patch keeps the jump target and length" {
    try std.testing.expectEqual(young_game_retail.len, young_game_skip.len);
    try std.testing.expectEqual(young_game_retail[1], young_game_skip[1]);
    try std.testing.expectEqual(@as(u8, 0xeb), young_game_skip[0]);
}
