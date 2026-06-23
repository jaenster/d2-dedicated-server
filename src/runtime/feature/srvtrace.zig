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

/// Localized display name for any unit (monster→"Mephisto", player→char name,
/// item→item name). Null-safe; returns null on a null unit.
fn nameOf(v: usize) ?[*:0]const u16 {
    const u = unit(v) orelse return null;
    return fns.GetUnitName.call(.{u});
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
    e.wstr("atk", nameOf(attacker));
    e.wstr("vic", nameOf(victim));
    if (pdamage != 0) {
        e.int("dmg", @as(i32, @bitCast(readU32(pdamage, 76)))); // dwDmgTotal
        e.int("phys", @as(i32, @bitCast(readU32(pdamage, 8)))); // dwPhysDamage
    }
    putPos(&e, victim);
    e.end();
}

fn onDeath(victim: usize, killer: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("death");
    e.wstr("vic", nameOf(victim));
    e.wstr("killer", nameOf(killer));
    putPos(&e, victim);
    e.end();
}

fn onItemDrop(pplayer: usize, item_guid: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("item_drop");
    e.wstr("player", nameOf(pplayer));
    e.hex("itemGUID", item_guid);
    e.end();
}

fn onItemSpawn(pctx: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("item_spawn");
    if (pctx != 0) {
        const g: *t.ItemGenerationData = @ptrFromInt(pctx);
        e.int("class", g.nItemClassId);
        e.int("quality", @intFromEnum(g.eQuality));
        e.int("ilvl", g.nItemLevel);
        e.int("x", g.nPosX);
        e.int("y", g.nPosY);
    }
    e.end();
}

fn onCmdDrop(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("cmd_drop");
    e.wstr("player", nameOf(pplayer));
    putPos(&e, pplayer);
    e.end();
}

fn onCmdPickup(pplayer: usize, _: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("cmd_pickup");
    e.wstr("player", nameOf(pplayer));
    e.end();
}

fn onSkillCast(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("skill_cast");
    e.wstr("player", nameOf(pplayer));
    e.int("skill", rightSkillId(pplayer));
    if (pkt != 0) {
        e.int("tx", readU16(pkt, 1)); // packet 0x0C: X u16 @+1
        e.int("ty", readU16(pkt, 3)); // Y u16 @+3
    }
    e.end();
}

fn onWaypoint(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("waypoint");
    e.wstr("player", nameOf(pplayer));
    if (pkt != 0) e.int("dest", readU16(pkt, 5)); // packet 0x49: dest wp id u16 @+5
    putPos(&e, pplayer);
    e.end();
}

fn onChat(pplayer: usize, pkt: usize, _: usize) callconv(.c) void {
    var e = evlog.Event.begin("chat");
    e.wstr("player", nameOf(pplayer));
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
};

pub fn install() void {
    log.print("srvtrace: installing server event hooks");
    inline for (hooks) |h| {
        TraceHook(h).install();
    }
}
