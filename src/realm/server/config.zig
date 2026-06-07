//! realmd configuration. Everything comes from the environment with sane
//! defaults — no config files, no sed. One binary, one set of env vars.
//!
//! Multi-instance note: every instance reads the same vars; what makes them
//! distinct is REALMD_INSTANCE (an id for logging/coordination) and the shared
//! Store backend (added later) they all point at. The protocol listeners
//! themselves are stateless, so scaling out is just "run more of these".
const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Config = struct {
    instance_id: []const u8 = "realmd-0",
    bind: []const u8 = "0.0.0.0",
    bnet_port: u16 = 6112,
    d2cs_port: u16 = 6113,
    d2dbs_port: u16 = 6114,

    /// Realm advertised to clients (what bnetd hands back as the realm address).
    realm_name: []const u8 = "TypeGuru",
    realm_addr: []const u8 = "127.0.0.1",

    /// Port the game server (our injected d2gs) connects to for the control
    /// link (its own port so we never confuse it with a client MCP connection).
    gs_port: u16 = 6115,
    /// Optional override for the game-server IP advertised to clients (when the
    /// GS is behind NAT). Empty = use the control connection's peer IP.
    gs_addr: []const u8 = "",

    /// Public address of the qqserver game-traffic gateway, advertised to clients on
    /// JOINGAME instead of the GS's own IP (dotted-quad). Empty = advertise the GS IP
    /// directly (back-compat, no qqserver deployed).
    game_addr: []const u8 = "",
    /// TTL (seconds) for the {client-ip → GS} routes realmd records on JOINGAME for
    /// the qqserver to consume.
    route_ttl_s: u32 = 60,
    /// Public port the qqserver listens on for game traffic (consumed by the qqserver
    /// binary; parsed here so realmd and qqserver share one config surface).
    qq_port: u16 = 4000,

    /// Directory for durable data (character saves). A shared volume here is
    /// what lets multiple instances see the same characters.
    data_dir: []const u8 = "realmd-data",

    /// Multi-instance mode: keep sessions/games in the shared Store (a shared
    /// data_dir volume) so instances run in tandem. Requires a distinct
    /// REALMD_INSTANCE per instance.
    shared: bool = false,

    /// When set, every listener hexdumps raw bytes instead of speaking the
    /// protocol — used to reverse the exact wire format the real client sends.
    capture: bool = false,

    /// Port for the HTTP health endpoint (k8s liveness/readiness probes).
    health_port: u16 = 8080,
    /// Emit structured JSON log lines instead of `[tag] msg`.
    log_json: bool = false,
    /// /readyz only goes green once at least one game server has registered.
    require_gs: bool = false,
    /// How long to keep serving (reporting not-ready) after SIGTERM before exit.
    shutdown_grace_ms: u32 = 5000,

    /// Persistence backends. `durable` serves character saves (the store of record);
    /// `ephemeral` serves sessions + games (short-lived, TTL'd). They are independent
    /// so Postgres and Redis are co-equal (durable=pg, ephemeral=redis is the common
    /// split). REALMD_STORE sets both; REALMD_DURABLE_STORE / REALMD_EPHEMERAL_STORE
    /// override each. Values: fs | redis | pg.
    durable_store: Backend = .fs,
    ephemeral_store: Backend = .fs,
    /// "host:port" for the Redis backend (DNS name ok).
    redis_addr: []const u8 = "redis:6379",
    /// libpq-style DSN for the Postgres backend.
    pg_dsn: []const u8 = "",

    /// Bearer token for the HTTP admin API (served on the health port under
    /// /admin/*). EMPTY (default) disables the admin API entirely — it returns
    /// 403 — so it is off unless explicitly enabled via REALMD_ADMIN_TOKEN.
    admin_token: []const u8 = "",
};

pub const Backend = enum { fs, redis, pg };

fn parseBackend(s: []const u8, current: Backend) Backend {
    if (std.mem.eql(u8, s, "fs")) return .fs;
    if (std.mem.eql(u8, s, "redis")) return .redis;
    if (std.mem.eql(u8, s, "pg")) return .pg;
    return current;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

fn envPort(name: [*:0]const u8, current: u16) u16 {
    const v = env(name) orelse return current;
    return std.fmt.parseInt(u16, v, 10) catch current;
}

pub fn fromEnv() Config {
    var c = Config{};
    if (env("REALMD_INSTANCE")) |v| c.instance_id = v;
    if (env("REALMD_BIND")) |v| c.bind = v;
    c.bnet_port = envPort("REALMD_BNET_PORT", c.bnet_port);
    c.d2cs_port = envPort("REALMD_D2CS_PORT", c.d2cs_port);
    c.d2dbs_port = envPort("REALMD_D2DBS_PORT", c.d2dbs_port);
    c.gs_port = envPort("REALMD_GS_PORT", c.gs_port);
    if (env("REALMD_GS_ADDR")) |v| c.gs_addr = v;
    if (env("REALMD_GAME_ADDR")) |v| c.game_addr = v;
    if (env("REALMD_ROUTE_TTL_S")) |v| c.route_ttl_s = std.fmt.parseInt(u32, v, 10) catch c.route_ttl_s;
    c.qq_port = envPort("REALMD_QQ_PORT", c.qq_port);
    if (env("REALMD_REALM_NAME")) |v| c.realm_name = v;
    if (env("REALMD_REALM_ADDR")) |v| c.realm_addr = v;
    if (env("REALMD_DATA_DIR")) |v| c.data_dir = v;
    if (env("REALMD_SHARED")) |_| c.shared = true;
    if (env("REALMD_CAPTURE")) |_| c.capture = true;
    c.health_port = envPort("REALMD_HEALTH_PORT", c.health_port);
    if (env("REALMD_LOG_JSON")) |_| c.log_json = true;
    if (env("REALMD_REQUIRE_GS")) |_| c.require_gs = true;
    if (env("REALMD_SHUTDOWN_GRACE_MS")) |v| c.shutdown_grace_ms = std.fmt.parseInt(u32, v, 10) catch c.shutdown_grace_ms;
    // REALMD_STORE sets both backends; the granular vars override each.
    if (env("REALMD_STORE")) |v| {
        c.durable_store = parseBackend(v, c.durable_store);
        c.ephemeral_store = parseBackend(v, c.ephemeral_store);
    }
    if (env("REALMD_DURABLE_STORE")) |v| c.durable_store = parseBackend(v, c.durable_store);
    if (env("REALMD_EPHEMERAL_STORE")) |v| c.ephemeral_store = parseBackend(v, c.ephemeral_store);
    if (env("REALMD_REDIS_ADDR")) |v| c.redis_addr = v;
    if (env("REALMD_PG_DSN")) |v| c.pg_dsn = v;
    if (env("REALMD_ADMIN_TOKEN")) |v| c.admin_token = v;
    return c;
}
