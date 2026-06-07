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
};

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
    if (env("REALMD_REALM_NAME")) |v| c.realm_name = v;
    if (env("REALMD_REALM_ADDR")) |v| c.realm_addr = v;
    if (env("REALMD_DATA_DIR")) |v| c.data_dir = v;
    if (env("REALMD_SHARED")) |_| c.shared = true;
    if (env("REALMD_CAPTURE")) |_| c.capture = true;
    return c;
}
