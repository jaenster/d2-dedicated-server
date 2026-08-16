//! Server-side diagnostic feature (engine/feature.zig consumer). Off unless `--srvdiag`. Logs
//! server lifecycle events and hangs per-game state on the game's own FOG pool. No engine
//! byte-hooks of its own: the fan-out drivers (engine/server.zig tick(), per-game loop) call these.
const std = @import("std");
const log = @import("../../log.zig");
const GameCtx = @import("../../engine/ctx.zig").GameCtx;

var ticks: u64 = 0;

/// Per-game state, allocated from the game's own pool in gameCreate — so it dies
/// with the game. Proves the "hang data on the game" allocator path.
const GameState = struct {
    loops: u64 = 0,
};

pub fn serverTick() void {
    ticks += 1;
    if (ticks % 500 == 0) log.hex("srvdiag: serverTick heartbeat, n=0x", @intCast(ticks));
}

pub fn gameCreate(ctx: *const GameCtx) void {
    log.hex("srvdiag: game created @0x", @intFromPtr(ctx.game));
    const st = ctx.alloc.create(GameState) catch {
        log.print("srvdiag: game-pool alloc failed");
        return;
    };
    st.* = .{};
    log.hex("srvdiag: per-game state hung on game pool @0x", @intFromPtr(st));
}

pub fn gameDestroy(ctx: *const GameCtx) void {
    log.hex("srvdiag: game destroyed @0x", @intFromPtr(ctx.game));
}

/// Fires per room activation (via runtime/roominit.zig) with a real per-game ctx.
/// Round-trips an allocation through the game's OWN FOG pool (ctx.alloc) to prove
/// the per-game allocator path end-to-end.
pub fn roomInit(ctx: *const GameCtx, room: *anyopaque) void {
    const p = ctx.alloc.create(u32) catch {
        log.print("srvdiag: roomInit game-pool alloc FAILED");
        return;
    };
    p.* = ctx.game.difficulty();
    log.hex("srvdiag: roomInit (game-pool alloc ok), room=0x", @intFromPtr(room));
    ctx.alloc.destroy(p);
}

pub fn expAward(_: *const GameCtx, _: *anyopaque, exp: u32) u32 {
    log.hex("srvdiag: expAward exp=0x", @intCast(exp));
    return exp; // pass through unchanged
}
