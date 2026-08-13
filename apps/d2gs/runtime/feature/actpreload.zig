//! Eager-load every act's DRLG at game start so a cross-act warp never races act allocation.
//!
//! On a headless GS (-d2gs-boot) a player can WAYPOINT straight across acts — e.g. kolbot's
//! Mephisto run waypoints from Act 1 (Rogue Encampment) to Durance of Hate (Act 3). The engine
//! activates the destination room and DRLGROOMTILE_SetupWarpTile @0x66e260 walks that room's
//! warp-cache (pRoomEx->pTileGrid), which is built from pLevel->pDrlg->pWarpsInfo. pWarpsInfo
//! only exists once the destination ACT's DRLG is allocated. Game-create allocates acts lazily,
//! and the server warp path can activate the room before its act is loaded -> the cache is empty
//! -> assert `!!pWarpCacheHead` @0x66e2ab and the GS exits ("no GS available" to the client).
//!
//! The real client's CLIENT_WarpToAct @0x53acc0 self-heals (InitDrlgAct before SpawnUnit), but a
//! path under -d2gs-boot reaches room-activation outside that guard. Rather than chase every warp
//! path, we allocate ALL acts up front the moment the game's first room inits (town gen), so any
//! later warp finds pGame->pAct[n] (hence its pWarpsInfo) already populated.
//!
//! InitDrlgAct only ALLOCATES an act's DRLG (AllocAct + per-act quest state) — no unit spawns, no
//! room activation, no live-game mutation — so pre-loading is side-effect-free. This is the exact
//! act force-load srvtrace's DRLG oracle already performs safely mid-town-gen.
const std = @import("std");
const log = @import("../../log.zig");
const feature = @import("../../engine/feature.zig");

/// D2GameStrc offsets (same as srvtrace/cainfix use).
const ACT_ARRAY_OFF: usize = 0xBC; // pAct[5]
const EXPANSION_OFF: usize = 0x70; // bExpansion (0 = classic: acts 0..3 only)

var done_for_game: usize = 0; // pGame we've already preloaded (pointer identity)

fn readU32(base: usize, off: usize) u32 {
    return @as(*const u32, @ptrFromInt(base + off)).*;
}

/// InitDrlgAct(pGame, nActNo) @0x53AC70 — allocate act nActNo for this game (derives the town
/// level id, AllocAct with the game's init seed/difficulty/pool, stores pGame->pAct[nActNo],
/// inits the act's quest state). Custom register ABI verified by disassembly (see srvtrace): pGame
/// in ESI, nActNo in BL, no stack args — NOT the __fastcall Ghidra's decompiler infers. We
/// overwrite ESI/EBX (marked clobbered so Zig saves the caller's); [buf] stays in EDI/EBP.
fn initDrlgAct(pGame: usize, nActNo: u8) void {
    var buf = [3]u32{ @truncate(pGame), nActNo, 0x53AC70 };
    asm volatile (
        \\movl (%[buf]), %%esi
        \\movl 4(%[buf]), %%ebx
        \\call *8(%[buf])
        :
        : [buf] "r" (&buf),
        : .{ .eax = true, .ecx = true, .edx = true, .esi = true, .ebx = true, .memory = true, .cc = true });
}

// roomInit fans out per room as a level is built; the FIRST one for a game is the spawn act's
// town, mid town-gen — the proven-safe point to force-load the other acts. ctx.game is pGame.
pub fn roomInit(ctx: *const feature.GameCtx, room: *anyopaque) void {
    _ = room;
    const pGame = @intFromPtr(ctx.game);
    if (pGame == done_for_game) return; // once per game (pointer identity changes per game)
    done_for_game = pGame;

    // Classic (no expansion) has no act 5 — forcing act 4 would create an act the mode lacks.
    const nActs: u8 = if (readU32(pGame, EXPANSION_OFF) == 0) 4 else 5;
    var loaded: u8 = 0;
    var act: u8 = 0;
    while (act < nActs) : (act += 1) {
        if (readU32(pGame, ACT_ARRAY_OFF + @as(usize, act) * 4) != 0) continue; // already allocated
        initDrlgAct(pGame, act);
        if (readU32(pGame, ACT_ARRAY_OFF + @as(usize, act) * 4) != 0) loaded += 1;
    }
    log.hex2("actpreload: acts pre-loaded (of expansion count)", loaded, nActs);
}

pub fn install() void {
    log.print("actpreload: armed (eager cross-act DRLG load at game start)");
}
