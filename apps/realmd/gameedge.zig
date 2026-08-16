//! Embedded game-traffic edge — the lightweight, in-realmd version of d2ingress.
//!
//! Clients dial one public :4000; we speak `0xAF00` for the not-yet-dialled GS, read the
//! GAMELOGON (0x68) token, look up {gs_ip,gs_port,gameid} in the in-process store (no redis
//! hop), rewrite the token to the GS's real engine gameid, dial the GS, replay the first
//! packet, then splice both directions. Thread-per-connection fits the single-binary path;
//! enable with REALMD_GAME_PORT (0=off). d2cs records the token-route on CREATE/JOIN, shared
//! with d2ingress — only the splice is duplicated here.
const std = @import("std");
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const store = @import("store.zig");

const GAMELOGON_ID: u8 = 0x68;
// Raw-wire layout: nId(u8,=0x68) ++ nGameHash(u32) ++ nGameToken(u16) ++ ... → token@5.
const TOKEN_OFFSET: usize = 5;
const MIN_LOGON_BYTES: usize = TOKEN_OFFSET + 2;

pub fn handle(fd: net.Socket, tag: []const u8) void {
    // Speak 0xAF00 (ack-only) for the GS we haven't dialled yet — the client needs a
    // connection-established packet to advance, but we can't route until we read its
    // GAMELOGON token. The GS's own 0xAF01 (relayed once spliced) does the real flip
    // to the compressed game phase; sending 0xAF00 here keeps the client in the raw
    // handshake phase so that switch isn't duplicated/desynced.
    if (!net.writeAll(fd, &[_]u8{ 0xaf, 0x00 })) return;

    // Accumulate the client's first packet until the GAMELOGON token is readable.
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (len < MIN_LOGON_BYTES) {
        const n = net.readSome(fd, buf[len..]);
        if (n == 0) return;
        len += n;
    }
    if (buf[0] != GAMELOGON_ID) {
        log.line(tag, "game edge: first byte 0x{x:0>2} != GAMELOGON (0x68), dropping", .{buf[0]});
        return;
    }
    const token = std.mem.readInt(u16, buf[TOKEN_OFFSET..][0..2], .little);
    const route = store.lookupTokenRoute(token) orelse {
        log.line(tag, "game edge: no route for token {d} (expired/unknown), dropping", .{token});
        return;
    };
    // Rewrite the realm-minted token to the GS's real engine gameid (truncate u32→u16).
    std.mem.writeInt(u16, buf[TOKEN_OFFSET..][0..2], @truncate(route.gameid), .little);

    // Dial the owning GS (internal address) and replay the rewritten first packet.
    var ipbuf: [16]u8 = undefined;
    const ipz = std.fmt.bufPrintZ(&ipbuf, "{d}.{d}.{d}.{d}", .{
        route.gs_ip[0], route.gs_ip[1], route.gs_ip[2], route.gs_ip[3],
    }) catch return;
    const gs = net.connectTcp(ipz, route.gs_port) catch {
        log.line(tag, "game edge: dial GS {s}:{d} failed", .{ ipz, route.gs_port });
        return;
    };
    defer net.closeSocket(gs);
    if (!net.writeAll(gs, buf[0..len])) return;
    log.line(tag, "game edge: token {d} -> GS {s}:{d} gameid {d}, splicing", .{ token, ipz, route.gs_port, route.gameid });

    // Bidirectional splice: a thread pumps GS→client; this thread pumps client→GS. On
    // either side's EOF the pump shuts BOTH fds down so the partner unblocks and returns.
    var sp = Splice{ .cli = fd, .gs = gs };
    const t = std.Thread.spawn(.{}, pump, .{ &sp, gs, fd }) catch return;
    pump(&sp, fd, gs);
    t.join();
}

const Splice = struct { cli: net.Socket, gs: net.Socket };

fn pump(sp: *Splice, from: net.Socket, to: net.Socket) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = net.readSome(from, &buf);
        if (n == 0) break;
        if (!net.writeAll(to, buf[0..n])) break;
    }
    net.shutdownSocket(sp.cli);
    net.shutdownSocket(sp.gs);
}
