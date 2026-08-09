//! Clientless wire-protocol clients for realmd: BNCS (bnetd), MCP (d2cs),
//! d2dbs/gs-link control framing — raw TCP, no wine/Game.exe. Ported from
//! tools/e2e/realmclient.py; the Python encodes the exact wire formats.
const std = @import("std");
const net = @import("net.zig");
const xsha1 = @import("xsha1.zig");
const Socket = net.Socket;

// Ports the harness's own realmd listens on. Overridable as a block via E2E_PORT_BASE
// (set by main() before anything connects) so a run is not at the mercy of whatever else
// happens to be sitting on 6112 — which silently turns the whole suite into a test of
// someone else's server.
pub var HOST_BNET: u16 = 6112;
pub var HOST_D2CS: u16 = 6113;
pub var HOST_D2DBS: u16 = 6114;
pub var HOST_GS: u16 = 6115;

/// Move the block to `base`..`base+3`.
pub fn setPortBase(base: u16) void {
    HOST_BNET = base;
    HOST_D2CS = base + 1;
    HOST_D2DBS = base + 2;
    HOST_GS = base + 3;
}

// BNCS opcodes
const SID_ENTERCHAT = 0x0A;
const SID_JOINCHANNEL = 0x0C;
const SID_CHATEVENT = 0x0F;
const SID_CHATCOMMAND = 0x0E;
const SID_LOGONRESPONSE2 = 0x3A;
const SID_CREATEACCOUNT2 = 0x3D;
const SID_LOGONREALMEX = 0x3E;
const SID_LEAVECHAT = 0x10;
const SID_GETFILETIME = 0x33;
const SID_NOTIFYJOIN = 0x22;
const SID_FRIENDSLIST = 0x65;
const SID_CHECKAD = 0x15;
const SID_QUERYADURL = 0x41;

// Fixed client token used for OLS login double-hashing (any non-zero value works;
// the server combines it with the per-connection server_token it sent us).
const CLIENT_TOKEN: u32 = 0xCAFEBABE;
const SID_AUTH_INFO = 0x50;
const SID_AUTH_CHECK = 0x51;

// MCP opcodes
const MCP_STARTUP = 0x01;
const MCP_CHARCREATE = 0x02;
const MCP_CREATEGAME = 0x03;
const MCP_GAMELIST = 0x05;
const MCP_GAMEINFO = 0x06;
const MCP_CHARLOGON = 0x07;
const MCP_LADDERDATA = 0x11;
const MCP_JOINGAME = 0x04;
const MCP_CHARDELETE = 0x0a;
const MCP_CHARLIST2 = 0x19;
const MCP_CHARUPGRADE = 0x18;

// d2dbs opcodes
pub const DBS_SAVE = 0x30;
pub const DBS_GET = 0x31;
pub const DBS_DATATYPE_CHARSAVE = 0x01;

// gs-link control opcodes
pub const GS_AUTHREQ = 0x10;
pub const GS_AUTHREPLY = 0x11;
pub const GS_SETGSINFO = 0x12;
pub const GS_ADDRINFO = 0x24;
pub const GS_CREATEGAME = 0x20;
pub const GS_JOINGAME = 0x21;
pub const GS_UPDATEGAMEINFO = 0x22;

pub const CLASS_NAMES = [_][]const u8{
    "Amazon", "Sorceress", "Necromancer", "Paladin",
    "Barbarian", "Druid", "Assassin",
};

// --- BNCS framing: <BBH ff,id,len> + body ---
fn bncsSend(fd: Socket, id: u8, body: []const u8) !void {
    var hdr: [4]u8 = undefined;
    var w = net.Writer.init(&hdr);
    w.u8v(0xFF);
    w.u8v(id);
    w.u16v(@intCast(4 + body.len));
    try net.writeAll(fd, w.slice());
    try net.writeAll(fd, body);
}

/// Read a BNCS packet body into `buf`; returns (id, body slice into buf).
fn bncsRecv(fd: Socket, buf: []u8) !struct { id: u8, body: []const u8 } {
    var hdr: [4]u8 = undefined;
    try net.readFull(fd, &hdr);
    if (hdr[0] != 0xFF) return error.BadBncsHeader;
    const id = hdr[1];
    const ln = net.rdU16(&hdr, 2);
    const blen = ln - 4;
    try net.readFull(fd, buf[0..blen]);
    return .{ .id = id, .body = buf[0..blen] };
}

// --- MCP framing: <HB len,id> + body ---
fn mcpSend(fd: Socket, id: u8, body: []const u8) !void {
    var hdr: [3]u8 = undefined;
    var w = net.Writer.init(&hdr);
    w.u16v(@intCast(3 + body.len));
    w.u8v(id);
    try net.writeAll(fd, w.slice());
    try net.writeAll(fd, body);
}

fn mcpRecv(fd: Socket, buf: []u8) !struct { id: u8, body: []const u8 } {
    var hdr: [3]u8 = undefined;
    try net.readFull(fd, &hdr);
    const ln = net.rdU16(&hdr, 0);
    const id = hdr[2];
    const blen = ln - 3;
    try net.readFull(fd, buf[0..blen]);
    return .{ .id = id, .body = buf[0..blen] };
}

// --- gs-link / d2dbs control framing: <HHI size,type,seq> + body ---
pub fn ctlSend(fd: Socket, typ: u16, body: []const u8) !void {
    var hdr: [8]u8 = undefined;
    var w = net.Writer.init(&hdr);
    w.u16v(@intCast(8 + body.len));
    w.u16v(typ);
    w.u32v(1); // seq
    try net.writeAll(fd, w.slice());
    try net.writeAll(fd, body);
}

pub const Ctl = struct { typ: u16, seq: u32, body: []const u8 };

pub fn ctlRecv(fd: Socket, buf: []u8) !Ctl {
    var hdr: [8]u8 = undefined;
    try net.readFull(fd, &hdr);
    const size = net.rdU16(&hdr, 0);
    const typ = net.rdU16(&hdr, 2);
    const seq = net.rdU32(&hdr, 4);
    const blen = size - 8;
    try net.readFull(fd, buf[0..blen]);
    return .{ .typ = typ, .seq = seq, .body = buf[0..blen] };
}

fn dec14(b0: u8, b1: u8) u16 {
    return (@as(u16, b1) & 0x7F) * 128 + (@as(u16, b0) & 0x7F);
}

pub const ChatEvent = struct {
    eid: u32,
    username: []const u8, // slice into RealmClient.rxbuf (valid until next recv)
    text: []const u8,
};

// SID_CHATEVENT event ids.
pub const EID_SHOWUSER = 0x01;
pub const EID_JOIN = 0x02;
pub const EID_LEAVE = 0x03;
pub const EID_WHISPER = 0x04;
pub const EID_TALK = 0x05;
pub const EID_CHANNEL = 0x07;
pub const EID_INFO = 0x12;
pub const EID_ERROR = 0x13;

/// Reply to MCP_CREATEGAME / MCP_JOINGAME. Named rather than anonymous so the
/// no-password wrappers can forward the password-carrying versions' return value.
pub const CreateResult = struct { token: u16, result: u32 };
pub const JoinResult = struct { token: u16, ip: [4]u8, result: u32 };

/// The join screen's detail panel for one game (MCP_GAMEINFO).
pub const GameDetail = struct {
    token: u32 = 0,
    uptime: u32 = 0,
    level: u8 = 0,
    level_diff: u8 = 0,
    max_players: u8 = 0,
    players: u8 = 0,
    /// Parallel to `names`: class id and level of each listed player.
    classes: [16]u8 = [_]u8{0} ** 16,
    levels: [16]u8 = [_]u8{0} ** 16,
    description: []const u8 = "",
    names: [8][]const u8 = [_][]const u8{""} ** 8,
};

/// One row of the join-screen game list.
pub const GameEntry = struct {
    name: []const u8, // slice into the caller's dst buffer
    description: []const u8, // ditto
    gameid: u32 = 0,
    players: u8 = 0,
};

pub const LadderEntry = struct {
    name: []const u8, // slice into the caller's dst buffer
    level: u32 = 0,
    class_id: u8 = 0,
    experience: u32 = 0,
};

pub const CharEntry = struct {
    name: []const u8, // slice into the caller's recv buffer
    class_id: i32 = -1,
    level: u32 = 0,
    flags: u16 = 0,
};

/// Decode a CHARLIST2 statstring. Layout (CharSel.cpp):
///   [0..2) 14-bit realm count; [13] class byte (class_id=byte-1);
///   [25] level; [26..28) 14-bit flags — the low byte mirrors the .d2s status byte
///   (hardcore 0x04, died 0x08, expansion 0x20, ladder 0x40), progression above it.
fn decodeStatstring(ss: []const u8, e: *CharEntry) void {
    if (ss.len > 13) e.class_id = @as(i32, ss[13]) - 1;
    if (ss.len > 25) e.level = ss[25];
    if (ss.len >= 28) e.flags = dec14(ss[26], ss[27]);
}

// ---------------------------------------------------------------------------
// RealmClient: bnetd handshake -> d2cs session
// ---------------------------------------------------------------------------
pub const RealmClient = struct {
    bnet: ?Socket = null,
    d2cs: ?Socket = null,
    // Ports default to the single-instance harness layout; the multi-instance
    // scenario overrides these to point at a specific realmd instance.
    // 0 = "the harness's own realmd", resolved at connect time so the port block can be
    // moved without every scenario having to know. A scenario that targets a specific
    // instance sets these explicitly.
    bnet_port: u16 = 0,
    d2cs_port: u16 = 0,
    d2dbs_port: u16 = 0,
    realm_name: []const u8 = "TypeGuru",
    account: []const u8 = "",
    server_token: u32 = 0,
    cookie: u32 = 0,
    status: u32 = 0,
    lo: u32 = 0,
    hi: u32 = 0,
    rxbuf: [4096]u8 = undefined,
    unique_name_buf: [64]u8 = undefined,
    unique_name_len: usize = 0,

    pub fn sessionId(self: *RealmClient) u64 {
        return @as(u64, self.lo) | (@as(u64, self.hi) << 32);
    }

    pub fn connectBnet(self: *RealmClient) !void {
        const fd = try net.connectLocal(if (self.bnet_port != 0) self.bnet_port else HOST_BNET);
        try net.writeAll(fd, &[_]u8{0x01}); // protocol selector
        self.bnet = fd;
    }

    pub fn auth(self: *RealmClient) !void {
        const fd = self.bnet.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(0);
        w.u32v(0x49583836);
        w.u32v(0x44325850);
        w.u32v(0x0E);
        w.zeros(20); // five u32 zeros
        w.bytes("US\x00US\x00");
        try bncsSend(fd, SID_AUTH_INFO, w.slice());

        var r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_AUTH_INFO) return error.AuthInfoBadId;
        const logon_type = net.rdU32(r.body, 0);
        self.server_token = net.rdU32(r.body, 4);
        if (logon_type != 0) return error.UnexpectedLogonType;

        var cbuf: [16]u8 = undefined;
        var cw = net.Writer.init(&cbuf);
        cw.u32v(1);
        cw.u32v(0);
        cw.u32v(0);
        cw.u32v(0);
        // followed by "\x00i\x00o\x00"
        var c2: [21]u8 = undefined;
        @memcpy(c2[0..16], cw.slice());
        @memcpy(c2[16..21], "\x00i\x00o\x00");
        try bncsSend(fd, SID_AUTH_CHECK, &c2);
        r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_AUTH_CHECK or net.rdU32(r.body, 0) != 0) return error.AuthCheckFailed;
    }

    pub fn login(self: *RealmClient, acct: []const u8) !void {
        const fd = self.bnet.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(1);
        w.u32v(self.server_token);
        w.zeros(20);
        w.cstr(acct);
        try bncsSend(fd, SID_LOGONRESPONSE2, w.slice());
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_LOGONRESPONSE2 or net.rdU32(r.body, 0) != 0) return error.LogonFailed;
        self.account = acct;
    }

    /// SID_CREATEACCOUNT2 — body: u8[20] xsha1(lowercased password) + cstr name.
    /// Returns the server's result u32 (0 = created, non-zero = name taken/invalid).
    pub fn createAccount(self: *RealmClient, acct: []const u8, password: []const u8) !u32 {
        const fd = self.bnet.?;
        const pwhash = xsha1.passwordHash(password);
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.bytes(&pwhash);
        w.cstr(acct);
        try bncsSend(fd, SID_CREATEACCOUNT2, w.slice());
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_CREATEACCOUNT2) return error.CreateAccountBadId;
        return net.rdU32(r.body, 0);
    }

    /// Password-aware OLS login. Sends the double-hash computed from CLIENT_TOKEN,
    /// the server_token read during auth(), and xsha1(password). Returns the
    /// server's result u32 (0 = success, 2 = bad password).
    pub fn loginPwResult(self: *RealmClient, acct: []const u8, password: []const u8) !u32 {
        const fd = self.bnet.?;
        const dbl = xsha1.doubleHash(CLIENT_TOKEN, self.server_token, xsha1.passwordHash(password));
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(CLIENT_TOKEN);
        w.u32v(self.server_token);
        w.bytes(&dbl);
        w.cstr(acct);
        try bncsSend(fd, SID_LOGONRESPONSE2, w.slice());
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_LOGONRESPONSE2) return error.LogonBadId;
        const result = net.rdU32(r.body, 0);
        if (result == 0) self.account = acct;
        return result;
    }

    pub fn enterRealm(self: *RealmClient) !void {
        const fd = self.bnet.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(1);
        w.zeros(20);
        w.cstr(self.realm_name);
        try bncsSend(fd, SID_LOGONREALMEX, w.slice());
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_LOGONREALMEX) return error.RealmExBadId;
        self.cookie = net.rdU32(r.body, 0);
        self.status = net.rdU32(r.body, 4);
        self.lo = net.rdU32(r.body, 8);
        self.hi = net.rdU32(r.body, 12);
        if (self.status != 0) return error.RealmLogonStatus;
    }

    /// SID_ENTERCHAT — announce ourselves into chat. Server replies with our
    /// unique/account name (consumed, not validated here).
    pub fn enterChat(self: *RealmClient) !void {
        return self.enterChatAs(self.account, "");
    }

    /// SID_ENTERCHAT with an explicit requested username and statstring. A real D2 client
    /// asks to be known as `clan*charname`; the reply's first string is the identity the
    /// client then adopts, so this returns it for the caller to check.
    pub fn enterChatAs(self: *RealmClient, username: []const u8, statstring: []const u8) !void {
        const fd = self.bnet.?;
        var body: [256]u8 = undefined;
        var w = net.Writer.init(&body);
        w.cstr(username);
        w.cstr(statstring);
        try bncsSend(fd, SID_ENTERCHAT, w.slice());
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_ENTERCHAT) return error.EnterChatBadId;
        const unique = std.mem.sliceTo(r.body, 0);
        const n = @min(unique.len, self.unique_name_buf.len);
        @memcpy(self.unique_name_buf[0..n], unique[0..n]);
        self.unique_name_len = n;
    }

    /// The unique name SID_ENTERCHAT came back with (valid after enterChatAs).
    pub fn uniqueName(self: *RealmClient) []const u8 {
        return self.unique_name_buf[0..self.unique_name_len];
    }

/// SID_CHECKAD reply, as NET_SID_CLIENT_Incoming_CheckAd @0x521150 reads it.
pub const AdInfo = struct {
    id: u32 = 0,
    extension: u32 = 0,
    filetime: u64 = 0,
    filename: []const u8 = "",
    url: []const u8 = "",
    /// Whether the client would actually act on this: the handler needs a body longer
    /// than 0x10, a new id, and BOTH strings non-empty before it fetches anything.
    body_len: usize = 0,
};

    /// SID_GETFILETIME (0x33): how old is a server file? Request is
    /// { u32 requestId, u32 unknown, cstr filename }; the reply echoes both dwords, then
    /// a FILETIME and the filename. Returns the FILETIME (0 = the server has no such file).
    pub fn getFileTime(self: *RealmClient, filename: []const u8) !u64 {
        const fd = self.bnet.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(1); // request id
        w.u32v(0);
        w.cstr(filename);
        try bncsSend(fd, SID_GETFILETIME, w.slice());
        var r = try bncsRecv(fd, &self.rxbuf);
        var tries: usize = 0;
        while (r.id != SID_GETFILETIME) : (tries += 1) {
            if (tries >= 8) return error.GetFileTimeBadId;
            r = try bncsRecv(fd, &self.rxbuf);
        }
        if (r.body.len < 16) return error.GetFileTimeShort;
        return @as(u64, net.rdU32(r.body, 8)) | (@as(u64, net.rdU32(r.body, 12)) << 32);
    }

    /// SID_NOTIFYJOIN (0x22): tell bnetd we went off to play. Body is
    /// { u32 product, u32 0x0e, cstr game name, cstr password } — the shape
    /// NET_SID_CLIENT_Send_0x22_NotifyJoin @0x51b320 builds. No reply.
    pub fn notifyJoin(self: *RealmClient, game_name: []const u8) !void {
        const fd = self.bnet.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(0x44325850); // D2XP
        w.u32v(0x0e);
        w.cstr(game_name);
        w.cstr("");
        try bncsSend(fd, SID_NOTIFYJOIN, w.slice());
    }

    /// SID_LEAVECHAT (0x10): leave the channel. No reply.
    pub fn leaveChat(self: *RealmClient) !void {
        try bncsSend(self.bnet.?, SID_LEAVECHAT, "");
    }

    /// SID_FRIENDSLIST (0x65): u8 count, then per friend cstr name, u8 status,
    /// u8 location, u32 product, cstr location-string. Names are copied into `dst`.
    pub fn friendsList(self: *RealmClient, out: [][]const u8, dst: []u8) !usize {
        const fd = self.bnet.?;
        try bncsSend(fd, SID_FRIENDSLIST, "");
        // Chat events queue up on the same socket, so skip whatever is already in flight
        // rather than mistaking the first packet back for the reply.
        var r = try bncsRecv(fd, &self.rxbuf);
        var tries: usize = 0;
        while (r.id != SID_FRIENDSLIST) : (tries += 1) {
            if (tries >= 16) return error.FriendsListBadId;
            r = try bncsRecv(fd, &self.rxbuf);
        }
        if (r.body.len < 1) return error.FriendsListShort;
        const count = r.body[0];
        var off: usize = 1;
        var di: usize = 0;
        var n: usize = 0;
        while (n < count and n < out.len) : (n += 1) {
            if (off >= r.body.len) break;
            const nm = std.mem.sliceTo(r.body[off..], 0);
            @memcpy(dst[di .. di + nm.len], nm);
            out[n] = dst[di .. di + nm.len];
            di += nm.len;
            off += nm.len + 1 + 1 + 1 + 4; // name NUL, status, location, product
            const loc = std.mem.sliceTo(r.body[@min(off, r.body.len)..], 0);
            off += loc.len + 1;
        }
        return n;
    }

    /// SID_CHECKAD (0x15): ask for a banner. Body is { "IX86", product, last-ad-id,
    /// unix time } — 16 bytes, matching NET_SID_CLIENT_Send_0x15_CheckAd @0x51b010.
    /// Returns null when the server sends nothing back (its "no ad" answer).
    pub fn checkAd(self: *RealmClient, last_ad_id: u32, dst: []u8) !?AdInfo {
        const fd = self.bnet.?;
        var body: [16]u8 = undefined;
        var w = net.Writer.init(&body);
        w.bytes("IX86");
        w.u32v(0x44325850); // product D2XP
        w.u32v(last_ad_id);
        w.u32v(0);
        try bncsSend(fd, SID_CHECKAD, w.slice());
        const r = bncsRecv(fd, &self.rxbuf) catch return null;
        if (r.id != SID_CHECKAD) return error.CheckAdBadId;
        if (r.body.len < 0x10) return error.CheckAdShort;
        var ad = AdInfo{
            .id = net.rdU32(r.body, 0),
            .extension = net.rdU32(r.body, 4),
            .body_len = r.body.len,
        };
        ad.filetime = @as(u64, net.rdU32(r.body, 8)) | (@as(u64, net.rdU32(r.body, 12)) << 32);
        const fname = std.mem.sliceTo(r.body[0x10..], 0);
        @memcpy(dst[0..fname.len], fname);
        ad.filename = dst[0..fname.len];
        const url = std.mem.sliceTo(r.body[0x10 + fname.len + 1 ..], 0);
        @memcpy(dst[fname.len .. fname.len + url.len], url);
        ad.url = dst[fname.len .. fname.len + url.len];
        return ad;
    }

    /// SID_QUERYADURL (0x41): where a clicked banner goes. Returns { id, url }.
    pub fn queryAdUrl(self: *RealmClient, ad_id: u32, dst: []u8) !struct { id: u32, url: []const u8 } {
        const fd = self.bnet.?;
        var body: [4]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(ad_id);
        try bncsSend(fd, SID_QUERYADURL, w.slice());
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_QUERYADURL) return error.QueryAdUrlBadId;
        const id = net.rdU32(r.body, 0);
        const url = std.mem.sliceTo(r.body[4..], 0);
        @memcpy(dst[0..url.len], url);
        return .{ .id = id, .url = dst[0..url.len] };
    }

    /// SID_JOINCHANNEL — body is u32 flags + cstr channel name.
    pub fn joinChannel(self: *RealmClient, channel: []const u8) !void {
        const fd = self.bnet.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(0); // flags
        w.cstr(channel);
        try bncsSend(fd, SID_JOINCHANNEL, w.slice());
    }

    /// SID_CHATCOMMAND — body is cstr text (channel talk or /w whisper).
    pub fn chatCommand(self: *RealmClient, text: []const u8) !void {
        const fd = self.bnet.?;
        var body: [256]u8 = undefined;
        var w = net.Writer.init(&body);
        w.cstr(text);
        try bncsSend(fd, SID_CHATCOMMAND, w.slice());
    }

    /// Read one SID_CHATEVENT. Body: u32 eid, u32 flags, u32 ping, u32 ip,
    /// u32 acctNumber, u32 regAuthority, cstr username, cstr text. The username
    /// and text are sliced into self.rxbuf (valid until the next recv).
    pub fn readChatEvent(self: *RealmClient) !ChatEvent {
        const fd = self.bnet.?;
        const r = try bncsRecv(fd, &self.rxbuf);
        if (r.id != SID_CHATEVENT) return error.NotChatEvent;
        const b = r.body;
        const eid = net.rdU32(b, 0);
        var off: usize = 24; // 6 u32s
        const ustart = off;
        while (off < b.len and b[off] != 0) off += 1;
        const username = b[ustart..off];
        off += 1; // NUL
        const tstart = off;
        while (off < b.len and b[off] != 0) off += 1;
        const text = b[tstart..off];
        return .{ .eid = eid, .username = username, .text = text };
    }

    /// Give bnet reads a deadline so a missing event fails instead of hanging.
    pub fn setBnetTimeout(self: *RealmClient, ms: u32) void {
        net.setRecvTimeout(self.bnet.?, ms);
    }

    pub fn connectD2cs(self: *RealmClient) !void {
        const fd = try net.connectLocal(if (self.d2cs_port != 0) self.d2cs_port else HOST_D2CS);
        try net.writeAll(fd, &[_]u8{0x01});
        self.d2cs = fd;
    }

    /// MCP_STARTUP -> result (0 = identified).
    pub fn startup(self: *RealmClient) !u32 {
        const fd = self.d2cs.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(self.cookie);
        w.u32v(self.status);
        w.u32v(self.lo);
        w.u32v(self.hi);
        w.zeros(48);
        w.cstr(self.account);
        try mcpSend(fd, MCP_STARTUP, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_STARTUP) return error.StartupBadId;
        return net.rdU32(r.body, 0);
    }

    /// MCP_CHARLIST2 -> total; fills `out` with up to out.len entries, returns
    /// (total, count). Names/statstrings are sliced from `dst` (caller-owned).
    pub fn charList(self: *RealmClient, out: []CharEntry, dst: []u8) !struct { total: u32, count: usize } {
        const fd = self.d2cs.?;
        var rq: [4]u8 = undefined;
        std.mem.writeInt(u32, &rq, 64, .little);
        try mcpSend(fd, MCP_CHARLIST2, &rq);
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_CHARLIST2) return error.CharListBadId;
        const b = r.body;
        const total = net.rdU32(b, 2);
        const ret = net.rdU16(b, 6);
        // copy body into dst so name slices outlive rxbuf reuse
        @memcpy(dst[0..b.len], b);
        const body = dst[0..b.len];
        var off: usize = 8;
        var count: usize = 0;
        var i: usize = 0;
        while (i < ret and count < out.len) : (i += 1) {
            off += 4; // expiration u32
            const nstart = off;
            while (off < body.len and body[off] != 0) off += 1;
            const name = body[nstart..off];
            off += 1; // NUL
            const sstart = off;
            while (off < body.len and body[off] != 0) off += 1;
            const ss = body[sstart..off];
            off += 1;
            var e = CharEntry{ .name = name };
            decodeStatstring(ss, &e);
            out[count] = e;
            count += 1;
        }
        return .{ .total = total, .count = count };
    }

    /// MCP_CHARDELETE -> result (0 = deleted). Reply: reqid@0, result@2.
    pub fn charDelete(self: *RealmClient, charname: []const u8) !u32 {
        const fd = self.d2cs.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u16v(9); // reqid
        w.cstr(charname);
        try mcpSend(fd, MCP_CHARDELETE, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_CHARDELETE) return error.CharDeleteBadId;
        return net.rdU32(r.body, 2);
    }

    /// MCP_LADDERDATA (0x11): request the ladder, parse the entry buffer into `out`
    /// (names copied into `dst`), return the entry count. Mirrors NET_MCP_CLIENT_Incoming0x11:
    /// body = [u8 flag][u16 total][u16 chunk][u16 offset][u32 rankBase][u32 count][u32 entrySize]
    /// then count × [u32 expLo][u32 expHi][u32 stats][entrySize-byte name].
    pub fn ladderData(self: *RealmClient, mode: u8, out: []LadderEntry, dst: []u8) !usize {
        const fd = self.d2cs.?;
        var body: [4]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u8v(mode);
        w.u16v(0); // reqid
        try mcpSend(fd, MCP_LADDERDATA, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_LADDERDATA) return error.LadderBadId;
        if (r.body.len < 7 or net.rdU16(r.body, 1) < 12) return 0; // empty ladder
        const data = r.body[7..];
        if (data.len < 12) return 0;
        const count = net.rdU32(data, 4);
        const entry_size = net.rdU32(data, 8);
        var off: usize = 12;
        var di: usize = 0;
        var n: usize = 0;
        while (n < count and n < out.len) : (n += 1) {
            if (off + 12 + entry_size > data.len) break;
            const experience = net.rdU32(data, off + 0);
            const stats = net.rdU32(data, off + 8);
            const nm = std.mem.sliceTo(data[off + 12 .. off + 12 + entry_size], 0);
            @memcpy(dst[di .. di + nm.len], nm);
            out[n] = .{ .name = dst[di .. di + nm.len], .level = stats >> 16, .class_id = @intCast(stats & 0xf), .experience = experience };
            di += nm.len;
            off += 12 + entry_size;
        }
        return n;
    }

    /// MCP_GAMELIST (0x05): the join-screen list. The realm sends ONE packet PER GAME
    /// and then a terminator whose token is -2, so we read until we see it. Per-game
    /// body: [u16 reqid][u32 gameid][u8 players][u32 token][cstr name][cstr description].
    /// Names/descriptions are copied into `dst`; returns how many games were listed.
    pub fn gameList(self: *RealmClient, out: []GameEntry, dst: []u8) !usize {
        const fd = self.d2cs.?;
        var body: [8]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u16v(0); // reqid
        w.u32v(0); // difficulty filter
        w.u8v(0); // empty search cstr
        try mcpSend(fd, MCP_GAMELIST, w.slice());

        var n: usize = 0;
        var di: usize = 0;
        while (true) {
            const r = try mcpRecv(fd, &self.rxbuf);
            if (r.id != MCP_GAMELIST) return error.GameListBadId;
            if (r.body.len < 11) return error.GameListShort;
            if (net.rdU32(r.body, 7) == 0xFFFF_FFFE) return n; // -2 = end of list
            const nm = std.mem.sliceTo(r.body[11..], 0);
            const dsc = std.mem.sliceTo(r.body[11 + nm.len + 1 ..], 0);
            if (n < out.len) {
                @memcpy(dst[di .. di + nm.len], nm);
                @memcpy(dst[di + nm.len .. di + nm.len + dsc.len], dsc);
                out[n] = .{
                    .name = dst[di .. di + nm.len],
                    .description = dst[di + nm.len .. di + nm.len + dsc.len],
                    .gameid = net.rdU32(r.body, 2),
                    .players = r.body[6],
                };
                di += nm.len + dsc.len;
                n += 1;
            }
        }
    }

    /// MCP_CHARUPGRADE (0x18) -> result (0 = converted, non-zero = refused). Request body
    /// is just the character name as a cstr (Send_0x18_CharUpgrade @0x44a810).
    pub fn charUpgrade(self: *RealmClient, charname: []const u8) !u32 {
        const fd = self.d2cs.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.cstr(charname);
        try mcpSend(fd, MCP_CHARUPGRADE, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_CHARUPGRADE) return error.CharUpgradeBadId;
        return net.rdU32(r.body, 0);
    }

    /// MCP_GAMEINFO (0x06): the detail panel. Mirrors NET_MCP_CLIENT_Incoming0x06 —
    /// reqid@1, token@3, uptime@7, level@0xb, diff@0xc, maxplayers@0xd, count@0xe,
    /// class[16]@0xf, level[16]@0x1f, then the description cstr and `count` name cstrs.
    pub fn gameInfo(self: *RealmClient, name: []const u8, dst: []u8) !GameDetail {
        const fd = self.d2cs.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u16v(0); // reqid
        w.cstr(name);
        try mcpSend(fd, MCP_GAMEINFO, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_GAMEINFO) return error.GameInfoBadId;
        if (r.body.len < 10) return error.GameInfoShort;

        var d = GameDetail{ .token = net.rdU32(r.body, 2) };
        if (d.token == 0xFFFF_FFFF or d.token == 0xFFFF_FFFE) return d; // "no info" / end
        if (r.body.len < 0x2e) return error.GameInfoShort;
        d.uptime = net.rdU32(r.body, 6);
        d.level = r.body[10];
        d.level_diff = r.body[11];
        d.max_players = r.body[12];
        d.players = r.body[13];
        @memcpy(&d.classes, r.body[14..30]);
        @memcpy(&d.levels, r.body[30..46]);

        var off: usize = 46;
        const desc = std.mem.sliceTo(r.body[off..], 0);
        var di: usize = 0;
        @memcpy(dst[di .. di + desc.len], desc);
        d.description = dst[di .. di + desc.len];
        di += desc.len;
        off += desc.len + 1;
        var i: usize = 0;
        while (i < d.players and i < d.names.len) : (i += 1) {
            if (off >= r.body.len) break;
            const nm = std.mem.sliceTo(r.body[off..], 0);
            @memcpy(dst[di .. di + nm.len], nm);
            d.names[i] = dst[di .. di + nm.len];
            di += nm.len;
            off += nm.len + 1;
        }
        return d;
    }

    /// MCP_CHARCREATE (0x02) -> result (0 ok, 0x14 name taken, 0x15 invalid).
    /// Body: [u32 class][u16 status (expansion 0x20 / hardcore 0x04 / ladder 0x40)][cstr name].
    pub fn charCreate(self: *RealmClient, class: u8, status: u16, charname: []const u8) !u32 {
        const fd = self.d2cs.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u32v(class);
        w.u16v(status);
        w.cstr(charname);
        try mcpSend(fd, MCP_CHARCREATE, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_CHARCREATE) return error.CharCreateBadId;
        return net.rdU32(r.body, 0);
    }

    /// MCP_CREATEGAME -> (token, result).
    pub fn createGame(self: *RealmClient, name: []const u8, desc: []const u8) !CreateResult {
        return self.createGameWithPassword(name, desc, "");
    }

    /// MCP_CHARLOGON (0x07): select the character this connection is playing. Reply is a
    /// u32 result (0 = ok). Needed before anything that depends on WHICH character it is.
    pub fn charLogon(self: *RealmClient, charname: []const u8) !u32 {
        const fd = self.d2cs.?;
        var body: [64]u8 = undefined;
        var w = net.Writer.init(&body);
        w.cstr(charname);
        try mcpSend(fd, MCP_CHARLOGON, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_CHARLOGON) return error.CharLogonBadId;
        return net.rdU32(r.body, 0);
    }

    /// Create a game at a specific difficulty. It rides in bits 12-14 of the create flags
    /// (Normal 0, Nightmare 0x1000, Hell 0x2000).
    pub fn createGameDiff(self: *RealmClient, name: []const u8, desc: []const u8, difficulty: u2) !CreateResult {
        return self.createGameFull(name, desc, "", @as(u32, difficulty) << 12);
    }

    pub fn createGameWithPassword(self: *RealmClient, name: []const u8, desc: []const u8, password: []const u8) !CreateResult {
        return self.createGameFull(name, desc, password, 0);
    }

    fn createGameFull(self: *RealmClient, name: []const u8, desc: []const u8, password: []const u8, flags: u32) !CreateResult {
        const fd = self.d2cs.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u16v(7);
        w.u32v(flags);
        w.u8v(1);
        w.u8v(0);
        w.u8v(8); // max_players
        w.cstr(name);
        w.cstr(password);
        w.cstr(desc);
        try mcpSend(fd, MCP_CREATEGAME, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_CREATEGAME) return error.CreateGameBadId;
        // <HHHI reqid,token,unk,result>
        const token = net.rdU16(r.body, 2);
        const result = net.rdU32(r.body, 6);
        return .{ .token = token, .result = result };
    }

    /// MCP_JOINGAME -> (token, gs_ip octets, result).
    pub fn joinGame(self: *RealmClient, name: []const u8) !JoinResult {
        return self.joinGameWithPassword(name, "");
    }

    pub fn joinGameWithPassword(self: *RealmClient, name: []const u8, password: []const u8) !JoinResult {
        const fd = self.d2cs.?;
        var body: [128]u8 = undefined;
        var w = net.Writer.init(&body);
        w.u16v(8);
        w.cstr(name);
        w.cstr(password);
        try mcpSend(fd, MCP_JOINGAME, w.slice());
        const r = try mcpRecv(fd, &self.rxbuf);
        if (r.id != MCP_JOINGAME) return error.JoinGameBadId;
        // <HHHIII reqid,token,unk,ip,gh,result>
        const token = net.rdU16(r.body, 2);
        const ip_le = net.rdU32(r.body, 6);
        const result = net.rdU32(r.body, 14);
        var ip: [4]u8 = undefined;
        std.mem.writeInt(u32, &ip, ip_le, .little);
        return .{ .token = token, .ip = ip, .result = result };
    }

    pub fn close(self: *RealmClient) void {
        if (self.bnet) |fd| net.closeSocket(fd);
        if (self.d2cs) |fd| net.closeSocket(fd);
        self.bnet = null;
        self.d2cs = null;
    }
};

// ---------------------------------------------------------------------------
// d2dbs character-save store
// ---------------------------------------------------------------------------
/// SAVE_DATA 0x30 -> result (0 = ok).
pub fn d2dbsSave(acct: []const u8, char: []const u8, d2s: []const u8) !u32 {
    const fd = try net.connectLocal(HOST_D2DBS);
    defer net.closeSocket(fd);
    var body: [4096]u8 = undefined;
    var w = net.Writer.init(&body);
    w.u16v(DBS_DATATYPE_CHARSAVE);
    w.cstr(acct);
    w.cstr(char);
    w.u16v(@intCast(d2s.len));
    w.bytes(d2s);
    try ctlSend(fd, DBS_SAVE, w.slice());
    var rx: [4096]u8 = undefined;
    const c = try ctlRecv(fd, &rx);
    if (c.typ != DBS_SAVE) return error.SaveReplyType;
    return net.rdU32(c.body, 0);
}
