//! PvP arena mode — a server-side last-man-standing arena that runs entirely
//! inside one persistent game. Players join a game named "arena" (the lobby town);
//! when enough have gathered the feature warps them all into a bounded combat
//! level, forces mutual hostility, and runs timed rounds, warping survivors back
//! to the lobby and keeping score. The stock 1.14d client is untouched.
//!
//! See ARENA.md. The whole feature is driven from three entry hooks (player
//! join/leave + death, addresses proven by srvtrace) plus the already-wired
//! per-tick serverTick() fan-out — no per-game engine patch is needed because the
//! arena is a single tracked game.
const std = @import("std");
const patch = @import("../patch.zig");
const trampoline = @import("../trampoline.zig");
const log = @import("../../log.zig");
const d2types = @import("../../engine/d2types.zig");
const d2 = @import("../../engine/d2/types.zig");
const fns = @import("../../engine/d2/functions.zig");
const round = @import("arena_round.zig");

const D2GameStrc = d2types.D2GameStrc;
const UnitAny = d2.UnitAny;

// ── configuration ────────────────────────────────────────────────────────────
// Hybrid venue (ARENA.md): the floor is a configurable existing 1.14d level Id,
// so a restored classic arena map can drop in later by changing one constant.
const ARENA_GAME_PREFIX = "arena"; // games whose name starts with this are arenas
const FLOOR_LEVEL: u32 = 2; // Act 1 - Blood Moor (bounded outdoor; v1 floor)
const LOBBY_LEVEL: u32 = 1; // Act 1 - Rogue Encampment (town / staging)
const MIN_PLAYERS: u32 = 2;
const MAX_PLAYERS: usize = 8;

// Server logic runs ~25 frames/sec; timings (in ~40ms ticks) live in the policy
// core's Config below.
const round_cfg = round.Config{
    .min_players = MIN_PLAYERS,
    .countdown_ticks = 25 * 8, // ~8s gather countdown
    .resolve_ticks = 25 * 5, // ~5s scoreboard before reset
    .fight_timeout_ticks = 25 * 60 * 4, // 4min safety cap per round
};

// ── state ────────────────────────────────────────────────────────────────────
const Participant = struct {
    unit: *UnitAny,
    alive: bool = true,
    score: u32 = 0,
};

const Arena = struct {
    game: ?*D2GameStrc = null,
    policy: round.Round = .{ .cfg = round_cfg },
    players: [MAX_PLAYERS]Participant = undefined,
    count: usize = 0,

    fn find(self: *Arena, unit: *UnitAny) ?*Participant {
        for (self.players[0..self.count]) |*p| {
            if (p.unit == unit) return p;
        }
        return null;
    }

    fn add(self: *Arena, unit: *UnitAny) void {
        if (self.find(unit) != null or self.count >= MAX_PLAYERS) return;
        self.players[self.count] = .{ .unit = unit };
        self.count += 1;
    }

    fn remove(self: *Arena, unit: *UnitAny) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.players[i].unit == unit) {
                self.players[i] = self.players[self.count - 1];
                self.count -= 1;
                return;
            }
        }
    }

    fn aliveCount(self: *Arena) usize {
        var n: usize = 0;
        for (self.players[0..self.count]) |p| {
            if (p.alive) n += 1;
        }
        return n;
    }
};

var arena: Arena = .{};

// ── helpers ──────────────────────────────────────────────────────────────────
fn isArenaGame(game: *D2GameStrc) bool {
    const nm = game.name();
    if (nm.len < ARENA_GAME_PREFIX.len) return false;
    return std.ascii.eqlIgnoreCase(nm[0..ARENA_GAME_PREFIX.len], ARENA_GAME_PREFIX);
}

fn warpAll(level: u32) void {
    const game = arena.game orelse return;
    for (arena.players[0..arena.count]) |p| {
        fns.WarpUnitToLevel.call(.{ @as(?*anyopaque, game), p.unit, level, 0 });
    }
}

/// Force every participant mutually hostile to every other. SetHostileRelation
/// sets one direction (and notifies that target's client), so issue it for every
/// ordered pair.
fn makeAllHostile() void {
    const game = arena.game orelse return;
    const ps = arena.players[0..arena.count];
    for (ps, 0..) |a, i| {
        for (ps, 0..) |b, j| {
            if (i == j) continue;
            fns.SetHostileRelation.call(.{ @as(?*anyopaque, game), a.unit, b.unit });
        }
    }
}

fn beginRound() void {
    for (arena.players[0..arena.count]) |*p| p.alive = true;
    warpAll(FLOOR_LEVEL);
    makeAllHostile();
    log.hex("[arena] round start, players 0x", arena.count);
}

fn awardSurvivor() void {
    // Last one standing (if any) takes the point.
    for (arena.players[0..arena.count]) |*p| {
        if (p.alive) {
            p.score += 1;
            log.hex("[arena] round winner score 0x", p.score);
            break;
        }
    }
}

// ── round driver (per server tick) ───────────────────────────────────────────
// Pure policy decides the transition; we just apply the engine effect it asks for.
pub fn serverTick() void {
    if (arena.game == null) return;
    const act = arena.policy.step(@intCast(arena.count), @intCast(arena.aliveCount()));
    switch (act) {
        .none => {},
        .begin_round => beginRound(),
        .end_round => awardSurvivor(),
        .reset_lobby => warpAll(LOBBY_LEVEL),
    }
}

// ── engine event handlers (called from the entry hooks below) ─────────────────
fn onJoin(pGame: usize, pClient: usize, _: usize) callconv(.c) void {
    const game: *D2GameStrc = @ptrFromInt(pGame);
    if (!isArenaGame(game)) return;
    const unit = fns.GetPlayerFromClient.call(@ptrFromInt(pClient)) orelse return;
    arena.game = game;
    arena.add(unit);
    log.hex("[arena] player joined, count 0x", arena.count);
}

fn onLeave(pGame: usize, pClient: usize, _: usize) callconv(.c) void {
    const game: *D2GameStrc = @ptrFromInt(pGame);
    if (arena.game != game) return;
    if (fns.GetPlayerFromClient.call(@ptrFromInt(pClient))) |unit| arena.remove(unit);
    if (arena.count == 0) {
        arena.game = null;
        arena.policy = .{ .cfg = round_cfg };
    }
}

fn onDeath(pGame: usize, pVictim: usize, _: usize) callconv(.c) void {
    const game: *D2GameStrc = @ptrFromInt(pGame);
    if (arena.game != game or arena.policy.phase != .fight) return;
    const victim: *UnitAny = @ptrFromInt(pVictim);
    if (arena.find(victim)) |p| p.alive = false;
}

// ── entry-hook machinery (modeled on srvtrace.zig: relocate the prologue into a
//    trampoline, JMP the entry to a naked shim that captures args, calls our
//    cdecl handler, then resumes the original) ─────────────────────────────────
const Src = union(enum) { none, ecx, edx, stack: usize };

fn pushAsm(comptime s: Src, comptime pushed: usize) []const u8 {
    return switch (s) {
        .none => "pushl $0\n",
        .ecx => "push %ecx\n",
        .edx => "push %edx\n",
        // 32 (pushal) + 4 (pushfl) + bytes pushed so far + the original k.
        .stack => |k| std.fmt.comptimePrint("pushl {d}(%esp)\n", .{36 + pushed + k}),
    };
}

const Handler = *const fn (usize, usize, usize) callconv(.c) void;

fn EntryHook(
    comptime addr: usize,
    comptime prologue: usize,
    comptime a1: Src,
    comptime a2: Src,
    comptime a3: Src,
    comptime handler: Handler,
) type {
    return struct {
        var tramp: usize = 0;

        fn shim() callconv(.naked) void {
            asm volatile ("pushal\npushfl\n" ++
                    // args pushed right-to-left: a3 (0 pushed), a2 (4), a1 (8).
                    pushAsm(a3, 0) ++ pushAsm(a2, 4) ++ pushAsm(a1, 8) ++
                    "call %[f:P]\n" ++
                    "add $12, %%esp\n" ++
                    "popfl\npopal\n" ++
                    "mov %[tramp], %%eax\n" ++
                    "jmp *(%%eax)\n"
                :
                : [f] "X" (handler),
                  [tramp] "X" (&tramp),
            );
        }

        fn install(comptime label: []const u8) void {
            const t = trampoline.build(addr, prologue, &.{}) orelse {
                log.print("arena: trampoline FAILED — " ++ label);
                return;
            };
            tramp = @intFromPtr(t.buffer);
            if (patch.MemoryPatch(addr).jump(@intFromPtr(&shim)).nopTo(addr + prologue).commit()) {
                log.print("arena: hooked " ++ label);
            } else {
                log.print("arena: patch FAILED — " ++ label);
            }
        }
    };
}

// BroadcastPlayerJoin  @0x52C410 __fastcall(pGame ECX, pClient EDX), prologue 6.
// BroadcastPlayerLeave @0x52C500 __fastcall(pGame ECX, pClient EDX), prologue 5.
// PLAYER_HandleDeathPenalties @0x535AB0 __fastcall(pGame ECX, pVictim EDX,
//                                                  [esp+4]=pKiller), prologue 6.
const JoinHook = EntryHook(0x52C410, 6, .ecx, .edx, .none, &onJoin);
const LeaveHook = EntryHook(0x52C500, 5, .ecx, .edx, .none, &onLeave);
const DeathHook = EntryHook(0x535AB0, 6, .ecx, .edx, .none, &onDeath);

pub fn install() void {
    log.print("arena: installing PvP arena mode");
    JoinHook.install("BroadcastPlayerJoin");
    LeaveHook.install("BroadcastPlayerLeave");
    DeathHook.install("PLAYER_HandleDeathPenalties");
}
