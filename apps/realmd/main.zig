//! realmd — a clean-room Battle.net / D2 realm server in Zig.
//!
//! Replaces pvpgn (bnetd + d2cs + d2dbs) with a single binary. It serves clients on one port
//! and keeps everything shared in redis, so instances are interchangeable rather than each
//! owning a piece of the realm.
//!
//! It is the realm the unmodified 1.14d client connects to. Games reach a game server through
//! the shared store rather than a connection this instance holds — see fleet.zig.
const std = @import("std");
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const config = @import("realm_infra").config;
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const obs = @import("realm_infra").obs;

extern "c" fn time(t: ?*c_long) c_long; // unix seconds — portable (Linux + macOS), no struct-layout traps
/// Milliseconds for obs span durations. Seconds-resolution (×1000) keeps it portable
/// and trap-free across libc/OS; precise sub-second span timing can come later behind a
/// per-OS monotonic clock. The trace/span ids — the correlation value — are exact.
fn nowMs() u64 {
    return @as(u64, @intCast(time(null))) *% 1000;
}
const bncs = @import("bncs.zig");
const chat = @import("chat.zig");
const d2cs = @import("d2cs.zig");
const fleet = @import("fleet.zig");
const gameedge = @import("gameedge.zig");
const charflush = @import("charflush.zig");
const store = @import("store.zig");
const state = @import("state.zig");
const health = @import("health.zig");
const admin = @import("admin.zig");
const shutdown = @import("shutdown.zig");
const xsha1 = @import("libd2").bnet.xsha1;

fn hashStr(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

/// Ensure `name` exists as an admin account: create it (with `password` if given,
/// lowercased+xsha1 to match the login path) when missing, then set the admin flag.
/// Idempotent — used by both `create-admin` and REALMD_ADMIN_BOOTSTRAP. Assumes
/// store.init() has run.
fn ensureAdmin(name: []const u8, password: ?[]const u8) void {
    if (name.len == 0) return;
    if (!store.accountExists(name)) {
        var pwhash: ?[20]u8 = null;
        if (password) |p| {
            if (p.len > 0) {
                pwhash = xsha1.passwordHash(p);
            }
        }
        _ = store.createAccount(name, pwhash);
        log.line("realmd", "admin account '{s}' created (password={})", .{ name, password != null and password.?.len > 0 });
    }
    _ = store.setAdmin(name, true);
    log.line("realmd", "admin account '{s}' flagged admin", .{name});
}

/// Seed ordinary (non-admin) accounts with passwords from REALMD_SEED_ACCOUNTS
/// ("name:pw,name:pw"). Idempotent: only creates a missing account. Lets strict
/// logon (unknown account rejected) still admit fixture accounts. store.init() must
/// have run.
fn seedAccounts(spec: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |pair| {
        const sep = std.mem.indexOfScalar(u8, pair, ':') orelse pair.len;
        const name = pair[0..sep];
        const pw = if (sep < pair.len) pair[sep + 1 ..] else "";
        if (name.len == 0 or store.accountExists(name)) continue;
        var pwhash: ?[20]u8 = null;
        if (pw.len > 0) {
            pwhash = xsha1.passwordHash(pw);
        }
        _ = store.createAccount(name, pwhash);
        log.line("realmd", "seeded account '{s}' (password={})", .{ name, pw.len > 0 });
    }
}

/// Whether any stored account carries the DB admin flag (cheap startup scan).
fn anyDbAdmin() bool {
    var names: [256][32]u8 = undefined;
    const n = store.listAccounts(&names);
    for (names[0..n]) |nm| {
        const name = std.mem.sliceTo(&nm, 0);
        if (store.accountIsAdmin(name)) return true;
    }
    return false;
}

fn initStore(cfg: config.Config, io: anytype) void {
    store.init(.{
        .io = io,
        .data_dir = cfg.data_dir,
        .redis_addr = cfg.redis_addr,
        .pg_dsn = cfg.pg_dsn,
    });
}

/// `realmd create-admin <name> [password]` — create/flag an admin account offline
/// (no server, no token) against the configured store, then exit. Returns true if a
/// subcommand was handled.
fn runSubcommand(cfg: config.Config, args: std.process.Args) bool {
    var it = args.iterate();
    _ = it.next(); // argv[0] — program name
    const sub = it.next() orelse return false;
    if (!std.mem.eql(u8, sub, "create-admin")) return false;
    const name = it.next() orelse {
        log.line("realmd", "usage: realmd create-admin <name> [password]", .{});
        std.process.exit(2);
    };
    const password: ?[]const u8 = if (it.next()) |p| p else null;
    var threaded = std.Io.Threaded.init_single_threaded;
    initStore(cfg, threaded.io());
    ensureAdmin(name, password);
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const cfg = config.fromEnv();
    log.json = cfg.log_json;
    obs.nowMsFn = &nowMs; // span durations
    if (runSubcommand(cfg, init.args)) return;
    log.line("realmd", "starting instance={s} bind={s} bnet={d} realm={s}@{s} capture={}", .{
        cfg.instance_id, cfg.bind, cfg.bnet_port, cfg.realm_name, cfg.realm_addr, cfg.capture,
    });
    // Graceful shutdown for k8s rolling updates + readiness gating.
    health.require_gs = cfg.require_gs;
    // Admin API + web UI (served on the health port under /admin/*). Enabled by any of:
    // bearer token (scripts/break-glass), account login (REALMD_ADMINS), or SSO header.
    admin.token = cfg.admin_token;
    admin.instance = cfg.instance_id;
    admin.durable = "pg";
    admin.ephemeral = "redis";
    admin.admins = cfg.admins;
    admin.trusted_header = cfg.trusted_auth_header;
    admin.initSigning(cfg.admin_secret);
    if ((cfg.admins.len > 0 or cfg.admin_bootstrap.len > 0) and cfg.admin_secret.len == 0)
        log.line("realmd", "WARNING REALMD_ADMIN_SECRET unset; web-UI sessions use a per-process key (break on restart, not multi-instance)", .{});
    shutdown.install(cfg.shutdown_grace_ms);

    // bnetd advertises the d2cs address to the client. realm_addr must be an
    // IPv4 the client can dial (127.0.0.1 in dev, the public IP in prod).
    var threaded = std.Io.Threaded.init_single_threaded;
    initStore(cfg, threaded.io());
    log.line("realmd", "store: postgres for the record, redis for what is in flight", .{});
    // Both are required, and both are checked here rather than discovered per request. Every
    // failure they cause reads as a game bug — a character that will not load, a game nobody can
    // join — so a missing dependency has to announce itself as one, once, by name.
    if (cfg.pg_dsn.len == 0) {
        log.line("realmd", "FATAL REALMD_PG_DSN is required: it is the store of record for characters and accounts", .{});
        return error.PostgresRequired;
    }
    if (!store.ephemeralReachable()) {
        log.line("realmd", "FATAL redis at '{s}' did not answer", .{cfg.redis_addr});
        return error.RedisUnreachable;
    }
    if (!store.durableReachable()) {
        log.line("realmd", "FATAL postgres did not answer (REALMD_PG_DSN)", .{});
        return error.PostgresUnreachable;
    }
    // Seed a break-glass admin from REALMD_ADMIN_BOOTSTRAP=name[:password] (idempotent).
    if (cfg.admin_bootstrap.len > 0) {
        const sep = std.mem.indexOfScalar(u8, cfg.admin_bootstrap, ':');
        const name = if (sep) |s| cfg.admin_bootstrap[0..s] else cfg.admin_bootstrap;
        const pw: ?[]const u8 = if (sep) |s| cfg.admin_bootstrap[s + 1 ..] else null;
        ensureAdmin(name, pw);
    }
    // Seed ordinary fixture/test accounts with passwords (REALMD_SEED_ACCOUNTS).
    if (cfg.seed_accounts.len > 0) seedAccounts(cfg.seed_accounts);
    // Keep the admin API/UI enabled across restarts if any stored account is a DB admin
    // (so it doesn't go dark just because no env auth is configured this boot).
    admin.any_db_admin = anyDbAdmin();
    if (admin.token.len > 0 or admin.admins.len > 0 or admin.trusted_header.len > 0 or admin.any_db_admin)
        log.line("realmd", "admin API + web UI enabled on health port {d} (token={} env-admins={} sso={} db-admins={})", .{ cfg.health_port, admin.token.len > 0, admin.admins.len > 0, admin.trusted_header.len > 0, admin.any_db_admin });
    // Sessions and games always live in redis, so instances are interchangeable by construction
    // rather than by being told to be. The instance hash keeps their minted ids apart.
    state.shared = true;
    state.instance_hash = hashStr(cfg.instance_id);
    chat.instance = state.instance_hash; // which inbox chat events for our members arrive on
    log.line("realmd", "instance {s} (hash 0x{x})", .{ cfg.instance_id, state.instance_hash });
    bncs.realm_name = cfg.realm_name;
    bncs.permissive_auth = cfg.permissive_auth;
    if (getenv("REALMD_TRACE") != null) {
        bncs.trace_packets = true; // hexdump the BNCS client stream
        d2cs.trace_packets = true; // and the MCP client stream
    }
    if (getenv("REALMD_MODERN_CHALLENGE") != null) bncs.modern_challenge = true; // CheckRevision.mpq+base64 (clientless probe)
    bncs.admin_accounts = cfg.admins;
    bncs.ad_file = cfg.ad_file;
    bncs.ad_url = cfg.ad_url;
    if (cfg.ad_file.len > 0 and cfg.ad_url.len > 0)
        log.line("realmd", "banner ad '{s}' -> {s} (served from {s}/bnftp/)", .{ cfg.ad_file, cfg.ad_url, cfg.data_dir });
    // The realm speaks MCP on the BNCS port: bncs.handle selector-muxes it (0x01 + non-0xFF)
    // onto :6112, exactly as real bnet does. There is no second listener — the client was never
    // told about one, so the only thing the old d2cs port ever served was our own test harness.
    bncs.d2cs_port = cfg.bnet_port;
    if (net.resolve4(cfg.realm_addr)) |ip| {
        bncs.d2cs_ip = ip;
    } else {
        log.line("realmd", "WARNING realm_addr '{s}' did not resolve; advertising 127.0.0.1 to clients", .{cfg.realm_addr});
    }
    if (cfg.gs_addr.len > 0) {
        if (net.resolve4(cfg.gs_addr)) |ip| {
            fleet.gs_ip_override = ip;
        } else {
            log.line("realmd", "WARNING gs_addr '{s}' did not resolve; ignoring", .{cfg.gs_addr});
        }
    }
    // The game-traffic ingress clients dial, and the routes it resolves. Not optional: the token
    // the client is handed is realm-global, so a client sent straight at a game server presents a
    // token that server has never heard of. Refuse to start rather than serve joins that cannot
    // land — the failure would otherwise surface as a game the client connects to and falls out of.
    d2cs.route_ttl_s = cfg.route_ttl_s;
    if (cfg.game_addr.len == 0) {
        log.line("realmd", "FATAL REALMD_GAME_ADDR is required: the address clients dial for game traffic (d2ingress, or realmd's own edge via REALMD_GAME_PORT)", .{});
        return error.GameAddrRequired;
    }
    d2cs.game_ip = net.resolve4(cfg.game_addr) orelse {
        log.line("realmd", "FATAL REALMD_GAME_ADDR '{s}' did not resolve to an IPv4", .{cfg.game_addr});
        return error.GameAddrInvalid;
    };
    log.line("realmd", "game ingress: advertising {s} ({d}.{d}.{d}.{d}):{d} to clients (route ttl {d}s)", .{
        cfg.game_addr,       d2cs.game_ip[0],   d2cs.game_ip[1], d2cs.game_ip[2],
        d2cs.game_ip[3], cfg.ingress_port, cfg.route_ttl_s,
    });

    const bnet_fd = try net.listenTcp(cfg.bind, cfg.bnet_port);
    const health_fd = try net.listenTcp(cfg.bind, cfg.health_port);
    log.line("realmd", "listening on {d} (health {d})", .{ cfg.bnet_port, cfg.health_port });

    // Capture mode hexdumps raw bytes (protocol discovery); otherwise speak it.
    const bnet_handler: net.Handler = if (cfg.capture) net.captureHandler else bncs.handle;

    const t_health = try std.Thread.spawn(.{}, net.serve, .{ "health", health_fd, health.handle });

    // Game servers report what happens on them into the shared store rather than down a socket
    // to whichever instance they connected to. Every instance drains that stream; each event is
    // taken by exactly one of them.
    _ = std.Thread.spawn(.{}, fleet.consumeEvents, .{}) catch |e|
        log.line("realmd", "WARNING game-server event consumer did not start: {s} — the join list will not update", .{@errorName(e)});

    // Chat that reaches members held by another instance, and keeps ours visible to them. Without
    // it a channel is only as big as one replica, and nothing says so — talk just does not arrive.
    _ = std.Thread.spawn(.{}, chat.runInbox, .{}) catch |e|
        log.line("realmd", "WARNING chat inbox did not start: {s} — chat will not cross instances", .{@errorName(e)});

    // Optional embedded game edge: realmd fronts game traffic itself (in-process token
    // splice) instead of a standalone d2ingress — the lightweight single-binary path.
    var t_game: ?std.Thread = null;
    // Moves saved characters from the redis cache to the store of record. Every instance runs
    // one; they need no coordination because a flush reads the current bytes, so duplicated work
    // writes the same save twice rather than the wrong one.
    _ = std.Thread.spawn(.{}, charflush.run, .{}) catch |e|
        log.line("realmd", "WARNING character flush worker did not start: {s} — saves will stay in redis", .{@errorName(e)});

    if (cfg.game_port != 0) {
        const game_fd = try net.listenTcp(cfg.bind, cfg.game_port);
        log.line("realmd", "embedded game edge on {d} (in-process splice; no standalone d2ingress needed)", .{cfg.game_port});
        t_game = try std.Thread.spawn(.{}, net.serve, .{ "game", game_fd, gameedge.handle });
    }

    health.markStarted(); // all listeners bound → probes may go green
    net.serve("bnet", bnet_fd, bnet_handler); // main thread serves clients
    t_health.join();
    if (t_game) |t| t.join();
}
