//! Pure arena round-policy state machine — no engine, no Windows, no pointers, so
//! it is host-testable in isolation. `arena.zig` owns the participant table and
//! engine effects (warp / hostility / scoring) and drives this each server tick,
//! acting on the returned `Action`. Keeping policy separate from effects is what
//! makes the round logic verifiable without standing up Game.exe.
const std = @import("std");

pub const Phase = enum { idle, countdown, fight, resolve };

/// What the glue layer must do as a result of a `step`. The policy never touches
/// the engine; it just says what should happen.
pub const Action = enum {
    none,
    begin_round, // reset alive, warp everyone to the floor, force mutual hostility
    end_round, // award the survivor a point (announce)
    reset_lobby, // warp everyone back to the lobby town
};

pub const Config = struct {
    min_players: u32 = 2,
    countdown_ticks: u32 = 25 * 8,
    resolve_ticks: u32 = 25 * 5,
    fight_timeout_ticks: u32 = 25 * 60 * 4,
};

pub const Round = struct {
    cfg: Config = .{},
    phase: Phase = .idle,
    timer: u32 = 0,

    /// Advance one tick. `player_count` = participants present; `alive_count` =
    /// participants still alive this round (only meaningful in .fight).
    pub fn step(self: *Round, player_count: u32, alive_count: u32) Action {
        switch (self.phase) {
            .idle => {
                if (player_count >= self.cfg.min_players) {
                    self.phase = .countdown;
                    self.timer = self.cfg.countdown_ticks;
                }
                return .none;
            },
            .countdown => {
                if (player_count < self.cfg.min_players) {
                    self.phase = .idle;
                    return .none;
                }
                if (self.timer == 0) {
                    self.phase = .fight;
                    self.timer = self.cfg.fight_timeout_ticks;
                    return .begin_round;
                }
                self.timer -= 1;
                return .none;
            },
            .fight => {
                if (alive_count <= 1 or self.timer == 0) {
                    self.phase = .resolve;
                    self.timer = self.cfg.resolve_ticks;
                    return .end_round;
                }
                self.timer -= 1;
                return .none;
            },
            .resolve => {
                if (self.timer == 0) {
                    self.phase = .idle;
                    return .reset_lobby;
                }
                self.timer -= 1;
                return .none;
            },
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;

// Tiny config so tests don't loop thousands of ticks.
const tcfg = Config{ .min_players = 2, .countdown_ticks = 3, .resolve_ticks = 2, .fight_timeout_ticks = 100 };

test "idle stays idle below min players" {
    var r = Round{ .cfg = tcfg };
    try testing.expectEqual(Action.none, r.step(1, 1));
    try testing.expectEqual(Phase.idle, r.phase);
}

test "enough players arms a countdown" {
    var r = Round{ .cfg = tcfg };
    try testing.expectEqual(Action.none, r.step(2, 2));
    try testing.expectEqual(Phase.countdown, r.phase);
    try testing.expectEqual(@as(u32, 3), r.timer);
}

test "countdown aborts if players drop below min" {
    var r = Round{ .cfg = tcfg, .phase = .countdown, .timer = 3 };
    try testing.expectEqual(Action.none, r.step(1, 1));
    try testing.expectEqual(Phase.idle, r.phase);
}

test "countdown expiry begins the round" {
    var r = Round{ .cfg = tcfg, .phase = .countdown, .timer = 3 };
    _ = r.step(2, 2); // 3 -> 2
    _ = r.step(2, 2); // 2 -> 1
    try testing.expectEqual(Action.none, r.step(2, 2)); // 1 -> 0
    try testing.expectEqual(Action.begin_round, r.step(2, 2)); // fires
    try testing.expectEqual(Phase.fight, r.phase);
}

test "fight ends when one survivor remains" {
    var r = Round{ .cfg = tcfg, .phase = .fight, .timer = 100 };
    try testing.expectEqual(Action.none, r.step(2, 2));
    try testing.expectEqual(Action.end_round, r.step(2, 1));
    try testing.expectEqual(Phase.resolve, r.phase);
}

test "fight ends on timeout even with multiple alive" {
    var r = Round{ .cfg = tcfg, .phase = .fight, .timer = 1 };
    try testing.expectEqual(Action.none, r.step(3, 3)); // 1 -> 0
    try testing.expectEqual(Action.end_round, r.step(3, 3)); // timeout
}

test "resolve returns everyone to the lobby and idles" {
    var r = Round{ .cfg = tcfg, .phase = .resolve, .timer = 2 };
    _ = r.step(2, 1); // 2 -> 1
    try testing.expectEqual(Action.none, r.step(2, 1)); // 1 -> 0
    try testing.expectEqual(Action.reset_lobby, r.step(2, 1));
    try testing.expectEqual(Phase.idle, r.phase);
}

test "full cycle returns to idle" {
    var r = Round{ .cfg = tcfg };
    var guard: u32 = 0;
    // Drive a complete round: gather -> countdown -> fight -> resolve -> idle.
    _ = r.step(2, 2); // -> countdown
    while (r.phase != .fight and guard < 50) : (guard += 1) _ = r.step(2, 2);
    try testing.expectEqual(Phase.fight, r.phase);
    _ = r.step(2, 1); // -> resolve (one survivor)
    try testing.expectEqual(Phase.resolve, r.phase);
    guard = 0;
    while (r.phase != .idle and guard < 50) : (guard += 1) _ = r.step(2, 1);
    try testing.expectEqual(Phase.idle, r.phase);
}
