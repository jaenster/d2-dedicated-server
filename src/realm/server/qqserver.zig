//! qqserver — the cloud-native game-traffic gateway, a "QServer of QServers" fronting
//! the GS fleet. Clients connect to ONE public address for game traffic (:4000); the
//! qqserver looks up which backend GS owns that client and splices the TCP connection
//! to it. It is the network edge: realmd handles the realm/MCP handshake and, on
//! JOINGAME, records {client source IP → GS internal addr} in the shared store; the
//! qqserver then forwards by the connecting socket's PEER IP — no packet parsing, no
//! protocol knowledge, pure byte splice.
//!
//! Routing is SOURCE-IP based. Caveat: if two clients share one public IP (carrier
//! NAT / same office) and join different GS within the route TTL, the second join
//! overwrites the first's route — both would splice to the same GS. The future
//! hardening is to peek the join token in the first bytes and route on that; for the
//! current fleet (one GS per game, distinct clients) source-IP routing is correct and
//! keeps the data path dumb and fast.
const std = @import("std");
const config = @import("config.zig");
const net = @import("net.zig");
const log = @import("log.zig");
const store = @import("store.zig");

fn mapBackend(b: config.Backend) store.Backend {
    return switch (b) {
        .fs => .fs,
        .redis => .redis,
        .pg => .pg,
    };
}

pub fn main() !void {
    const cfg = config.fromEnv();
    log.json = cfg.log_json;

    // SAME store config as realmd (main.zig) so the qqserver reads the routes realmd
    // recorded — over the same fs data dir / redis / pg.
    var threaded = std.Io.Threaded.init_single_threaded;
    store.init(.{
        .io = threaded.io(),
        .data_dir = cfg.data_dir,
        .durable = mapBackend(cfg.durable_store),
        .ephemeral = mapBackend(cfg.ephemeral_store),
        .redis_addr = cfg.redis_addr,
        .pg_dsn = cfg.pg_dsn,
    });

    const fd = try net.listenTcp(cfg.bind, cfg.qq_port);
    log.line("qq", "qqserver listening on {s}:{d} (store ephemeral={s})", .{ cfg.bind, cfg.qq_port, @tagName(cfg.ephemeral_store) });
    net.serve("qq", fd, handle);
}

/// One client game connection: resolve its backend by source IP, dial that GS, and
/// splice bytes both ways until either side closes.
fn handle(fd: net.Socket, tag: []const u8) void {
    const peer = net.peerIp(fd);
    const route = store.lookupRoute(peer) orelse {
        log.line(tag, "no route for {d}.{d}.{d}.{d} — dropping", .{ peer[0], peer[1], peer[2], peer[3] });
        return;
    };

    var hostbuf: [16]u8 = undefined;
    const host = std.fmt.bufPrintZ(&hostbuf, "{d}.{d}.{d}.{d}", .{ route.gs_ip[0], route.gs_ip[1], route.gs_ip[2], route.gs_ip[3] }) catch return;
    const up = net.connectTcp(host, route.gs_port) catch {
        log.line(tag, "{d}.{d}.{d}.{d} -> GS {s}:{d} connect failed", .{ peer[0], peer[1], peer[2], peer[3], host, route.gs_port });
        return;
    };
    // `up` is closed exactly once, here, after both pumps have finished. The client
    // `fd` is closed by net.serve's connThread after handle() returns.
    defer net.closeSocket(up);
    log.line(tag, "{d}.{d}.{d}.{d} -> GS {s}:{d} spliced", .{ peer[0], peer[1], peer[2], peer[3], host, route.gs_port });

    // Splice: a thread copies GS->client, this thread copies client->GS. Whichever
    // direction EOFs first shuts down BOTH sockets (half-close each end) so the other
    // pump's blocking read returns and its thread exits — then we join it.
    var pair = Pair{ .a = fd, .b = up };
    const t = std.Thread.spawn(.{}, pumpThread, .{&pair}) catch {
        pipe(up, fd); // no thread: at least drain GS->client
        return;
    };
    pipe(fd, up); // client -> GS
    shutdownBoth(&pair);
    t.join();
}

const Pair = struct { a: net.Socket, b: net.Socket };

/// Half-close both ends (SHUT_RDWR) so a blocked read on either returns 0 and its pump
/// exits. Idempotent and fd-number safe (unlike close, which could be reused).
fn shutdownBoth(p: *Pair) void {
    net.shutdownSocket(p.a);
    net.shutdownSocket(p.b);
}

/// GS -> client direction (runs on the spawned thread). On EOF it shuts down both ends
/// so the client->GS pump on the main thread unblocks.
fn pumpThread(p: *Pair) void {
    pipe(p.b, p.a);
    shutdownBoth(p);
}

/// Copy bytes from src to dst until src EOFs or a write fails.
fn pipe(src: net.Socket, dst: net.Socket) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = net.readSome(src, &buf);
        if (n == 0) break;
        if (!net.writeAll(dst, buf[0..n])) break;
    }
}
