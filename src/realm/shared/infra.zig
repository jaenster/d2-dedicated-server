//! realm_infra — shared host-side infrastructure imported by the native binaries
//! (realmd server + qqserver gateway), but NOT by the injected Windows DLL. Kept
//! separate from `realm_shared` (the wire protocol, which the x86-windows DLL also
//! imports) so libc-socket / POSIX code never gets dragged into the DLL build.
pub const net = @import("net.zig");
pub const log = @import("log.zig");
pub const obs = @import("obs.zig"); // per-thread trace/span context (log.zig stamps it)
pub const config = @import("config.zig");
pub const lock = @import("lock.zig");
pub const types = @import("store_types.zig");

// A re-export alone does not get a file analysed; naming each one here is what puts the infra
// unit tests into `zig build test`.
test {
    _ = net;
    _ = log;
    _ = obs;
    _ = config;
    _ = lock;
    _ = types;
}
