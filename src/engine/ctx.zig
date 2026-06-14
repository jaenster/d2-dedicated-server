//! Shared hook context types. Lives in its own file so feature modules and the
//! registry (engine/feature.zig) can both reference it without an import cycle
//! (the registry imports the feature modules; they'd import the registry back
//! just for this type).
const std = @import("std");
const d2types = @import("d2types.zig");

/// Context handed to every per-game server hook. `alloc` is the *game's own* FOG
/// pool (via fog.forPool) — allocate per-game feature state from it and it is
/// freed when the game ends (see engine/fog.zig registerCleanup). `game` is the
/// typed D2GameStrc pointer.
pub const GameCtx = struct {
    game: *d2types.D2GameStrc,
    alloc: std.mem.Allocator,
};
