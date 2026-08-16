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
const srvtrace = @import("../runtime/feature/srvtrace.zig");

// game addresses / globals (retail 1.14d)
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
    closeAndLaunchCharSelect(); // queues char-select app-mode

    // The char-select app-mode resets the count then parses saves over the next
    // frames. Let it run, then read a settled count + the first char.
    async_.waitFrames(80);
    log.hex("test: chars found=0x", TotalCurrentChars.*);

    const ch = D2CharSelStrcFirst.* orelse {
        log.print("test: char list null (no saves found in Save\\)");
        return;
    };
    const cname = std.mem.sliceTo(&ch.szCharname, 0);
    log.print("test: first char:");
    log.print(cname);
    log.print("test: entering game with first character");
    // Sets nScreenToShow=1, gnSelectedCharGameState=1, nGAMETYPE=SINGLEPLAYER and
    // clears the message-loop flag so the app-mode loop advances to game-load.
    // The task ENDS here (like aether) — we must not keep the fiber alive during
    // the transition; verification happens in the frame callback below.
    _ = SelectedChar.call(.{ ch, ch.nCharacterFlags, @as(u32, ch.ePlayerClassID), "" });
    log.print("test: SelectedChar done, awaiting game load (verifying in frame loop)");
}

var started: bool = false;
var verified: bool = false;
var verify_frames: u32 = 0;

fn frame() void {
    if (!started) {
        started = true;
        async_.spawn(&task);
        return;
    }
    if (async_.isActive()) {
        _ = async_.tick();
        return;
    }
    // Task finished (SelectedChar issued) — let the engine load the game, then verify.
    // Once in-game, drive srvtrace.serverTick each frame so the deferred DRLG
    // seed loop (D2GS_DRLG_SEED_LO/HI) fires — autoenter owns on_game, so without
    // this the multi-seed dump never runs under --test-enter.
    if (verified) {
        srvtrace.serverTick();
        return;
    }
    verify_frames += 1;
    if (playerUnit.* != null) {
        verified = true;
        log.print("test: PASS — entered game, player unit loaded");
    } else if (verify_frames == 100000) {
        // generous: the SP load (world gen + disk) takes real time across many frames
        log.print("test: FAIL — never entered game (SP load didn't complete)");
    }
}

/// Install the auto-enter test: hook the loops and drive the menus on the game thread.
pub fn install() void {
    gameloop.on_oog = &frame;
    gameloop.on_game = &frame; // keep ticking the task once in-game (for verification)
    gameloop.install();
    log.print("test: auto-enter installed");
}
