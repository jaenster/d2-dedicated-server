//! realm_store — the concrete persistence backends behind the store facade. These are
//! the "driven adapters": the domain (server/store.zig) names operations in D2 terms and
//! dispatches to one of these by a plain `switch` — no ptr/vtable adapter objects. This
//! full barrel (incl. the Postgres client) is imported by realmd; the d2ingress uses the
//! pg-free `route.zig` barrel instead.
pub const fs = @import("fs.zig");
pub const redis = @import("redis.zig");
pub const pg = @import("pg.zig");

// As in infra.zig: naming the backends is what gets their `test` blocks compiled in.
test {
    _ = fs;
    _ = redis;
    _ = pg;
}
