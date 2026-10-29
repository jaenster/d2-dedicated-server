//! Ubers (server): the Pandemonium Event and Uber Tristram, as Blizzard's realm ran them.
//!
//! 1.14d's Game.exe still carries almost all of the event. What it ships:
//!   - the uber monsters and their quest umods: MONSTER_OnCreateAttachQuests @0x5B1CF0 gives Uber
//!     Mephisto questcomplete, aura, lightning, resist and fast, Uber Diablo questcomplete, resist and
//!     fast, Uber Baal questcomplete, cold, resist and fast, on every create path;
//!   - the reward: umod 22 (questcomplete) runs MONSTER_DispatchSpecialDeath @0x5A3250 when one of the
//!     three dies, and AI_UberTristram_CheckDeathAndDropLoot @0x5E0070 marks it on the game and, once
//!     all three are down, drops the Hellfire Torch (cm2, unique quality; its class and +3 come from the
//!     unique's randclassskill property) and one Standard of Heroes (std) per player in the game;
//!   - the three minion spawners, the census callback and the minion target picker, all with no caller;
//!   - SERVER_SpawnPortal's leave to open red portals from town to 133..136, and the ban on town
//!     portals in Uber Tristram.
//! What the realm build cut, and this module puts back:
//!   - the two cube outputs: CUBE_SpecialOutput_Unused2/3 are thunks to `xor eax,eax; ret`;
//!   - the boss spawn: SUNIT_SpawnPresetUnitsForRoom @0x5559A0 still holds back the presets the realm
//!     spawned the bosses at, and in Uber Tristram even still makes the stray call that was left when
//!     the spawn call was taken out;
//!   - the uber AI entries: three `ret 4` stubs where the minion blocks were.
//!
//! The portal name. A red portal's destination byte (object data +4) is written by its object init,
//! Objects_InitFn12 @0x54FE70, from a table keyed on the level the portal stands in: Harrogath means
//! Nihlathak's Temple. SERVER_SpawnPortal never overwrites it, so a portal from Harrogath to any of the
//! four uber levels went out to the client as Nihlathak's Temple. The realm wrote the destination
//! after the portal was made; so does this.
const std = @import("std");
const patch = @import("../patch.zig");
const log = @import("../../log.zig");
const feature = @import("../../engine/feature.zig");
const d2types = @import("../../engine/d2types.zig");
const d2 = @import("../../engine/d2/functions.zig");
const types = @import("../../engine/d2/types.zig");
const policy = @import("ubers_policy.zig");
const ai = @import("ubers_ai.zig");

const UnitAny = types.UnitAny;
const Game = d2types.D2GameStrc;

const CUBE_KEYS: usize = 0x565A90; // CUBE_SpecialOutput_Unused2, "Pandemonium Portal"
const CUBE_ORGANS: usize = 0x565AA0; // CUBE_SpecialOutput_Unused3, "Pandemonium Finale Portal"
const UBER_MEPHISTO_AI: usize = 0x5F81C0;
const UBER_DIABLO_AI: usize = 0x5E9DF0;
const UBER_BAAL_AI: usize = 0x5FD200;
/// AITHINK_Fn1_Diablo's `call AI_Diablo_DecideAction`, between its target choice and its action switch.
const DIABLO_SELECT_CALL: usize = 0x5E924A;
const DIABLO_SELECT_BYTES = [_]u8{ 0xE8, 0xC1, 0xF5, 0xFF, 0xFF };

/// SUNIT_SpawnPresetUnitsForRoom: in Uber Tristram, after the Cain-cage preset (object 26) is held
/// back, `push ebx; call DRLGROOM_GetLevelIdFromRoom` with the answer thrown away, then `jmp next`.
/// That is where the spawn call was.
const PRESET_TRISTRAM_SITE: usize = 0x555A29;
const PRESET_TRISTRAM_BYTES = [_]u8{ 0x53, 0xE8, 0x81, 0x47, 0x0C, 0x00, 0xEB, 0x60 };
/// The `jz next` that holds back object 397 in Matron's Den and the Furnace of Pain, and the chosen
/// corner object in the Forgotten Sands. Pointed at the site above, so a held-back preset reaches the
/// same call.
const PRESET_HOLD_JZ: usize = 0x555A85;
const PRESET_HOLD_BYTES = [_]u8{ 0x74, 0x0A };

const PORTAL_RED: i32 = 0x3C;
const CANT_SOUND: u32 = 0x14; // the cube's "I can't" event, as CUBE_SpecialOutput_CowPortal uses it

// the per-game record of which portals are open

/// These belong to the game, but 1.14d's D2GameStrc has no room for them, so they live here, one
/// row per game, claimed when the game is made and freed when it ends.
const Opened = struct { keys: [3]bool = .{ false, false, false }, tristram: bool = false };
const Row = struct { game: ?*Game = null, opened: Opened = .{} };
var rows: [256]Row = @splat(.{});

fn rowFor(game: *Game) ?*Row {
    for (&rows) |*r| if (r.game == game) return r;
    for (&rows) |*r| if (r.game == null) {
        r.* = .{ .game = game };
        return r;
    };
    return null; // never seen with 256 games in one process; the cube output then fails
}

pub fn gameCreate(ctx: *const feature.GameCtx) void {
    if (rowFor(ctx.game)) |r| r.opened = .{};
}

pub fn gameDestroy(ctx: *const feature.GameCtx) void {
    for (&rows) |*r| if (r.game == ctx.game) {
        r.* = .{};
    };
}

// helpers

fn levelOf(unit: *UnitAny) i32 {
    const room = unit.getRoom1() orelse return -1;
    return d2.GetLevelIdFromRoom.call(room);
}

fn roll(unit: *UnitAny, n: u32) u32 {
    return d2.SeedRoll.call(.{ @ptrCast(&unit.dwLoSeed), n });
}

/// Open a red portal at the player to `level`, the way the realm's cube outputs did, and name its
/// destination. Returns false when there was no room for it.
fn openPortal(game: *Game, player: *UnitAny, level: i32) bool {
    const room = player.getRoom1() orelse return false;
    var pos: types.POINT = undefined;
    d2.UnitLocation.call(player, &pos);
    var xy = [2]i32{ pos.x, pos.y };
    var spot: ?*anyopaque = null;
    d2.FindSpawnableLocation.call(.{ @ptrCast(room), &xy, 3, 0x400, &spot, 4, 100 });
    if (spot == null) return false;

    var portal: ?*UnitAny = null;
    if (d2.SpawnPortal.call(.{ @ptrCast(game), player, spot, xy[0], xy[1], level, &portal, PORTAL_RED, 0 }) == 0) return false;
    if (portal) |p| {
        // Object data +4: the level the client names this portal after (see the module comment).
        const data: [*]u8 = @ptrCast(p.pUnitData orelse return true);
        data[4] = @intCast(level);
    }
    return true;
}

fn refuse(player: *UnitAny) i32 {
    d2.SetupUpdateEvent.call(.{ player, CANT_SOUND, player });
    return 0;
}

// the cube outputs (__fastcall: ECX = pGame, EDX = the player; TRUE consumes the ingredients)

/// Keys: Hell, in Harrogath, while one of the three is still closed. The player's seed is rolled
/// before any of that is checked, as the realm did.
fn cubeKeys(game: *Game, player: *UnitAny) callconv(.c) i32 {
    const r = roll(player, 3);
    if (game.nDifficulty != policy.HELL or levelOf(player) != policy.HARROGATH) return refuse(player);
    const row = rowFor(game) orelse return refuse(player);
    const level = policy.keyPortalLevel(r, row.opened.keys) orelse return refuse(player);
    if (!openPortal(game, player, level)) return refuse(player);
    row.opened.keys[@intCast(level - policy.MATRONS_DEN)] = true;
    return 1;
}

/// Organs: Hell, in Harrogath, once per game.
fn cubeOrgans(game: *Game, player: *UnitAny) callconv(.c) i32 {
    if (game.nDifficulty != policy.HELL or levelOf(player) != policy.HARROGATH) return refuse(player);
    const row = rowFor(game) orelse return refuse(player);
    if (row.opened.tristram) return refuse(player);
    if (!openPortal(game, player, policy.UBER_TRISTRAM)) return refuse(player);
    row.opened.tristram = true;
    return 1;
}

fn CubeShim(comptime handler: anytype) type {
    return struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\push %edx
                \\push %ecx
                \\call %[h:P]
                \\add $8, %esp
                \\ret
                :
                : [h] "X" (&handler),
            );
        }
    };
}

// the boss spawn

const PresetUnit = extern struct {
    mode: i32,
    class_id: i32,
    x: i32,
    next: ?*PresetUnit,
    path: ?*anyopaque,
    unit_type: i32,
    y: i32,
    flags: i32,
};

/// The realm's boss spawn, which is the preset-monster spawn (SPAWN_SpawnMonsterWithCollisionObj
/// @0x54E490 by way of SpawnUnitByType @0x5557D0) with spawn flag 0x10 added: the exact spot first,
/// then a search four out, and the unit marked ISINIT|ISRESURRECT like every preset spawn. None of the
/// six uber rows sets neverCount, so the flag that would add 8 is left out.
fn spawnBoss(game: *Game, room: *anyopaque, x: i32, y: i32, class_id: u32) void {
    const unit = d2.SpawnMonsterAtRoomPos.call(.{ @ptrCast(game), room, x, y, class_id, 1, -1, 0x10 }) orelse
        d2.SpawnMonsterAtRoomPos.call(.{ @ptrCast(game), room, x, y, class_id, 1, 4, 0x10 }) orelse {
        log.hex("ubers: boss did not spawn, class ", class_id);
        return;
    };
    unit.dwFlags |= 0x0300_0000;
}

/// A preset the stock code held back for the realm (EDI = pGame, EBX = pRoom, ESI = the preset).
fn heldPreset(game: *Game, room: *anyopaque, preset: *PresetUnit) callconv(.c) void {
    var at: d2.RoomCoords = undefined;
    d2.GetRoomCoordinates.call(room, &at);
    const x = at.x + preset.x;
    const y = at.y + preset.y;
    switch (d2.GetLevelIdFromRoom.call(room)) {
        policy.UBER_TRISTRAM => if (preset.class_id == 0x1A) {
            spawnBoss(game, room, x, y, 704); // Uber Mephisto
            spawnBoss(game, room, x, y, 709); // Uber Baal
            spawnBoss(game, room, x, y, 705); // Uber Diablo
        },
        policy.MATRONS_DEN => spawnBoss(game, room, x, y, 707), // Lilith
        policy.FURNACE_OF_PAIN => spawnBoss(game, room, x, y, 706), // Uber Izual
        // She spawns at 0,0 room-relative, not at the object's place: the room's corner.
        policy.FORGOTTEN_SANDS => spawnBoss(game, room, at.x, at.y, 708), // Uber Duriel
        else => {},
    }
}

/// Reached by `call` from the Tristram site, and by the redirected `jz` through it. Keeps every
/// register the loop lives on (EBX, ESI, EDI are callee-saved in the handler).
fn heldPresetShim() callconv(.naked) void {
    asm volatile (
        \\push %esi
        \\push %ebx
        \\push %edi
        \\call %[h:P]
        \\add $12, %esp
        \\ret
        :
        : [h] "X" (&heldPreset),
    );
}

/// The engine calls an AI entry __fastcall(pGame, pUnit), pAiParam on the stack, `ret 4`.
fn AiShim(comptime handler: anytype) type {
    return struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\pushl 4(%esp)
                \\push %edx
                \\push %ecx
                \\call %[h:P]
                \\add $12, %esp
                \\ret $4
                :
                : [h] "X" (&handler),
            );
        }
    };
}

// install

pub fn install() void {
    const stub = [_]u8{0xC2}; // ret 4
    const thunk = [_]u8{0xE9}; // jmp to the `xor eax,eax; ret` the realm build left
    var ok = true;
    ok = patch.MemoryPatch(CUBE_KEYS).expect(&thunk).jump(@intFromPtr(&CubeShim(cubeKeys).shim)).commit() and ok;
    ok = patch.MemoryPatch(CUBE_ORGANS).expect(&thunk).jump(@intFromPtr(&CubeShim(cubeOrgans).shim)).commit() and ok;
    ok = patch.MemoryPatch(UBER_MEPHISTO_AI).expect(&stub).jump(@intFromPtr(&AiShim(ai.mephisto).shim)).commit() and ok;
    ok = patch.MemoryPatch(UBER_DIABLO_AI).expect(&stub).jump(@intFromPtr(&AiShim(ai.diablo).shim)).commit() and ok;
    ok = patch.MemoryPatch(UBER_BAAL_AI).expect(&stub).jump(@intFromPtr(&AiShim(ai.baal).shim)).commit() and ok;
    // Only Uber Diablo takes the other selector; the shim sends every other class on to 1.14d's.
    ok = patch.MemoryPatch(DIABLO_SELECT_CALL).expect(&DIABLO_SELECT_BYTES).call(@intFromPtr(&ai.diabloSelectShim)).commit() and ok;
    // `push ebx; call GetLevelIdFromRoom` (6 bytes) becomes `call heldPresetShim; nop`; the `jmp next`
    // after it stays.
    ok = patch.MemoryPatch(PRESET_TRISTRAM_SITE).expect(&PRESET_TRISTRAM_BYTES).call(@intFromPtr(&heldPresetShim)).nops(1).commit() and ok;
    // `jz next` becomes `jz PRESET_TRISTRAM_SITE`: rel8 from the end of the jz.
    const rel: i8 = @intCast(@as(isize, PRESET_TRISTRAM_SITE) - @as(isize, PRESET_HOLD_JZ + 2));
    ok = patch.MemoryPatch(PRESET_HOLD_JZ).expect(&PRESET_HOLD_BYTES).bytes(&.{ 0x74, @bitCast(rel) }).commit() and ok;

    if (ok) {
        log.print("ubers: installed (Pandemonium Event and Uber Tristram)");
    } else {
        log.print("ubers: FAILED to install one or more patches");
    }
}
