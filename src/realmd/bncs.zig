//! BNCS — the Battle.net chat server (bnetd, port 6112). The unmodified 1.14d
//! client logs in here, then asks for the realm list and does the realm logon
//! handoff to d2cs.
//!
//! MVP policy: we are the authority and we trust the client — version/checksum
//! (SID_AUTH_CHECK) and password (SID_LOGONRESPONSE2) are ACCEPTED unconditionally,
//! accounts auto-create on first logon. Real verification (X-SHA-1, version MPQ)
//! is a later hardening pass; "just works" first.
//!
//! Framing: each packet is `FF <id:u8> <len:u16 LE>` where len includes the
//! 4-byte header. The very first byte on the socket is a protocol selector
//! (0x01 = game/BNCS), consumed once.
const std = @import("std");
const net = @import("net.zig");
const log = @import("log.zig");
const proto = @import("proto.zig");
const protocol = @import("protocol.zig");
const state = @import("state.zig");
const bnftp = @import("bnftp.zig");

// Set by main() before serving.
pub var realm_name: []const u8 = "TypeGuru";
pub var realm_desc: []const u8 = "D2 Closed Realm";
pub var d2cs_ip: [4]u8 = .{ 127, 0, 0, 1 };
pub var d2cs_port: u16 = 6113;

// BNCS message ids (subset we handle; everything else is logged).
const SID_NULL = 0x00;
const SID_ENTERCHAT = 0x0a;
const SID_GETCHANNELLIST = 0x0b;

comptime {
    // Keep the protocol-constants module (chat flags, D2GS message IDs) compiled
    // and type-checked with the server even though nothing dispatches on them yet.
    _ = protocol.ChatUserFlag;
    _ = protocol.ChatChannelFlag;
    _ = protocol.D2gsMsg;
    _ = protocol.has;
}
const SID_JOINCHANNEL = 0x0c;
const SID_CHATCOMMAND = 0x0e;
const SID_GETFILETIME = 0x33;
const SID_PING = 0x25;
const SID_LOGONRESPONSE2 = 0x3a;
const SID_CREATEACCOUNT2 = 0x3d;
const SID_LOGONREALMEX = 0x3e;
const SID_QUERYREALMS2 = 0x40;
const SID_NETGAMEPORT = 0x45;
const SID_AUTH_INFO = 0x50;
const SID_AUTH_CHECK = 0x51;

// Token generator. These tokens aren't security-relevant (we don't verify
// them), they just need to be distinct per connection. A counter stepped by an
// odd constant gives a full-period non-repeating sequence.
var token_ctr = std.atomic.Value(u32).init(0x1234abcd);
fn nextToken() u32 {
    return token_ctr.fetchAdd(0x9e3779b1, .monotonic);
}

const Conn = struct {
    fd: net.Socket,
    server_token: u32,
    client_token: u32 = 0,
    account: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    account_len: u8 = 0,

    fn setAccount(c: *Conn, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, state.max_name));
        @memcpy(c.account[0..n], name[0..n]);
        c.account_len = n;
    }
    fn accountName(c: *Conn) []const u8 {
        return c.account[0..c.account_len];
    }
};

fn startPacket(buf: []u8, id: u8) proto.Writer {
    var w = proto.Writer.init(buf);
    w.putU8(0xff);
    w.putU8(id);
    w.putU16(0); // length placeholder, back-patched in finish()
    return w;
}
fn finish(c: *Conn, w: *proto.Writer) void {
    w.patchU16(2, @intCast(w.pos));
    _ = net.writeAll(c.fd, w.slice());
}

pub fn handle(fd: net.Socket, tag: []const u8) void {
    var c = Conn{ .fd = fd, .server_token = nextToken() };
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
            if (acc[0] == 0x02) { // BNFTP file transfer (version-check MPQ)
                bnftp.handle(fd, tag, acc[1..len]);
                return;
            }
            if (acc[0] != 0x01) {
                log.line(tag, "unexpected protocol byte 0x{x:0>2}", .{acc[0]});
                return;
            }
            got_proto = true;
            off = 1;
        }
        while (len - off >= 4) {
            if (acc[off] != 0xff) {
                log.line(tag, "desync: expected 0xff", .{});
                return;
            }
            const plen = std.mem.readInt(u16, acc[off + 2 ..][0..2], .little);
            if (plen < 4) {
                log.line(tag, "bad packet length {d}", .{plen});
                return;
            }
            if (len - off < plen) break; // wait for the rest
            dispatch(&c, tag, acc[off + 1], acc[off + 4 .. off + plen]);
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

fn dispatch(c: *Conn, tag: []const u8, id: u8, body: []const u8) void {
    switch (id) {
        SID_NULL => {}, // keepalive
        SID_AUTH_INFO => onAuthInfo(c, tag, body),
        SID_AUTH_CHECK => onAuthCheck(c, tag),
        SID_LOGONRESPONSE2 => onLogon(c, tag, body),
        SID_CREATEACCOUNT2 => onCreateAccount(c, tag, body),
        SID_ENTERCHAT => onEnterChat(c, tag, body),
        SID_GETCHANNELLIST => onGetChannelList(c),
        SID_JOINCHANNEL => log.line(tag, "join channel (ignored)", .{}),
        SID_QUERYREALMS2 => onQueryRealms(c, tag),
        SID_LOGONREALMEX => onLogonRealm(c, tag, body),
        SID_GETFILETIME => onGetFileTime(c, tag, body),
        SID_PING => onPing(c, body),
        SID_NETGAMEPORT => {},
        else => {
            log.line(tag, "unhandled SID 0x{x:0>2} ({d} bytes)", .{ id, body.len });
            if (body.len > 0) log.hexdump(tag, body);
        },
    }
}

fn onAuthInfo(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU32(); // protocol id
    _ = r.getU32(); // platform ("IX86")
    const product = r.getU32(); // "D2DV" / "D2XP"
    var pc: [4]u8 = @bitCast(product);
    log.line(tag, "auth_info product={s}", .{&pc});

    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, SID_AUTH_INFO);
    w.putU32(0); // logon type 0 (OLS) — password not verified
    w.putU32(c.server_token);
    w.putU32(0); // UDP value
    w.putU64(0); // MPQ filetime
    w.putStr("ver-IX86-1.mpq"); // version-check MPQ name (client BNFTP-fetches it)
    w.putStr("A=1 B=1 C=1 4 A=A^S B=B^C C=C^A A=A^B"); // checksum formula (ignored)
    finish(c, &w);
}

fn onAuthCheck(c: *Conn, tag: []const u8) void {
    log.line(tag, "auth_check -> passed", .{});
    var buf: [64]u8 = undefined;
    var w = startPacket(&buf, SID_AUTH_CHECK);
    w.putU32(0x000); // passed
    w.putStr(""); // extra info (only meaningful on failure)
    finish(c, &w);
}

fn onLogon(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    c.client_token = r.getU32();
    _ = r.getU32(); // server token echo
    r.skip(20); // double-hashed password (not verified)
    c.setAccount(r.getStr());
    log.line(tag, "logon account={s} -> ok", .{c.accountName()});

    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_LOGONRESPONSE2);
    w.putU32(0); // success
    finish(c, &w);
}

fn onCreateAccount(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    r.skip(20); // password hash
    c.setAccount(r.getStr());
    log.line(tag, "create account={s} -> ok", .{c.accountName()});

    var buf: [64]u8 = undefined;
    var w = startPacket(&buf, SID_CREATEACCOUNT2);
    w.putU32(0); // success
    w.putStr(""); // name suggestion (on failure)
    finish(c, &w);
}

fn onEnterChat(c: *Conn, tag: []const u8, body: []const u8) void {
    _ = body;
    const acct = c.accountName();
    log.line(tag, "enter chat as {s}", .{acct});
    var buf: [128]u8 = undefined;
    var w = startPacket(&buf, SID_ENTERCHAT);
    w.putStr(acct); // unique name
    w.putStr(""); // statstring
    w.putStr(acct); // account name
    finish(c, &w);
    // NOTE: do not push a SID_CHATEVENT here. The D2 realm lobby is not a chat
    // channel and an unsolicited channel-join event corrupts its control state
    // (crash in D2WINMAIN_SetControlDisabled). Chat-flag enums live in protocol.zig.
}

fn onGetChannelList(c: *Conn) void {
    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, SID_GETCHANNELLIST);
    w.putStr(""); // empty list terminator
    finish(c, &w);
}

fn onQueryRealms(c: *Conn, tag: []const u8) void {
    log.line(tag, "query realms -> {s}", .{realm_name});
    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, SID_QUERYREALMS2);
    w.putU32(0); // unknown
    w.putU32(1); // realm count
    w.putU32(1); // unknown (per realm)
    w.putStr(realm_name);
    w.putStr(realm_desc);
    finish(c, &w);
}

fn onLogonRealm(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    c.client_token = r.getU32();
    r.skip(20); // hashed realm password (not verified)
    const title = r.getStr();

    const acct = c.accountName();
    const sid = state.global.createSession(acct);
    const cookie = nextToken();
    log.line(tag, "realm logon account={s} realm={s} session={d}", .{ acct, title, sid });

    // MCP startup chunk: cookie, status, chunk1[2]=session id, IP, Port,
    // chunk2[12]. The client forwards cookie+status+chunk1+chunk2 (NOT IP/Port)
    // to d2cs as MCP_STARTUP; d2cs reads the session id from chunk1.
    var buf: [128]u8 = undefined;
    var w = startPacket(&buf, SID_LOGONREALMEX);
    w.putU32(cookie); // MCP cookie
    w.putU32(0); // MCP status = success
    w.putU32(@truncate(sid)); // chunk1[0] = session id low
    w.putU32(@truncate(sid >> 32)); // chunk1[1] = session id high
    w.putBytes(&d2cs_ip); // d2cs IP (in_addr, network order)
    w.putU16(std.mem.nativeToBig(u16, d2cs_port)); // d2cs port (network order)...
    w.putU16(0); // ...zero-extended to UINT32
    w.zeros(48); // chunk2[12]
    w.putStr(acct); // bnet unique name
    finish(c, &w);
}

// SID_GETFILETIME (0x33): client asks for a server file's timestamp (e.g.
// bnserver-D2DV.ini) before deciding to BNFTP-download it. Replying filetime 0
// tells the client we have no such file, so it proceeds without downloading.
fn onGetFileTime(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU32();
    const unknown = r.getU32();
    const fname = r.getStr();
    log.line(tag, "getfiletime '{s}' -> none", .{fname});
    var buf: [128]u8 = undefined;
    var w = startPacket(&buf, SID_GETFILETIME);
    w.putU32(reqid);
    w.putU32(unknown);
    w.putU64(0); // filetime 0 = not available
    w.putStr(fname);
    finish(c, &w);
}

fn onPing(c: *Conn, body: []const u8) void {
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_PING);
    w.putBytes(body); // echo the cookie back
    finish(c, &w);
}
