//! D2CS — the realm/character server (port 6113), client-facing side. After
//! bnetd's realm handoff the client connects here, proves who it is with the
//! session bnetd minted (MCP_STARTUP), lists/selects a character, and
//! creates/joins games.
//!
//! Framing: `<len:u16 LE> <id:u8>` where len includes the 3-byte header. The
//! first byte on the socket is a protocol selector (0x01), consumed once.
//!
//! The STARTUP handler resolving a session another listener (bnetd) created is
//! the proof that the front is stateless over shared state — i.e. that a second
//! realmd instance could resolve it too once the session table is a shared Store.
const std = @import("std");
const net = @import("net.zig");
const log = @import("log.zig");
const proto = @import("proto.zig");
const state = @import("state.zig");
const store = @import("store.zig");
const gslink = @import("gslink.zig");

// MCP message ids (subset; everything else is logged).
const MCP_STARTUP = 0x01;
const MCP_CHARCREATE = 0x02;
const MCP_CREATEGAME = 0x03;
const MCP_JOINGAME = 0x04;
const MCP_GAMELIST = 0x05;
const MCP_GAMEINFO = 0x06;
const MCP_CHARLOGON = 0x07;
const MCP_CHARDELETE = 0x0a;
const MCP_MOTD = 0x12;
const MCP_CHARLIST2 = 0x19;

const DConn = struct {
    fd: net.Socket,
    session: u64 = 0,
    account: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    account_len: u8 = 0,
    char: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    char_len: u8 = 0,

    fn setAccount(c: *DConn, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, state.max_name));
        @memcpy(c.account[0..n], name[0..n]);
        c.account_len = n;
    }
    fn accountName(c: *DConn) []const u8 {
        return c.account[0..c.account_len];
    }
    fn setChar(c: *DConn, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, state.max_name));
        @memcpy(c.char[0..n], name[0..n]);
        c.char_len = n;
    }
    fn charName(c: *DConn) []const u8 {
        return c.char[0..c.char_len];
    }
};

fn startPacket(buf: []u8, id: u8) proto.Writer {
    var w = proto.Writer.init(buf);
    w.putU16(0); // length placeholder ([0..2]), back-patched in finish()
    w.putU8(id);
    return w;
}
fn finish(c: *DConn, w: *proto.Writer) void {
    w.patchU16(0, @intCast(w.pos));
    _ = net.writeAll(c.fd, w.slice());
}

pub fn handle(fd: net.Socket, tag: []const u8) void {
    var c = DConn{ .fd = fd };
    log.line(tag, "client connected", .{});

    var acc: [16384]u8 = undefined;
    var len: usize = 0;
    var got_proto = false;

    while (true) {
        const n = net.readSome(fd, acc[len..]);
        if (n == 0) break;
        len += n;

        var off: usize = 0;
        if (!got_proto) {
            if (acc[0] != 0x01) {
                log.line(tag, "unexpected protocol byte 0x{x:0>2}", .{acc[0]});
                return;
            }
            got_proto = true;
            off = 1;
        }
        while (len - off >= 3) {
            const plen = std.mem.readInt(u16, acc[off..][0..2], .little);
            if (plen < 3) {
                log.line(tag, "bad packet length {d}", .{plen});
                return;
            }
            if (len - off < plen) break; // wait for the rest
            dispatch(&c, tag, acc[off + 2], acc[off + 3 .. off + plen]);
            off += plen;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, acc[0 .. len - off], acc[off..len]);
            len -= off;
        }
        if (len == acc.len) {
            log.line(tag, "oversized packet, dropping connection", .{});
            return;
        }
    }
    log.line(tag, "client disconnected ({s})", .{c.accountName()});
}

fn dispatch(c: *DConn, tag: []const u8, id: u8, body: []const u8) void {
    switch (id) {
        MCP_STARTUP => onStartup(c, tag, body),
        MCP_CHARLIST2 => onCharList(c, tag, body),
        MCP_CHARLOGON => onCharLogon(c, tag, body),
        MCP_CHARCREATE => onCharCreate(c, tag, body),
        MCP_CREATEGAME => onCreateGame(c, tag, body),
        MCP_JOINGAME => onJoinGame(c, tag, body),
        MCP_GAMELIST => onGameList(c, tag, body),
        else => {
            log.line(tag, "unhandled MCP 0x{x:0>2} ({d} bytes)", .{ id, body.len });
            if (body.len > 0) log.hexdump(tag, body);
        },
    }
}

fn onStartup(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU32(); // cookie
    _ = r.getU32(); // status
    const lo = r.getU32(); // chunk1[0] = session id low
    const hi = r.getU32(); // chunk1[1] = session id high
    const sid = @as(u64, lo) | (@as(u64, hi) << 32);

    var namebuf: [state.max_name + 1]u8 = undefined;
    var result: u32 = 0x0a; // "unable to identify" until proven
    if (state.global.accountForSession(sid, &namebuf)) |acct| {
        c.session = sid;
        c.setAccount(acct);
        result = 0x00;
        log.line(tag, "startup session={d} -> account={s}", .{ sid, acct });
    } else {
        log.line(tag, "startup session={d} -> UNKNOWN (rejected)", .{sid});
    }

    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, MCP_STARTUP);
    w.putU32(result);
    finish(c, &w);
}

fn onCharList(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const requested: u16 = @truncate(r.getU32());

    var names: [store.max_chars]store.Name = [_]store.Name{.{}} ** store.max_chars;
    const total = store.listChars(c.accountName(), &names);
    const ret: u16 = @intCast(@min(total, requested));
    log.line(tag, "charlist requested={d} (account={s}) -> total={d} returned={d}", .{ requested, c.accountName(), total, ret });

    var buf: [4096]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARLIST2);
    w.putU16(requested); // number requested
    w.putU32(@intCast(total)); // total characters on the account
    w.putU16(ret); // number returned in this packet
    var i: usize = 0;
    while (i < ret) : (i += 1) {
        // Pull class + level from the .d2s (class@0x28, level@0x2b) for the
        // statstring the client renders the list from.
        var save: [1024]u8 = undefined;
        const n = store.getCharD2s(c.accountName(), names[i].slice(), &save);
        const class: u8 = if (n > 0x2b) save[0x28] else 1;
        const level: u8 = if (n > 0x2b) save[0x2b] else 1;

        w.putU32(0xFFFF_FFFF); // expiration — far future so it's NOT "expired"
        w.putStr(names[i].slice()); // character name
        writeStatString(&w, class, level); // CharSel.cpp layout (no null bytes)
        w.putU8(0); // statstring C-string terminator
    }
    finish(c, &w);
}

// 14-bit-encoded int: 7 bits/byte, high bit always set so the value never
// produces a 0x00 byte (the statstring is sent as a C-string).
fn enc14(w: *proto.Writer, v: u32) void {
    w.putU8(@intCast((v & 0x7F) | 0x80));
    w.putU8(@intCast(((v >> 7) & 0x7F) | 0x80));
}

// Character statstring parsed by D2Client CharSel.cpp:
//   [0..2] realm char count, [2..13] equip slot1 (0xFF=none), [13] class
//   (parser subtracts CLASS_SORCERESS=1), [14..25] equip slot2, [25] level,
//   [26..28] flags, [28..30] field9, [30..33] act/fields (0xFF->0), [33..36] guild.
// All bytes are kept non-zero so it survives as a C-string.
fn writeStatString(w: *proto.Writer, class: u8, level: u8) void {
    enc14(w, 1); // realm char count
    var k: usize = 0;
    while (k < 11) : (k += 1) w.putU8(0xFF); // equip slot 1 (none)
    w.putU8(class + 1); // class (CharSel subtracts CLASS_SORCERESS=1)
    k = 0;
    while (k < 11) : (k += 1) w.putU8(0xFF); // equip slot 2 (none)
    w.putU8(if (level == 0) 1 else level); // level (avoid 0)
    enc14(w, 0x04); // character flags: expansion
    enc14(w, 0); // field9
    w.putU8(0xFF); // act      (0xFF -> 0)
    w.putU8(0xFF); // field_0x32f
    w.putU8(0xFF); // field_0x330
    w.putU8(0xFF); // guild tag [0]
    w.putU8(0xFF); // guild tag [1]
    w.putU8(0xFF); // guild tag [2]
}

fn onCharLogon(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const name = r.getStr();
    c.setChar(name); // remember the active char so a later join can name it to the GS
    log.line(tag, "char logon '{s}' (account={s}) -> ok", .{ name, c.accountName() });
    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARLOGON);
    w.putU32(0); // success
    finish(c, &w);
}

fn onCharCreate(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const class = r.getU32();
    const name = r.getStr();
    log.line(tag, "char create '{s}' class={d} (account={s}) -> ok (store TODO)", .{ name, class, c.accountName() });
    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARCREATE);
    w.putU32(0); // success
    finish(c, &w);
}

fn onCreateGame(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    _ = r.getU32(); // difficulty bitfield (TODO: map to GS flags via real capture)
    _ = r.getU8(); // unknown (1)
    _ = r.getU8(); // player difference
    _ = r.getU8(); // max players
    const name = r.getStr();
    const pass = r.getStr();
    const desc = r.getStr();

    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, MCP_CREATEGAME);
    w.putU16(reqid);

    if (!gslink.ready()) {
        log.line(tag, "create game '{s}' -> NO GS available", .{name});
        w.putU16(0); // token
        w.putU16(0); // unknown
        w.putU32(0x06); // result: server down / unavailable
        finish(c, &w);
        return;
    }
    // MVP flags: expansion (LOD), normal difficulty, softcore, non-ladder.
    // The registry picks the least-loaded GS with capacity and gives us its address.
    const routed = gslink.createGameRouted(name, pass, desc, 0, true, 0, false);
    if (routed == null) {
        log.line(tag, "create game '{s}' -> GS refused / all full", .{name});
        w.putU16(0);
        w.putU16(0);
        w.putU32(0x1e); // result: a game with that name failed
        finish(c, &w);
        return;
    }
    const rr = routed.?;
    _ = state.global.registerGame(name, rr.gameid, rr.ip, rr.port, rr.gsid);
    log.line(tag, "create game '{s}' (account={s}) -> gameid={d} gs=0x{x}@{d}.{d}.{d}.{d}:{d}", .{ name, c.accountName(), rr.gameid, rr.gsid, rr.ip[0], rr.ip[1], rr.ip[2], rr.ip[3], rr.port });
    w.putU16(@truncate(rr.gameid)); // game token (client passes to the GS)
    w.putU16(0); // unknown
    w.putU32(0); // result: success
    finish(c, &w);
}

fn onJoinGame(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    const name = r.getStr();
    _ = r.getStr(); // password

    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, MCP_JOINGAME);
    w.putU16(reqid);

    const game = state.global.findGame(name);
    if (game == null) {
        log.line(tag, "join game '{s}' -> not found", .{name});
        w.putU16(0); // token
        w.putU16(0); // unknown
        w.putU32(0); // d2gs IP
        w.putU32(0); // game hash
        w.putU32(0x29); // result: game does not exist
        finish(c, &w);
        return;
    }
    const g = game.?;
    // The client connects to the GS directly using the IP in the game record, so
    // any realmd instance can serve a join. Best-effort notify the GS that owns this
    // game (by its fleet id) so it can prefetch the joining account's character.
    if (g.gsid != 0) _ = gslink.notifyJoin(g.gsid, g.gameid, g.gameid, c.charName(), c.accountName());
    log.line(tag, "join game '{s}' (account={s}) gameid={d} gs={d}.{d}.{d}.{d}", .{ name, c.accountName(), g.gameid, g.gs_ip[0], g.gs_ip[1], g.gs_ip[2], g.gs_ip[3] });
    w.putU16(@truncate(g.gameid)); // game token
    w.putU16(0); // unknown
    w.putBytes(&g.gs_ip); // d2gs IP (in_addr, network order)
    w.putU32(0); // game hash
    w.putU32(0); // result: success
    finish(c, &w);
}

fn onGameList(c: *DConn, tag: []const u8, body: []const u8) void {
    _ = body;
    log.line(tag, "game list -> empty", .{});
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, MCP_GAMELIST);
    w.putU16(0); // request id
    w.putU32(0); // index
    w.putU8(0); // count
    finish(c, &w);
}
