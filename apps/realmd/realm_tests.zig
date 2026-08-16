//! Root for `zig build test`. Pulls in every realm-server module that carries unit tests
//! so they run together; rooting the test binary at one service (as this used to do) only
//! ever ran the tests reachable from that service's imports.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    _ = @import("guilds.zig");
    _ = @import("friends.zig");
    _ = @import("d2s.zig");
    _ = @import("proto.zig");
    _ = @import("fleet.zig");
    // Shared infrastructure every listener sits on.
    _ = @import("realm_infra").lock;
    _ = @import("realm_infra").log;
    _ = @import("realm_store").redis;
}
