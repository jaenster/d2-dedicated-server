//! Shared realm definitions — the package both sides of the realm link depend on:
//! the GS-side client (`realm/client`) and the realm server (`realm/server`). Imported
//! as the `realm_shared` module (see build.zig) so it crosses module boundaries cleanly.
//!
//! Holds the wire contracts (and any enums/types) that MUST agree on both ends.
pub const protocol = @import("protocol.zig");

/// The cut "Guild Halls" data model (reconstructed from the beta/1.00 binaries).
/// Authoritative state lives in realmd; the GS + client read it for display.
pub const guild = @import("guild.zig");
