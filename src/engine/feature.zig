//! Feature registry — d2gs's Charon-style extensibility surface, Zig-native.
//!
//! A *feature* is just a module (namespace). It opts into a hook by declaring a
//! `pub fn` of that name — there is no base type to inherit and no vtable:
//! dispatch is a comptime `inline for` over `registry` that calls `f.mod.<hook>(...)`
//! only on the features that declare it (`@hasDecl`). "Overriding" a hook = declaring
//! the function; the default is to not declare it. This is the Zig analog of
//! Charon's `Feature` virtuals.
//!
//! Feature modules stay PURE — they contain only behaviour (`install()` + hooks).
//! All config (name, toggle flag, default state) lives in ONE place: the `registry`
//! table below. That table is the single source of truth for "what features exist
//! and how they're toggled".
//!
//! Features are runtime-toggleable: `enabled[i]` gates every dispatch, settable by
//! name via setEnabled() (from flags now, realm/redis config later).
//!
//! ── Hook contract (a feature declares any subset) ────────────────────────────
//!   Lifecycle:
//!     pub fn install() void              // apply byte-patches / set up (gated by enabled)
//!     pub fn postInit() void             // after engine init completes
//!     pub fn deinit() void
//!   Client frame loops (driven by runtime/gameloop.zig):
//!     pub fn gameFrame() void            // each in-game frame
//!     pub fn oogFrame() void             // each out-of-game (menu) frame
//!   Dedicated-server domain (driven by engine/server.zig + runtime/pkttrace.zig):
//!     pub fn serverTick() void                        // each server tick
//!     pub fn gameCreate(ctx: *const GameCtx) void     // a game was created
//!     pub fn gameDestroy(ctx: *const GameCtx) void    // a game is being torn down
//!     pub fn gameServerLoop(ctx: *const GameCtx) void // per-game, per-tick
//!     pub fn roomInit(ctx: *const GameCtx, room: *anyopaque) void
//!     pub fn expAward(ctx: *const GameCtx, unit: *anyopaque, exp: u32) u32 // transform: return new exp
//!     pub fn packetIn(bytes: []const u8) bool         // false = consume (stop dispatch)
//!     pub fn packetOut(bytes: []const u8) void
//!     pub fn playerJoin(ctx: *const GameCtx, client: u32) void
//!     pub fn playerLeave(ctx: *const GameCtx, client: u32) void
//!
//! See runtime/template.zig for a copy-paste starting point.

const std = @import("std");
const fog = @import("fog.zig");
const d2types = @import("d2types.zig");

/// Re-exported so callers can write `feature.GameCtx`; defined in ctx.zig to keep
/// feature modules from importing this registry back (cycle). See ctx.zig.
pub const GameCtx = @import("ctx.zig").GameCtx;

/// Build a per-game hook context whose allocator IS the game's own FOG pool, so
/// anything a feature allocates from `ctx.alloc` dies with the game. The driver
/// (e.g. runtime/roominit.zig) passes the game + its pool (game.pMemoryPool @0x1C).
pub fn gameCtx(game: *d2types.D2GameStrc, pool: *fog.D2PoolManagerStrc) GameCtx {
    return .{ .game = game, .alloc = fog.forPool(pool) };
}

/// One registry entry: the feature module plus its toggle config. `flag` is the
/// bare command-line switch ("--<flag>") that enables it; null = no flag.
/// `default` is the enable state before flags are applied.
const Feature = struct {
    mod: type,
    name: []const u8,
    flag: ?[]const u8 = null,
    default: bool = true,
};

/// The one table: every feature, its name, and how it toggles. Edit here to add,
/// remove, or re-flag a feature — nothing in the modules themselves changes.
/// Infra dispatchers (gameloop, pkttrace, server) are NOT here: they own engine
/// byte-hooks and *drive* the fan-out helpers below rather than being toggled here.
const registry = [_]Feature{
    .{ .mod = @import("../runtime/feature/crash.zig"), .name = "crash" },
    .{ .mod = @import("../runtime/feature/halt_hook.zig"), .name = "halt_hook" },
    .{ .mod = @import("../runtime/feature/gamecrashfix.zig"), .name = "gamecrashfix" },
    .{ .mod = @import("../runtime/feature/multiinstance.zig"), .name = "multiinstance" },
    .{ .mod = @import("../runtime/feature/headless.zig"), .name = "headless", .flag = "headless", .default = false },
    .{ .mod = @import("../runtime/feature/checkrev_patch.zig"), .name = "checkrev", .flag = "bypass-checkrev", .default = false },
    .{ .mod = @import("../runtime/feature/nocompress.zig"), .name = "nocompress", .flag = "no-compress", .default = false },
    .{ .mod = @import("../runtime/feature/clientdiag.zig"), .name = "clientdiag", .flag = "clientdiag", .default = false },
    .{ .mod = @import("../runtime/feature/srvdiag.zig"), .name = "srvdiag" },
    .{ .mod = @import("../runtime/feature/srvtrace.zig"), .name = "srvtrace" },
    .{ .mod = @import("../runtime/feature/cainfix.zig"), .name = "cainfix" },
    .{ .mod = @import("../runtime/feature/actpreload.zig"), .name = "actpreload" },
    // Off by default: the CompileTxt detour destabilizes engine bootstrap (flaky crash
    // during data load) — opt in with --ladder-items only once the detour is fixed.
    .{ .mod = @import("../runtime/feature/ladderitems.zig"), .name = "ladderitems", .flag = "ladder-items", .default = false },
    .{ .mod = @import("../runtime/feature/arena.zig"), .name = "arena", .flag = "arena", .default = false },
    .{ .mod = @import("../runtime/feature/expmod.zig"), .name = "expmod", .flag = "expmod", .default = false },
    .{ .mod = @import("../runtime/feature/ubers.zig"), .name = "ubers", .flag = "ubers", .default = false },
    // Client-side maphack (the d2gs.dll injects into the real client too).
    .{ .mod = @import("../runtime/feature/omnivision.zig"), .name = "omnivision", .flag = "omnivision", .default = false },
    .{ .mod = @import("../runtime/feature/mapunits.zig"), .name = "mapunits", .flag = "mapunits", .default = false },
    .{ .mod = @import("../runtime/feature/mapreveal.zig"), .name = "mapreveal", .flag = "mapreveal", .default = false },
    // Debug: draw our clean-room collision diff vs the engine as colored automap dots (SEED 1 only).
    .{ .mod = @import("../runtime/feature/colloverlay.zig"), .name = "colloverlay", .flag = "colloverlay", .default = false },
    // Cut Guild Halls: the client-side Steeg Stone panel (ported from GuildStone.cpp).
    .{ .mod = @import("../runtime/feature/guild_panel.zig"), .name = "guild_panel", .flag = "guild-panel", .default = false },
};

fn initEnabled() [registry.len]bool {
    var e: [registry.len]bool = undefined;
    for (registry, 0..) |f, i| e[i] = f.default;
    return e;
}

/// Per-feature runtime enable bits, indexed by position in `registry`.
var enabled: [registry.len]bool = initEnabled();

/// Toggle a feature by its registry `name`. Returns false if no such feature.
/// Call before installAll() to gate install(); later toggles gate dispatch only.
pub fn setEnabled(name: []const u8, on: bool) bool {
    inline for (registry, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) {
            enabled[i] = on;
            return true;
        }
    }
    return false;
}

/// Apply command-line flags onto the enable bits: every feature that declares a
/// `flag` is enabled iff `hasFlag(flag)` is true. `hasFlag` is the caller's
/// (DllMain's) flag matcher, taken as a comptime value since it has a comptime
/// parameter (each `fl` is comptime-known here, inside the inline for).
pub fn applyFlags(comptime hasFlag: anytype) void {
    inline for (registry, 0..) |f, i| {
        if (f.flag) |fl| enabled[i] = hasFlag(fl);
    }
}

// ── lifecycle dispatch ───────────────────────────────────────────────────────

/// Run each enabled feature's install() (byte-patches / setup). Call once at
/// process attach, after flags have set the enable bits.
pub fn installAll() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "install") and enabled[i]) f.mod.install();
    }
}

pub fn postInitAll() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "postInit") and enabled[i]) f.mod.postInit();
    }
}

pub fn deinitAll() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "deinit") and enabled[i]) f.mod.deinit();
    }
}

// ── client frame dispatch ────────────────────────────────────────────────────

pub fn fanGameFrame() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gameFrame") and enabled[i]) f.mod.gameFrame();
    }
}

pub fn fanOogFrame() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "oogFrame") and enabled[i]) f.mod.oogFrame();
    }
}

// ── client draw dispatch (driven by runtime/drawing.zig) ─────────────────────
// Only the automap hooks have a driver so far; the rest of Charon's draw surface
// (gameUnitPreDraw/PostDraw, gamePostDraw, oogPostDraw, allPostDraw, allFinalDraw,
// preDraw) lands with the full Drawing driver when a feature needs it.

/// Just before the engine renders the automap (good place to inject cells).
pub fn fanGameAutomapPreDraw() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gameAutomapPreDraw") and enabled[i]) f.mod.gameAutomapPreDraw();
    }
}

/// Just after the automap is rendered (good place to draw unit dots / labels).
pub fn fanGameAutomapPostDraw() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gameAutomapPostDraw") and enabled[i]) f.mod.gameAutomapPostDraw();
    }
}

/// After the in-game viewport is rendered (world-space overlays / HUD text
/// drawn on top of the scene). Driven by runtime/drawing.zig's post-draw hook.
pub fn fanGamePostDraw() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gamePostDraw") and enabled[i]) f.mod.gamePostDraw();
    }
}

// ── server domain dispatch ───────────────────────────────────────────────────

pub fn fanServerTick() void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "serverTick") and enabled[i]) f.mod.serverTick();
    }
}

pub fn fanGameCreate(ctx: *const GameCtx) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gameCreate") and enabled[i]) f.mod.gameCreate(ctx);
    }
}

pub fn fanGameDestroy(ctx: *const GameCtx) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gameDestroy") and enabled[i]) f.mod.gameDestroy(ctx);
    }
}

pub fn fanGameServerLoop(ctx: *const GameCtx) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "gameServerLoop") and enabled[i]) f.mod.gameServerLoop(ctx);
    }
}

pub fn fanRoomInit(ctx: *const GameCtx, room: *anyopaque) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "roomInit") and enabled[i]) f.mod.roomInit(ctx, room);
    }
}

/// Transform: thread `exp` through each enabled feature's expAward, returning the
/// final value (Charon's serverExpAward as an editable pipeline).
pub fn fanExpAward(ctx: *const GameCtx, unit: *anyopaque, exp: u32) u32 {
    var out = exp;
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "expAward") and enabled[i]) out = f.mod.expAward(ctx, unit, out);
    }
    return out;
}

/// Inbound packet observers. Returns false if a feature consumed the packet
/// (dispatch should stop); true to keep processing normally.
pub fn fanPacketIn(bytes: []const u8) bool {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "packetIn") and enabled[i]) {
            if (!f.mod.packetIn(bytes)) return false;
        }
    }
    return true;
}

pub fn fanPacketOut(bytes: []const u8) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "packetOut") and enabled[i]) f.mod.packetOut(bytes);
    }
}

pub fn fanPlayerJoin(ctx: *const GameCtx, client: u32) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "playerJoin") and enabled[i]) f.mod.playerJoin(ctx, client);
    }
}

pub fn fanPlayerLeave(ctx: *const GameCtx, client: u32) void {
    inline for (registry, 0..) |f, i| {
        if (@hasDecl(f.mod, "playerLeave") and enabled[i]) f.mod.playerLeave(ctx, client);
    }
}
