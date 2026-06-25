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
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const proto = @import("proto.zig");
const protocol = @import("bncs_protocol.zig");
const state = @import("state.zig");
const bnftp = @import("bnftp.zig");
const chat = @import("chat.zig");
const friends = @import("friends.zig");
const store = @import("store.zig");
const guilds = @import("guilds.zig");
const guild = @import("realm_shared").guild;
const xsha1 = @import("xsha1.zig");

// Set by main() before serving.
pub var realm_name: []const u8 = "TypeGuru";
pub var realm_desc: []const u8 = "D2 Closed Realm";
pub var d2cs_ip: [4]u8 = .{ 127, 0, 0, 1 };
pub var d2cs_port: u16 = 6113;

// Comma-separated account names that get Battle.net-admin + operator flags in chat
// (the "@"/Blizzard-rep style ops). Set from REALMD_ADMINS. Case-insensitive.
pub var admin_accounts: []const u8 = "";

const FLAG_OPERATOR: u32 = @intFromEnum(protocol.ChatUserFlag.operator);
const FLAG_ADMIN: u32 = @intFromEnum(protocol.ChatUserFlag.bnet_admin);

fn isAdmin(account: []const u8) bool {
    if (admin_accounts.len == 0 or account.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, admin_accounts, ',');
    while (it.next()) |a| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, a, " "), account)) return true;
    }
    return false;
}

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
const SID_LEAVECHAT = 0x10;
const SID_CHECKAD = 0x15;
const SID_STARTADVEX3 = 0x1c;
const SID_NOTIFYJOIN = 0x22;
const SID_NEWS_INFO = 0x46;
const SID_READUSERDATA = 0x26;
const SID_WRITEUSERDATA = 0x27;
const SID_GETFILETIME = 0x33;
const SID_PING = 0x25;
const SID_LOGONRESPONSE2 = 0x3a;
const SID_CREATEACCOUNT2 = 0x3d;
const SID_LOGONREALMEX = 0x3e;
const SID_QUERYREALMS2 = 0x40;
const SID_NETGAMEPORT = 0x45;
const SID_AUTH_INFO = 0x50;
const SID_AUTH_CHECK = 0x51;
const SID_FRIENDSLIST = 0x65;
// Remaining client SIDs (D2 1.14d's NET_SID_CLIENT_* surface). Reply-bearing ones
// get handlers; the rest are fire-and-forget notifications or legacy/alt-auth
// paths D2 1.14d never takes (it uses AUTH_INFO/CHECK + LOGONRESPONSE2).
const SID_CLIENTID = 0x05; // S->C reply to CLIENTID2
const SID_STARTVERSIONING = 0x06; // legacy versioning
const SID_REPORTVERSION = 0x07; // legacy versioning
const SID_GETADVLISTEX = 0x09; // public game-list search
const SID_LOCALEINFO = 0x12; // client locale info (notify)
const SID_CLICKAD = 0x16; // ad clicked (notify)
const SID_CLIENTID2 = 0x1e; // client registration
const SID_LEAVEGAME = 0x1f; // left a game (notify)
const SID_DISPLAYAD = 0x21; // ad displayed (notify)
const SID_LOGONRESPONSE = 0x29; // legacy logon
const SID_CHANGEPASSWORD = 0x31; // change account password
const SID_QUERYADURL = 0x41; // ask for an ad URL
const SID_CDKEY3 = 0x42; // legacy cd-key auth
const SID_AUTHACCOUNTLOGON = 0x53; // NLS/SRP logon (D2 uses OLS)
const SID_SETEMAIL = 0x59; // set account email (notify)
const SID_RESETPASSWORD = 0x5a; // request password reset (notify)
const SID_CHANGEEMAIL = 0x5b; // change account email (notify)
const SID_REPORTCRASH = 0x5d; // crash dump upload (notify)

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
    user_flags: u32 = 0, // this account's chat flags (admin/operator) in the current channel
    // The client's SID_ENTERCHAT statstring (D2: encodes the char it's on). Captured
    // on enter, replayed to other members in EID_SHOWUSER/EID_JOIN so chat shows chars.
    stat: [chat.max_stat]u8 = [_]u8{0} ** chat.max_stat,
    stat_len: u8 = 0,

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
    fn setStat(c: *Conn, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, chat.max_stat));
        @memcpy(c.stat[0..n], s[0..n]);
        c.stat_len = n;
    }
    fn statSlice(c: *Conn) []const u8 {
        return c.stat[0..c.stat_len];
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
        broadcastEvent(&c, EID_LEAVE, c.user_flags, c.accountName(), "");
    }
    if (c.account_len > 0) friends.setOffline(c.accountName());
    log.line(tag, "client disconnected ({s})", .{c.accountName()});
}

fn dispatch(c: *Conn, tag: []const u8, id: u8, body: []const u8) void {
    switch (id) {
        SID_NULL => {}, // keepalive
        SID_AUTH_INFO => onAuthInfo(c, tag, body),
        SID_AUTH_CHECK => onAuthCheck(c, tag, body),
        SID_LOGONRESPONSE2 => onLogon(c, tag, body),
        SID_CREATEACCOUNT2 => onCreateAccount(c, tag, body),
        SID_ENTERCHAT => onEnterChat(c, tag, body),
        SID_GETCHANNELLIST => onGetChannelList(c),
        SID_JOINCHANNEL => onJoinChannel(c, tag, body),
        SID_CHATCOMMAND => onChatCommand(c, tag, body),
        SID_QUERYREALMS2 => onQueryRealms(c, tag),
        SID_LOGONREALMEX => onLogonRealm(c, tag, body),
        SID_GETFILETIME => onGetFileTime(c, tag, body),
        SID_READUSERDATA => onReadUserData(c, tag, body),
        SID_WRITEUSERDATA => onWriteUserData(c, tag, body),
        SID_FRIENDSLIST => onFriendsList(c, tag),
        SID_PING => onPing(c, body),
        SID_NETGAMEPORT => {},
        // Client notifications with no BNCS reply — accept silently so they aren't
        // logged as "unhandled". LeaveChat (left a channel), NotifyJoin (entered a
        // game), CheckAd (banner-ad poll; we serve no ads).
        SID_LEAVECHAT, SID_NOTIFYJOIN, SID_CHECKAD => {},
        SID_STARTADVEX3 => onStartAdvex(c, tag, body),
        SID_NEWS_INFO => onNewsInfo(c, tag, body),
        SID_GETADVLISTEX => onGetAdvListEx(c, tag),
        SID_CLIENTID2 => onClientId2(c, tag),
        SID_QUERYADURL => onQueryAdURL(c, tag),
        SID_CHANGEPASSWORD => onChangePassword(c, tag, body),
        SID_SETEMAIL => onSetEmail(c, tag, body),
        SID_CHANGEEMAIL => onChangeEmail(c, tag, body),
        // NLS/SRP logon — reachable only when the client's g_nBNetClientToken == 1
        // (non-default; D2 closed-realm uses OLS via LOGONRESPONSE2). realmd is
        // OLS-only, so fail it cleanly rather than hang an NLS-mode client.
        SID_AUTHACCOUNTLOGON => onAuthAccountLogon(c, tag),
        // Fire-and-forget notifications (no reply expected), plus legacy SIDs
        // RE-verified DEAD in 1.14d — 0x06/0x07/0x29/0x42 have no reachable caller
        // (connect-flow RE). Accept silently so they aren't logged as "unhandled".
        SID_LOCALEINFO, SID_CLICKAD, SID_LEAVEGAME, SID_DISPLAYAD, SID_REPORTCRASH, SID_RESETPASSWORD, SID_STARTVERSIONING, SID_REPORTVERSION, SID_LOGONRESPONSE, SID_CDKEY3 => {},
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

fn onAuthCheck(c: *Conn, tag: []const u8, body: []const u8) void {
    // Capture the EXACT client packet — ground truth for the modern SID_AUTH_CHECK
    // envelope (how CheckRevision's outputs map into the fields + the CD-key block
    // shape). realmd accepts any result regardless; this is purely for fidelity.
    log.line(tag, "auth_check raw ({d} bytes):", .{body.len});
    log.hexdump(tag, body);
    var r = proto.Reader.init(body);
    const client_token = r.getU32();
    const exe_version = r.getU32();
    const exe_hash = r.getU32();
    const num_keys = r.getU32();
    const spawn = r.getU32();
    log.line(tag, "  serverToken=0x{x:0>8} clientToken=0x{x:0>8} exeVersion=0x{x:0>8} exeHash=0x{x:0>8} numKeys={d} spawn={d}", .{ c.server_token, client_token, exe_version, exe_hash, num_keys, spawn });
    var k: u32 = 0;
    while (k < num_keys and k < 8) : (k += 1) {
        const klen = r.getU32();
        const product = r.getU32();
        const public = r.getU32();
        _ = r.getU32(); // reserved (0)
        inline for (0..5) |_| _ = r.getU32(); // 5-dword hashed key data
        log.line(tag, "  key[{d}] len={d} product=0x{x:0>8} public=0x{x:0>8}", .{ k, klen, product, public });
    }
    const exe_info = r.getStr();
    const owner = r.getStr();
    log.line(tag, "  exeInfo=\"{s}\" owner=\"{s}\"", .{ exe_info, owner });

    var buf: [64]u8 = undefined;
    var w = startPacket(&buf, SID_AUTH_CHECK);
    w.putU32(0x000); // passed (we trust the client; capture above is for fidelity)
    w.putStr(""); // extra info (only meaningful on failure)
    finish(c, &w);
}

// SID_LOGONRESPONSE2 results.
const LOGON_OK: u32 = 0;
const LOGON_NO_ACCOUNT: u32 = 1; // SID_LOGONRESPONSE2: account does not exist
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
    if (result == LOGON_OK) friends.setOnline(acct); // presence for friends online-status
    log.line(tag, "logon account={s} -> result={d}", .{ acct, result });

    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_LOGONRESPONSE2);
    w.putU32(result);
    finish(c, &w);
}

// Auth policy: realmd VERIFIES OLS passwords for any account that has one. The
// broken-SHA-1 double-hash is reverse-engineered from Game.exe (D2Client::_net_sid::SHA1)
// and verified bit-for-bit against a real 1.14d client login (see xsha1.zig tests), so
// SID_LOGONRESPONSE2 hashes from the genuine client now match. REALMD_PERMISSIVE_AUTH only
// governs UNKNOWN accounts: permissive auto-registers them password-less (legacy/test
// convenience); strict (default) rejects them with LOGON_NO_ACCOUNT.
pub var permissive_auth: bool = false;

fn logonResult(c: *Conn, server_token: u32, got: [20]u8) u32 {
    const acct = c.accountName();
    var stored: [20]u8 = undefined;
    const has_pw = store.accountPwHash(acct, &stored) orelse {
        if (permissive_auth) {
            _ = store.createAccount(acct, null); // legacy: auto-register password-less
            return LOGON_OK;
        }
        return LOGON_NO_ACCOUNT; // strict: a brand-new name is rejected, not auto-created
    };
    if (!has_pw) return LOGON_OK; // password-less account: nothing to verify
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
    // SID_ENTERCHAT C->S: (STRING) requested-username (empty; we use the account),
    // (STRING) statstring (D2: the char the client is on). Capture the statstring so
    // we can replay it to other members when this user joins a channel.
    var r = proto.Reader.init(body);
    _ = r.getStr();
    c.setStat(r.getStr());
    const acct = c.accountName();
    log.line(tag, "enter chat as {s} (stat {d}B)", .{ acct, c.stat_len });
    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, SID_ENTERCHAT);
    w.putStr(acct); // unique name
    w.putStr(c.statSlice()); // statstring (echo the client's own)
    w.putStr(acct); // account name
    finish(c, &w);
    // NOTE: do not push a SID_CHATEVENT here. The D2 realm lobby is not a chat
    // channel and an unsolicited channel-join event corrupts its control state
    // (crash in D2WINMAIN_SetControlDisabled). Chat-flag enums live in protocol.zig.
}

fn onGetChannelList(c: *Conn) void {
    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, SID_GETCHANNELLIST);
    // Public channels offered in the channel-select UI. The home channel first.
    w.putStr(default_channel); // "Diablo II"
    w.putStr("Trade");
    w.putStr("Hardcore");
    w.putStr(""); // empty string terminates the list
    finish(c, &w);
}

// --- chat channels ----------------------------------------------------------

// Build a SID_CHATEVENT into `buf` and return its on-wire slice. Body (S->C):
// u32 EventID, u32 userFlags, u32 ping, u32 ip(0), u32 acctNumber(0),
// u32 regAuthority(0), cstr username, cstr text.
fn buildChatEvent(buf: []u8, eid: u32, flags: u32, username: []const u8, text: []const u8) []u8 {
    var w = startPacket(buf, SID_CHATEVENT);
    w.putU32(eid);
    w.putU32(flags); // user flags (operator/admin/...) or channel flags for EID_CHANNEL
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
fn sendEvent(c: *Conn, eid: u32, flags: u32, username: []const u8, text: []const u8) void {
    var buf: [512]u8 = undefined;
    const bytes = buildChatEvent(&buf, eid, flags, username, text);
    _ = net.writeAll(c.fd, bytes);
}

const BcastCtx = struct { eid: u32, flags: u32, username: []const u8, text: []const u8 };

fn bcastCb(ctx: *const BcastCtx, m: *chat.Member) void {
    // Squelch: a recipient who /ignore'd the sender doesn't see their talk. Checked
    // on the Member directly — forEachInChannel already holds the registry lock, so
    // we must NOT call back into a lock-taking chat helper here (it would deadlock).
    if (ctx.eid == EID_TALK and m.ignoresName(ctx.username)) return;
    var buf: [512]u8 = undefined;
    const bytes = buildChatEvent(&buf, ctx.eid, ctx.flags, ctx.username, ctx.text);
    chat.sendTo(m, bytes);
}

// Broadcast a CHATEVENT to every OTHER member in this connection's channel.
fn broadcastEvent(c: *Conn, eid: u32, flags: u32, username: []const u8, text: []const u8) void {
    const ctx = BcastCtx{ .eid = eid, .flags = flags, .username = username, .text = text };
    chat.forEachInChannel(c.channelName(), c.fd, &ctx, bcastCb);
}

const ShowUserCtx = struct { c: *Conn };

// On join, the joiner gets an EID_SHOWUSER for each existing member (with that
// member's own flags, so ops/admins show with the right icon).
fn showUserCb(ctx: *const ShowUserCtx, m: *chat.Member) void {
    sendEvent(ctx.c, EID_SHOWUSER, m.flags, m.nameSlice(), m.statSlice());
}

fn onJoinChannel(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU32(); // flags
    var channel = r.getStr();
    if (channel.len == 0) channel = default_channel;
    const acct = c.accountName();

    // Compute this user's chat flags: configured admins always; the FIRST person in
    // an otherwise-empty channel becomes its operator (typical Battle.net behaviour).
    var flags: u32 = 0;
    if (isAdmin(acct)) flags |= FLAG_ADMIN | FLAG_OPERATOR;
    if (chat.countInChannel(channel, c.fd) == 0) flags |= FLAG_OPERATOR;
    c.user_flags = flags;
    log.line(tag, "join channel '{s}' as {s} (flags=0x{x})", .{ channel, acct, flags });

    c.setChannel(channel);
    _ = chat.join(c.fd, acct, channel, flags, c.statSlice());

    // Tell the joiner which channel they're in (EID_CHANNEL carries the CHANNEL flags),
    // then list existing members, then announce the join to everyone else.
    sendEvent(c, EID_CHANNEL, @intFromEnum(protocol.ChatChannelFlag.public), channel, "");
    const ctx = ShowUserCtx{ .c = c };
    chat.forEachInChannel(channel, c.fd, &ctx, showUserCb);
    broadcastEvent(c, EID_JOIN, flags, acct, c.statSlice());
}

fn guildErr(e: guilds.Error) []const u8 {
    return switch (e) {
        error.NotFound => "No such guild.",
        error.Exists => "That name is already taken.",
        error.Denied => "You don't have permission to do that.",
        error.Full => "The guild roster is full.",
        error.BadName => "Invalid name.",
        error.BadTag => "Invalid tag (1-3 letters).",
        error.AtMaxLevel => "The Guild Hall is already at the maximum level.",
        error.Insufficient => "The treasury can't fund the next upgrade yet.",
        error.NotMember => "You are not a member of that guild.",
        error.IoError => "Storage error — try again.",
    };
}

// "/guild ..." — the cut Guild Halls feature, driven from chat. Replies to the
// sender via EID_INFO / EID_ERROR. Returns true if it consumed the command.
fn handleGuildCmd(c: *Conn, tag: []const u8, text: []const u8) bool {
    if (!std.mem.eql(u8, text, "/guild") and !std.mem.startsWith(u8, text, "/guild ")) return false;
    const acct = c.accountName();
    const rest = std.mem.trim(u8, text[@min(text.len, 6)..], " ");
    const sp = std.mem.indexOfScalar(u8, rest, ' ');
    const sub = if (sp) |i| rest[0..i] else rest;
    const args = if (sp) |i| std.mem.trim(u8, rest[i + 1 ..], " ") else "";
    var rb: [256]u8 = undefined;

    if (sub.len == 0 or std.mem.eql(u8, sub, "help")) {
        sendEvent(c, EID_INFO, 0, "", "Guild: /guild create <TAG> <name> | info | deposit <gold> | upgrade | invite <name> | kick <name> | promote <name> | disband");
        return true;
    }

    if (std.mem.eql(u8, sub, "create")) {
        const asp = std.mem.indexOfScalar(u8, args, ' ') orelse {
            sendEvent(c, EID_ERROR, 0, "", "Usage: /guild create <TAG> <name>");
            return true;
        };
        const tagv = std.mem.trim(u8, args[0..asp], "[]");
        const namev = std.mem.trim(u8, args[asp + 1 ..], " ");
        guilds.create(acct, tagv, namev) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        const msg = std.fmt.bufPrint(&rb, "Guild '{s}' [{s}] founded — you are the Guildmaster.", .{ namev, tagv }) catch "Guild founded.";
        sendEvent(c, EID_INFO, 0, "", msg);
        log.line(tag, "{s} founded guild '{s}' [{s}]", .{ acct, namev, tagv });
        return true;
    }

    // The remaining ops act on the actor's own guild.
    var gnb: [guild.name_max]u8 = undefined;
    const gname = guilds.guildNameOf(acct, &gnb) orelse {
        sendEvent(c, EID_ERROR, 0, "", "You are not in a guild. Found one with: /guild create <TAG> <name>");
        return true;
    };

    if (std.mem.eql(u8, sub, "info")) {
        var g = guilds.load(gname) orelse return true;
        const msg = if (g.nextUpgradeCost()) |cost|
            std.fmt.bufPrint(&rb, "{s} [{s}] | Hall lvl {d} | Treasury {d} (next {d}) | {d} members", .{ g.nameSlice(), g.tagSlice(), g.hall_level, g.treasury, cost, g.member_count }) catch "guild"
        else
            std.fmt.bufPrint(&rb, "{s} [{s}] | Hall lvl {d} (MAX) | Treasury {d} | {d} members", .{ g.nameSlice(), g.tagSlice(), g.hall_level, g.treasury, g.member_count }) catch "guild";
        sendEvent(c, EID_INFO, 0, "", msg);
        return true;
    }
    if (std.mem.eql(u8, sub, "deposit")) {
        const gold = std.fmt.parseInt(u64, args, 10) catch {
            sendEvent(c, EID_ERROR, 0, "", "Usage: /guild deposit <gold>");
            return true;
        };
        const total = guilds.deposit(acct, gname, gold) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        const msg = std.fmt.bufPrint(&rb, "Deposited {d} into the Steeg Stone. Treasury: {d}.", .{ gold, total }) catch "Deposited.";
        sendEvent(c, EID_INFO, 0, "", msg);
        return true;
    }
    if (std.mem.eql(u8, sub, "upgrade")) {
        const lvl = guilds.upgrade(acct, gname) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        const msg = std.fmt.bufPrint(&rb, "Guild Hall upgraded to level {d}!", .{lvl}) catch "Upgraded.";
        sendEvent(c, EID_INFO, 0, "", msg);
        return true;
    }
    if (std.mem.eql(u8, sub, "invite")) {
        guilds.invite(acct, gname, args) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        const msg = std.fmt.bufPrint(&rb, "{s} added to the guild.", .{args}) catch "Invited.";
        sendEvent(c, EID_INFO, 0, "", msg);
        return true;
    }
    if (std.mem.eql(u8, sub, "kick")) {
        guilds.kick(acct, gname, args) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        sendEvent(c, EID_INFO, 0, "", "Member removed from the guild.");
        return true;
    }
    if (std.mem.eql(u8, sub, "promote")) {
        guilds.promote(acct, gname, args, .lieutenant) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        sendEvent(c, EID_INFO, 0, "", "Member promoted to Lieutenant.");
        return true;
    }
    if (std.mem.eql(u8, sub, "disband")) {
        guilds.disband(acct, gname) catch |e| {
            sendEvent(c, EID_ERROR, 0, "", guildErr(e));
            return true;
        };
        sendEvent(c, EID_INFO, 0, "", "The guild has been disbanded.");
        return true;
    }

    sendEvent(c, EID_ERROR, 0, "", "Unknown /guild subcommand. Try /guild help.");
    return true;
}

fn onChatCommand(c: *Conn, tag: []const u8, body: []const u8) void {
    if (!c.in_channel) return; // talking before joining a channel: ignore
    var r = proto.Reader.init(body);
    const text = r.getStr();
    const acct = c.accountName();

    if (parseWhisper(text)) |w| {
        // A recipient who squelched the sender never gets the whisper, but Battle.net
        // still shows the sender a normal "To <target>:" echo (no hint they're ignored).
        if (chat.fdOf(w.target)) |tfd| {
            if (chat.recipientIgnores(tfd, acct)) {
                sendEvent(c, EID_WHISPER, c.user_flags, w.target, w.msg);
                return;
            }
        }
        log.line(tag, "{s} whispers {s}: {s}", .{ acct, w.target, w.msg });
        var buf: [512]u8 = undefined;
        const bytes = buildChatEvent(&buf, EID_WHISPER, c.user_flags, acct, w.msg);
        const res = chat.whisperEx(w.target, bytes); // delivers unless target is in DND
        if (!res.found) {
            sendEvent(c, EID_ERROR, 0, w.target, "That user is not logged on.");
            return;
        }
        // Echo to sender (D2 shows "To <target>: msg"), then surface the target's
        // away/DND auto-reply if they set one (DND also suppressed delivery above).
        sendEvent(c, EID_WHISPER, c.user_flags, w.target, w.msg);
        var rb: [192]u8 = undefined;
        if (res.dnd_len > 0) {
            const s = std.fmt.bufPrint(&rb, "{s} is unavailable ({s})", .{ w.target, res.dndSlice() }) catch return;
            sendEvent(c, EID_INFO, 0, w.target, s);
        } else if (res.away_len > 0) {
            const s = std.fmt.bufPrint(&rb, "{s} is away ({s})", .{ w.target, res.awaySlice() }) catch return;
            sendEvent(c, EID_INFO, 0, w.target, s);
        }
        return;
    }
    if (handleSocialCmd(c, tag, text)) return;
    if (handleGuildCmd(c, tag, text)) return;
    if (parseFriendCmd(text)) |fc| {
        handleFriendCmd(c, tag, fc);
        return;
    }
    if (text.len > 0 and text[0] == '/') {
        // Unknown slash command: acknowledge minimally, don't broadcast.
        sendEvent(c, EID_INFO, 0, acct, "");
        return;
    }

    log.line(tag, "{s} talks: {s}", .{ acct, text });
    // Broadcast to the OTHER members only (forEachInChannel excludes c.fd). The 1.14d
    // client already displays the sender's own line locally, so echoing it back here
    // makes every message the user types appear twice.
    broadcastEvent(c, EID_TALK, c.user_flags, acct, text);
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

const Slash = struct { verb: []const u8, arg: []const u8 };

// Split "/verb the rest" into {verb, arg}. Null if `text` isn't a slash command.
fn parseSlash(text: []const u8) ?Slash {
    if (text.len == 0 or text[0] != '/') return null;
    const rest = text[1..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ');
    const verb = if (sp) |i| rest[0..i] else rest;
    const arg = if (sp) |i| std.mem.trim(u8, rest[i + 1 ..], " ") else "";
    return .{ .verb = verb, .arg = arg };
}
fn eqCmd(verb: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(verb, name);
}

// Battle.net social commands driven from chat: /away, /dnd, /ignore (/squelch),
// /unignore (/unsquelch), /whois (/where, /whereis), /kick. Returns true if consumed.
fn handleSocialCmd(c: *Conn, tag: []const u8, text: []const u8) bool {
    const acct = c.accountName();
    const cmd = parseSlash(text) orelse return false;

    // /away [msg] — set, or (no arg) clear, the whisper auto-reply.
    if (eqCmd(cmd.verb, "away")) {
        chat.setAway(c.fd, cmd.arg);
        const msg = if (cmd.arg.len > 0) "You are now marked as being Away." else "You are no longer marked as being Away.";
        sendEvent(c, EID_INFO, 0, acct, msg);
        return true;
    }
    // /dnd [msg] — Do-Not-Disturb; suppresses incoming whispers while set.
    if (eqCmd(cmd.verb, "dnd")) {
        chat.setDnd(c.fd, cmd.arg);
        const msg = if (cmd.arg.len > 0) "Do Not Disturb mode engaged." else "Do Not Disturb mode cancelled.";
        sendEvent(c, EID_INFO, 0, acct, msg);
        return true;
    }
    var rb: [128]u8 = undefined;
    // /ignore <name> (alias /squelch) — stop seeing that user's talk and whispers.
    if (eqCmd(cmd.verb, "ignore") or eqCmd(cmd.verb, "squelch")) {
        if (cmd.arg.len == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "Usage: /ignore <name>");
        } else if (chat.addIgnore(c.fd, cmd.arg)) {
            sendEvent(c, EID_INFO, 0, acct, std.fmt.bufPrint(&rb, "{s} has been squelched.", .{cmd.arg}) catch return true);
        } else sendEvent(c, EID_ERROR, 0, acct, "Already squelched, or your ignore list is full.");
        return true;
    }
    // /unignore <name> (alias /unsquelch).
    if (eqCmd(cmd.verb, "unignore") or eqCmd(cmd.verb, "unsquelch")) {
        if (cmd.arg.len == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "Usage: /unignore <name>");
        } else if (chat.removeIgnore(c.fd, cmd.arg)) {
            sendEvent(c, EID_INFO, 0, acct, std.fmt.bufPrint(&rb, "{s} is no longer squelched.", .{cmd.arg}) catch return true);
        } else sendEvent(c, EID_ERROR, 0, acct, "That user was not squelched.");
        return true;
    }
    // /whois <name> (aliases /where, /whereis) — which channel is a user in?
    if (eqCmd(cmd.verb, "whois") or eqCmd(cmd.verb, "where") or eqCmd(cmd.verb, "whereis")) {
        if (cmd.arg.len == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "Usage: /whois <name>");
            return true;
        }
        var chbuf: [chat.max_channel]u8 = undefined;
        if (chat.whereIs(cmd.arg, &chbuf)) |n| {
            sendEvent(c, EID_INFO, 0, acct, std.fmt.bufPrint(&rb, "{s} is in channel {s}.", .{ cmd.arg, chbuf[0..n] }) catch return true);
        } else sendEvent(c, EID_ERROR, 0, acct, "That user is not logged on.");
        return true;
    }
    // /kick <name> — channel operators/admins only. shutdownSocket unblocks the
    // victim's read thread, which runs its own leave + EID_LEAVE broadcast.
    if (eqCmd(cmd.verb, "kick")) {
        if (c.user_flags & FLAG_OPERATOR == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "You are not a channel operator.");
        } else if (cmd.arg.len == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "Usage: /kick <name>");
        } else if (chat.fdOf(cmd.arg)) |kfd| {
            net.shutdownSocket(kfd);
            log.line(tag, "{s} kicked {s}", .{ acct, cmd.arg });
            sendEvent(c, EID_INFO, 0, acct, std.fmt.bufPrint(&rb, "{s} was kicked.", .{cmd.arg}) catch return true);
        } else sendEvent(c, EID_ERROR, 0, acct, "That user is not logged on.");
        return true;
    }
    return false;
}

const FriendCmd = struct { action: enum { add, remove, list }, name: []const u8 };

// "/f ...", "/friend ...", "/friends ..." — manage the friends list from chat.
fn parseFriendCmd(text: []const u8) ?FriendCmd {
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, text, "/friends")) {
        rest = std.mem.trim(u8, text[8..], " ");
    } else if (std.mem.startsWith(u8, text, "/friend")) {
        rest = std.mem.trim(u8, text[7..], " ");
    } else if (std.mem.eql(u8, text, "/f") or std.mem.startsWith(u8, text, "/f ")) {
        rest = std.mem.trim(u8, text[2..], " ");
    } else return null;

    const sp = std.mem.indexOfScalar(u8, rest, ' ');
    const verb = if (sp) |s| rest[0..s] else rest;
    const arg = if (sp) |s| std.mem.trim(u8, rest[s + 1 ..], " ") else "";
    if (verb.len == 0 or std.mem.startsWith(u8, "list", verb)) return .{ .action = .list, .name = "" };
    if (std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "a")) return .{ .action = .add, .name = arg };
    if (std.mem.eql(u8, verb, "remove") or std.mem.eql(u8, verb, "r") or std.mem.eql(u8, verb, "del")) return .{ .action = .remove, .name = arg };
    return .{ .action = .list, .name = "" };
}

fn handleFriendCmd(c: *Conn, tag: []const u8, fc: FriendCmd) void {
    const acct = c.accountName();
    switch (fc.action) {
        .add => {
            if (fc.name.len == 0) return sendEvent(c, EID_INFO, 0, "", "Usage: /f add <account>");
            const ok = friends.add(acct, fc.name);
            log.line(tag, "{s} friend-add {s} -> {}", .{ acct, fc.name, ok });
            sendEvent(c, EID_INFO, 0, "", if (ok) "Added to your friends list." else "Already on your list (or it is full).");
        },
        .remove => {
            const ok = friends.remove(acct, fc.name);
            log.line(tag, "{s} friend-remove {s} -> {}", .{ acct, fc.name, ok });
            sendEvent(c, EID_INFO, 0, "", if (ok) "Removed from your friends list." else "That player is not on your list.");
        },
        .list => {
            var infos: [friends.max_friends]friends.FriendInfo = undefined;
            const n = friends.list(acct, &infos);
            if (n == 0) sendEvent(c, EID_INFO, 0, "", "Your friends list is empty.");
            for (infos[0..n]) |f| sendEvent(c, EID_INFO, 0, f.nameSlice(), if (f.online) "online" else "offline");
            onFriendsList(c, tag); // also push the structured list so the UI panel updates
        },
    }
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
    log.line(tag, "realm logon: parsed token=0x{x} title='{s}' acct='{s}' (minting session)", .{ c.client_token, title, acct });
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

// SID_READUSERDATA (0x26): C->S { u32 numAccounts, u32 numKeys, u32 reqId,
// STRING[numAccounts] accounts, STRING[numKeys] keys }. Reply mirrors the
// header then STRING[numAccounts*numKeys] values (account-major). Profile reads
// are public (you can view anyone's profile), so we serve whatever is named; an
// unset key is returned as an empty string (what the client expects).
fn onReadUserData(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const num_accounts = r.getU32();
    const num_keys = r.getU32();
    const reqid = r.getU32();

    var accts: [4][]const u8 = undefined;
    const na = @min(num_accounts, accts.len);
    var i: u32 = 0;
    while (i < num_accounts) : (i += 1) {
        const s = r.getStr();
        if (i < na) accts[i] = s;
    }
    var keys: [16][]const u8 = undefined;
    const nk = @min(num_keys, keys.len);
    i = 0;
    while (i < num_keys) : (i += 1) {
        const s = r.getStr();
        if (i < nk) keys[i] = s;
    }

    var buf: [2048]u8 = undefined;
    var w = startPacket(&buf, SID_READUSERDATA);
    w.putU32(num_accounts);
    w.putU32(num_keys);
    w.putU32(reqid);
    var ai: usize = 0;
    while (ai < na) : (ai += 1) {
        var ki: usize = 0;
        while (ki < nk) : (ki += 1) {
            var vbuf: [256]u8 = undefined;
            const n = store.getUserData(accts[ai], keys[ki], &vbuf);
            w.putStr(vbuf[0..n]);
        }
    }
    finish(c, &w);
    log.line(tag, "readuserdata accts={d} keys={d}", .{ num_accounts, num_keys });
}

// SID_WRITEUSERDATA (0x27): C->S { u32 numAccounts, u32 numKeys,
// STRING[numAccounts] accounts, STRING[numKeys] keys,
// STRING[numAccounts*numKeys] values }. No reply. A client may only write its
// OWN account's profile (others are silently ignored).
fn onWriteUserData(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const num_accounts = r.getU32();
    const num_keys = r.getU32();

    var accts: [4][]const u8 = undefined;
    const na = @min(num_accounts, accts.len);
    var i: u32 = 0;
    while (i < num_accounts) : (i += 1) {
        const s = r.getStr();
        if (i < na) accts[i] = s;
    }
    var keys: [16][]const u8 = undefined;
    const nk = @min(num_keys, keys.len);
    i = 0;
    while (i < num_keys) : (i += 1) {
        const s = r.getStr();
        if (i < nk) keys[i] = s;
    }

    var stored: usize = 0;
    var ai: usize = 0;
    while (ai < num_accounts) : (ai += 1) {
        var ki: usize = 0;
        while (ki < num_keys) : (ki += 1) {
            const val = r.getStr();
            if (ai < na and ki < nk and std.ascii.eqlIgnoreCase(accts[ai], c.accountName())) {
                if (store.setUserData(accts[ai], keys[ki], val)) stored += 1;
            }
        }
    }
    log.line(tag, "writeuserdata keys={d} stored={d}", .{ num_keys, stored });
}

// SID_GETADVLISTEX (0x09): public game-list search { STRING name, pass, stat }.
// D2 closed games live on the realm (MCP/d2cs), not BNCS, so this list is always
// empty: reply u32 0 (zero games), the minimal valid reply the client accepts.
fn onGetAdvListEx(c: *Conn, tag: []const u8) void {
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_GETADVLISTEX);
    w.putU32(0);
    finish(c, &w);
    log.line(tag, "getadvlistex -> 0 games", .{});
}

// SID_CLIENTID2 (0x1E): client registration. Reply SID_CLIENTID (0x05) with the
// four registration dwords (version/authority/id/token); zeros are valid.
fn onClientId2(c: *Conn, tag: []const u8) void {
    var buf: [24]u8 = undefined;
    var w = startPacket(&buf, SID_CLIENTID);
    w.putU32(0);
    w.putU32(0);
    w.putU32(0);
    w.putU32(0);
    finish(c, &w);
    log.line(tag, "clientid2 -> clientid", .{});
}

// SID_QUERYADURL (0x41): the client asks for an ad URL { u32 adType }. We serve no
// ads: reply ad-id 0 + an empty URL string.
fn onQueryAdURL(c: *Conn, tag: []const u8) void {
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_QUERYADURL);
    w.putU32(0);
    w.putStr("");
    finish(c, &w);
    log.line(tag, "queryadurl -> none", .{});
}

// SID_CHANGEPASSWORD (0x31): { u32 clientToken, u32 serverToken, u8[20] oldProof
// (OLS double-hash of the OLD password, exactly as LOGONRESPONSE2), u8[20] newHash
// (single xSHA-1 of the NEW password), STRING username }. Verify the old proof
// against the stored hash, then store the new hash. Reply u32 status (0=success).
fn onChangePassword(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const client_token = r.getU32();
    const server_token = r.getU32();
    const old_proof = r.take20().*;
    const new_hash = r.take20().*;
    const user = r.getStr();

    var ok = false;
    var stored: [20]u8 = undefined;
    if (store.accountPwHash(user, &stored)) |has_pw| {
        var verified = !has_pw; // password-less account: nothing to prove
        if (!verified) {
            const expect = xsha1.doubleHash(client_token, server_token, stored);
            verified = std.mem.eql(u8, &expect, &old_proof);
        }
        if (verified) ok = store.setAccountPassword(user, new_hash);
    } // null = no such account -> ok stays false

    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_CHANGEPASSWORD);
    w.putU32(if (ok) 0 else 1); // 0 = success
    finish(c, &w);
    log.line(tag, "changepassword '{s}' -> {s}", .{ user, if (ok) "ok" else "denied" });
}

// SID_SETEMAIL (0x59): { STRING email }. The client registers an email for its
// account (often answering a server prompt). Persist it in the account's userdata
// hive. No reply expected.
fn onSetEmail(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const email = r.getStr();
    if (c.account_len > 0 and email.len > 0) _ = store.setUserData(c.accountName(), "email", email);
    log.line(tag, "setemail '{s}' ({d}B)", .{ c.accountName(), email.len });
}

// SID_CHANGEEMAIL (0x5B): { STRING account, STRING oldEmail, STRING newEmail }.
// Update the stored email — only for the client's own account. No reply.
fn onChangeEmail(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const acct = r.getStr();
    _ = r.getStr(); // old email (we hold no email auth, so nothing to verify against)
    const new_email = r.getStr();
    if (std.ascii.eqlIgnoreCase(acct, c.accountName()) and new_email.len > 0)
        _ = store.setUserData(acct, "email", new_email);
    log.line(tag, "changeemail '{s}'", .{acct});
}

// SID_AUTHACCOUNTLOGON (0x53): the NLS/SRP secure-logon path. The 1.14d client
// only sends this when its g_nBNetClientToken == 1 (a client-side config, not the
// default) — RE-confirmed reachable via BNCLIENT_SendLogonRequest. Standard D2
// closed-realm uses OLS (LOGONRESPONSE2 0x3a), which we implement; realmd does NOT
// implement NLS/SRP. So instead of leaving an NLS-mode client hanging on its logon
// reply, fail it cleanly: SID_AUTHACCOUNTLOGON reply = u32 status, 1 = "account
// does not exist" (on failure no salt/serverKey follows). The user gets a defined
// error, not a hang. (Full NLS/SRP would be a separate feature.)
fn onAuthAccountLogon(c: *Conn, tag: []const u8) void {
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_AUTHACCOUNTLOGON);
    w.putU32(1); // 1 = account does not exist — clean NLS failure (realmd is OLS-only)
    finish(c, &w);
    log.line(tag, "authaccountlogon (NLS) -> rejected; realmd is OLS-only", .{});
}

// Product code for an online friend (D2XP), little-endian 4 chars as the client expects.
const PRODUCT_D2XP: u32 = @bitCast([4]u8{ 'D', '2', 'X', 'P' });

// SID_FRIENDSLIST (0x65): reply with this account's friends. Per entry:
// cstr name, u8 status flags, u8 location (0=offline,1=online), u32 product, cstr loc-string.
fn onFriendsList(c: *Conn, tag: []const u8) void {
    var infos: [friends.max_friends]friends.FriendInfo = undefined;
    const n = friends.list(c.accountName(), &infos);
    log.line(tag, "friends list for {s} -> {d} friend(s)", .{ c.accountName(), n });
    var buf: [2048]u8 = undefined;
    var w = startPacket(&buf, SID_FRIENDSLIST);
    w.putU8(@intCast(n));
    for (infos[0..n]) |f| {
        w.putStr(f.nameSlice());
        w.putU8(0); // status flags (mutual/DND/away) — none yet
        w.putU8(if (f.online) @as(u8, 1) else 0); // location
        w.putU32(if (f.online) PRODUCT_D2XP else 0);
        w.putStr(""); // location string (channel/game name)
    }
    finish(c, &w);
}

fn onPing(c: *Conn, body: []const u8) void {
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_PING);
    w.putBytes(body); // echo the cookie back
    finish(c, &w);
}

// Message-of-the-day shown on the Battle.net chat screen (SID_NEWS_INFO).
pub var motd: []const u8 = "Welcome to the realm.";

// SID_STARTADVEX3 (0x1c): the client advertises a game it is hosting. Realm games are
// created over MCP, so there's nothing to advertise here — just ack success (status 0)
// so the client doesn't stall waiting on the reply.
fn onStartAdvex(c: *Conn, tag: []const u8, body: []const u8) void {
    _ = body;
    log.line(tag, "startadvex3 -> ok", .{});
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_STARTADVEX3);
    w.putU32(0); // status: 0 = success
    finish(c, &w);
}

// SID_NEWS_INFO (0x46): client requests news + MOTD since a timestamp. Reply with a
// single entry whose timestamp is 0, which the client treats as the MOTD.
fn onNewsInfo(c: *Conn, tag: []const u8, body: []const u8) void {
    _ = body; // request: u32 newest-news timestamp the client already has
    log.line(tag, "news info -> motd '{s}'", .{motd});
    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, SID_NEWS_INFO);
    w.putU8(1); // number of entries
    w.putU32(0); // last logon timestamp
    w.putU32(0); // oldest news timestamp
    w.putU32(0); // newest news timestamp
    w.putU32(0); // entry timestamp; 0 = this entry is the MOTD
    w.putStr(motd); // MOTD text (NUL-terminated)
    finish(c, &w);
}
