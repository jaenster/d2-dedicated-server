//! Serialize engine calls onto the tick thread.
//!
//! D2's engine is not safe to call for game create/join from arbitrary threads
//! (the tick loop iterates the same game hashmap). So the D2CS thread enqueues a
//! request and blocks until the single tick thread executes it. One outstanding
//! command at a time is enough — there's a single D2CS connection.

const std = @import("std");
const server = @import("server.zig");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const Kind = enum(u32) { none = 0, create_game = 1 };

/// Gate for the (still-crashing) game-creation path. GAME_CreateBattleNetGame
/// faults because the server-only boot hasn't initialized the game-data
/// prerequisites its RollSeed/Alloc*Control read (see PVPGN.md). Off by default
/// so the server stays stable; `--create-games` flips it on for development.
pub var allow_create: bool = false;

var kind: u32 = 0; // atomic: pending command
var done: u32 = 0; // atomic: result ready

// create-game params / results (only valid while a command is in flight)
var c_name: [36]u8 = undefined;
var c_pass: [20]u8 = undefined;
var c_desc: [36]u8 = undefined;
var c_flags: u32 = 0;
var c_ladder: u32 = 0;
var r_ok: u32 = 0;
var r_gameid: u16 = 0;

fn copyz(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

/// Run pending engine commands. Called once per tick by the server thread.
pub fn pump() void {
    if (@atomicLoad(u32, &kind, .acquire) != @intFromEnum(Kind.create_game)) return;
    r_gameid = 0;
    r_ok = server.GAME_CreateBattleNetGame(
        @ptrCast(&c_name),
        @ptrCast(&c_pass),
        @ptrCast(&c_desc),
        c_flags,
        0,
        0,
        c_ladder,
        &r_gameid,
    );
    @atomicStore(u32, &kind, @intFromEnum(Kind.none), .release);
    @atomicStore(u32, &done, 1, .release);
}

/// Enqueue a create-game and block (≤~5s) until the tick thread runs it.
/// Returns the gameid (server token), or 0 on failure/timeout.
pub fn createGame(name: []const u8, pass: []const u8, desc: []const u8, flags: u32, ladder: u32) u16 {
    if (!allow_create) return 0; // gated until game-data init is solved
    copyz(&c_name, name);
    copyz(&c_pass, pass);
    copyz(&c_desc, desc);
    c_flags = flags;
    c_ladder = ladder;
    @atomicStore(u32, &done, 0, .release);
    @atomicStore(u32, &kind, @intFromEnum(Kind.create_game), .release);
    var spins: u32 = 0;
    while (@atomicLoad(u32, &done, .acquire) == 0 and spins < 500) : (spins += 1) Sleep(10);
    return if (r_ok != 0) r_gameid else 0;
}
