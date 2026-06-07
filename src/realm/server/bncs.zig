//! BNCS — the Battle.net chat server (bnetd, port 6112). The unmodified 1.14d
//! client logs in here, then asks for the realm list and does the realm logon
//! handoff to d2cs.
//!
//! Auth policy: version/checksum (SID_AUTH_CHECK) is still ACCEPTED (version MPQ
//! verification is a later pass), but passwords are now REAL via Battle.net OLS
//! (xSHA-1, see xsha1.zig). SID_CREATEACCOUNT2 stores xsha1(password); on
//! SID_LOGONRESPONSE2 an unknown account auto-registers PASSWORD-LESS (back-compat
//! for the bare-login path) and a password-protected account is verified by the
//! OLS double-hash and rejected on mismatch.
//!
//! Framing: each packet is `FF <id:u8> <len:u16 LE>` where len includes the
//! 4-byte header. The very first byte on the socket is a protocol selector
//! (0x01 = game/BNCS), consumed once.
const std = @import("std");
const net = @import("net.zig");
const log = @import("log.zig");
const proto = @import("proto.zig");
const protocol = @import("bncs_protocol.zig");
const state = @import("state.zig");
const bnftp = @import("bnftp.zig");
const chat = @import("chat.zig");
const store = @import("store.zig");
const xsha1 = @import("xsha1.zig");

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
const SID_CHATEVENT = 0x0f;
const SID_CHATCOMMAND = 0x0e;

// SID_CHATEVENT event ids (S->C).
const EID_SHOWUSER = 0x01;
const EID_JOIN = 0x02;
const EID_LEAVE = 0x03;
const EID_WHISPER = 0x04;
const EID_TALK = 0x05;
const EID_CHANNEL = 0x07;
const EID_INFO = 0x12;
const EID_ERROR = 0x13;

const default_channel = "Diablo II";
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
    in_channel: bool = false,
    channel: [chat.max_channel]u8 = [_]u8{0} ** chat.max_channel,
    channel_len: u8 = 0,

    fn setChannel(c: *Conn, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, chat.max_channel));
        @memcpy(c.channel[0..n], name[0..n]);
        c.channel_len = n;
        c.in_channel = true;
    }
    fn channelName(c: *Conn) []const u8 {
        return c.channel[0..c.channel_len];
    }

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
    // If this connection was in a chat channel, leave it and tell the others.
    if (c.in_channel) {
        chat.leave(fd);
        broadcastEvent(&c, EID_LEAVE, c.accountName(), "");
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
        SID_JOINCHANNEL => onJoinChannel(c, tag, body),
        SID_CHATCOMMAND => onChatCommand(c, tag, body),
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

// SID_LOGONRESPONSE2 results.
const LOGON_OK: u32 = 0;
const LOGON_BAD_PASSWORD: u32 = 2;

fn onLogon(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    c.client_token = r.getU32();
    const server_token = r.getU32(); // client echoes the token we sent
    var got: [20]u8 = undefined;
    @memcpy(&got, r.take20());
    const acct = r.getStr();
    c.setAccount(acct);

    const result = logonResult(c, server_token, got);
    log.line(tag, "logon account={s} -> result={d}", .{ acct, result });

    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_LOGONRESPONSE2);
    w.putU32(result);
    finish(c, &w);
}

// Apply the auto-register + verify policy. Unknown account → auto-create
// password-less and accept; password-less account → accept; password-protected
// account → verify the OLS double-hash, accept on match else reject.
fn logonResult(c: *Conn, server_token: u32, got: [20]u8) u32 {
    const acct = c.accountName();
    var stored: [20]u8 = undefined;
    const has_pw = store.accountPwHash(acct, &stored) orelse {
        // No such account → auto-register password-less and accept.
        _ = store.createAccount(acct, null);
        return LOGON_OK;
    };
    if (!has_pw) return LOGON_OK; // password-less account → accept
    const expect = xsha1.doubleHash(c.client_token, server_token, stored);
    return if (std.mem.eql(u8, &expect, &got)) LOGON_OK else LOGON_BAD_PASSWORD;
}

fn onCreateAccount(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    var pwhash: [20]u8 = undefined;
    @memcpy(&pwhash, r.take20());
    const acct = r.getStr();
    c.setAccount(acct);

    const created = store.createAccount(acct, pwhash);
    log.line(tag, "create account={s} -> {s}", .{ acct, if (created) "ok" else "exists" });

    var buf: [64]u8 = undefined;
    var w = startPacket(&buf, SID_CREATEACCOUNT2);
    w.putU32(if (created) @as(u32, 0) else 1); // 0 = created, non-zero = name taken
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

// --- chat channels ----------------------------------------------------------

// Build a SID_CHATEVENT into `buf` and return its on-wire slice. Body (S->C):
// u32 EventID, u32 userFlags, u32 ping, u32 ip(0), u32 acctNumber(0),
// u32 regAuthority(0), cstr username, cstr text.
fn buildChatEvent(buf: []u8, eid: u32, username: []const u8, text: []const u8) []u8 {
    var w = startPacket(buf, SID_CHATEVENT);
    w.putU32(eid);
    w.putU32(0); // user flags
    w.putU32(0); // ping
    w.putU32(0); // ip
    w.putU32(0); // account number
    w.putU32(0); // registration authority
    w.putStr(username);
    w.putStr(text);
    w.patchU16(2, @intCast(w.pos));
    return w.slice();
}

// Send a CHATEVENT directly to this connection.
fn sendEvent(c: *Conn, eid: u32, username: []const u8, text: []const u8) void {
    var buf: [512]u8 = undefined;
    const bytes = buildChatEvent(&buf, eid, username, text);
    _ = net.writeAll(c.fd, bytes);
}

const BcastCtx = struct { eid: u32, username: []const u8, text: []const u8 };

fn bcastCb(ctx: *const BcastCtx, m: *chat.Member) void {
    var buf: [512]u8 = undefined;
    const bytes = buildChatEvent(&buf, ctx.eid, ctx.username, ctx.text);
    chat.sendTo(m, bytes);
}

// Broadcast a CHATEVENT to every OTHER member in this connection's channel.
fn broadcastEvent(c: *Conn, eid: u32, username: []const u8, text: []const u8) void {
    const ctx = BcastCtx{ .eid = eid, .username = username, .text = text };
    chat.forEachInChannel(c.channelName(), c.fd, &ctx, bcastCb);
}

const ShowUserCtx = struct { c: *Conn };

// On join, the joiner gets an EID_SHOWUSER for each existing member.
fn showUserCb(ctx: *const ShowUserCtx, m: *chat.Member) void {
    sendEvent(ctx.c, EID_SHOWUSER, m.nameSlice(), "");
}

fn onJoinChannel(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU32(); // flags
    var channel = r.getStr();
    if (channel.len == 0) channel = default_channel;
    const acct = c.accountName();
    log.line(tag, "join channel '{s}' as {s}", .{ channel, acct });

    c.setChannel(channel);
    _ = chat.join(c.fd, acct, channel);

    // Tell the joiner which channel they're in, then list existing members.
    sendEvent(c, EID_CHANNEL, channel, "");
    const ctx = ShowUserCtx{ .c = c };
    chat.forEachInChannel(channel, c.fd, &ctx, showUserCb);

    // Tell everyone else this user joined.
    broadcastEvent(c, EID_JOIN, acct, "");
}

fn onChatCommand(c: *Conn, tag: []const u8, body: []const u8) void {
    if (!c.in_channel) return; // talking before joining a channel: ignore
    var r = proto.Reader.init(body);
    const text = r.getStr();
    const acct = c.accountName();

    if (parseWhisper(text)) |w| {
        log.line(tag, "{s} whispers {s}: {s}", .{ acct, w.target, w.msg });
        var buf: [512]u8 = undefined;
        const bytes = buildChatEvent(&buf, EID_WHISPER, acct, w.msg);
        _ = chat.whisper(w.target, bytes);
        // Confirmation echo back to sender (D2 shows the whisper you sent).
        sendEvent(c, EID_WHISPER, w.target, w.msg);
        return;
    }
    if (text.len > 0 and text[0] == '/') {
        // Unknown slash command: acknowledge minimally, don't broadcast.
        sendEvent(c, EID_INFO, acct, "");
        return;
    }

    log.line(tag, "{s} talks: {s}", .{ acct, text });
    broadcastEvent(c, EID_TALK, acct, text); // to the others
    sendEvent(c, EID_TALK, acct, text); // echo to self (D2 shows own talk)
}

const Whisper = struct { target: []const u8, msg: []const u8 };

fn parseWhisper(text: []const u8) ?Whisper {
    const rest = if (std.mem.startsWith(u8, text, "/w "))
        text[3..]
    else if (std.mem.startsWith(u8, text, "/whisper "))
        text[9..]
    else
        return null;
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return .{ .target = rest[0..sp], .msg = rest[sp + 1 ..] };
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
    const sid = state.global.mintSession(acct);
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
