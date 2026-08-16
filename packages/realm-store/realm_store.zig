//! realm_store — where the realm's state actually lives. Postgres is the store of record and
//! Redis is what is in flight; `assets` is BNFTP files on disk, which is content rather than
//! state. There is no third option and no backend selection: the domain (apps/realmd/store.zig)
//! names operations in D2 terms and each one has exactly one home.
//!
//! This full barrel (incl. the Postgres client) is imported by realmd; the d2ingress talks to
//! redis directly and never needs the rest.
pub const assets = @import("assets.zig");
pub const redis = @import("redis.zig");
pub const pg = @import("pg.zig");

// As in infra.zig: naming the backends is what gets their `test` blocks compiled in.
test {
    _ = assets;
    _ = redis;
    _ = pg;
}
