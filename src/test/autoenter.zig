//! Auto-enter test: drive the real client through the menus into a single-player
//! game with an existing character and verify it loads (playerUnit becomes
//! non-null). Ported from aether's auto_enter. This is the baseline for the goal
//! ("enter the game with a char and it loads"); the same SelectedChar entry point
//! does Bnet/TCP-IP too, so multiplayer extends from here.

const std = @import("std");
const async_ = @import("../runtime/async.zig");
const gameloop = @import("../runtime/gameloop.zig");
const fastcall = @import("../runtime/fastcall.zig");
const log = @import("../log.zig");

// ── game addresses / globals (retail 1.14d) ─────────────────────────────────
const OogCurrentCharSelectionMode: *u32 = @ptrFromInt(0x007795ec);
const D2CharSelStrcFirst: *?*const D2CharSelStrc = @ptrFromInt(0x00779dbc);
const TotalCurrentChars: *u32 = @ptrFromInt(0x00779dc4);
const playerUnit: *?*anyopaque = @ptrFromInt(0x007a6a70);

const showMainMenu: *const fn () callconv(.winapi) void = @ptrFromInt(0x004336c0);
const closeAndLaunchCharSelect: *const fn () callconv(.winapi) void = @ptrFromInt(0x0042fdd0);

// SelectedCharBnetSingleTcpIp @0x434a00 — __fastcall(charsel*, flags, class, realm)
const SelectedChar = fastcall.fastcall_call(0x00434a00, fn (*const D2CharSelStrc, u16, u32, [*:0]const u8) u32);

const D2CharSelStrc = extern struct {
    szCharname: [256]u8,
    szCommandStringTable: [512]u8,
    abEquipSlot1: [16]u8,
    abEquipSlot2: [16]u8,
    ePlayerClassID: u8,
    _pad801: u8,
    nLevel: u16,
    nCharacterFlags: u16,
    _pad806: [14]u8,
    nEntryType: u32,
    pCharSelCompStrc: ?*anyopaque,
    _pad828: [4]u8,
    ftLastWriteTimeLow: u32,
    ftLastWriteTimeHigh: u32,
    _pad840: [4]u8,
    pNext: ?*const D2CharSelStrc,
};

comptime {
    if (@offsetOf(D2CharSelStrc, "ePlayerClassID") != 800) @compileError("ePlayerClassID off");
    if (@offsetOf(D2CharSelStrc, "nCharacterFlags") != 804) @compileError("nCharacterFlags off");
    if (@offsetOf(D2CharSelStrc, "pNext") != 844) @compileError("pNext off");
}

fn task() void {
    log.print("test: auto-enter starting");
    async_.waitFrames(10);
    showMainMenu();
    async_.waitFrames(10);

    OogCurrentCharSelectionMode.* = 0; // single-player mode
    closeAndLaunchCharSelect(); // opens char select, enumerates saves

    var wait: u32 = 0;
    while (TotalCurrentChars.* == 0 and wait < 300) : (wait += 1) async_.yield();
    log.hex("test: chars found=0x", TotalCurrentChars.*);
    if (TotalCurrentChars.* == 0) {
        log.print("test: NO CHARACTERS (need a save to enter with)");
        return;
    }

    const ch = D2CharSelStrcFirst.* orelse {
        log.print("test: char list null");
        return;
    };
    log.print("test: entering game with first character");
    _ = SelectedChar.call(.{ ch, ch.nCharacterFlags, @as(u32, ch.ePlayerClassID), "" });

    // Wait to actually be in-game (player unit loaded).
    var w2: u32 = 0;
    while (playerUnit.* == null and w2 < 600) : (w2 += 1) async_.yield();
    if (playerUnit.* != null) {
        log.print("test: PASS — entered game, player unit loaded");
    } else {
        log.print("test: FAIL — never entered game");
    }
}

var started: bool = false;

fn frame() void {
    if (!started) {
        started = true;
        async_.spawn(&task);
    }
    _ = async_.tick();
}

/// Install the auto-enter test: hook the loops and drive the menus on the game thread.
pub fn install() void {
    gameloop.on_oog = &frame;
    gameloop.on_game = &frame; // keep ticking the task once in-game (for verification)
    gameloop.install();
    log.print("test: auto-enter installed");
}
