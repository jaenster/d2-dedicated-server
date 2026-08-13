//! Feature template — copy this file, rename it, register it in engine/feature.zig's
//! `registry` table, and delete the hooks you don't need. A feature is just a module
//! that declares `pub fn`s named after the hook points it wants; the registry calls
//! only the ones you declare (`@hasDecl`). There is no base type and no metadata in
//! here — name/flag/default live in the registry table.
//!
//! This module is NOT in the registry (it declares nothing live); it's reference only.
const std = @import("std");
const log = @import("../../log.zig");
const patch = @import("../patch.zig");
const GameCtx = @import("../../engine/ctx.zig").GameCtx;

// ── lifecycle ────────────────────────────────────────────────────────────────

/// Apply byte-patches / set up. Runs once at process attach if the feature is
/// enabled. Use patch.MemoryPatch(addr).…commit() or the writeX helpers.
pub fn install() void {
    log.print("template: install");
}

pub fn postInit() void {} // after engine init completes
pub fn deinit() void {}

// ── client frame loops (driven by runtime/gameloop.zig) ──────────────────────

pub fn gameFrame() void {} // each in-game frame
pub fn oogFrame() void {} // each out-of-game (menu) frame

// ── dedicated-server domain (driven by engine/server.zig) ────────────────────

pub fn serverTick() void {} // each server tick

pub fn gameCreate(ctx: *const GameCtx) void {
    // ctx.alloc is THIS game's FOG pool — anything allocated here dies with the game.
    _ = ctx;
}

pub fn gameDestroy(ctx: *const GameCtx) void {
    _ = ctx;
}

pub fn gameServerLoop(ctx: *const GameCtx) void {
    _ = ctx;
}

pub fn roomInit(ctx: *const GameCtx, room: *anyopaque) void {
    _ = ctx;
    _ = room;
}

/// Transform the exp the server is about to award; return the (possibly modified) value.
pub fn expAward(ctx: *const GameCtx, unit: *anyopaque, exp: u32) u32 {
    _ = ctx;
    _ = unit;
    return exp;
}

/// Inbound packet observer. Return false to consume it (stop dispatch).
pub fn packetIn(bytes: []const u8) bool {
    _ = bytes;
    return true;
}

pub fn packetOut(bytes: []const u8) void {
    _ = bytes;
}

pub fn playerJoin(ctx: *const GameCtx, client: u32) void {
    _ = ctx;
    _ = client;
}

pub fn playerLeave(ctx: *const GameCtx, client: u32) void {
    _ = ctx;
    _ = client;
}

comptime {
    _ = std; // template references std for callers; silence unused in this stub
    _ = patch;
}
