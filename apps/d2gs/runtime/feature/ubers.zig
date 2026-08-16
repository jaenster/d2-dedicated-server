//! Ubers (server) — Pandemonium event + Uber Tristram. Ported from Charon's Ubers.cpp,
//! EXCLUDING Diablo Clone (no SoJ-sale announce, no SPAWN_UniqueMonster hook, no anni drop).
//!
//! roomInit spawns uber minions/bosses once per game by preset: Pandemonium (133 Lilith, 134
//! Duriel, 135 Izual) and Uber Tristram (136: Meph/Baal/Diablo at Cain-cage preset 26).
//! CubeKeys/CubeOrgans intercepts spawn the matching red portals (Hell only, once per game).
//! KillMonster tracks uber Meph/Diablo/Baal kills in level 136 and drops the Hellfire Torch
//! ("cm2 ", unique txt 400) + a "std " once all three die. Boss AIs summon random adds first.
//!
//! Addresses + struct offsets verified against recon session 9df5e900 (1.14d Game.exe).
const std = @import("std");
const patch = @import("../patch.zig");
const log = @import("../../log.zig");
const feature = @import("../../engine/feature.zig");
const d2types = @import("../../engine/d2types.zig");
const d2 = @import("../../engine/d2/functions.zig");
const types = @import("../../engine/d2/types.zig");

const UnitAny = types.UnitAny;
const Room1 = types.Room1;
const POINT = types.POINT;
const ItemQuality = types.ItemQuality;

// hook / jump sites (recon-verified)
const CUBE_KEYS_HOOK: usize = 0x565A90; // 5-byte JMP thunk (CUBE_SpecialOutput_Unused2)
const CUBE_ORGANS_HOOK: usize = 0x565AA0; // 5-byte JMP thunk (CUBE_SpecialOutput_Unused3)
const KILLMONSTER_ENTRY: usize = 0x57CCB0; // SERVER_KillMonster
const KILLMONSTER_REJOIN: usize = 0x57CCB6; // entry + 6 (push ebp; mov ebp,esp; sub esp,0x20)
const UBER_MEPH_AI: usize = 0x5F81C0; // AI_Function1_UberMephisto (empty `ret 4` stub)
const UBER_DIABLO_AI: usize = 0x5E9DF0; // AI_Function1_UberDiablo (empty `ret 4` stub)
const UBER_BAAL_AI: usize = 0x5FD200; // AI_Function1_UberBaal (empty `ret 4` stub)
const DURABILITY_NOP_FROM: usize = 0x559009; // ITEM_CreateItemInstance durability setup
const DURABILITY_NOP_TO: usize = 0x559025; // next clean instruction (PUSH EDI)

// per-game flags
// Fixed-size registry keyed by the game's unique token (D2GameStrc.nToken @0x00).
// NOTE vs Charon: Charon keys its map by pGame+0x4 ("seed"), which the recon labels
// pHashLink1 (a hash-chain pointer, NOT a seed). nToken @0x00 is the documented
// per-game unique token, so we key on that instead. No std hashmap / global churn.
const GameFlags = packed struct {
    den_portal: bool = false,
    sands_portal: bool = false,
    furnace_portal: bool = false,
    tristram_portal: bool = false,
    lilith_spawned: bool = false,
    duriel_spawned: bool = false,
    izual_spawned: bool = false,
    meph_spawned: bool = false,
    baal_spawned: bool = false,
    diablo_spawned: bool = false,
    meph_killed: bool = false,
    diablo_killed: bool = false,
    baal_killed: bool = false,
    torch_dropped: bool = false,
};

const Entry = struct { token: u32, used: bool = false, flags: GameFlags = .{} };
const MAX_GAMES = 64;
var registry: [MAX_GAMES]Entry = .{Entry{ .token = 0 }} ** MAX_GAMES;

fn flagsFor(token: u32) *GameFlags {
    for (&registry) |*e| {
        if (e.used and e.token == token) return &e.flags;
    }
    for (&registry) |*e| {
        if (!e.used) {
            e.* = .{ .token = token, .used = true, .flags = .{} };
            return &e.flags;
        }
    }
    // Registry full: recycle slot 0 (best-effort; games are short-lived).
    registry[0] = .{ .token = token, .used = true, .flags = .{} };
    return &registry[0].flags;
}

// RNG (mt19937 substitute)
// std Math.random is unavailable here and CRT rand() is forbidden (and gives the
// same sequence every launch). Use a 64-bit SplitMix-style xorshift seeded from a
// monotonically-advancing counter, so item seeds differ across spawns and launches.
var rng_state: u64 = 0x9E3779B97F4A7C15;
var guid: u32 = 0x4FFFFFFF;

fn rngNext() u64 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rng_state = x +% 0x9E3779B97F4A7C15;
    return rng_state;
}

/// Inclusive [min, max].
fn randomNumber(min: i32, max: i32) i32 {
    if (max <= min) return min;
    const span: u64 = @intCast(@as(i64, max) - @as(i64, min) + 1);
    return min + @as(i32, @intCast(rngNext() % span));
}

fn randomElement(comptime T: type, items: []const T) T {
    return items[@intCast(randomNumber(0, @as(i32, @intCast(items.len)) - 1))];
}

fn randSeed() i32 {
    return @intCast(rngNext() & 0x7FFFFFFF);
}

// helpers

fn getActFromRoom(room: *Room1) u32 {
    const room2 = room.pRoom2 orelse return 0;
    const level = room2.pLevel orelse return 0;
    return d2.GetAct.call(@bitCast(level.dwLevelNo));
}

/// Charon PortalTo: spawn a red portal from pUnit's room to `level_id` (same act).
fn portalTo(pGame: *d2types.D2GameStrc, pUnit: *UnitAny, level_id: i32, is_blue: bool) ?*UnitAny {
    const room = pUnit.getRoom1() orelse return null;
    if (getActFromRoom(room) != d2.GetAct.call(level_id)) return null;

    var pos: POINT = undefined;
    d2.UnitLocation.call(pUnit, &pos);

    var target: ?*Room1 = null;
    // FindSpawnableLocation(pRoom, &pos, nScanRadius=3, eFlags=0x400, &target, dwTag=4, nMaxIter=100)
    d2.FindSpawnableLocation.call(.{ @ptrCast(room), @ptrCast(&pos), 3, 0x400, @ptrCast(&target), 4, 100 });

    var pPortal: ?*UnitAny = null;
    const class_id: i32 = if (is_blue) 0x3B else 0x3C;
    d2.SpawnPortal.call(.{ @ptrCast(pGame), null, @ptrCast(target), pos.x, pos.y, level_id, &pPortal, class_id, 0 });
    return pPortal;
}

/// Charon SpawnItem: spawn a custom item near pVictim using the item-gen struct.
fn spawnItem(pGame: *d2types.D2GameStrc, pVictim: *UnitAny, code: *const [4]u8, item_level: i32, quality: ItemQuality, txt_file_no: i32) ?*UnitAny {
    var gen = std.mem.zeroes(types.ItemGenerationData);
    var pos: POINT = undefined;
    var new_pos: POINT = undefined;

    d2.UnitLocation.call(pVictim, &pos);
    const room = pVictim.getRoom1() orelse return null;
    gen.pDrlgRoom = d2.FindBestSpotToSpawnItem.call(.{ room, &pos, &new_pos, 1, 1 });
    gen.wItemFormat = pGame.wItemFormat;
    gen.nItemClassId = d2.GetItemClassIdByCode.call(@bitCast(code.*));
    gen.nPosX = new_pos.x;
    gen.nPosY = new_pos.y;
    gen.eQuality = quality;
    gen.pGame = @ptrCast(pGame);
    gen.nItemLevel = item_level;
    gen.usually_one = 1;
    gen.dwMode = 3;

    if (txt_file_no >= 0) {
        gen.somethingCustom = 1;
        gen.dwFileIndex = @bitCast(txt_file_no);
    }

    gen.nInitSeed = randSeed();
    gen.nModSeed = randSeed();

    return d2.SpawnItemWithStruct.call(.{ @ptrCast(pGame), &gen, 1 });
}

const minion_mods: [9]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0 };

fn spawnUber(pGame: *d2types.D2GameStrc, room: *Room1, x: i32, y: i32, class_id: u32) bool {
    const u = d2.SpawnMonster.call(.{ @ptrCast(pGame), @ptrCast(room), x, y, class_id, guid, 0, 0, 0, 0, &minion_mods });
    guid +%= 1;
    return u != null;
}

// CubeKeys / CubeOrgans intercepts (__fastcall: ECX=pGame, EDX=pUnit)
// Return TRUE → cube consumes the items (the desired behaviour). The engine
// thunk site is a 5-byte JMP, so we JUMP-replace it cleanly.

fn cubeKeysHandler(pGame: *d2types.D2GameStrc, pUnit: *UnitAny) callconv(.c) i32 {
    if (pGame.nDifficulty != 2) {
        d2.PlaySoundMaybe.call(.{ pUnit, 0x14, pUnit });
        return 0;
    }
    const f = flagsFor(pGame.nToken);

    var choices: [3]i32 = undefined;
    var n: usize = 0;
    if (!f.den_portal) {
        choices[n] = 133;
        n += 1;
    }
    if (!f.sands_portal) {
        choices[n] = 134;
        n += 1;
    }
    if (!f.furnace_portal) {
        choices[n] = 135;
        n += 1;
    }

    if (n > 0) {
        const target = randomElement(i32, choices[0..n]);
        if (portalTo(pGame, pUnit, target, false) != null) {
            switch (target) {
                133 => {
                    f.den_portal = true;
                    return 1;
                },
                134 => {
                    f.sands_portal = true;
                    return 1;
                },
                135 => {
                    f.furnace_portal = true;
                    return 1;
                },
                else => {},
            }
        }
    }

    d2.PlaySoundMaybe.call(.{ pUnit, 0x14, pUnit });
    return 0;
}

fn cubeOrgansHandler(pGame: *d2types.D2GameStrc, pUnit: *UnitAny) callconv(.c) i32 {
    const f = flagsFor(pGame.nToken);
    if (pGame.nDifficulty != 2 and !f.tristram_portal) {
        d2.PlaySoundMaybe.call(.{ pUnit, 0x14, pUnit });
        return 0;
    }
    if (portalTo(pGame, pUnit, 136, false) != null) {
        f.tristram_portal = true;
        return 1;
    }
    d2.PlaySoundMaybe.call(.{ pUnit, 0x14, pUnit });
    return 0;
}

/// Naked __fastcall shim: ECX=pGame, EDX=pUnit, no stack args. Forward to the
/// cdecl handler, return its BOOL in EAX, callee-clean `ret`.
fn cubeKeysShim() callconv(.naked) void {
    asm volatile (
        \\push %edx
        \\push %ecx
        \\call %[h:P]
        \\add $8, %esp
        \\ret
        :
        : [h] "X" (&cubeKeysHandler),
        : .{ .ecx = true, .edx = true, .memory = true });
}

fn cubeOrgansShim() callconv(.naked) void {
    asm volatile (
        \\push %edx
        \\push %ecx
        \\call %[h:P]
        \\add $8, %esp
        \\ret
        :
        : [h] "X" (&cubeOrgansHandler),
        : .{ .ecx = true, .edx = true, .memory = true });
}

// KillMonster detour (relocated-prologue, like roominit)
// __fastcall(pGame ECX, pVictim EDX, pAttacker [esp+4], bRemove [esp+8]).
// Original is callee-clean `ret 8`. Our shim re-runs the original (reloc stub),
// then calls our handler, then `ret 8`.

fn killMonsterRelocated() callconv(.naked) void {
    asm volatile (
        \\push %ebp
        \\mov %esp, %ebp
        \\sub $0x20, %esp
        \\push $0x0057CCB6
        \\ret
    );
}

fn killMonsterHandler(pGame: *d2types.D2GameStrc, pVictim: *UnitAny) callconv(.c) void {
    const f = flagsFor(pGame.nToken);

    const room = pVictim.getRoom1();
    const level_no: u32 = blk: {
        const r = room orelse break :blk 0;
        const r2 = r.pRoom2 orelse break :blk 0;
        const lvl = r2.pLevel orelse break :blk 0;
        break :blk lvl.dwLevelNo;
    };

    if (level_no == 136) {
        switch (pVictim.dwTxtFileNo) {
            704 => f.meph_killed = true,
            705 => f.diablo_killed = true,
            709 => f.baal_killed = true,
            else => {},
        }
    }

    if (f.meph_killed and f.diablo_killed and f.baal_killed and !f.torch_dropped) {
        if (spawnItem(pGame, pVictim, "cm2 ", 90, .unique, 400) != null) {
            _ = spawnItem(pGame, pVictim, "std ", 90, .normal, -1);
            f.torch_dropped = true;
        }
    }
}

/// Reached via JMP at the original entry (ECX=pGame, EDX=pVictim, [esp]=ret,
/// [esp+4]=pAttacker, [esp+8]=bRemove). Run the original with the same frame, then
/// call our handler, then callee-clean `ret 8`.
fn killMonsterShim() callconv(.naked) void {
    asm volatile (
    // Save pGame/pVictim across the original call.
        \\push %ecx
        \\push %edx
        // Re-invoke original: re-push its two stack args (now at +12 / +8 due to the
        // two saves above), restore ECX/EDX, call the relocated prologue.
        \\pushl 16(%esp)              // bRemove  (orig [esp+8] -> +8+8)
        \\pushl 16(%esp)              // pAttacker(orig [esp+4] -> +4+8+4)
        \\mov 8(%esp), %edx           // pVictim
        \\mov 12(%esp), %ecx          // pGame
        \\call %[reloc:P]            // original; its `ret 8` cleans the 2 re-pushed args
        \\pop %edx                    // restore pVictim
        \\pop %ecx                    // restore pGame
        // Call our handler(pGame, pVictim) cdecl.
        \\push %edx
        \\push %ecx
        \\call %[handler:P]
        \\add $8, %esp
        \\ret $8                      // callee-clean like the original
        :
        : [reloc] "X" (&killMonsterRelocated),
          [handler] "X" (&killMonsterHandler),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true });
}

// Uber boss AI replacements (__fastcall: ECX=pGame, EDX=pUnit, [esp+4]=pAi)
// The stub functions are empty `ret 4`; we JUMP-replace them. Each summons random
// adds at the target/self, then runs the real boss AI, then callee-clean `ret 4`.

fn uberMephHandler(pGame: *d2types.D2GameStrc, pUnit: *UnitAny, pAi: *types.AIParams) callconv(.c) void {
    const ids = [_]u32{ 725, 726, 727, 728, 729, 730 };
    if (pAi.pTarget) |target| {
        if (randomNumber(0, 9) < 3) {
            if (target.dynamicPath()) |dp| {
                if (dp.pRoom1) |room| {
                    _ = d2.SpawnMonsterWithMode.call(.{ @ptrCast(pGame), @ptrCast(room), @as(i32, dp.xPos), @as(i32, dp.yPos), randomElement(u32, &ids), 8, 1, 0 });
                }
            }
        }
    }
    d2.MephAI.call(.{ @ptrCast(pGame), pUnit, pAi });
}

fn uberDiabloHandler(pGame: *d2types.D2GameStrc, pUnit: *UnitAny, pAi: *types.AIParams) callconv(.c) void {
    if (pAi.pTarget) |target| {
        if (randomNumber(0, 9) == 0) {
            if (target.dynamicPath()) |dp| {
                if (dp.pRoom1) |room| {
                    _ = d2.SpawnMonsterWithMode.call(.{ @ptrCast(pGame), @ptrCast(room), @as(i32, dp.xPos), @as(i32, dp.yPos), 711, 1, 1, 0 });
                }
            }
        }
    }
    d2.DiabloAI.call(.{ @ptrCast(pGame), pUnit, pAi });
}

fn uberBaalHandler(pGame: *d2types.D2GameStrc, pUnit: *UnitAny, pAi: *types.AIParams) callconv(.c) void {
    const ids = [_]u32{ 731, 732 };
    if (randomNumber(0, 9) < 3) {
        if (pUnit.dynamicPath()) |dp| {
            if (dp.pRoom1) |room| {
                _ = d2.SpawnMonsterWithMode.call(.{ @ptrCast(pGame), @ptrCast(room), @as(i32, dp.xPos), @as(i32, dp.yPos), randomElement(u32, &ids), 1, 1, 0 });
            }
        }
    }
    d2.BaalAI.call(.{ @ptrCast(pGame), pUnit, pAi });
}

/// Build a naked __fastcall AI shim around a cdecl handler(pGame, pUnit, pAi).
fn AiShim(comptime handler: anytype) type {
    return struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\pushl 4(%esp)               // pAiParam (the one stack arg)
                \\push %edx                    // pUnit
                \\push %ecx                    // pGame
                \\call %[h:P]
                \\add $12, %esp
                \\ret $4                       // callee-clean (original was `ret 4`)
                :
                : [h] "X" (&handler),
                : .{ .eax = true, .ecx = true, .edx = true, .memory = true });
        }
    };
}

// roomInit hook (fanned out by runtime/roominit.zig)

/// `room` is the D2RoomStrc* (Room1) handed by the roominit driver.
pub fn roomInit(ctx: *const feature.GameCtx, room: *anyopaque) void {
    const pGame = ctx.game;
    const pRoom1: *Room1 = @ptrCast(@alignCast(room));
    const room2 = pRoom1.pRoom2 orelse return;
    const level = room2.pLevel orelse return;
    const f = flagsFor(pGame.nToken);

    const base_x: i32 = @bitCast(room2.dwPosX *% 5);
    const base_y: i32 = @bitCast(room2.dwPosY *% 5);

    switch (level.dwLevelNo) {
        133 => { // Den → Lilith (707), preset 397
            var preset = room2.pPreset;
            while (preset) |p| : (preset = p.pPresetNext) {
                if (p.dwTxtFileNo == 397 and !f.lilith_spawned) {
                    const x = base_x + @as(i32, @bitCast(p.dwPosX));
                    const y = base_y + @as(i32, @bitCast(p.dwPosY));
                    if (spawnUber(pGame, pRoom1, x, y, 707)) f.lilith_spawned = true;
                }
            }
        },
        134 => { // Sands → Duriel (708), preset 402
            var preset = room2.pPreset;
            while (preset) |p| : (preset = p.pPresetNext) {
                if (p.dwTxtFileNo == 402 and !f.duriel_spawned) {
                    const x = base_x + @as(i32, @bitCast(p.dwPosX));
                    const y = base_y + @as(i32, @bitCast(p.dwPosY));
                    if (spawnUber(pGame, pRoom1, x, y, 708)) f.duriel_spawned = true;
                }
            }
        },
        135 => { // Furnace → Izual (706), preset 397
            var preset = room2.pPreset;
            while (preset) |p| : (preset = p.pPresetNext) {
                if (p.dwTxtFileNo == 397 and !f.izual_spawned) {
                    const x = base_x + @as(i32, @bitCast(p.dwPosX));
                    const y = base_y + @as(i32, @bitCast(p.dwPosY));
                    if (spawnUber(pGame, pRoom1, x, y, 706)) f.izual_spawned = true;
                }
            }
        },
        136 => { // Uber Tristram → Meph (704), Baal (709), Diablo (705) at Cain cage (26)
            var preset = room2.pPreset;
            while (preset) |p| : (preset = p.pPresetNext) {
                if (p.dwTxtFileNo == 26) {
                    const x = base_x + @as(i32, @bitCast(p.dwPosX));
                    const y = base_y + @as(i32, @bitCast(p.dwPosY));
                    if (!f.meph_spawned and spawnUber(pGame, pRoom1, x, y, 704)) f.meph_spawned = true;
                    if (!f.baal_spawned and spawnUber(pGame, pRoom1, x, y, 709)) f.baal_spawned = true;
                    if (!f.diablo_spawned and spawnUber(pGame, pRoom1, x, y, 705)) f.diablo_spawned = true;
                }
            }
        },
        else => {},
    }
}

// install

pub fn install() void {
    comptime {
        if (KILLMONSTER_REJOIN != KILLMONSTER_ENTRY + 6) @compileError("killmonster rejoin must be entry+6");
    }

    const MephShim = AiShim(uberMephHandler);
    const DiabloShim = AiShim(uberDiabloHandler);
    const BaalShim = AiShim(uberBaalHandler);

    var ok = true;
    ok = patch.MemoryPatch(CUBE_KEYS_HOOK).jump(@intFromPtr(&cubeKeysShim)).commit() and ok;
    ok = patch.MemoryPatch(CUBE_ORGANS_HOOK).jump(@intFromPtr(&cubeOrgansShim)).commit() and ok;
    ok = patch.MemoryPatch(UBER_MEPH_AI).jump(@intFromPtr(&MephShim.shim)).commit() and ok;
    ok = patch.MemoryPatch(UBER_DIABLO_AI).jump(@intFromPtr(&DiabloShim.shim)).commit() and ok;
    ok = patch.MemoryPatch(UBER_BAAL_AI).jump(@intFromPtr(&BaalShim.shim)).commit() and ok;
    ok = patch.MemoryPatch(KILLMONSTER_ENTRY).jump(@intFromPtr(&killMonsterShim)).nops(1).commit() and ok;
    // Ignore durability modification on custom spawn items.
    ok = patch.MemoryPatch(DURABILITY_NOP_FROM).nopTo(DURABILITY_NOP_TO).commit() and ok;

    if (ok) {
        log.print("ubers: installed (Pandemonium + Uber Tristram)");
    } else {
        log.print("ubers: FAILED to install one or more patches");
    }
}
