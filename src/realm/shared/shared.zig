//! Shared realm definitions — the package both sides of the realm link depend on:
//! the GS-side client (`realm/client`) and the realm server (`realm/server`). Imported
//! as the `realm_shared` module (see build.zig) so it crosses module boundaries cleanly.
//!
//! Holds the wire contracts (and any enums/types) that MUST agree on both ends.
pub const protocol = @import("protocol.zig");
