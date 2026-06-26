//! Server-side event tracing — a fat bundle of entry-detour hooks on the engine's
//! discrete server actions (game lifecycle, combat, items, skills, warps, monster/
//! portal spawns). Always on. Each hook DECODES the real engine structs and emits a
//! structured JSON line via evlog.zig, e.g.
//!   {"evt":"damage","atk":"EpicAma","vic":"Mephisto"}
//!   {"evt":"monster_spawn","class":242,"x":17500,"y":8100}
//! so a Grafana/Loki pipeline can scrape d2gs_log.txt and query every event.
//!
//! Mechanism: each hook relocates the target's first `prologue` bytes into a
//! trampoline (trampoline.zig fixes up E8/E9), drops a 5-byte JMP at the entry to a
//! per-hook naked shim that captures up to three args (registers / [esp+k] / byte-
//! deref), then calls that hook's `handler(a,b,c)` decoder, restores, and resumes
//! the original. ECX/EDX are never clobbered (only EAX is used transiently for a
//! deref), so the original ABI survives untouched. The handlers run on the engine
//! thread mid-call and only READ engine state (+ pure GetUnitName), so they're safe.
//!
//! Adding a trace point: write a `handler` decoder + one row in the `hooks` table.
const std = @import("std");
const patch = @import("../patch.zig");
const trampoline = @import("../trampoline.zig");
const log = @import("../../log.zig");
const evlog = @import("../evlog.zig");
const t = @import("../../engine/d2/types.zig");
const fns = @import("../../engine/d2/functions.zig");
const game = @import("../../engine/d2types.zig");

extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;

// ── decode helpers ───────────────────────────────────────────────────────────

fn unit(v: usize) ?*t.UnitAny {
    return if (v == 0) null else @ptrFromInt(v);
}

/// Put a unit's name as `key`, resolved SERVER-SIDE (GetUnitName @0x464A60 is a
/// client function and returns nothing on the headless GS). Players → PlayerData
/// .szName (ASCII @ pUnitData+0); monsters → MonStats NameStr→GetLocaleString;
/// anything else → GetUnitName as a best-effort fallback. No-op on a null unit.
fn putName(e: *evlog.Event, key: []const u8, v: usize) void {
    const u = unit(v) orelse return;
    switch (u.dwType) {
        0 => { // player
            const pd = u.pUnitData orelse return;
            e.str(key, ascii(@intFromPtr(pd), 16));
        },
        1 => { // monster
            if (fns.TxtMonStatsGetLine.call(.{@as(i32, @bitCast(u.dwTxtFileNo))})) |rec| {
                e.wstr(key, fns.GetLocaleString.call(.{readU16(@intFromPtr(rec), 6)}));
            }
        },
        else => e.wstr(key, fns.GetUnitName.call(.{u})),
    }
}

/// Put an acting player's char name as "player" plus "uid" — the unit GUID, a
/// stable per-session actor trace id. With the game token (on lifecycle/tick
/// events) this gives a (game, uid) correlation key for everything a player did.
fn putPlayerName(e: *evlog.Event, v: usize) void {
    putName(e, "player", v);
    if (unit(v)) |u| e.int("uid", @as(i64, u.dwUnitId));
}

/// Emit "x"/"y" for a unit's world position, if it has a path.
fn putPos(e: *evlog.Event, v: usize) void {
    const u = unit(v) orelse return;
    if (u.pPath == null) return;
    const p = u.getPos();
    e.int("x", p.x);
    e.int("y", p.y);
}

/// The right-hand skill id currently selected on a player unit, or -1.
fn rightSkillId(v: usize) i32 {
    const u = unit(v) orelse return -1;
    const info = u.pInfo orelse return -1;
    const sk = info.pRightSkill orelse return -1;
    const si = sk.pSkillInfo orelse return -1;
    return @intCast(si.wSkillId);
}

/// The left-hand skill id currently selected on a player unit, or -1.
fn leftSkillId(v: usize) i32 {
    const u = unit(v) orelse return -1;
    const info = u.pInfo orelse return -1;
    const sk = info.pLeftSkill orelse return -1;
    const si = sk.pSkillInfo orelse return -1;
    return @intCast(si.wSkillId);
}

fn gamePtr(v: usize) ?*game.D2GameStrc {
    return if (v == 0) null else @ptrFromInt(v);
}

fn putGame(e: *evlog.Event, v: usize) void {
    const g = gamePtr(v) orelse return;
    e.str("game", g.name());
    e.int("diff", g.nDifficulty);
}

fn trunc32(v: usize) u32 {
    return @truncate(v);
}
fn s32(v: usize) i32 {
    return @bitCast(@as(u32, @truncate(v)));
}

fn readU16(base: usize, off: usize) u16 {
    return @as(*align(1) const u16, @ptrFromInt(base + off)).*;
}
fn readU32(base: usize, off: usize) u32 {
    return @as(*align(1) const u32, @ptrFromInt(base + off)).*;
}
/// Bounded ASCII slice up to the first NUL (or `max`), starting at `base`.
fn ascii(base: usize, max: usize) []const u8 {
    const p: [*]const u8 = @ptrFromInt(base);
    var i: usize = 0;
    while (i < max and p[i] != 0) : (i += 1) {}
    return p[0..i];
}

/// The game whose handler is in flight, set by every shim before it calls the
/// handler (0 when no game pointer is available). Lets ev() stamp the game token
/// on every event without threading pGame through each handler's args.
var cur_game: usize = 0;

fn setCurGame(pg: usize) callconv(.c) void {
    cur_game = pg;
}

/// Begin an event, auto-stamping the game "token" (the per-game trace id) whenever
/// the in-flight game is known. Use for every per-game event; lifecycle/tick build
/// their token explicitly so they call evlog.Event.begin directly.
fn ev(name: []const u8) evlog.Event {
    var e = evlog.Event.begin(name);
    if (cur_game != 0) e.int("token", @as(i64, readU32(cur_game, 0)));
    return e;
}

/// Emit a packed 4-char item code (D2 stores codes like "hp1"/"ssd " as a u32),
/// trimming trailing spaces/NULs.
fn putCode4(e: *evlog.Event, key: []const u8, code: u32) void {
    var b: [4]u8 = @bitCast(code);
    var n: usize = 4;
    while (n > 0 and (b[n - 1] == ' ' or b[n - 1] == 0)) : (n -= 1) {}
    e.str(key, b[0..n]);
}

// D2ClientStrc field offsets (size 0x518): nClientNo@0, szCharName@0x0D, pPlayer@0x174.
const CL_SLOT = 0x00;
const CL_NAME = 0x0D;
const CL_PLAYER = 0x174;

/// Put a player's char name + slot from a D2ClientStrc pointer.
fn putClient(e: *evlog.Event, pclient: usize) void {
    if (pclient == 0) return;
    e.str("player", ascii(pclient + CL_NAME, 16));
    e.int("slot", readU32(pclient, CL_SLOT));
}

// ── active-game tracking + per-game tick heartbeat ───────────────────────────
// We can't cheaply walk the engine's intrusive game list, so we track live games
// off the join/destroy hooks and read their fields directly each heartbeat.
// D2GameStrc offsets: nToken@0, szGameName@42, nClientsCount@140, dwSpawnedPlayers@144,
// dwSpawnedMonsters@148, dwGameFrame@168.

/// Set once by DllMain (computeGsId) so the tick line carries the game-server id.
pub var gsid: u32 = 0;

/// serverTick() runs at ~100 Hz (d2gs.zig main loop); emit a tick every N so it's
/// ~1/sec per game rather than a per-frame flood.
const TICK_EVERY: u64 = 100;

var games: [32]usize = [_]usize{0} ** 32;
var tick_n: u64 = 0;

fn trackGame(pg: usize) void {
    if (pg == 0) return;
    var free: ?usize = null;
    for (games, 0..) |g, i| {
        if (g == pg) return; // already tracked
        if (g == 0 and free == null) free = i;
    }
    if (free) |i| games[i] = pg;
}

fn untrackGame(pg: usize) void {
    for (&games) |*g| {
        if (g.* == pg) g.* = 0;
    }
}

pub fn serverTick() void {
    tick_n += 1;
    if (tick_n % TICK_EVERY != 0) return;
    for (games) |pg| {
        if (pg == 0) continue;
        var e = evlog.Event.begin("tick");
        e.int("gsid", gsid);
        e.int("token", readU32(pg, 0));
        e.str("game", ascii(pg + 42, 16));
        e.int("frame", @as(i32, @bitCast(readU32(pg, 168))));
        e.int("clients", @as(i32, @bitCast(readU32(pg, 140))));
        e.int("players", @as(i32, @bitCast(readU32(pg, 144))));
        e.int("monsters", @as(i32, @bitCast(readU32(pg, 148))));
        e.end();
    }
}

// ── per-event handlers ───────────────────────────────────────────────────────
// Signature is always fn(a1, a2, a3) callconv(.c); each interprets the captured
// args (see the hooks table for what a1/a2/a3 hold for that hook).

fn onGameCreate(token_map: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("game_create");
    e.hex("tokenMap", token_map);
    e.end();
}

/// Optional observer fired when a game is destroyed, with the game's name (read
/// from the engine game struct). The realm GS client subscribes to tell realmd to
/// drop the game from the join list — without it, dead games linger until their
/// redis TTL and clients get "game name and password don't match" on join.
pub var on_game_destroy: ?*const fn (name: []const u8) void = null;

fn onGameDestroy(token: usize, pgame: usize, _: usize) callconv(.c) void {
    untrackGame(pgame);
    var e = ev("game_destroy");
    e.int("token", trunc32(token));
    putGame(&e, pgame);
    e.end();
    if (on_game_destroy) |cb| cb(ascii(pgame + 42, 16));
}

fn onPlayerJoin(pgame: usize, pclient: usize, _: usize) callconv(.c) void {
    trackGame(pgame);
    var e = ev("player_join");
    putGame(&e, pgame);
    putClient(&e, pclient);
    e.end();
}

fn onPlayerLeave(pgame: usize, pclient: usize, _: usize) callconv(.c) void {
    var e = ev("player_leave");
    putGame(&e, pgame);
    putClient(&e, pclient);
    e.end();
}

fn onDamage(attacker: usize, victim: usize, pdamage: usize) callconv(.c) void {
    var e = ev("damage");
    putName(&e, "atk", attacker);
    putName(&e, "vic", victim);
    if (pdamage != 0) {
        e.int("dmg", @as(i32, @bitCast(readU32(pdamage, 76)))); // dwDmgTotal
        e.int("phys", @as(i32, @bitCast(readU32(pdamage, 8)))); // dwPhysDamage
    }
    putPos(&e, victim);
    e.end();
}

fn onDeath(victim: usize, killer: usize, _: usize) callconv(.c) void {
    var e = ev("death");
    putName(&e, "vic", victim);
    putName(&e, "killer", killer);
    putPos(&e, victim);
    e.end();
}

fn onItemDrop(pplayer: usize, item_guid: usize, _: usize) callconv(.c) void {
    var e = ev("item_drop");
    putPlayerName(&e, pplayer);
    e.hex("itemGUID", item_guid);
    e.end();
}

fn onItemSpawn(pctx: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("item_spawn");
    if (pctx != 0) {
        const g: *t.ItemGenerationData = @ptrFromInt(pctx);
        e.int("class", g.nItemClassId);
        // Items.txt record: szCode (3-char item code, e.g. "hp1") @ 0x80.
        if (fns.GetItemText.call(@bitCast(g.nItemClassId))) |it| {
            e.str("code", ascii(@intFromPtr(it) + 0x80, 4));
        }
        e.int("quality", @intFromEnum(g.eQuality));
        e.int("ilvl", g.nItemLevel);
        e.int("x", g.nPosX);
        e.int("y", g.nPosY);
    }
    e.end();
}

fn onCmdDrop(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("cmd_drop");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

fn onCmdPickup(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("cmd_pickup");
    putPlayerName(&e, pplayer);
    e.end();
}

fn onSkillCast(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("skill_cast");
    putPlayerName(&e, pplayer);
    e.int("skill", rightSkillId(pplayer));
    if (pkt != 0) {
        e.int("tx", readU16(pkt, 1)); // packet 0x0C: X u16 @+1
        e.int("ty", readU16(pkt, 3)); // Y u16 @+3
    }
    e.end();
}

fn onWaypoint(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("waypoint");
    putPlayerName(&e, pplayer);
    if (pkt != 0) e.int("dest", readU16(pkt, 5)); // packet 0x49: dest wp id u16 @+5
    putPos(&e, pplayer);
    e.end();
}

fn onChat(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("chat");
    putPlayerName(&e, pplayer);
    if (pkt != 0) e.str("msg", ascii(pkt + 3, 256)); // packet 0x14: ASCII NUL-term msg @+3
    e.end();
}

fn onSpawnMonster(class_id: usize, x: usize, y: usize) callconv(.c) void {
    var e = ev("monster_spawn");
    e.int("class", trunc32(class_id));
    // MonStats record: NameStr key u16 @+6 → localized name; Code char[4] @+0x10.
    if (fns.TxtMonStatsGetLine.call(.{s32(class_id)})) |rec| {
        const base = @intFromPtr(rec);
        e.wstr("name", fns.GetLocaleString.call(.{readU16(base, 6)}));
        e.str("code", ascii(base + 0x10, 4));
    }
    e.int("x", s32(x));
    e.int("y", s32(y));
    e.end();
}

fn onSpawnPortal(dest_level: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("portal_spawn");
    e.int("destLevel", s32(dest_level));
    e.end();
}

// -- NPC vendor / store path (debugging the blank trade window) --

fn onNpcInteract(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("npc_interact");
    putPlayerName(&e, pplayer);
    if (pkt != 0) e.int("npcGUID", readU32(pkt, 5)); // 0x2F: [op][unk:u32][npcGUID:u32]
    e.end();
}

fn onNpcMenu(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("npc_menu");
    putPlayerName(&e, pplayer);
    if (pkt != 0) {
        e.int("npcGUID", readU32(pkt, 1)); // 0x38: [op][npcGUID:u32][menuId:u32][params:4B]
        e.int("menuId", readU32(pkt, 5));
    }
    e.end();
}

/// Per vendor item the engine rolls for an NPC store. If this NEVER fires while a
/// trade window is open, generation was gated out → that's the blank window.
fn onNpcGenItem(pnpc: usize, code: usize, is_vendor: usize) callconv(.c) void {
    var e = ev("npc_genitem");
    putName(&e, "npc", pnpc); // NPC is a monster → MonStats name
    if (unit(pnpc)) |u| e.int("npcClass", u.dwTxtFileNo);
    putCode4(&e, "code", trunc32(code)); // EDX = packed 4-char item code
    e.int("vendor", s32(is_vendor));
    e.end();
}

// -- expanded discrete events --

fn onWarp(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("warp");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

fn onQuestState(quest: usize, state: usize, _: usize) callconv(.c) void {
    var e = ev("quest_state");
    e.int("quest", trunc32(quest));
    e.int("state", s32(state));
    e.end();
}

fn onGoldChange(pplayer: usize, stat: usize, delta: usize) callconv(.c) void {
    var e = ev("gold_change");
    putPlayerName(&e, pplayer);
    e.int("stat", trunc32(stat)); // 0xD = gold, 0xE = stash gold
    e.int("delta", s32(delta));
    e.end();
}

fn onTownPortal(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("town_portal");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

fn onCube(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("cube_transmute");
    putPlayerName(&e, pplayer);
    e.end();
}

fn onHostility(pplayer: usize, ptarget: usize, flag: usize) callconv(.c) void {
    var e = ev("hostility");
    putPlayerName(&e, pplayer);
    putName(&e, "target", ptarget);
    e.int("hostile", s32(flag));
    e.end();
}

fn onPartyInvite(pinviter: usize, ptarget: usize, _: usize) callconv(.c) void {
    var e = ev("party_invite");
    putPlayerName(&e, pinviter);
    putName(&e, "target", ptarget);
    e.end();
}

// -- decoded player actions (C->S SCMD handlers; ECX=pGame EDX=player, [esp+4]=pkt) --

fn onSkillLeft(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("skill_left");
    putPlayerName(&e, pplayer);
    e.int("skill", leftSkillId(pplayer));
    e.end();
}

fn onSkillRightEntity(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("skill_right");
    putPlayerName(&e, pplayer);
    e.int("skill", rightSkillId(pplayer));
    e.end();
}

/// 0x13 InteractWithEntity — open chest / click shrine / pull lever / pick up gold.
/// Packet: [op][unitType:u32 @+1][GUID:u32 @+5].
fn onInteract(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("interact");
    putPlayerName(&e, pplayer);
    if (pkt != 0) {
        e.int("unitType", readU32(pkt, 1));
        e.int("target", readU32(pkt, 5));
    }
    e.end();
}

/// 0x18 ItemToInventory — move item to inv/stash/trade.
/// Packet: [op][itemGUID:u32 @+1][x:u32][y:u32][bufferId:u32 @+13] (0=inv 4=stash 2/3=trade).
fn onItemMove(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = ev("item_move");
    putPlayerName(&e, pplayer);
    if (pkt != 0) {
        e.hex("itemGUID", readU32(pkt, 1));
        e.int("buffer", readU32(pkt, 13));
    }
    e.end();
}

fn onItemEquip(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("item_equip");
    putPlayerName(&e, pplayer);
    e.end();
}

fn onItemUse(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = ev("item_use");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

// ── DRLG oracle ──────────────────────────────────────────────────────────────
// Hooked at DRLG_ApplyRoomExStateFlags(D2DrlgLevelStrc* pLevel) @0x642390, which
// InitLevel @0x6424A0 calls in EVERY generation path (maze/preset/wilderness) AFTER
// the per-type generator has linked the rooms. (We do NOT hook InitLevel's entry:
// there pLevel->pRoomExFirst is still null because InitLevel BUILDS the rooms, so a
// v1 entry hook always saw roomCount 0.) pLevel arrives in EDX (fastcall-style; a1 =
// .edx). We dump the full room layout as a single JSON line so a separate Zig DRLG
// reimplementation can be verified offset-for-offset against the real 1.14d engine.
//
// At this hook the level's own sSeed has ALREADY been consumed by generation, so we
// do NOT read pLevel->sSeed. Instead we recompute the INITIAL level seed exactly as
// InitLevel did: pLevel->pDrlg->dwStartSeed + pLevel->eD2LevelId.
//
// D2DrlgLevelStrc: +0x00 eDrlgType(i32), +0x08 nRoomExCount(i32), +0x10 pRoomExFirst,
//   +0x1C sCoordsAndSize (POINT WorldPos@+0x1C, POINT WorldSize@+0x24),
//   +0x1B4 pDrlg(D2DrlgStrc*), +0x1D0 eD2LevelId(i32).
// D2DrlgStrc: +0x470 dwStartSeed(u32).
// D2RoomExStrc: +0x14 sSeed.nSeedLow, +0x24 pRoomExNext, +0x34 sCoords (WorldPos@+0x34,
//   WorldSize@+0x3C).

/// 1.14d GameSeed static global (D2Game::Game::Server). RollSeed @0x52C280 uses it as
/// a forced game seed when != -1; default is -1 (random). Pin it via D2GS_DRLG_SEED
/// for reproducible dumps. Writer of record: GAME_SetForcedGameSeed @0x52C320.
const GAME_SEED_GLOBAL: usize = 0x00731004;

/// Room walk cap — bounds the linked-list traversal against a corrupt pointer.
const DRLG_ROOM_CAP: usize = 4096;

fn onDrlgLevel(pLevel: usize, _: usize, _: usize) callconv(.c) void {
    if (pLevel == 0) return;
    const levelId = @as(i32, @bitCast(readU32(pLevel, 0x1D0)));
    // sSeed is consumed by generation at this point — recompute the INITIAL level
    // seed = pDrlg->dwStartSeed + eD2LevelId (what InitLevel originally stored).
    const pDrlg: usize = readU32(pLevel, 0x1B4);
    const seed: u32 = if (pDrlg != 0) readU32(pDrlg, 0x470) +% @as(u32, @bitCast(levelId)) else 0;
    // Big line buffer: a full level (all rooms) on one JSON line for the oracle.
    var e = evlog.EventN(65536).begin("drlg_level");
    e.int("levelId", levelId);
    e.int("drlgType", @as(i32, @bitCast(readU32(pLevel, 0x00))));
    e.int("seed", seed);
    e.int("roomCount", @as(i32, @bitCast(readU32(pLevel, 0x08))));
    // Level coords {x,y,w,h} (POINT WorldPosition @+0x1C, POINT WorldSize @+0x24).
    e.objField("coords");
    e.intFirst("x", @as(i32, @bitCast(readU32(pLevel, 0x1C))));
    e.int("y", @as(i32, @bitCast(readU32(pLevel, 0x20))));
    e.int("w", @as(i32, @bitCast(readU32(pLevel, 0x24))));
    e.int("h", @as(i32, @bitCast(readU32(pLevel, 0x28))));
    e.objClose();
    // Rooms: walk pRoomExFirst -> pRoomExNext, emit {x,y,w,h,seed} per room.
    e.arrayField("rooms");
    var room: usize = readU32(pLevel, 0x10); // pRoomExFirst
    var i: usize = 0;
    while (room != 0 and i < DRLG_ROOM_CAP and !e.full) : (i += 1) {
        if (i != 0) e.comma();
        e.objOpen();
        e.intFirst("x", @as(i32, @bitCast(readU32(room, 0x34))));
        e.int("y", @as(i32, @bitCast(readU32(room, 0x38))));
        e.int("w", @as(i32, @bitCast(readU32(room, 0x3C))));
        e.int("h", @as(i32, @bitCast(readU32(room, 0x40))));
        e.int("seed", readU32(room, 0x14)); // sSeed.nSeedLow
        e.objClose();
        room = readU32(room, 0x24); // pRoomExNext
    }
    e.arrayEnd();
    e.end();
}

/// Pin the engine's game seed to D2GS_DRLG_SEED (decimal u32) for reproducible DRLG
/// dumps. No-op when unset → normal random seeding is untouched.
fn pinDrlgSeed() void {
    var buf: [16]u8 = undefined;
    const n = GetEnvironmentVariableA("D2GS_DRLG_SEED", &buf, buf.len);
    if (n == 0 or n >= buf.len) return;
    const seed = std.fmt.parseInt(u32, buf[0..n], 10) catch return;
    @as(*volatile u32, @ptrFromInt(GAME_SEED_GLOBAL)).* = seed;
    log.hex("srvtrace: DRLG game seed pinned to 0x", seed);
}

// ── hook framework ───────────────────────────────────────────────────────────

/// Where a captured value comes from at function entry. `.stack` is the original
/// [esp+k] BEFORE the shim pushed anything (we correct for pushal/pushfl + our own
/// pushes). `.deref_*` captures the byte at [reg].
const Src = union(enum) {
    none,
    ecx,
    edx,
    esi,
    edi,
    ebx,
    deref_ecx,
    deref_edx,
    stack: usize,
};

fn pushAsm(comptime s: Src, comptime pushed: usize) []const u8 {
    return switch (s) {
        .none => "pushl $0\n",
        .ecx => "push %ecx\n",
        .edx => "push %edx\n",
        .esi => "push %esi\n",
        .edi => "push %edi\n",
        .ebx => "push %ebx\n",
        .deref_ecx => "movzbl (%ecx), %eax\npush %eax\n",
        .deref_edx => "movzbl (%edx), %eax\npush %eax\n",
        .stack => |k| std.fmt.comptimePrint("pushl {d}(%esp)\n", .{36 + pushed + k}),
    };
}

const Handler = *const fn (usize, usize, usize) callconv(.c) void;

/// One trace point: where to hook, how many prologue bytes are relocatable (>=5,
/// must end on an instruction boundary), the decoder, and what a1/a2/a3 capture.
const Hook = struct {
    addr: usize,
    prologue: usize,
    label: []const u8,
    handler: Handler,
    a1: Src = .none,
    a2: Src = .none,
    a3: Src = .none,
    /// Where the game pointer is at entry (usually .ecx). Captured into cur_game
    /// before the handler runs so ev() can stamp the game token. .none = no game.
    game: Src = .none,
    /// Byte offsets within the prologue of any rel8 short branch (Jcc 0x70-0x7F /
    /// JMP 0xEB) the trampoline must expand to rel32. Verified by hand alongside
    /// the prologue length; empty for prologues with no short branches.
    rel8: []const usize = &.{},
};

fn TraceHook(comptime h: Hook) type {
    return struct {
        var tramp: usize = 0;

        fn shim() callconv(.naked) void {
            asm volatile ("pushal\npushfl\n" ++
                    // Push the handler args FIRST, while ECX/EDX still hold the entry
                    // values (right-to-left: a3 @0 pushed, a2 @4, a1 @8).
                    pushAsm(h.a3, 0) ++ pushAsm(h.a2, 4) ++ pushAsm(h.a1, 8) ++
                    // THEN capture the game pointer into cur_game. The call may clobber
                    // ECX/EDX (caller-saved), but the args are already on the stack, so
                    // that's fine; popal restores them for the engine. game push accounts
                    // for the 12 bytes of args already pushed.
                    pushAsm(h.game, 12) ++ "call %[sg:P]\nadd $4, %%esp\n" ++
                    "call %[f:P]\n" ++
                    "add $12, %%esp\n" ++
                    "popfl\npopal\n" ++
                    "mov %[tramp], %%eax\n" ++
                    "jmp *(%%eax)\n"
                :
                : [sg] "X" (&setCurGame),
                  [f] "X" (h.handler),
                  [tramp] "X" (&tramp),
            );
        }

        /// Returns true if the hook installed. Logs only on FAILURE — success is
        /// rolled into a single summary line by install() to keep the log quiet.
        fn install() bool {
            const tr = trampoline.build(h.addr, h.prologue, h.rel8) orelse {
                log.print("srvtrace: trampoline FAILED — " ++ h.label);
                return false;
            };
            tramp = @intFromPtr(tr.buffer);
            if (patch.MemoryPatch(h.addr).jump(@intFromPtr(&shim)).nopTo(h.addr + h.prologue).commit()) {
                return true;
            }
            log.print("srvtrace: patch FAILED — " ++ h.label);
            return false;
        }
    };
}

// ── trace points ─────────────────────────────────────────────────────────────
// 1.14d retail addresses (base 0x400000); `prologue` = verified relocatable bytes.
// Keep to DISCRETE actions — never per-frame/per-unit AI ticks.
const hooks = [_]Hook{
    // -- game lifecycle --
    .{ .addr = 0x451000, .prologue = 6, .label = "game_create", .handler = &onGameCreate, .a1 = .{ .stack = 4 } },
    .{ .addr = 0x52C7F0, .prologue = 7, .label = "game_destroy", .handler = &onGameDestroy, .a1 = .ecx, .a2 = .edx },
    .{ .addr = 0x52C410, .prologue = 6, .label = "player_join", .handler = &onPlayerJoin, .game = .ecx, .a1 = .ecx, .a2 = .edx },
    .{ .addr = 0x52C500, .prologue = 5, .label = "player_leave", .handler = &onPlayerLeave, .game = .ecx, .a1 = .ecx, .a2 = .edx },

    // -- combat --
    .{ .addr = 0x57C6C0, .prologue = 6, .label = "damage", .handler = &onDamage, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 }, .a3 = .{ .stack = 0xC } },
    .{ .addr = 0x535AB0, .prologue = 6, .label = "death", .handler = &onDeath, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },

    // -- items --
    .{ .addr = 0x563C00, .prologue = 6, .label = "item_drop", .handler = &onItemDrop, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x558D90, .prologue = 6, .label = "item_spawn", .handler = &onItemSpawn, .game = .ecx, .a1 = .edx },

    // -- client command handlers (acting player = EDX=pUnit) --
    .{ .addr = 0x54AB40, .prologue = 7, .label = "cmd_drop", .handler = &onCmdDrop, .game = .ecx, .a1 = .edx },
    .{ .addr = 0x54ACD0, .prologue = 7, .label = "cmd_pickup", .handler = &onCmdPickup, .game = .ecx, .a1 = .edx },
    .{ .addr = 0x549FC0, .prologue = 5, .label = "skill_cast", .handler = &onSkillCast, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x54C5D0, .prologue = 7, .label = "waypoint", .handler = &onWaypoint, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x54A290, .prologue = 9, .label = "chat", .handler = &onChat, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },

    // -- monster / portal spawn --
    .{ .addr = 0x5A4440, .prologue = 7, .label = "monster_spawn", .handler = &onSpawnMonster, .game = .ecx, .a1 = .{ .stack = 12 }, .a2 = .{ .stack = 4 }, .a3 = .{ .stack = 8 } },
    .{ .addr = 0x56D130, .prologue = 6, .label = "portal_spawn", .handler = &onSpawnPortal, .game = .ecx, .a1 = .{ .stack = 16 } },

    // -- NPC vendor / store path (ECX=pGame EDX=player, [esp+4]=pkt; genitem: ECX=pNpc EDX=code) --
    .{ .addr = 0x54B930, .prologue = 11, .label = "npc_interact", .handler = &onNpcInteract, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x54BCA0, .prologue = 11, .label = "npc_menu", .handler = &onNpcMenu, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x576330, .prologue = 12, .label = "npc_genitem", .handler = &onNpcGenItem, .game = .{ .stack = 4 }, .a1 = .ecx, .a2 = .edx, .a3 = .{ .stack = 8 } },

    // -- expanded discrete events --
    .{ .addr = 0x5550B0, .prologue = 8, .label = "warp", .handler = &onWarp, .game = .ecx, .a1 = .edx }, // TakeStairs: ECX=pGame EDX=pUnit
    .{ .addr = 0x544720, .prologue = 9, .label = "quest_state", .handler = &onQuestState, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } }, // ECX=pGame EDX=eQuest, [esp+4]=eState
    .{ .addr = 0x53FF00, .prologue = 5, .label = "gold_change", .handler = &onGoldChange, .a1 = .ecx, .a2 = .edx, .a3 = .{ .stack = 4 } }, // ECX=pUnit EDX=stat, [esp+4]=delta
    .{ .addr = 0x5BE290, .prologue = 8, .label = "town_portal", .handler = &onTownPortal, .game = .ecx, .a1 = .edx }, // ECX=pGame EDX=caster
    .{ .addr = 0x54C300, .prologue = 7, .label = "cube_transmute", .handler = &onCube, .game = .ecx, .a1 = .edx }, // ECX=pGame EDX=pPlayer
    .{ .addr = 0x5A5E50, .prologue = 6, .label = "hostility", .handler = &onHostility, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 }, .a3 = .{ .stack = 8 } }, // ECX=pGame EDX=pUnit, [esp+4]=pTarget, [esp+8]=bHostile
    .{ .addr = 0x5A5BE0, .prologue = 5, .label = "party_invite", .handler = &onPartyInvite, .a1 = .edx, .a2 = .{ .stack = 4 } }, // EDX=inviter, [esp+4]=pTarget

    // -- decoded player actions (SCMD handlers; ECX=pGame EDX=player, [esp+4]=pkt) --
    .{ .addr = 0x549D80, .prologue = 5, .label = "skill_left", .handler = &onSkillLeft, .game = .ecx, .a1 = .edx }, // 0x06 LeftSkillOnEntity
    .{ .addr = 0x54A040, .prologue = 5, .label = "skill_right", .handler = &onSkillRightEntity, .game = .ecx, .a1 = .edx }, // 0x0D RightSkillOnEntity
    .{ .addr = 0x54AA90, .prologue = 7, .label = "interact", .handler = &onInteract, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } }, // 0x13 InteractWithEntity
    .{ .addr = 0x54ABB0, .prologue = 8, .label = "item_move", .handler = &onItemMove, .game = .ecx, .a1 = .edx, .a2 = .{ .stack = 4 } }, // 0x18 ItemToInventory
    .{ .addr = 0x54AD90, .prologue = 6, .label = "item_equip", .handler = &onItemEquip, .game = .ecx, .a1 = .edx }, // 0x1A EquipItem
    .{ .addr = 0x54B1E0, .prologue = 6, .label = "item_use", .handler = &onItemUse, .game = .ecx, .a1 = .edx }, // 0x20 UseItemAtLocation
    .{ .addr = 0x54B560, .prologue = 6, .label = "item_use", .handler = &onItemUse, .game = .ecx, .a1 = .edx }, // 0x26 UseItemAtPlayerCoords

    // -- DRLG oracle: DRLG_ApplyRoomExStateFlags(pLevel) — called by InitLevel in
    // every path AFTER rooms are linked; pLevel in EDX. Prologue = CMP [EDX+8],0 (4)
    // + JZ rel8 (2) = 6; the JZ at +4 is relocated by the trampoline (.rel8 = {4}). --
    .{ .addr = 0x642390, .prologue = 6, .label = "drlg_level", .handler = &onDrlgLevel, .a1 = .edx, .rel8 = &.{4} },
};

pub fn install() void {
    pinDrlgSeed();
    var ok: usize = 0;
    inline for (hooks) |h| {
        if (TraceHook(h).install()) ok += 1;
    }
    log.hex2("srvtrace: event hooks installed", ok, hooks.len);
}
