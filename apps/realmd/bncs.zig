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
const obs = @import("realm_infra").obs;
const proto = @import("proto.zig");
const protocol = @import("libd2").bnet.protocol;
const state = @import("state.zig");
const bnftp = @import("bnftp.zig");
const d2cs = @import("d2cs.zig");
const chat = @import("chat.zig");
const friends = @import("friends.zig");
const store = @import("store.zig");
const guilds = @import("guilds.zig");
const hook = @import("hook.zig");

extern "c" fn time(t: ?*c_long) c_long; // POSIX seconds, for the banner-ad FILETIME
const guild = @import("realm_proto").guild;
const xsha1 = @import("libd2").bnet.xsha1;

// Set by main() before serving.
pub var realm_name: []const u8 = "TypeGuru";
pub var realm_desc: []const u8 = "D2 Closed Realm";
pub var d2cs_ip: [4]u8 = .{ 127, 0, 0, 1 };
/// The port the realm tells clients to reach MCP on. Muxed onto BNCS, so it is the BNCS port;
/// main() sets it from the configured one.
pub var d2cs_port: u16 = 6112;

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

pub const Conn = struct {
    fd: net.Socket,
    server_token: u32,
    // Outbound packets accumulate here and go out in one write; most requests answer with
    // several (a channel join sends the join, the user list and the MOTD). Flushed before we
    // block on read so the client never waits on bytes we hold, and by a `defer` on the
    // handler so no exit path can strand them.
    out: [8192]u8 = undefined,
    out_len: usize = 0,
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
    // The `clan*charname` the client asked to be known as in SID_ENTERCHAT.
    chat_name: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    chat_name_len: u8 = 0,

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
        obs.setAccount(name); // mirror into the per-thread trace context (every log line gets it)
    }
    fn accountName(c: *Conn) []const u8 {
        return c.account[0..c.account_len];
    }
    fn setStat(c: *Conn, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, chat.max_stat));
        @memcpy(c.stat[0..n], s[0..n]);
        c.stat_len = n;
    }
    fn setChatName(c: *Conn, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, state.max_name));
        @memcpy(c.chat_name[0..n], s[0..n]);
        c.chat_name_len = n;
    }
    /// How this connection is named in chat events. The client hands us a `clan*charname`
    /// in SID_ENTERCHAT and the channel list is drawn from the part after the '*', so
    /// echoing it back is what makes characters (rather than account names) show up.
    fn chatName(c: *Conn) []const u8 {
        return if (c.chat_name_len > 0) c.chat_name[0..c.chat_name_len] else c.accountName();
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
/// Push `bytes` into the connection's outbound buffer, flushing first if they will not fit.
/// A single packet larger than the whole buffer goes straight out on its own.
fn queue(c: *Conn, bytes: []const u8) void {
    if (bytes.len > c.out.len) {
        flushOut(c);
        _ = net.writeAll(c.fd, bytes);
        return;
    }
    if (c.out_len + bytes.len > c.out.len) flushOut(c);
    @memcpy(c.out[c.out_len..][0..bytes.len], bytes);
    c.out_len += bytes.len;
}

/// Write everything queued. Cheap to call when nothing is pending.
fn flushOut(c: *Conn) void {
    if (c.out_len == 0) return;
    const n = c.out_len;
    c.out_len = 0; // cleared first: a failed write must not leave bytes to be re-sent
    _ = net.writeAll(c.fd, c.out[0..n]);
}

fn finish(c: *Conn, w: *proto.Writer) void {
    w.patchU16(2, @intCast(w.pos));
    queue(c, w.slice());
}

pub fn handle(fd: net.Socket, tag: []const u8) void {
    _ = obs.startTrace(); // one trace per client connection — every line on this thread carries it
    var c = Conn{ .fd = fd, .server_token = nextToken() };
    defer flushOut(&c); // no exit path may strand queued packets
    log.line(tag, "client connected", .{});

    var acc: [16384]u8 = undefined;
    var len: usize = 0;
    var got_proto = false;

    while (true) {
        // Answers go out before we wait for the next request; the client must never be
        // blocked on bytes sitting in our buffer.
        flushOut(&c);
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
            // 0x01 fronts BOTH BNCS and MCP — real bnet tells them apart by host,
            // not by selector. Demux on the byte AFTER 0x01: a BNCS packet starts
            // 0xFF; an MCP packet is u16-length-prefixed (low length byte, never
            // 0xFF). Both clients speak first, so the discriminator always arrives.
            if (len < 2) continue; // wait for the discriminator byte
            if (acc[1] != 0xff) { // MCP realm session riding :6112
                d2cs.handleFrom(fd, tag, acc[1..len]);
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
            break; // fall through to the teardown below; returning here leaked the member
        }
    }
    disconnect(&c, fd, tag);
}

/// Tear down a connection's presence. Runs on EVERY exit from the read loop.
///
/// The de-registration is NOT conditional on being in a channel, and that distinction is
/// the whole bug it fixes: a client that went into a game is deliberately left registered
/// (so whispers still find them) with `in_channel` false, so gating the cleanup on that
/// flag left them in the registry for good — a ghost in the user list that never logs off.
/// The BROADCAST is still conditional, because there is only someone to tell if they were
/// actually in a channel.
fn disconnect(c: *Conn, fd: net.Socket, tag: []const u8) void {
    if (c.in_channel) broadcastEvent(c, EID_LEAVE, c.user_flags, c.chatName(), "");
    c.in_channel = false;
    chat.leave(fd);
    if (c.account_len > 0) friends.setOffline(c.accountName());
    log.line(tag, "client disconnected ({s})", .{c.accountName()});
}

// REALMD_TRACE=1 -> hexdump every inbound BNCS packet (the full client stream) while
// realmd still responds normally. Used to capture exactly what the real client sends
// (e.g. the account-create + set-email sequence). Set in main from the env.
pub var trace_packets: bool = false;

// Serve the modern CheckRevision.mpq + base64 challenge (mirrors real bnet) only when
// REALMD_MODERN_CHALLENGE is set — for the clientless probe. Default is the legacy A/B/C
// formula, which the real bypassed 1.14d client is stable with (modern crashes its UI path).
pub var modern_challenge: bool = false;

fn dispatch(c: *Conn, tag: []const u8, id: u8, body: []const u8) void {
    if (!hook.bncsPacket(c, id, body)) return; // an extension took it
    if (trace_packets) {
        log.line(tag, "rx SID 0x{x:0>2} ({d} bytes)", .{ id, body.len });
        if (body.len > 0) log.hexdump(tag, body);
    }
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
        SID_LEAVECHAT => onLeaveChat(c, tag),
        SID_NOTIFYJOIN => onNotifyJoin(c, tag, body),
        SID_CHECKAD => onCheckAd(c, tag),
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
        // Ad telemetry: the client reporting that it drew the banner / that someone
        // clicked it. Nothing is owed in reply, but they are the only signal an operator
        // has that the banner is actually being seen, so they are logged rather than dropped.
        SID_DISPLAYAD => log.line(tag, "ad displayed", .{}),
        SID_CLICKAD => log.line(tag, "ad clicked", .{}),
        SID_LOCALEINFO, SID_LEAVEGAME, SID_REPORTCRASH, SID_RESETPASSWORD, SID_STARTVERSIONING, SID_REPORTVERSION, SID_LOGONRESPONSE, SID_CDKEY3 => {},
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
    // Default: legacy A/B/C formula + ver-IX86-1.mpq — what the real bypassed 1.14d client
    // is stable with. (The modern CheckRevision.mpq + base64 challenge that mirrors real bnet
    // is served only when REALMD_MODERN_CHALLENGE is set, for the clientless probe — it makes
    // the real client crash, so it's opt-in.)
    if (modern_challenge) {
        w.putStr("CheckRevision.mpq");
        var chal_raw: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, chal_raw[0..4], c.server_token, .little);
        var chal_b64: [8]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&chal_b64, &chal_raw);
        w.putStr(&chal_b64);
    } else {
        w.putStr("ver-IX86-1.mpq");
        w.putStr("A=1 B=1 C=1 4 A=A^S B=B^C C=C^A A=A^B");
    }
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
    hook.accountLogin(acct, result == LOGON_OK);
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
    // The requested username is NOT decoration: for D2 it arrives as `clan*charname`, and
    // the channel list draws the part after the '*' as the character. Discarding it and
    // substituting the account name is why the lobby showed accounts instead of characters.
    const requested = r.getStr();
    if (requested.len > 0) c.setChatName(requested);
    c.setStat(r.getStr());
    const acct = c.accountName();
    log.line(tag, "enter chat as {s} (chat name '{s}', stat {d}B)", .{ acct, c.chatName(), c.stat_len });
    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, SID_ENTERCHAT);
    w.putStr(c.chatName()); // unique name — the identity the client adopts for itself
    w.putStr(c.statSlice()); // statstring (echo the client's own)
    w.putStr(acct); // account name
    finish(c, &w);
    // NOTE: do not push a SID_CHATEVENT here. The D2 realm lobby is not a chat
    // channel and an unsolicited channel-join event corrupts its control state
    // (crash in D2WINMAIN_SetControlDisabled). Chat-flag enums live in protocol.zig.
}

// SID_LEAVECHAT (0x10): the client is leaving the channel. It used to be accepted and
// ignored, which left the member sitting in the channel afterwards — still listed to
// everyone else and still receiving talk they had walked away from.
fn onLeaveChat(c: *Conn, tag: []const u8) void {
    if (!c.in_channel) return;
    // State first, announcement second. Anyone who reacts to the departure — a /whois, a friend
    // list refresh — must find the player already gone, and a broadcast now reaches other
    // instances, so the gap between the two is a store round trip wide rather than a few
    // instructions.
    chat.setGame(c.fd, ""); // clears the game; the channel is cleared below
    chat.clearChannel(c.fd);
    c.in_channel = false;
    broadcastEvent(c, EID_LEAVE, c.user_flags, c.chatName(), "");
    log.line(tag, "{s} left chat", .{c.accountName()});
}

// SID_NOTIFYJOIN (0x22): { u32 product, u32 0x0e, cstr game name, cstr password } — the
// client telling bnetd it has gone off to play (NET_SID_CLIENT_Send_0x22_NotifyJoin
// @0x51b320). The connection stays up, so whispers should still find them, but they are
// no longer in the channel and channel talk must stop reaching them. Ignoring this left a
// player in a game listed in the lobby and reading it.
fn onNotifyJoin(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU32(); // product tag
    _ = r.getU32(); // 0x0e
    const game_name = r.getStr();
    const was_in_channel = c.in_channel;
    c.in_channel = false;
    // Recorded before announced, for the same reason as leaving chat: a watcher who reacts to
    // the EID_LEAVE must find them already in the game, not still in the channel.
    chat.setGame(c.fd, game_name);
    if (was_in_channel) broadcastEvent(c, EID_LEAVE, c.user_flags, c.chatName(), "");
    log.line(tag, "{s} joined game '{s}'", .{ c.accountName(), game_name });
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
    queue(c, bytes);
}

/// `username` is what goes on the wire (the `clan*charname` the channel list draws from);
/// `account` is who the sender actually is. They are different strings and the squelch
/// list is keyed on the account, so /ignore has to be checked against that one.
const BcastCtx = struct { eid: u32, flags: u32, username: []const u8, account: []const u8, text: []const u8 };

fn bcastCb(ctx: *const BcastCtx, m: *chat.Member) void {
    // Squelch: a recipient who /ignore'd the sender doesn't see their talk. Checked
    // on the Member directly — forEachInChannel already holds the registry lock, so
    // we must NOT call back into a lock-taking chat helper here (it would deadlock).
    if (ctx.eid == EID_TALK and m.ignoresName(ctx.account)) return;
    var buf: [512]u8 = undefined;
    const bytes = buildChatEvent(&buf, ctx.eid, ctx.flags, ctx.username, ctx.text);
    chat.sendTo(m, bytes);
}

// Broadcast a CHATEVENT to every OTHER member in this connection's channel — here and on every
// other instance holding someone in it. The packet is built once and travels as bytes; the
// receiving instance applies its own members' /ignore lists, because squelching is a fact about
// the person receiving and only they know it.
fn broadcastEvent(c: *Conn, eid: u32, flags: u32, username: []const u8, text: []const u8) void {
    const ctx = BcastCtx{ .eid = eid, .flags = flags, .username = username, .account = c.accountName(), .text = text };
    chat.forEachInChannel(c.channelName(), c.fd, &ctx, bcastCb);
    var buf: [512]u8 = undefined;
    const bytes = buildChatEvent(&buf, eid, flags, username, text);
    chat.broadcastRemote(c.channelName(), c.accountName(), eid, bytes);
}

const ShowUserCtx = struct { c: *Conn };

// On join, the joiner gets an EID_SHOWUSER for each existing member (with that
// member's own flags, so ops/admins show with the right icon).
fn showUserCb(ctx: *const ShowUserCtx, m: *chat.Member) void {
    sendEvent(ctx.c, EID_SHOWUSER, m.flags, m.displaySlice(), m.statSlice());
}

// The same, for members held by another instance. Without this the channel list shows only the
// people who happened to land on the same realmd — half the room, with nothing to say it is half.
fn showRemoteUserCb(ctx: *const ShowUserCtx, rm: chat.RemoteMember) void {
    sendEvent(ctx.c, EID_SHOWUSER, rm.flags, rm.display, rm.stat);
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
    // Realm-wide, not per-instance: counting only our own members would hand the operator badge
    // to the first person on every replica, so a busy channel would have as many ops as instances.
    if (chat.countInChannelShared(channel) == 0) flags |= FLAG_OPERATOR;
    c.user_flags = flags;
    log.line(tag, "join channel '{s}' as {s} (flags=0x{x})", .{ channel, acct, flags });

    c.setChannel(channel);
    _ = chat.joinShared(c.fd, acct, c.chatName(), channel, flags, c.statSlice());
    chat.setGame(c.fd, ""); // back in the lobby: no longer in a game

    // Tell the joiner which channel they're in (EID_CHANNEL carries the CHANNEL flags),
    // then list existing members, then announce the join to everyone else.
    sendEvent(c, EID_CHANNEL, @intFromEnum(protocol.ChatChannelFlag.public), channel, "");
    const ctx = ShowUserCtx{ .c = c };
    chat.forEachInChannel(channel, c.fd, &ctx, showUserCb);
    chat.forEachRemoteInChannel(channel, &ctx, showRemoteUserCb);
    broadcastEvent(c, EID_JOIN, flags, c.chatName(), c.statSlice());
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
        const bytes = buildChatEvent(&buf, EID_WHISPER, c.user_flags, c.chatName(), w.msg);
        // Local first — most whispers are between people on the same instance and cost nothing
        // extra. Only when nobody here answers to that name do we ask the rest of the realm,
        // which is the difference between "not logged on" and "not on THIS realmd".
        var res = chat.whisperEx(w.target, bytes); // delivers unless target is in DND
        if (!res.found) res = chat.whisperRemote(w.target, acct, bytes);
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
    if (handleHelpCmd(c, text)) return;
    if (hook.chatCommand(c, tag, text)) return;
    if (text.len > 0 and text[0] == '/') {
        // An unknown command must never reach the channel — typing a typo should not say
        // it out loud. It used to answer with an empty INFO line, which looks to the
        // player exactly like the command silently working.
        sendEvent(c, EID_ERROR, 0, acct, "That is not a valid command. Type /help for a list.");
        return;
    }

    log.line(tag, "{s} talks: {s}", .{ acct, text });
    // Broadcast to the OTHER members only (forEachInChannel excludes c.fd). The 1.14d
    // client already displays the sender's own line locally, so echoing it back here
    // makes every message the user types appear twice.
    // Named the same way the channel list names them, or the client cannot match a
    // line of chat to the row it came from.
    broadcastEvent(c, EID_TALK, c.user_flags, c.chatName(), text);
}

const Whisper = struct { target: []const u8, msg: []const u8 };

/// If `text` starts with "<verb> " (case-insensitively), the rest after the space.
fn afterVerb(text: []const u8, verb: []const u8) ?[]const u8 {
    if (text.len <= verb.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[0..verb.len], verb)) return null;
    if (text[verb.len] != ' ') return null;
    return text[verb.len + 1 ..];
}

/// The whisper aliases the 1.14d client itself offers. CHAT_HandleWhisperCommand is tried
/// with "/msg", "/m", "/whisper" and "/w" in turn (D2Client/UI/Chat.cpp @0x47c1e0) and the
/// input is forwarded to the realm verbatim, so all four have to be understood here — /m
/// and /msg used to fall through and do nothing at all. The client compares them with
/// stricmp, so this does too.
const whisper_verbs = [_][]const u8{ "/w", "/whisper", "/m", "/msg" };

fn parseWhisper(text: []const u8) ?Whisper {
    for (whisper_verbs) |v| {
        const rest = afterVerb(text, v) orelse continue;
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        return .{ .target = rest[0..sp], .msg = rest[sp + 1 ..] };
    }
    return null;
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
        // Store the ACCOUNT, not what was typed: the broadcast path checks the sender's
        // account, and a player types the character name the channel list shows them.
        // Falls back to the literal text so squelching someone offline still records
        // something rather than silently doing nothing.
        var abuf: [chat.max_name]u8 = undefined;
        const target = chat.resolveAccount(cmd.arg, &abuf) orelse cmd.arg;
        if (cmd.arg.len == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "Usage: /ignore <name>");
        } else if (chat.addIgnore(c.fd, target)) {
            sendEvent(c, EID_INFO, 0, acct, std.fmt.bufPrint(&rb, "{s} has been squelched.", .{cmd.arg}) catch return true);
        } else sendEvent(c, EID_ERROR, 0, acct, "Already squelched, or your ignore list is full.");
        return true;
    }
    // /unignore <name> (alias /unsquelch).
    if (eqCmd(cmd.verb, "unignore") or eqCmd(cmd.verb, "unsquelch")) {
        var abuf2: [chat.max_name]u8 = undefined;
        const untarget = chat.resolveAccount(cmd.arg, &abuf2) orelse cmd.arg;
        if (cmd.arg.len == 0) {
            sendEvent(c, EID_ERROR, 0, acct, "Usage: /unignore <name>");
        } else if (chat.removeIgnore(c.fd, untarget)) {
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
        if (chat.presenceOfAnywhere(cmd.arg)) |pres| {
            const where = pres.channelSlice();
            const line = if (where.len == 0)
                std.fmt.bufPrint(&rb, "{s} is logged on.", .{cmd.arg}) catch return true
            else if (pres.in_game)
                std.fmt.bufPrint(&rb, "{s} is in the game {s}.", .{ cmd.arg, where }) catch return true
            else
                std.fmt.bufPrint(&rb, "{s} is in channel {s}.", .{ cmd.arg, where }) catch return true;
            sendEvent(c, EID_INFO, 0, acct, line);
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

/// "/help" and "/?" — the client forwards both to the realm rather than answering them
/// itself (CHAT_HandleResignCommand is called with each in turn), so this is the only
/// place a player can be told what they can type.
fn handleHelpCmd(c: *Conn, text: []const u8) bool {
    const cmd = parseSlash(text) orelse return false;
    if (!eqCmd(cmd.verb, "help") and !std.mem.eql(u8, cmd.verb, "?")) return false;
    const lines = [_][]const u8{
        "Commands:",
        "  /w /whisper /m /msg <name> <text>  send a private message",
        "  /f add|remove|list <name>          manage your friends list",
        "  /away [message]                    set or clear an away reply",
        "  /dnd [message]                     block incoming whispers",
        "  /ignore /unignore <name>           squelch or unsquelch someone",
        "  /whois <name>                      find which channel someone is in",
        "  /kick <name>                       remove someone (channel operators)",
        "  /guild                             guild commands (/guild help)",
    };
    for (lines) |l| sendEvent(c, EID_INFO, 0, "", l);
    return true;
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
            // Chat text is the ONLY way a 1.14d client can be shown this — see the note on
            // onFriendsList. So say where each friend actually is, not just whether they
            // are on: "online in Diablo II", "away", and so on.
            for (infos[0..n]) |f| {
                var rb: [96]u8 = undefined;
                const where: []const u8 = if (!f.online)
                    "offline"
                else if (f.dnd)
                    "online (do not disturb)"
                else if (f.away)
                    "online (away)"
                else if (f.location_len > 0 and f.in_game)
                    std.fmt.bufPrint(&rb, "in the game {s}", .{f.locationSlice()}) catch "online"
                else if (f.location_len > 0)
                    std.fmt.bufPrint(&rb, "online in {s}", .{f.locationSlice()}) catch "online"
                else
                    "online";
                sendEvent(c, EID_INFO, 0, f.nameSlice(), where);
            }
        },
    }
}

fn onQueryRealms(c: *Conn, tag: []const u8) void {
    if (trace_packets) log.line(tag, "query realms -> {s}", .{realm_name});
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
    // Field-level detail for protocol work; the line below reports the same logon with the
    // session id.
    if (trace_packets) log.line(tag, "realm logon: parsed token=0x{x} title='{s}' acct='{s}' (minting session)", .{ c.client_token, title, acct });
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

// SID_GETFILETIME (0x33): client asks how old a server file is (bnserver-D2DV.ini, ToS, ...)
// before fetching via BNFTP. NET_SID_CLIENT_Incoming_GetFileTime @0x521110 compares the
// timestamp against its cache; zero means "older than anything owned" -> never fetched.
// Reply with the real mtime when we have the file, zero only when we genuinely don't.
fn onGetFileTime(c: *Conn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU32();
    const unknown = r.getU32();
    const fname = r.getStr();
    const mtime = store.bnftpMtime(fname);
    if (mtime) |m| {
        log.line(tag, "getfiletime '{s}' -> mtime {d}", .{ fname, m });
    } else {
        log.line(tag, "getfiletime '{s}' -> not held", .{fname});
    }
    var buf: [128]u8 = undefined;
    var w = startPacket(&buf, SID_GETFILETIME);
    w.putU32(reqid);
    w.putU32(unknown);
    w.putU64(if (mtime) |m| unixToFiletime(m) else 0);
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

    // Four accounts x sixteen keys x a 256-byte value is the shape the request can ask
    // for, and it does not fit in anything modest — size for it rather than truncate.
    var buf: [4 * 16 * 258 + 32]u8 = undefined;
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
//
// Banner ad flow:
//   C->S SID_CHECKAD (0x15)  { platform "IX86", product, last-ad-id, unix time }
//   S->C SID_CHECKAD (0x15)  { u32 adId, u32 fileExtension, FILETIME fileTime,
//                              cstr filename, cstr url }
//   client downloads `filename` over BNFTP, reports SID_DISPLAYAD (0x21), and on a
//   click sends SID_CLICKAD (0x16) then SID_QUERYADURL (0x41) for the browser target.
//
// NET_SID_CLIENT_Incoming_CheckAd @0x521150 only redraws when the packet is > 0x10
// bytes, the ad id differs, and both strings are non-empty — else the empty reply
// looked indistinguishable from having no ads.
//
// Set by main() from REALMD_AD_FILE / REALMD_AD_URL; served from <data_dir>/bnftp/
// by the same BNFTP listener as the version-check MPQ.
pub var ad_file: []const u8 = "";
pub var ad_url: []const u8 = "";

/// Pack a filename's extension into the u32 the client carries alongside the ad, the
/// same 4-char-tag form as everything else on this wire ("pcx", "mng", …).
fn adExtension(filename: []const u8) u32 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return 0;
    var tag: [4]u8 = .{ 0, 0, 0, 0 };
    const ext = filename[dot + 1 ..];
    const n = @min(ext.len, tag.len);
    for (0..n) |i| tag[i] = ext[i];
    return std.mem.readInt(u32, &tag, .little);
}

/// A stable id for the configured ad. The client re-downloads only when this differs
/// from the id it is already showing, so it must NOT change per connection (that would
/// re-fetch the banner constantly) and must not be zero (the client's initial value).
fn adId() u32 {
    var h: u32 = 2166136261;
    for (ad_file) |ch| h = (h ^ ch) *% 16777619;
    return h | 1;
}

fn onCheckAd(c: *Conn, tag: []const u8) void {
    if (ad_file.len == 0 or ad_url.len == 0) {
        // Silent: every client asks on every login, and main() already reports a configured ad.
        return; // no reply at all: the client just keeps whatever it has
    }
    var buf: [512]u8 = undefined;
    var w = startPacket(&buf, SID_CHECKAD);
    w.putU32(adId());
    w.putU32(adExtension(ad_file));
    // FILETIME the download layer compares a cached copy against. We hand it "now", so a
    // client that already has the file still treats the server's as current rather than
    // deciding its cache is newer and skipping the fetch.
    w.putU64(unixToFiletime(time(null)));
    w.putStr(ad_file);
    w.putStr(ad_url);
    finish(c, &w);
    log.line(tag, "checkad -> ad 0x{x} file='{s}' url='{s}'", .{ adId(), ad_file, ad_url });
}

/// Seconds-since-epoch to a Win32 FILETIME (100ns ticks since 1601-01-01).
fn unixToFiletime(secs: i64) u64 {
    const epoch_delta: u64 = 11644473600; // 1601 -> 1970 in seconds
    const s: u64 = if (secs < 0) 0 else @intCast(secs);
    return (s + epoch_delta) * 10_000_000;
}

// SID_QUERYADURL (0x41): the client asks where a clicked banner should take it. Reply is
// the ad id it asked about plus the URL; answering with id 0 and an empty string, as this
// used to, is how you get a banner that cannot be clicked.
fn onQueryAdURL(c: *Conn, tag: []const u8) void {
    var buf: [512]u8 = undefined;
    var w = startPacket(&buf, SID_QUERYADURL);
    if (ad_file.len == 0 or ad_url.len == 0) {
        w.putU32(0);
        w.putStr("");
        finish(c, &w);
        log.line(tag, "queryadurl -> none", .{});
        return;
    }
    w.putU32(adId());
    w.putStr(ad_url);
    finish(c, &w);
    log.line(tag, "queryadurl -> 0x{x} '{s}'", .{ adId(), ad_url });
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
        // A password-less account has no proof to offer, and treating that as "nothing to prove"
        // hands it to whoever asks first: an unauthenticated client could set a password on any
        // such account and own it. The only proof it can give is that this connection is ALREADY
        // logged in as that account, so that is what is required.
        var verified = false;
        if (has_pw) {
            const expect = xsha1.doubleHash(client_token, server_token, stored);
            verified = std.mem.eql(u8, &expect, &old_proof);
        } else {
            verified = c.account_len != 0 and std.ascii.eqlIgnoreCase(c.accountName(), user);
            if (!verified) log.line(tag, "changepassword '{s}' refused: password-less and this connection is not logged in as it", .{user});
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

// SID_AUTHACCOUNTLOGON (0x53): NLS/SRP secure-logon path, sent only when the client's
// g_nBNetClientToken == 1 (non-default; RE-confirmed via BNCLIENT_SendLogonRequest).
// realmd implements OLS (LOGONRESPONSE2 0x3a) only, not NLS/SRP, so fail cleanly instead
// of hanging: reply = u32 status, 1 = "account does not exist" (no salt/serverKey follows).
fn onAuthAccountLogon(c: *Conn, tag: []const u8) void {
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, SID_AUTHACCOUNTLOGON);
    w.putU32(1); // 1 = account does not exist — clean NLS failure (realmd is OLS-only)
    finish(c, &w);
    log.line(tag, "authaccountlogon (NLS) -> rejected; realmd is OLS-only", .{});
}

// Product code for an online friend (D2XP), little-endian 4 chars as the client expects.
const PRODUCT_D2XP: u32 = @bitCast([4]u8{ 'D', '2', 'X', 'P' });

// SID_FRIENDSLIST (0x65): this account's friends. Per entry: cstr name, u8 status flags,
// u8 location (0=offline, 1=online), u32 product, cstr location string.
//
// A 1.14d client CANNOT RECEIVE THIS: NET_SID_CLIENT_IncomingPacketHandler @0x521b00
// drops any id >= 0x5e before the table lookup. Kept because clientless tooling and other
// Battle.net clients do speak it; real D2 players get friend status via handleFriendCmd
// chat text instead.
const FRIEND_STATUS_DND: u8 = 0x01;
const FRIEND_STATUS_AWAY: u8 = 0x02;

/// Worst case on the wire: every friend at the longest name, in the longest-named channel.
/// Sized rather than guessed, because guessing is how the previous 2048 ended up ~800 bytes
/// short of what 50 friends can produce — and a short buffer here used to be a panic.
const friends_reply_max = 8 + friends.max_friends * friends_entry_max;

/// One entry at its longest: name + NUL, status, location byte, product, then the location
/// string + NUL.
const friends_entry_max = (friends.max_name + 1) + 1 + 1 + 4 + (chat.max_channel + 1);

comptime {
    // The reachable worst case is every friend online, in a maximum-length channel. It is
    // ~2.8KB; this buffer was 2048, which the bounds-checked writer would now truncate
    // rather than crash on — but a truncated friends list is still a broken reply, and the
    // arithmetic is right here to be checked rather than eyeballed.
    if (friends_reply_max < 5 + friends.max_friends * friends_entry_max)
        @compileError("SID_FRIENDSLIST buffer is smaller than the list it must hold");
}

fn onFriendsList(c: *Conn, tag: []const u8) void {
    var infos: [friends.max_friends]friends.FriendInfo = undefined;
    const n = friends.list(c.accountName(), &infos);
    log.line(tag, "friends list for {s} -> {d} friend(s)", .{ c.accountName(), n });
    var buf: [friends_reply_max]u8 = undefined;
    var w = startPacket(&buf, SID_FRIENDSLIST);
    w.putU8(@intCast(n));
    for (infos[0..n]) |f| {
        var flags: u8 = 0;
        if (f.dnd) flags |= FRIEND_STATUS_DND;
        if (f.away) flags |= FRIEND_STATUS_AWAY;
        w.putStr(f.nameSlice());
        w.putU8(flags);
        w.putU8(if (f.online) @as(u8, 1) else 0); // location
        w.putU32(if (f.online) PRODUCT_D2XP else 0);
        w.putStr(f.locationSlice()); // the channel they are in, empty if none
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
