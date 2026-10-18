//! The three Uber Tristram bosses' AI, put back on 1.14d.
//!
//! Each uber AI is a copy of the act boss's own AI with a minion block in front and, for Diablo and
//! Baal, a few weights changed. So each uber here is 1.14d's own code with exactly those differences,
//! and every helper it calls is 1.14d's:
//!   - Uber Mephisto: the minion block, then AITHINK_Fn1_Mephisto @0x5F78B0 unchanged.
//!   - Uber Diablo: AITHINK_Fn1_Diablo @0x5E9170 unchanged, except that for class 705 its call to the
//!     action selector goes to `diabloSelect` below, which runs the minion block first and then
//!     AI_Diablo_DecideAction @0x5E8810 with the uber's weights. The minion block sits between target
//!     choice and selection, which is where that call is.
//!   - Uber Baal: all of AI_Fn1_BaalCrab @0x5FCFE0 and its selector AI_BaalEvaluateCombatAction
//!     @0x5FC630, written out here, because the uber changes the main as well as every weight table.
//!     The action itself is still 1.14d's AI_Baal_ExecuteAction @0x5FCB60.
const std = @import("std");
const d2types = @import("../../engine/d2types.zig");
const d2 = @import("../../engine/d2/functions.zig");
const types = @import("../../engine/d2/types.zig");
const policy = @import("ubers_policy.zig");

const UnitAny = types.UnitAny;
const Game = d2types.D2GameStrc;
const fastcall = d2.fastcall;

const UBER_MEPHISTO: u32 = 704;
const UBER_DIABLO: u32 = 705;

// 1.14d helpers the AI calls

fn stdcall(comptime addr: usize, comptime F: type) *const F {
    return @ptrFromInt(addr);
}

const UnitsGetRoom = stdcall(0x620BB0, fn (?*UnitAny) callconv(.winapi) ?*anyopaque);
const CheckCollisionType = stdcall(0x64D910, fn (?*anyopaque, i32, i32, i32, i32) callconv(.winapi) i32);
const GetLeftSkill = stdcall(0x620190, fn (?*UnitAny) callconv(.winapi) ?*anyopaque);
const GetRightSkill = stdcall(0x6201D0, fn (?*UnitAny) callconv(.winapi) ?*anyopaque);
const GetSkillId = stdcall(0x643CE0, fn (?*anyopaque, usize, i32) callconv(.winapi) i32);
const GetSkillLevel = stdcall(0x6442A0, fn (?*UnitAny, ?*anyopaque, i32) callconv(.winapi) i32);
const IsInMeleeRange = stdcall(0x622C40, fn (?*UnitAny, ?*UnitAny, i32) callconv(.winapi) i32);
const GetStat = stdcall(0x625480, fn (?*UnitAny, i32, u32) callconv(.winapi) i32);
const LifePercent = stdcall(0x621F20, fn (?*UnitAny) callconv(.winapi) i32);
const GetUnitState = stdcall(0x639DF0, fn (?*UnitAny, i32) callconv(.winapi) i32);
const GetDistanceToXY = stdcall(0x6417F0, fn (?*UnitAny, i32, i32) callconv(.winapi) u32);
const TestCollisionWithUnit = stdcall(0x622AA0, fn (?*UnitAny, ?*UnitAny, i32) callconv(.winapi) i32);

const GetPlayerUniqueId = fastcall(0x5353F0, fn (?*UnitAny) u32);
const FindUnitFromTable = fastcall(0x552F60, fn (?*anyopaque, u32, u32) ?*UnitAny);
const GetDistance = fastcall(0x5DC380, fn (?*UnitAny, ?*UnitAny) u32);
const CollisionWithWall = fastcall(0x5DD290, fn (?*UnitAny, ?*UnitAny) u32);
const ValidateSkillAt = fastcall(0x5FD470, fn (?*anyopaque, ?*UnitAny, i32, ?*UnitAny, i32, i32) u32);
const InitLevelDifficulty = fastcall(0x573930, fn (?*anyopaque, *LevelData, ?*anyopaque, ?*UnitAny) void);
const FindMonsterAiCmd = fastcall(0x58EEF0, fn (?*UnitAny, i32, i32) ?*AiCmd);
const CreateAiCmdAndFill = fastcall(0x58EF40, fn (?*anyopaque, ?*UnitAny, *AiCmdArgs) void);
const CastSkill = fastcall(0x5DEAD0, fn (?*anyopaque, ?*UnitAny, u32, i32, ?*UnitAny, i32, i32) u32);
const BaalExecuteAction = fastcall(0x5FCB60, fn (?*anyopaque, ?*UnitAny, ?*anyopaque, ?*UnitAny, i32, ?*AiCmd) void);
const RestartAiThink = fastcall(0x5DE0F0, fn (?*anyopaque, ?*UnitAny, i32) void);

/// D2MonsterLevelDataStrc, filled by MONSTER_InitLevelDifficultyScaling; the selectors read +0xC.
const LevelData = extern struct { a: u32 = 0, b: u32 = 0, c: u32 = 0, players: i32 = 0, e: u32 = 0 };
/// D2MonsterAiCmdStrc: the anchor (command 10) keeps the boss's spawn point at +0xC/+0x10.
const AiCmd = extern struct { _0: [3]u32, x: i32, y: i32 };
const AiCmdArgs = extern struct { _0: [2]u32 = .{ 0, 0 }, id: i32, x: i32, y: i32, _1: [3]u32 = .{ 0, 0, 0 } };

/// AiThink4.cpp, the file name 1.14d's selectors pass to GetSkillId for its asserts.
const AITHINK4_CPP: usize = 0x6E3500;
const STATE_COLD: i32 = 0xB;
const STAT_FIRE_RESIST: i32 = 0x27;
const STAT_LIGHT_RESIST: i32 = 0x29;
const SKILL_MONSTER_REACH: i32 = 199;

fn aiPending(ai: *anyopaque) *i32 {
    return @ptrFromInt(@intFromPtr(ai) + 0x14); // D2AiGeneralStrc dwArg0: an action saved for the next think
}

fn roll(unit: *UnitAny, n: u32) u32 {
    return d2.SeedRoll.call(.{ @ptrCast(&unit.dwLoSeed), n });
}

/// The selectors' weighted pick: a roll below the total (no roll when the total is not positive),
/// then the first slot whose running sum passes it, comparing signed, as the weights can go negative.
fn pick(unit: *UnitAny, w: []const i32, fallback: i32) i32 {
    var sum: i32 = 0;
    for (w) |x| sum +%= x;
    const r: i32 = if (sum > 0) @bitCast(roll(unit, @bitCast(sum))) else 0;
    var acc: i32 = 0;
    for (w, 0..) |x, i| {
        acc +%= x;
        if (r < acc) return @intCast(i);
    }
    return fallback;
}

/// What a "Blizzard, Meteor, Fire Wall above 3, Immolation Arrow above 7" check finds on one hand.
fn handIsFeared(target: *UnitAny, skill: ?*anyopaque, line: i32) bool {
    const s = skill orelse return false;
    const id = GetSkillId(s, AITHINK4_CPP, line);
    if (id == 59 or id == 56) return true; // Blizzard, Meteor
    if (id == 51) return GetSkillLevel(target, s, 1) > 3; // Fire Wall
    if (id == 27) return GetSkillLevel(target, s, 1) > 7; // Immolation Arrow
    return false;
}

/// AI_BAAL_HasPowerfulSkill @0x5FC0C0 takes its unit in EAX.
fn baalTargetHasAoE(target: *UnitAny) bool {
    const r = asm volatile ("call *%[f]"
        : [ret] "={eax}" (-> u32),
        : [u] "{eax}" (target),
          [f] "r" (@as(usize, 0x5FC0C0)),
        : .{ .ecx = true, .edx = true, .memory = true });
    return r != 0;
}

/// SelectTargetBaal @0x5FBDD0 takes the boss in EBX and five stack words (game, &score, &count, 0, and
/// the AI_BAAL_IsUnitInRange filter: same act, within 1020), `ret 0x14`. Called through this cdecl
/// trampoline so EBX is saved and set in one place.
fn selectTargetBaalTrampoline() callconv(.naked) void {
    asm volatile (
        \\push %ebx
        \\movl 12(%esp), %ebx
        \\pushl $0x5FC000
        \\pushl $0
        \\pushl 28(%esp)
        \\pushl 28(%esp)
        \\pushl 24(%esp)
        \\movl $0x5FBDD0, %eax
        \\call *%eax
        \\pop %ebx
        \\ret
    );
}

fn selectTargetBaal(game: *Game, self: *UnitAny, score: *i32, count: *i32) ?*UnitAny {
    const f: *const fn (*Game, *UnitAny, *i32, *i32) callconv(.c) ?*UnitAny = @ptrCast(&selectTargetBaalTrampoline);
    return f(game, self, score, count);
}

// the census

fn census(game: *Game, centre: *UnitAny) policy.Census {
    var c: policy.Census = .{};
    _ = d2.AiForEach.call(.{ @ptrCast(game), centre, @ptrCast(&c), d2.UBER_CENSUS_CALLBACK, 0 });
    return c;
}

fn censusAtMaxDist(game: *Game, centre: *UnitAny, max_dist: i32) policy.Census {
    var c: policy.Census = .{ .max_dist = max_dist };
    _ = d2.AiForEach.call(.{ @ptrCast(game), centre, @ptrCast(&c), d2.UBER_CENSUS_CALLBACK, 0 });
    return c;
}

// Uber Mephisto

pub fn mephisto(game: *Game, self: *UnitAny, ai: *types.AIParams) callconv(.c) void {
    const around = census(game, ai.pTarget orelse self);
    const near: ?policy.Census = if (policy.mephistoSecondCensus(around, ai.pTarget != null)) censusAtMaxDist(game, self, 0) else null;
    if (policy.mephistoSpawns(around, near)) {
        d2.UberMephistoSpawnMinion.call(.{ @ptrCast(game), self, d2.UberMinionTarget.call(.{ @ptrCast(game), self }) });
    }
    d2.MephistoAI.call(.{ @ptrCast(game), self, ai });
}

// Uber Diablo

/// The census both Diablo and Baal take: around the target (or himself), and, when that finds neither
/// partner and there is a target, once more around himself, which can only say he is not alone.
const Partners = struct { c: policy.Census, alone: bool };

fn partnersCensus(game: *Game, self: *UnitAny, target: ?*UnitAny, boss: policy.Boss) Partners {
    const first = census(game, target orelse self);
    const second: ?policy.Census = if (policy.secondCensus(target != null, first, boss)) census(game, self) else null;
    return .{ .c = first, .alone = policy.alone(target != null, first, second, boss) };
}

/// Reached from AITHINK_Fn1_Diablo's selector call for Uber Diablo, with its arguments.
fn diabloSelect(game: *Game, ai: *anyopaque, self: *UnitAny, target: ?*UnitAny, score: u32, count: i32, anchor: ?*AiCmd) callconv(.c) i32 {
    const p = partnersCensus(game, self, target, .diablo);
    if (policy.diabloSpawns(p.c, p.alone, Roller{ .unit = self })) {
        d2.UberDiabloSpawnPit.call(.{ @ptrCast(game), null, d2.UberMinionTarget.call(.{ @ptrCast(game), self }) });
    }
    return diabloWeights(game, ai, self, target, score, count, anchor);
}

const Roller = struct {
    unit: *UnitAny,
    pub fn roll(self: Roller, n: u32) u32 {
        return d2.SeedRoll.call(.{ @ptrCast(&self.unit.dwLoSeed), n });
    }
};

/// AI_Diablo_DecideAction @0x5E8810 with Uber Diablo's weights. Slots are 1.14d's Diablo actions:
/// 1 walk to the target, 2/3 attack, 4 neutral, 5 DiabLight, 6 fire, 7 cold, 8 wall, 9 prison, 10 run,
/// 12 approach, 13 fire wall, 14 go home, 15 the portal attack, 16 random walk. Each change from the
/// 1.14d function is marked "uber".
fn diabloWeights(game: *Game, ai: *anyopaque, self: *UnitAny, target_opt: ?*UnitAny, score: u32, count: i32, anchor: ?*AiCmd) i32 {
    const pending = aiPending(ai).*;
    if (pending != 0) return pending;

    const target = target_opt orelse {
        const at = self.getPos();
        if (CheckCollisionType(UnitsGetRoom(self), at.x, at.y, 2, 0x40) != 0) return 0x10;
        return if (roll(self, 1000) >= 1) 0xB else 4;
    };

    // The portal attack: a player whose town portal stands in the Chaos Sanctuary near Diablo's home.
    var marker: ?*UnitAny = null;
    var portal_near = false;
    if (target.dwType == 0) {
        marker = FindUnitFromTable.call(.{ @ptrCast(game), 2, GetPlayerUniqueId.call(.{target}) });
        if (marker) |m| {
            if (d2.GetLevelIdFromRoom.call(UnitsGetRoom(m)) == 108) {
                if (anchor) |home| {
                    if (GetDistanceToXY(m, home.x, home.y) < 0x55) portal_near = true;
                }
            }
        }
    }

    var feared = handIsFeared(target, GetLeftSkill(target), 0x27F);
    if (handIsFeared(target, GetRightSkill(target), 0x286)) feared = true;

    var far = false;
    var very_far = false;
    if (anchor != null) {
        // uber: measured from Diablo, not from his home
        const d: i32 = @bitCast(GetDistance.call(.{ target, self }));
        far = d > 0x55;
        very_far = d > 0x69;
    }

    const melee = IsInMeleeRange(self, target, 0) != 0;
    const path = CollisionWithWall.call(.{ self, target }) != 0;
    const fire = GetStat(target, STAT_FIRE_RESIST, 0);
    const light = GetStat(target, STAT_LIGHT_RESIST, 0);

    var w = [_]i32{0} ** 17;
    if (melee) {
        w = .{ 0, 0, 40, 70, 0, 75, 24, 40, 15, 0, 0, 0, 0, 0, 0, 0, 0 }; // uber: slot 5 75, not 40
        if (LifePercent(target) < 20) w[2] = 50;
        if (GetUnitState(target, STATE_COLD) != 0) {
            w[7] = 0;
            w[8] = 0;
        }
        if (fire > light) w[6] -= 10;
        if (fire < light) w[6] += 10;
        if (!path) {
            w[5] = 0;
            w[6] = 0;
        }
        if (portal_near) w[15] = 10;
    } else if (!path) {
        w = .{ 0, 0, 0, 0, 5, 0, 25, 0, 25, 40, 0, 0, 25, 0, 0, 0, 0 };
        if (count < 2) {
            w[8] -= 5;
            w[6] = 0;
            w[1] = 25;
            w[9] = 0;
        }
        if (feared and !far) w[13] = 15;
        if (far) {
            const prison_unset = w[9] == 0;
            w[1] = 60; // uber: walk to the target, where 1.14d zeroes it
            w[12] = 15;
            w[13] = 25;
            if (prison_unset) w[9] = 20;
            if (count < 2) w[9] -= 5;
        }
        if (very_far) w[1] = 60; // uber: walk to the target, where 1.14d goes home (slot 14)
        if (portal_near) w[15] = 20;
    } else {
        w = .{ 0, 0, 0, 0, 0, 5, 25, 0, 15, 20, 10, 0, 20, 0, 0, 0, 0 }; // uber: slot 5 5, not 25
        if (GetDistance.call(.{ self, target }) > 25) {
            w[8] -= 5;
            w[10] = 20;
            w[5] = 0;
        }
        if (fire > light) {
            w[6] -= 10;
            w[8] -= 10;
        }
        if (fire < light) {
            w[6] += 10;
            w[8] += 10;
        }
        if (count < 2) w[6] -= 10;
        if (count > 3) w[6] += 5;
        if (score > 60) w[9] += 10;
        var level: LevelData = .{};
        InitLevelDifficulty.call(.{ @ptrCast(game), &level, UnitsGetRoom(self), self });
        if (count < 2 and level.players < 2) w[9] = 0;
        if (feared and !far) {
            w[6] += 10;
            w[10] = 30;
            w[13] = 15;
        }
        if (far) {
            const prison_unset = w[9] == 0;
            w[1] = 50; // uber: walk to the target; 1.14d zeroes it and sets slot 12 to 10
            w[10] = 0;
            w[13] = 15;
            if (prison_unset) w[9] = 10;
        }
        if (very_far) {
            w[9] = 20;
            w[1] = 60; // uber: walk to the target, where 1.14d goes home (slot 14)
        }
        if (portal_near) w[15] = 15;
    }

    if (ValidateSkillAt.call(.{ @ptrCast(game), self, SKILL_MONSTER_REACH, target, 0, 0 }) != 0) w[9] = 0;
    if (w[15] != 0) {
        if (marker) |m| {
            if (ValidateSkillAt.call(.{ @ptrCast(game), self, SKILL_MONSTER_REACH, m, 0, 0 }) == 0) w[15] = 0;
        }
    }
    return pick(self, &w, 0xB);
}

/// Naked shim for AITHINK_Fn1_Diablo's `call AI_Diablo_DecideAction`: ECX = the AI state, EDX = Diablo,
/// EDI = the game (the caller keeps it there), stack: target, score, candidate count, anchor; `ret 0x10`.
/// Any class but Uber Diablo goes on to the 1.14d selector untouched.
pub fn diabloSelectShim() callconv(.naked) void {
    asm volatile (
        \\cmpl $705, 4(%edx)
        \\jne 1f
        \\pushl 16(%esp)
        \\pushl 16(%esp)
        \\pushl 16(%esp)
        \\pushl 16(%esp)
        \\push %edx
        \\push %ecx
        \\push %edi
        \\call %[h:P]
        \\add $28, %esp
        \\ret $16
        \\1:
        \\pushl $0x5E8810
        \\ret
        :
        : [h] "X" (&diabloSelect),
    );
}

pub fn diablo(game: *Game, self: *UnitAny, ai: *types.AIParams) callconv(.c) void {
    d2.DiabloAI.call(.{ @ptrCast(game), self, ai });
}

// Uber Baal

/// AI_Fn1_BaalCrab @0x5FCFE0 as Uber Baal runs it.
pub fn baal(game: *Game, self: *UnitAny, param: *types.AIParams) callconv(.c) void {
    const ai = param.pMonsterAiGeneral orelse return;
    const stats: [*]const u8 = @ptrCast(param.pMonStats orelse return);
    var score: i32 = 0;
    var count: i32 = 0;
    const target = selectTargetBaal(game, self, &score, &count);

    const p = partnersCensus(game, self, target, .baal);
    if (policy.baalSpawns(p.c, p.alone, Roller{ .unit = self })) d2.UberBaalSpawnMinion.call(.{ @ptrCast(game), self });

    // uber: keep the eighth skill's aura up (Chilling Armor); the tick ends on the attempt
    const s7 = std.mem.readInt(i16, stats[0x17E..][0..2], .little);
    if (auraState(s7)) |state| {
        if (GetUnitState(self, state) == 0) {
            _ = CastSkill.call(.{ @ptrCast(game), self, @as(u32, stats[0x187]), s7, null, 0, 0 });
            return;
        }
    }

    const anchor = FindMonsterAiCmd.call(.{ self, 10, 0 }) orelse blk: {
        const at = self.getPos();
        var args: AiCmdArgs = .{ .id = 10, .x = at.x, .y = at.y };
        CreateAiCmdAndFill.call(.{ @ptrCast(game), self, &args });
        break :blk FindMonsterAiCmd.call(.{ self, 10, 0 });
    };

    const action = baalWeights(game, ai, self, target, score, count, anchor);
    // uber: no target, no action
    const t = target orelse return;
    if (TestCollisionWithUnit(self, t, 6) == 0) {
        BaalExecuteAction.call(.{ @ptrCast(game), self, ai, t, action, anchor });
        RestartAiThink.call(.{ @ptrCast(game), self, 25 });
    } else {
        // uber: blocked, teleport onto the target (fifth skill, Baal Teleport)
        const to = t.getPos();
        const s4 = std.mem.readInt(i16, stats[0x178..][0..2], .little);
        _ = CastSkill.call(.{ @ptrCast(game), self, @as(u32, stats[0x184]), s4, null, to.x, to.y });
    }
}

/// The aura state of a Skills.txt row (`aurastate` +0x80), or null when the row or the state is none.
fn auraState(skill: i16) ?i32 {
    if (skill < 0) return null;
    const table: [*]const u8 = @ptrFromInt(@as(*const usize, @ptrFromInt(0x744304)).*); // sgptDataTable
    const n = std.mem.readInt(i32, table[0xBA0..][0..4], .little);
    if (skill >= n) return null;
    const rows = std.mem.readInt(usize, table[0xB98..][0..4], .little);
    if (rows == 0) return null;
    const row: [*]const u8 = @ptrFromInt(rows + @as(usize, @intCast(skill)) * 0x23C);
    const state = std.mem.readInt(i16, row[0x80..][0..2], .little);
    return if (state < 0) null else state;
}

/// AI_BaalEvaluateCombatAction @0x5FC630 and its three tables, with Uber Baal's weights. Slots are
/// AI_Baal_ExecuteAction's cases: 1 stall, 2 and 6 approach, 3 close in, 4 random walk, 5 go home,
/// 8 curse, 9 Tentacle, 10 attack, 11 Nova, 12 Inferno, 13 Cold Missiles, 14 teleport, 15 clone.
fn baalWeights(game: *Game, ai: *anyopaque, self: *UnitAny, target_opt: ?*UnitAny, score: i32, count: i32, anchor: ?*AiCmd) i32 {
    const pending = aiPending(ai).*;
    if (pending != 0) return pending;

    const target = target_opt orelse {
        const at = self.getPos();
        if (CheckCollisionType(UnitsGetRoom(self), at.x, at.y, 2, 0x40) != 0) return 4;
        return if (roll(self, 100) < 8) 9 else 1;
    };
    _ = anchor; // uber: no go-home weight, and the throne-room portal term is never used

    const d: i32 = @bitCast(GetDistance.call(.{ target, self })); // uber: from Baal, not from home
    const far = d > 75;
    const very_far = d > 100;
    const melee = IsInMeleeRange(self, target, 0) != 0;
    const path = CollisionWithWall.call(.{ self, target }) != 0;

    var w = [_]i32{0} ** 16;
    if (melee) {
        w[1] = 100 - LifePercent(self);
        w[8] = 20;
        w[9] = 10;
        w[10] = 150;
        w[11] = 10;
        w[12] = 10;
        w[13] = 70;
        if (LifePercent(target) < 33) w[10] += 50;
        if (GetUnitState(target, STATE_COLD) != 0) {
            w[8] = 0;
            w[13] = 0;
            w[11] = 0;
        }
        if (!path) {
            w[11] = 0;
            w[13] = 0;
            w[12] = 0;
        }
    } else if (!path) {
        w[2] = 50;
        w[6] = 20;
        w[8] = 10;
        w[9] = 10;
        w[14] = 100;
        if (count < 2) {
            w[2] = 75;
            w[10] = 25;
        }
        if (baalTargetHasAoE(target) and !far) {
            w[13] += 50;
            w[14] += 50;
        }
        if (far) {
            w[2] = 0;
            w[6] = 0;
            w[13] += 25;
            w[11] += 25;
            w[14] += 100;
        }
        if (very_far) w[14] += 100;
    } else {
        w[2] = 80;
        w[3] = 5;
        w[6] = 20;
        w[8] = 10;
        w[9] = 10;
        w[11] = 70;
        w[12] = 80;
        w[13] = 60;
        w[14] = 80;
        const clones = @as(*const i32, @ptrFromInt(@intFromPtr(ai) + 0x18)).*;
        w[15] = @max(0, (2 - clones) * 10);
        const e: i32 = @bitCast(GetDistance.call(.{ self, target }));
        if (e > 35) {
            w[6] += 10;
            w[13] = 0;
        }
        if (e > 25) {
            w[14] += 100;
            w[11] = 0;
        }
        if (count < 2) w[11] -= 10;
        if (count > 3) w[13] += 25;
        if (score > 60) w[8] += 30;
        var level: LevelData = .{};
        InitLevelDifficulty.call(.{ @ptrCast(game), &level, UnitsGetRoom(self), self });
        if (count < 2 and level.players < 2) w[8] = 0;
        if (baalTargetHasAoE(target) and !far) {
            w[6] += 30;
            w[11] += 10;
            w[14] += 100;
        }
        if (far) {
            w[2] = 0;
            w[6] += 25;
            w[14] += 100;
        }
        if (very_far) w[14] += 100;
    }
    return pick(self, &w, 1);
}
