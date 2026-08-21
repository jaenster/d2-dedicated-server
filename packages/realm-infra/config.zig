//! realmd configuration. Everything comes from the environment with sane
//! defaults — no config files, no sed. One binary, one set of env vars.
//!
//! Multi-instance note: every instance reads the same vars; what makes them distinct is
//! REALMD_INSTANCE, which must differ per instance (it seeds session and request id ranges).
//! Everything else is shared — Postgres for the record, Redis for what is in flight — so the
//! listeners are stateless and scaling out is just "run more of these".
const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Config = struct {
    instance_id: []const u8 = "realmd-0",
    bind: []const u8 = "0.0.0.0",
    bnet_port: u16 = 6112,

    /// Realm advertised to clients (what bnetd hands back as the realm address).
    realm_name: []const u8 = "TypeGuru",
    realm_addr: []const u8 = "127.0.0.1",
    /// Comma-separated account names granted Battle.net-admin + channel-operator flags
    /// in chat (the realm's ops). Case-insensitive. Empty = no admins.
    admins: []const u8 = "",
    /// Banner ad shown above the chat window: the file the client downloads over BNFTP
    /// (so it must sit in <data_dir>/bnftp/) and the URL a click opens. The client only
    /// shows an ad when it gets BOTH, so either one empty means no ads.
    ad_file: []const u8 = "",
    ad_url: []const u8 = "",

    /// Optional override for the game-server IP advertised to clients (when the
    /// GS is behind NAT). Empty = use the address the server reports for itself.
    gs_addr: []const u8 = "",

    /// REQUIRED (dotted-quad). Public address of the game-traffic ingress, advertised to
    /// clients on JOINGAME — either a standalone d2ingress or realmd's own edge (`game_port`).
    /// Never a game server's own address: the token clients are handed is realm-global, so
    /// only an ingress can translate it. realmd refuses to start without it.
    game_addr: []const u8 = "",
    /// TTL (seconds) for the {client-ip → GS} routes realmd records on JOINGAME for
    /// the d2ingress to consume.
    route_ttl_s: u32 = 60,
    /// Public port the d2ingress listens on for game traffic (consumed by the d2ingress
    /// binary; parsed here so realmd and d2ingress share one config surface).
    ingress_port: u16 = 4000,
    /// When non-zero, realmd runs the EMBEDDED game-traffic edge (gameedge.zig) on this
    /// port itself — the lightweight, single-binary alternative to a standalone d2ingress
    /// (in-process token-route lookup, thread-per-conn splice). 0 = off (use d2ingress).
    game_port: u16 = 0,

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
    /// REQUIRED. Where the realm coordinates: sessions, games, the fleet and its queues, and the
    /// live character in front of Postgres. "host:port", DNS name ok.
    redis_addr: []const u8 = "redis:6379",
    /// REQUIRED. The store of record: characters, accounts, profiles, guilds. libpq-style DSN.
    pg_dsn: []const u8 = "",

    /// Bearer token for the HTTP admin API (served on the health port under
    /// /admin/*). A non-empty token enables the bearer path (for scripts/CI and as
    /// break-glass). The admin API is also enabled when `admins` is set (password
    /// login by realm account) or `trusted_auth_header` is set (SSO). When NONE of
    /// the three is configured the API is disabled entirely (403).
    admin_token: []const u8 = "",

    /// HMAC key that signs admin session cookies (the web UI's password-login
    /// sessions). Set REALMD_ADMIN_SECRET to a stable random string so sessions
    /// survive restarts and are shared across instances; if empty, a per-process
    /// random key is generated (sessions break on restart / aren't multi-instance).
    admin_secret: []const u8 = "",

    /// `name:password` of an admin account to ensure on startup (REALMD_ADMIN_BOOTSTRAP).
    /// If the account is missing it is created (with that password) and flagged admin;
    /// if it exists the admin flag is (re)set. Idempotent — the declarative way to seed a
    /// break-glass admin from a k8s Secret. The password part may be empty (SSO-only admin).
    admin_bootstrap: []const u8 = "",

    /// Comma-separated `name:password` pairs to seed as ordinary (non-admin) accounts on
    /// startup (REALMD_SEED_ACCOUNTS). Idempotent: each is created with that password only
    /// if missing. With strict logon (unknown account rejected), this is how test/fixture
    /// accounts get a real password so wrong passwords are refused. e.g. "EpicAma:secret,Sidekick:secret".
    seed_accounts: []const u8 = "",

    /// Legacy/test auth: unknown accounts auto-register password-less and passwords are
    /// verified (REALMD_PERMISSIVE_AUTH). Default false = strict (reject unknown accounts,
    /// no auto-register). The e2e harness sets it; real deployments leave it off.
    permissive_auth: bool = false,

    /// When set (e.g. "X-Forwarded-User"), realmd trusts this request header as an
    /// already-authenticated username — for SSO via a forward-auth proxy (Authentik
    /// outpost / oauth2-proxy). The username must still be in `admins`. ONLY enable
    /// when the admin port is reachable solely through that trusted proxy, since the
    /// header is trusted verbatim (a direct client could otherwise spoof it).
    trusted_auth_header: []const u8 = "",

    /// This extension's own options. On `Config` as well as at module scope because `startup` is
    /// handed a config and that is where an extension reads its settings.
    pub fn ext(_: Config, name: []const u8) ExtConfig {
        return .{ .name = name };
    }
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

/// An extension's own configuration, read from `REALMD_EXT_<NAME>_<KEY>`.
///
/// Extensions get a namespace here for the same reason they get one in the store: an option an
/// extension invents must not need a field in `Config`, or adding one would mean editing this
/// repo — which is the thing the extension mechanism exists to avoid. Nothing is parsed at
/// startup; each lookup reads the environment, so an extension names its own options and this
/// file never learns them.
pub const ExtConfig = struct {
    name: []const u8,

    /// The value of `REALMD_EXT_<NAME>_<KEY>`, upper-cased with `-` folded to `_`, so
    /// `cfg.ext("my-ladder").get("season_end")` reads `REALMD_EXT_MY_LADDER_SEASON_END`.
    pub fn get(e: ExtConfig, key: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const n = e.varName(&buf, key) orelse return null;
        return env(@ptrCast(n.ptr));
    }

    pub fn getOr(e: ExtConfig, key: []const u8, default: []const u8) []const u8 {
        return e.get(key) orelse default;
    }

    pub fn int(e: ExtConfig, comptime T: type, key: []const u8, default: T) T {
        const v = e.get(key) orelse return default;
        return std.fmt.parseInt(T, v, 10) catch default;
    }

    /// Present and not one of the words that mean "off". Set-means-on is how the realm's own
    /// switches already read (`REALMD_TRACE`), and an explicit `=0` still turns one off.
    pub fn flag(e: ExtConfig, key: []const u8) bool {
        const v = e.get(key) orelse return false;
        return !(std.ascii.eqlIgnoreCase(v, "0") or std.ascii.eqlIgnoreCase(v, "false") or
            std.ascii.eqlIgnoreCase(v, "no") or v.len == 0);
    }

    /// Build the sentinel-terminated env var name. Null if it would not fit, which is a name or
    /// key long enough to be a mistake rather than something to truncate into a different var.
    fn varName(e: ExtConfig, buf: []u8, key: []const u8) ?[:0]const u8 {
        const lead = "REALMD_EXT_";
        const total = lead.len + e.name.len + 1 + key.len;
        if (total + 1 > buf.len) return null;
        @memcpy(buf[0..lead.len], lead);
        var i = lead.len;
        for (e.name) |c| {
            buf[i] = if (c == '-') '_' else std.ascii.toUpper(c);
            i += 1;
        }
        buf[i] = '_';
        i += 1;
        for (key) |c| {
            buf[i] = if (c == '-') '_' else std.ascii.toUpper(c);
            i += 1;
        }
        buf[i] = 0;
        return buf[0..i :0];
    }
};

/// Configuration for one extension: `cfg.ext("ladder").int(u32, "season", 1)`.
pub fn ext(name: []const u8) ExtConfig {
    return .{ .name = name };
}

test "ExtConfig builds the namespaced env var name" {
    var buf: [128]u8 = undefined;
    const e = ExtConfig{ .name = "my-ladder" };
    try std.testing.expectEqualStrings("REALMD_EXT_MY_LADDER_SEASON_END", e.varName(&buf, "season_end").?);
    // A name that cannot fit is refused rather than truncated into some other extension's var.
    var small: [8]u8 = undefined;
    try std.testing.expect(e.varName(&small, "season_end") == null);
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
    if (env("REALMD_GS_ADDR")) |v| c.gs_addr = v;
    if (env("REALMD_GAME_ADDR")) |v| c.game_addr = v;
    if (env("REALMD_ROUTE_TTL_S")) |v| c.route_ttl_s = std.fmt.parseInt(u32, v, 10) catch c.route_ttl_s;
    c.ingress_port = envPort("REALMD_INGRESS_PORT", c.ingress_port);
    c.game_port = envPort("REALMD_GAME_PORT", c.game_port);
    if (env("REALMD_REALM_NAME")) |v| c.realm_name = v;
    if (env("REALMD_ADMINS")) |v| c.admins = v;
    if (env("REALMD_AD_FILE")) |v| c.ad_file = v;
    if (env("REALMD_AD_URL")) |v| c.ad_url = v;
    if (env("REALMD_REALM_ADDR")) |v| c.realm_addr = v;
    if (env("REALMD_DATA_DIR")) |v| c.data_dir = v;
    if (env("REALMD_SHARED")) |_| c.shared = true;
    if (env("REALMD_CAPTURE")) |_| c.capture = true;
    c.health_port = envPort("REALMD_HEALTH_PORT", c.health_port);
    if (env("REALMD_LOG_JSON")) |_| c.log_json = true;
    if (env("REALMD_REQUIRE_GS")) |_| c.require_gs = true;
    if (env("REALMD_SHUTDOWN_GRACE_MS")) |v| c.shutdown_grace_ms = std.fmt.parseInt(u32, v, 10) catch c.shutdown_grace_ms;
    if (env("REALMD_REDIS_ADDR")) |v| c.redis_addr = v;
    if (env("REALMD_PG_DSN")) |v| c.pg_dsn = v;
    if (env("REALMD_ADMIN_TOKEN")) |v| c.admin_token = v;
    if (env("REALMD_ADMIN_SECRET")) |v| c.admin_secret = v;
    if (env("REALMD_ADMIN_BOOTSTRAP")) |v| c.admin_bootstrap = v;
    if (env("REALMD_SEED_ACCOUNTS")) |v| c.seed_accounts = v;
    if (env("REALMD_PERMISSIVE_AUTH")) |_| c.permissive_auth = true;
    if (env("REALMD_TRUSTED_AUTH_HEADER")) |v| c.trusted_auth_header = v;
    return c;
}
