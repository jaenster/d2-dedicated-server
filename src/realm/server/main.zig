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
const config = @import("config.zig");
const net = @import("net.zig");
const log = @import("log.zig");
const bncs = @import("bncs.zig");
const d2cs = @import("d2cs.zig");
const d2dbs = @import("d2dbs.zig");
const gslink = @import("gslink.zig");
const store = @import("store.zig");
const state = @import("state.zig");
const health = @import("health.zig");
const shutdown = @import("shutdown.zig");

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

pub fn main() !void {
    const cfg = config.fromEnv();
    log.json = cfg.log_json;
    log.line("realmd", "starting instance={s} bind={s} bnet={d} d2cs={d} d2dbs={d} realm={s}@{s} capture={}", .{
        cfg.instance_id, cfg.bind,       cfg.bnet_port,  cfg.d2cs_port,
        cfg.d2dbs_port,  cfg.realm_name, cfg.realm_addr, cfg.capture,
    });
    // Graceful shutdown for k8s rolling updates + readiness gating.
    health.require_gs = cfg.require_gs;
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
    // A redis/pg ephemeral backend IS an external shared store — route sessions/games
    // through it even without REALMD_SHARED (the in-memory table is fs-only).
    state.shared = cfg.shared or cfg.ephemeral_store != .fs;
    state.instance_hash = hashStr(cfg.instance_id);
    if (cfg.shared) log.line("realmd", "multi-instance mode: sessions/games in shared store {s} (instance hash 0x{x})", .{ cfg.data_dir, state.instance_hash });
    bncs.realm_name = cfg.realm_name;
    bncs.d2cs_port = cfg.d2cs_port;
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

    const bnet_fd = try net.listenTcp(cfg.bind, cfg.bnet_port);
    const d2cs_fd = try net.listenTcp(cfg.bind, cfg.d2cs_port);
    const d2dbs_fd = try net.listenTcp(cfg.bind, cfg.d2dbs_port);
    const gs_fd = try net.listenTcp(cfg.bind, cfg.gs_port);
    const health_fd = try net.listenTcp(cfg.bind, cfg.health_port);
    log.line("realmd", "listening on {d}/{d}/{d} (gs link {d}, health {d})", .{ cfg.bnet_port, cfg.d2cs_port, cfg.d2dbs_port, cfg.gs_port, cfg.health_port });

    // Capture mode hexdumps raw bytes (protocol discovery); otherwise speak it.
    const bnet_handler: net.Handler = if (cfg.capture) net.captureHandler else bncs.handle;
    const d2cs_handler: net.Handler = if (cfg.capture) net.captureHandler else d2cs.handle;
    const d2dbs_handler: net.Handler = if (cfg.capture) net.captureHandler else d2dbs.handle;
    const gs_handler: net.Handler = if (cfg.capture) net.captureHandler else gslink.handle;

    const t_bnet = try std.Thread.spawn(.{}, net.serve, .{ "bnet", bnet_fd, bnet_handler });
    const t_d2cs = try std.Thread.spawn(.{}, net.serve, .{ "d2cs", d2cs_fd, d2cs_handler });
    const t_dbs = try std.Thread.spawn(.{}, net.serve, .{ "d2dbs", d2dbs_fd, d2dbs_handler });
    const t_health = try std.Thread.spawn(.{}, net.serve, .{ "health", health_fd, health.handle });
    health.markStarted(); // all listeners bound → probes may go green
    net.serve("gs", gs_fd, gs_handler); // main thread runs the GS link listener
    t_bnet.join();
    t_d2cs.join();
    t_dbs.join();
    t_health.join();
}
