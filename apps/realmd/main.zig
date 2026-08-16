//! realmd — a clean-room Battle.net / D2 realm server in Zig.
//!
//! Replaces pvpgn (bnetd + d2cs + d2dbs) with a single binary: three TCP
//! listeners over shared in-memory state, durable state behind a Store seam so
//! it survives restarts and can scale to multiple instances on a shared backend.
//!
//! It is the realm the unmodified 1.14d client connects to, and it dispatches
//! games to our injected d2gs (Game.exe) over the same d2cs<->d2gs protocol the
//! GS already speaks.
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
const d2cs = @import("d2cs.zig");
const d2dbs = @import("d2dbs.zig");
const gslink = @import("gslink.zig");
const gameedge = @import("gameedge.zig");
const charflush = @import("charflush.zig");
const store = @import("store.zig");
const state = @import("state.zig");
const health = @import("health.zig");
const admin = @import("admin.zig");
const shutdown = @import("shutdown.zig");
const xsha1 = @import("libd2").bnet.xsha1;

fn mapBackend(b: config.Backend) store.Backend {
    return switch (b) {
        .fs => .fs,
        .redis => .redis,
        .pg => .pg,
    };
}

fn hashStr(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

fn parseIp4(text: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) octets else null;
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
        .durable = mapBackend(cfg.durable_store),
        .ephemeral = mapBackend(cfg.ephemeral_store),
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
    log.line("realmd", "starting instance={s} bind={s} bnet={d} d2dbs={d} realm={s}@{s} capture={}", .{
        cfg.instance_id, cfg.bind,       cfg.bnet_port,
        cfg.d2dbs_port,  cfg.realm_name, cfg.realm_addr, cfg.capture,
    });
    // Graceful shutdown for k8s rolling updates + readiness gating.
    health.require_gs = cfg.require_gs;
    // Admin API + web UI (served on the health port under /admin/*). Enabled by any of:
    // bearer token (scripts/break-glass), account login (REALMD_ADMINS), or SSO header.
    admin.token = cfg.admin_token;
    admin.instance = cfg.instance_id;
    admin.durable = @tagName(cfg.durable_store);
    admin.ephemeral = @tagName(cfg.ephemeral_store);
    admin.admins = cfg.admins;
    admin.trusted_header = cfg.trusted_auth_header;
    admin.initSigning(cfg.admin_secret);
    if ((cfg.admins.len > 0 or cfg.admin_bootstrap.len > 0) and cfg.admin_secret.len == 0)
        log.line("realmd", "WARNING REALMD_ADMIN_SECRET unset; web-UI sessions use a per-process key (break on restart, not multi-instance)", .{});
    shutdown.install(cfg.shutdown_grace_ms);

    // bnetd advertises the d2cs address to the client. realm_addr must be an
    // IPv4 the client can dial (127.0.0.1 in dev, the public IP in prod).
    var threaded = std.Io.Threaded.init_single_threaded;
    store.init(.{
        .io = threaded.io(),
        .data_dir = cfg.data_dir,
        .durable = mapBackend(cfg.durable_store),
        .ephemeral = mapBackend(cfg.ephemeral_store),
        .redis_addr = cfg.redis_addr,
        .pg_dsn = cfg.pg_dsn,
    });
    log.line("realmd", "store: durable={s} ephemeral={s}", .{ @tagName(cfg.durable_store), @tagName(cfg.ephemeral_store) });
    // Redis is not one backend among several any more — it is where the realm's shared truth
    // lives. Characters, the seat each one holds, game tokens and the fleet all coordinate
    // through it, and every one of those fails in a way that reads as a game bug rather than a
    // missing dependency. So it is checked here, once, and named.
    //
    // The DURABLE store stays a choice: pg for a deployment, fs for a single host. Neither is
    // load-bearing for coordination, and requiring postgres would only make local iteration
    // slower for nothing.
    if (cfg.ephemeral_store != .redis) {
        log.line("realmd", "FATAL REALMD_EPHEMERAL_STORE must be redis (got {s}): the realm coordinates through it", .{@tagName(cfg.ephemeral_store)});
        return error.RedisRequired;
    }
    if (!store.ephemeralReachable()) {
        log.line("realmd", "FATAL redis at '{s}' did not answer", .{cfg.redis_addr});
        return error.RedisUnreachable;
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
    // A redis/pg ephemeral backend IS an external shared store — route sessions/games
    // through it even without REALMD_SHARED (the in-memory table is fs-only).
    state.shared = cfg.shared or cfg.ephemeral_store != .fs;
    state.instance_hash = hashStr(cfg.instance_id);
    if (cfg.shared) log.line("realmd", "multi-instance mode: sessions/games in shared store {s} (instance hash 0x{x})", .{ cfg.data_dir, state.instance_hash });
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
    gslink.realm_name = cfg.realm_name;
    if (parseIp4(cfg.realm_addr)) |ip| {
        bncs.d2cs_ip = ip;
    } else {
        log.line("realmd", "WARNING realm_addr '{s}' is not an IPv4; advertising 127.0.0.1 to clients", .{cfg.realm_addr});
    }
    if (cfg.gs_addr.len > 0) {
        if (parseIp4(cfg.gs_addr)) |ip| {
            gslink.gs_ip_override = ip;
        } else {
            log.line("realmd", "WARNING gs_addr '{s}' is not an IPv4; ignoring", .{cfg.gs_addr});
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
    d2cs.game_ip = parseIp4(cfg.game_addr) orelse {
        log.line("realmd", "FATAL REALMD_GAME_ADDR '{s}' is not an IPv4", .{cfg.game_addr});
        return error.GameAddrInvalid;
    };
    log.line("realmd", "game ingress: advertising {s}:{d} to clients (route ttl {d}s)", .{ cfg.game_addr, cfg.ingress_port, cfg.route_ttl_s });

    const bnet_fd = try net.listenTcp(cfg.bind, cfg.bnet_port);
    const d2dbs_fd = try net.listenTcp(cfg.bind, cfg.d2dbs_port);
    const gs_fd = try net.listenTcp(cfg.bind, cfg.gs_port);
    const health_fd = try net.listenTcp(cfg.bind, cfg.health_port);
    log.line("realmd", "listening on {d}/{d} (gs link {d}, health {d})", .{ cfg.bnet_port, cfg.d2dbs_port, cfg.gs_port, cfg.health_port });

    // Capture mode hexdumps raw bytes (protocol discovery); otherwise speak it.
    const bnet_handler: net.Handler = if (cfg.capture) net.captureHandler else bncs.handle;
    const d2dbs_handler: net.Handler = if (cfg.capture) net.captureHandler else d2dbs.handle;
    const gs_handler: net.Handler = if (cfg.capture) net.captureHandler else gslink.handle;

    const t_bnet = try std.Thread.spawn(.{}, net.serve, .{ "bnet", bnet_fd, bnet_handler });
    const t_dbs = try std.Thread.spawn(.{}, net.serve, .{ "d2dbs", d2dbs_fd, d2dbs_handler });
    const t_health = try std.Thread.spawn(.{}, net.serve, .{ "health", health_fd, health.handle });

    // Optional embedded game edge: realmd fronts game traffic itself (in-process token
    // splice) instead of a standalone d2ingress — the lightweight single-binary path.
    var t_game: ?std.Thread = null;
    // Moves saved characters from the redis cache to the store of record. Every instance runs
    // one; they need no coordination because a flush reads the current bytes, so duplicated work
    // writes the same save twice rather than the wrong one.
    if (cfg.ephemeral_store == .redis and cfg.durable_store != .redis) {
        _ = std.Thread.spawn(.{}, charflush.run, .{}) catch |e|
            log.line("realmd", "WARNING character flush worker did not start: {s} — saves will stay in redis", .{@errorName(e)});
    }

    if (cfg.game_port != 0) {
        const game_fd = try net.listenTcp(cfg.bind, cfg.game_port);
        log.line("realmd", "embedded game edge on {d} (in-process splice; no standalone d2ingress needed)", .{cfg.game_port});
        t_game = try std.Thread.spawn(.{}, net.serve, .{ "game", game_fd, gameedge.handle });
    }

    health.markStarted(); // all listeners bound → probes may go green
    net.serve("gs", gs_fd, gs_handler); // main thread runs the GS link listener
    t_bnet.join();
    t_dbs.join();
    t_health.join();
    if (t_game) |t| t.join();
}
