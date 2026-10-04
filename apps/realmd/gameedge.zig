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
    // GAMELOGON token. This is the client's only greeting: the GS's own is dropped from the
    // splice (see `pump`), as d2ingress does, because a second one reaches the client's
    // handler again and the join never goes on.
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

/// How many leading bytes of the GS's first output are its 0xAF greeting frame: 2 for 0xAF00, else byte[1]+1 (the
/// client's packet demux). 0 when `buf` does not begin with a complete one. The edge has already greeted the client
/// (0xAF00, before the logon could be read), so the engine's own greeting must not reach it: a second one reaches
/// the client's handler again and the join never goes on (d2ingress strips it the same way).
fn greetingStripLen(buf: []const u8) usize {
    if (buf.len < 2 or buf[0] != 0xaf) return 0;
    const n: usize = if (buf[1] == 0) 2 else @as(usize, buf[1]) + 1;
    return if (n <= buf.len) n else 0;
}

test "greetingStripLen: the engine's greeting is dropped, its payload kept" {
    try std.testing.expectEqual(@as(usize, 2), greetingStripLen(&.{ 0xaf, 0x00 }));
    try std.testing.expectEqual(@as(usize, 2), greetingStripLen(&.{ 0xaf, 0x00, 0x01, 0x02 }));
    try std.testing.expectEqual(@as(usize, 0), greetingStripLen(&.{0xaf}));
    try std.testing.expectEqual(@as(usize, 0), greetingStripLen(&.{ 0x01, 0xaf }));
}

const Splice = struct { cli: net.Socket, gs: net.Socket };

fn pump(sp: *Splice, from: net.Socket, to: net.Socket) void {
    var buf: [16384]u8 = undefined;
    var first = from == sp.gs; // the engine's greeting leads its first output only
    while (true) {
        const n = net.readSome(from, &buf);
        if (n == 0) break;
        var off: usize = 0;
        if (first) {
            first = false;
            off = greetingStripLen(buf[0..n]);
        }
        if (off < n and !net.writeAll(to, buf[off..n])) break;
    }
    net.shutdownSocket(sp.cli);
    net.shutdownSocket(sp.gs);
}
