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

/// Put an acting player's char name as "player" (the unit is known to be a player).
fn putPlayerName(e: *evlog.Event, v: usize) void {
    putName(e, "player", v);
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

// ── per-event handlers ───────────────────────────────────────────────────────
// Signature is always fn(a1, a2, a3) callconv(.c); each interprets the captured
// args (see the hooks table for what a1/a2/a3 hold for that hook).

fn onGameCreate(token_map: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("game_create");
    e.hex("tokenMap", token_map);
    e.end();
}

fn onGameDestroy(token: usize, pgame: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("game_destroy");
    e.int("token", trunc32(token));
    putGame(&e, pgame);
    e.end();
}

fn onPlayerJoin(pgame: usize, pclient: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("player_join");
    putGame(&e, pgame);
    putClient(&e, pclient);
    e.end();
}

fn onPlayerLeave(pgame: usize, pclient: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("player_leave");
    putGame(&e, pgame);
    putClient(&e, pclient);
    e.end();
}

fn onDamage(attacker: usize, victim: usize, pdamage: usize) callconv(.c) void {
    var e = evlog.Event.begin("damage");
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
    var e = evlog.Event.begin("death");
    putName(&e, "vic", victim);
    putName(&e, "killer", killer);
    putPos(&e, victim);
    e.end();
}

fn onItemDrop(pplayer: usize, item_guid: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("item_drop");
    putPlayerName(&e, pplayer);
    e.hex("itemGUID", item_guid);
    e.end();
}

fn onItemSpawn(pctx: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("item_spawn");
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
    var e = evlog.Event.begin("cmd_drop");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

fn onCmdPickup(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("cmd_pickup");
    putPlayerName(&e, pplayer);
    e.end();
}

fn onSkillCast(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("skill_cast");
    putPlayerName(&e, pplayer);
    e.int("skill", rightSkillId(pplayer));
    if (pkt != 0) {
        e.int("tx", readU16(pkt, 1)); // packet 0x0C: X u16 @+1
        e.int("ty", readU16(pkt, 3)); // Y u16 @+3
    }
    e.end();
}

fn onWaypoint(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("waypoint");
    putPlayerName(&e, pplayer);
    if (pkt != 0) e.int("dest", readU16(pkt, 5)); // packet 0x49: dest wp id u16 @+5
    putPos(&e, pplayer);
    e.end();
}

fn onChat(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("chat");
    putPlayerName(&e, pplayer);
    if (pkt != 0) e.str("msg", ascii(pkt + 3, 256)); // packet 0x14: ASCII NUL-term msg @+3
    e.end();
}

fn onSpawnMonster(class_id: usize, x: usize, y: usize) callconv(.c) void {
    var e = evlog.Event.begin("monster_spawn");
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
    var e = evlog.Event.begin("portal_spawn");
    e.int("destLevel", s32(dest_level));
    e.end();
}

// -- NPC vendor / store path (debugging the blank trade window) --

fn onNpcInteract(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("npc_interact");
    putPlayerName(&e, pplayer);
    if (pkt != 0) e.int("npcGUID", readU32(pkt, 5)); // 0x2F: [op][unk:u32][npcGUID:u32]
    e.end();
}

fn onNpcMenu(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("npc_menu");
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
    var e = evlog.Event.begin("npc_genitem");
    putName(&e, "npc", pnpc); // NPC is a monster → MonStats name
    if (unit(pnpc)) |u| e.int("npcClass", u.dwTxtFileNo);
    putCode4(&e, "code", trunc32(code)); // EDX = packed 4-char item code
    e.int("vendor", s32(is_vendor));
    e.end();
}

// -- expanded discrete events --

fn onWarp(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("warp");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

fn onQuestState(quest: usize, state: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("quest_state");
    e.int("quest", trunc32(quest));
    e.int("state", s32(state));
    e.end();
}

fn onGoldChange(pplayer: usize, stat: usize, delta: usize) callconv(.c) void {
    var e = evlog.Event.begin("gold_change");
    putPlayerName(&e, pplayer);
    e.int("stat", trunc32(stat)); // 0xD = gold, 0xE = stash gold
    e.int("delta", s32(delta));
    e.end();
}

fn onTownPortal(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("town_portal");
    putPlayerName(&e, pplayer);
    putPos(&e, pplayer);
    e.end();
}

fn onCube(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("cube_transmute");
    putPlayerName(&e, pplayer);
    e.end();
}

fn onHostility(pplayer: usize, ptarget: usize, flag: usize) callconv(.c) void {
    var e = evlog.Event.begin("hostility");
    putPlayerName(&e, pplayer);
    putName(&e, "target", ptarget);
    e.int("hostile", s32(flag));
    e.end();
}

fn onPartyInvite(pinviter: usize, ptarget: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("party_invite");
    putPlayerName(&e, pinviter);
    putName(&e, "target", ptarget);
    e.end();
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
};

fn TraceHook(comptime h: Hook) type {
    return struct {
        var tramp: usize = 0;

        fn shim() callconv(.naked) void {
            asm volatile ("pushal\npushfl\n" ++
                    // args pushed right-to-left: a3 (0 pushed), a2 (4), a1 (8).
                    pushAsm(h.a3, 0) ++ pushAsm(h.a2, 4) ++ pushAsm(h.a1, 8) ++
                    "call %[f:P]\n" ++
                    "add $12, %%esp\n" ++
                    "popfl\npopal\n" ++
                    "mov %[tramp], %%eax\n" ++
                    "jmp *(%%eax)\n"
                :
                : [f] "X" (h.handler),
                  [tramp] "X" (&tramp),
            );
        }

        fn install() void {
            const tr = trampoline.build(h.addr, h.prologue) orelse {
                log.print("srvtrace: trampoline FAILED — " ++ h.label);
                return;
            };
            tramp = @intFromPtr(tr.buffer);
            if (patch.MemoryPatch(h.addr).jump(@intFromPtr(&shim)).nopTo(h.addr + h.prologue).commit()) {
                log.print("srvtrace: hooked " ++ h.label);
            } else {
                log.print("srvtrace: patch FAILED — " ++ h.label);
            }
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
    .{ .addr = 0x52C410, .prologue = 6, .label = "player_join", .handler = &onPlayerJoin, .a1 = .ecx, .a2 = .edx },
    .{ .addr = 0x52C500, .prologue = 5, .label = "player_leave", .handler = &onPlayerLeave, .a1 = .ecx, .a2 = .edx },

    // -- combat --
    .{ .addr = 0x57C6C0, .prologue = 6, .label = "damage", .handler = &onDamage, .a1 = .edx, .a2 = .{ .stack = 4 }, .a3 = .{ .stack = 0xC } },
    .{ .addr = 0x535AB0, .prologue = 6, .label = "death", .handler = &onDeath, .a1 = .edx, .a2 = .{ .stack = 4 } },

    // -- items --
    .{ .addr = 0x563C00, .prologue = 6, .label = "item_drop", .handler = &onItemDrop, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x558D90, .prologue = 6, .label = "item_spawn", .handler = &onItemSpawn, .a1 = .edx },

    // -- client command handlers (acting player = EDX=pUnit) --
    .{ .addr = 0x54AB40, .prologue = 7, .label = "cmd_drop", .handler = &onCmdDrop, .a1 = .edx },
    .{ .addr = 0x54ACD0, .prologue = 7, .label = "cmd_pickup", .handler = &onCmdPickup, .a1 = .edx },
    .{ .addr = 0x549FC0, .prologue = 5, .label = "skill_cast", .handler = &onSkillCast, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x54C5D0, .prologue = 7, .label = "waypoint", .handler = &onWaypoint, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x54A290, .prologue = 9, .label = "chat", .handler = &onChat, .a1 = .edx, .a2 = .{ .stack = 4 } },

    // -- monster / portal spawn --
    .{ .addr = 0x5A4440, .prologue = 7, .label = "monster_spawn", .handler = &onSpawnMonster, .a1 = .{ .stack = 12 }, .a2 = .{ .stack = 4 }, .a3 = .{ .stack = 8 } },
    .{ .addr = 0x56D130, .prologue = 6, .label = "portal_spawn", .handler = &onSpawnPortal, .a1 = .{ .stack = 16 } },

    // -- NPC vendor / store path (ECX=pGame EDX=player, [esp+4]=pkt; genitem: ECX=pNpc EDX=code) --
    .{ .addr = 0x54B930, .prologue = 11, .label = "npc_interact", .handler = &onNpcInteract, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x54BCA0, .prologue = 11, .label = "npc_menu", .handler = &onNpcMenu, .a1 = .edx, .a2 = .{ .stack = 4 } },
    .{ .addr = 0x576330, .prologue = 12, .label = "npc_genitem", .handler = &onNpcGenItem, .a1 = .ecx, .a2 = .edx, .a3 = .{ .stack = 8 } },

    // -- expanded discrete events --
    .{ .addr = 0x5550B0, .prologue = 8, .label = "warp", .handler = &onWarp, .a1 = .edx }, // TakeStairs: ECX=pGame EDX=pUnit
    .{ .addr = 0x544720, .prologue = 9, .label = "quest_state", .handler = &onQuestState, .a1 = .edx, .a2 = .{ .stack = 4 } }, // ECX=pGame EDX=eQuest, [esp+4]=eState
    .{ .addr = 0x53FF00, .prologue = 5, .label = "gold_change", .handler = &onGoldChange, .a1 = .ecx, .a2 = .edx, .a3 = .{ .stack = 4 } }, // ECX=pUnit EDX=stat, [esp+4]=delta
    .{ .addr = 0x5BE290, .prologue = 8, .label = "town_portal", .handler = &onTownPortal, .a1 = .edx }, // ECX=pGame EDX=caster
    .{ .addr = 0x54C300, .prologue = 7, .label = "cube_transmute", .handler = &onCube, .a1 = .edx }, // ECX=pGame EDX=pPlayer
    .{ .addr = 0x5A5E50, .prologue = 6, .label = "hostility", .handler = &onHostility, .a1 = .edx, .a2 = .{ .stack = 4 }, .a3 = .{ .stack = 8 } }, // ECX=pGame EDX=pUnit, [esp+4]=pTarget, [esp+8]=bHostile
    .{ .addr = 0x5A5BE0, .prologue = 5, .label = "party_invite", .handler = &onPartyInvite, .a1 = .edx, .a2 = .{ .stack = 4 } }, // EDX=inviter, [esp+4]=pTarget
};

pub fn install() void {
    log.print("srvtrace: installing server event hooks");
    inline for (hooks) |h| {
        TraceHook(h).install();
    }
}
