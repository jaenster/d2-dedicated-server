//! What every host of a D2Game build has to agree with the engine on, independent of which build
//! it is: the 1.14d monolith injected into Game.exe and the pre-1.14 D2Game.dll host implement the
//! same contracts. Version differences stay here, next to the thing that differs, instead of being
//! re-derived in each host.

pub const callbacks = @import("callbacks.zig");
pub const version = @import("version.zig");
pub const hostapi = @import("hostapi.zig");
pub const gameflags = @import("gameflags.zig");
pub const cs_packets = @import("cs_packets.zig");
pub const fogabi = @import("fogabi.zig");

// A test artifact rooted here only runs the tests of files it actually analyses.
test {
    _ = callbacks;
    _ = version;
    _ = hostapi;
    _ = gameflags;
    _ = cs_packets;
    _ = fogabi;
}
