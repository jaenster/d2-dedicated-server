//! checkrev-probe — a clientless BNCS *version-check* client (protocol selector
//! 0x01), distinct from the BNFTP tool (selector 0x02). It points at a real
//! Battle.net server and exercises the version-check gauntlet end-to-end:
//!
//!   1. connect 0x01 → SID_AUTH_INFO (echoing the SID_PING cookie). The reply
//!      names the version-check MPQ + the base64 *challenge* (the "value string").
//!   2. compute the CheckRevision response with our portable core
//!      (`checkrev_core`, the same code the DLL and realmd use):
//!         response = base64( SHA1( first4(b64decode(challenge)) + ":"+ver+":" + sigOk ) )
//!   3. send SID_AUTH_CHECK carrying that response in the modern layout
//!      (dialog-result → EXE Version, first 4 base64 bytes → EXE Hash, rest →
//!      EXE Info) and print the server's result code.
//!
//! A version-error result (0x101/0x102) means our hash is wrong; a CD-key error
//! (0x2xx) means the *version check passed* (we send no real key). CD-key-free —
//! no account, no SRP, no login. Usage:
//!   zig build checkrev-probe -- <host> [product] [gameVersion] [--sig0]
const std = @import("std");
const core = @import("libd2").bnet.checkrev;
const cdkey = @import("libd2").bnet.cdkey;
const xsha1 = @import("libd2").bnet.xsha1;

// ── libc sockets (native host target; std.net/std.posix wrappers are gone in 0.16) ──
const Socket = c_int;
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
const SOCK_STREAM: c_int = 1;

fn setRecvTimeout(fd: Socket, ms: u32) void {
    const tv = std.posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &tv, @sizeOf(std.posix.timeval));
}
extern "c" fn gettimeofday(tv: *std.posix.timeval, tz: ?*anyopaque) c_int;
fn nowMs() i64 {
    var tv: std.posix.timeval = undefined;
    _ = gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
}
fn writeAll(fd: Socket, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        const n = write(fd, buf.ptr + sent, buf.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}
fn connectResolved(gpa: std.mem.Allocator, host: []const u8, port: u16) !Socket {
    const chost = try gpa.dupeZ(u8, host);
    var pbuf: [8]u8 = undefined;
    const cserv = std.fmt.bufPrintZ(&pbuf, "{d}", .{port}) catch unreachable;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = 0; // AF_UNSPEC
    hints.socktype = SOCK_STREAM;
    var res: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(chost.ptr, cserv.ptr, &hints, &res)) != 0) return error.ResolveFailed;
    defer if (res) |r| std.c.freeaddrinfo(r);
    var ai = res;
    while (ai) |a| : (ai = a.next) {
        const sa = a.addr orelse continue;
        const fd = socket(a.family, SOCK_STREAM, 0);
        if (fd < 0) continue;
        if (connect(fd, sa, a.addrlen) == 0) {
            setRecvTimeout(fd, 20000);
            return fd;
        }
        _ = close(fd);
    }
    return error.ConnectFailed;
}

const SID_AUTH_INFO = 0x50;
const SID_AUTH_CHECK = 0x51;
const SID_PING = 0x25;

fn fourcc(s: []const u8) u32 {
    return @as(u32, s[3]) | (@as(u32, s[2]) << 8) | (@as(u32, s[1]) << 16) | (@as(u32, s[0]) << 24);
}
fn cstrAt(b: []const u8, off: usize) []const u8 {
    if (off >= b.len) return "";
    const end = std.mem.indexOfScalarPos(u8, b, off, 0) orelse b.len;
    return b[off..end];
}
fn authMeaning(r: u32) []const u8 {
    return switch (r) {
        0x000 => "PASSED — version + checksum accepted",
        0x100 => "old game version (forced patch)",
        0x101 => "invalid version",
        0x102 => "game version must be downgraded",
        0x200 => "invalid CD key  => VERSION CHECK PASSED",
        0x201 => "CD key in use   => VERSION CHECK PASSED",
        0x202 => "banned key      => VERSION CHECK PASSED",
        0x203 => "wrong product   => VERSION CHECK PASSED",
        else => if (r & 0xFF00 == 0x0100) "invalid-version variant" else "other (version likely passed)",
    };
}

var rxbuf: [16384]u8 = undefined;
var rxlen: usize = 0;

// Hexdump every packet the server sends (matched or not), across BNCS + MCP, so we see
// ALL traffic. On by default.
var verbose: bool = true;
fn dumpPkt(proto: []const u8, id: u8, body: []const u8) void {
    if (!verbose) return;
    std.debug.print("  [rx {s} 0x{x:0>2}] {d} bytes\n", .{ proto, id, body.len });
    var i: usize = 0;
    while (i < body.len) : (i += 16) {
        const end = @min(i + 16, body.len);
        std.debug.print("    ", .{});
        for (body[i..end]) |b| std.debug.print("{x:0>2} ", .{b});
        var pad = end;
        while (pad < i + 16) : (pad += 1) std.debug.print("   ", .{});
        std.debug.print(" |", .{});
        for (body[i..end]) |b| std.debug.print("{c}", .{if (b >= 0x20 and b < 0x7f) b else '.'});
        std.debug.print("|\n", .{});
    }
}

/// Read framed BNCS packets until one with id == want; auto-echo SID_PING.
fn recvUntil(fd: Socket, want: u8, out: []u8) ![]const u8 {
    while (true) {
        while (rxlen >= 4 and rxbuf[0] == 0xFF) {
            const id = rxbuf[1];
            const plen = std.mem.readInt(u16, rxbuf[2..4], .little);
            if (plen < 4 or plen > rxbuf.len) return error.BadFrame;
            if (rxlen < plen) break; // need more bytes
            const body = rxbuf[4..plen];
            dumpPkt("BNCS", id, body);
            if (id == 0x4a or id == 0x4c) // SID_OPTIONALWORK / SID_REQUIREDWORK: a work MPQ name
                std.debug.print("[WORK 0x{x:0>2}] \"{s}\"\n", .{ id, cstrAt(body, 0) });
            if (id == SID_PING) {
                var echo: [8]u8 = .{ 0xFF, SID_PING, 8, 0, 0, 0, 0, 0 };
                @memcpy(echo[4..8], body[0..4]);
                try writeAll(fd, &echo);
                std.debug.print("  <- SID_PING, echoed cookie\n", .{});
            } else if (id == want) {
                const blen = plen - 4;
                @memcpy(out[0..blen], body);
                std.mem.copyForwards(u8, rxbuf[0 .. rxlen - plen], rxbuf[plen..rxlen]);
                rxlen -= plen;
                return out[0..blen];
            }
            std.mem.copyForwards(u8, rxbuf[0 .. rxlen - plen], rxbuf[plen..rxlen]);
            rxlen -= plen;
        }
        const got = read(fd, rxbuf[rxlen..].ptr, rxbuf.len - rxlen);
        if (got <= 0) return error.Closed;
        rxlen += @intCast(got);
    }
}

fn send(fd: Socket, id: u8, body: []const u8) !void {
    var hdr: [4]u8 = .{ 0xFF, id, 0, 0 };
    std.mem.writeInt(u16, hdr[2..4], @intCast(body.len + 4), .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, body);
}

const SID_LOGONRESPONSE2 = 0x3a;
const SID_CREATEACCOUNT2 = 0x3d;
const SID_QUERYREALMS2 = 0x40;
const SID_LOGONREALMEX = 0x3e;
const SID_ENTERCHAT = 0x0a;
const SID_GETCHANNELLIST = 0x0b;
const SID_JOINCHANNEL = 0x0c;
const SID_CHATCOMMAND = 0x0e;
const SID_CHATEVENT = 0x0f;
const SID_GETADVLISTEX = 0x09; // open-bnet public game list (peer-hosted games)
const MCP_STARTUP = 0x01;
const MCP_CHARCREATE = 0x02;
const MCP_CREATEGAME = 0x03;
const MCP_JOINGAME = 0x04;
const MCP_CHARLOGON = 0x07;
const MCP_LADDERDATA = 0x11;
const MCP_MOTD = 0x12;
const MCP_CHARLIST2 = 0x19;
const CLIENT_TOKEN: u32 = 0xCAFEBABE;

// Send a chat message / slash command (SID_CHATCOMMAND: STRING text).
fn sendChat(fd: Socket, text: []const u8) void {
    var buf: [256]u8 = undefined;
    if (text.len + 1 > buf.len) return;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    send(fd, SID_CHATCOMMAND, buf[0 .. text.len + 1]) catch {};
}

fn eidName(eid: u32) []const u8 {
    return switch (eid) {
        0x01 => "SHOWUSER", 0x02 => "JOIN", 0x03 => "LEAVE", 0x04 => "WHISPER",
        0x05 => "TALK", 0x06 => "BROADCAST", 0x07 => "CHANNEL", 0x09 => "USERFLAGS",
        0x0a => "WHISPERSENT", 0x0d => "CHANNELFULL", 0x12 => "INFO", 0x13 => "ERROR",
        0x17 => "EMOTE", else => "EID?",
    };
}

fn printChatEvent(body: []const u8) void {
    if (body.len < 28) return;
    const eid = std.mem.readInt(u32, body[0..4], .little);
    const uname = cstrAt(body, 24);
    const text = cstrAt(body, 24 + uname.len + 1);
    std.debug.print("    «{s}» {s}: {s}\n", .{ eidName(eid), uname, text });
}

// Poll the BNCS socket once (uses the current SO_RCVTIMEO), parse all complete frames,
// print chat events, auto-echo PING. Returns 0 if the peer closed, -1 on timeout, 1 on data.
fn pumpEvents(fd: Socket) i32 {
    const got = read(fd, rxbuf[rxlen..].ptr, rxbuf.len - rxlen);
    if (got == 0) return 0;
    if (got < 0) return -1;
    rxlen += @intCast(got);
    while (rxlen >= 4 and rxbuf[0] == 0xFF) {
        const id = rxbuf[1];
        const plen = std.mem.readInt(u16, rxbuf[2..4], .little);
        if (plen < 4 or plen > rxbuf.len or rxlen < plen) break;
        const body = rxbuf[4..plen];
        dumpPkt("BNCS", id, body);
        if (id == SID_PING) {
            var echo: [8]u8 = .{ 0xFF, SID_PING, 8, 0, 0, 0, 0, 0 };
            @memcpy(echo[4..8], body[0..4]);
            writeAll(fd, &echo) catch {};
        } else if (id == SID_CHATEVENT) {
            printChatEvent(body);
        }
        std.mem.copyForwards(u8, rxbuf[0 .. rxlen - plen], rxbuf[plen..rxlen]);
        rxlen -= plen;
    }
    return 1;
}

// MCP (realm/character server) framing: [u16 len incl header][u8 id][body]. Separate
// connection + buffer from BNCS (which uses the 0xFF framing).
var mrx: [16384]u8 = undefined;
var mrxlen: usize = 0;
fn mcpSend(fd: Socket, id: u8, body: []const u8) !void {
    var hdr: [3]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], @intCast(body.len + 3), .little);
    hdr[2] = id;
    try writeAll(fd, &hdr);
    if (body.len > 0) try writeAll(fd, body);
}
fn mcpRecv(fd: Socket, want: u8, out: []u8) ![]const u8 {
    while (true) {
        while (mrxlen >= 3) {
            const plen = std.mem.readInt(u16, mrx[0..2], .little);
            if (plen < 3 or plen > mrx.len) return error.BadFrame;
            if (mrxlen < plen) break;
            const id = mrx[2];
            const blen = plen - 3;
            dumpPkt("MCP", id, mrx[3..plen]);
            if (id == want) {
                @memcpy(out[0..blen], mrx[3..plen]);
                std.mem.copyForwards(u8, mrx[0 .. mrxlen - plen], mrx[plen..mrxlen]);
                mrxlen -= plen;
                return out[0..blen];
            }
            std.mem.copyForwards(u8, mrx[0 .. mrxlen - plen], mrx[plen..mrxlen]);
            mrxlen -= plen;
        }
        const got = read(fd, mrx[mrxlen..].ptr, mrx.len - mrxlen);
        if (got <= 0) return error.Closed;
        mrxlen += @intCast(got);
    }
}

fn lower(s: []const u8, buf: []u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    var host: ?[]const u8 = null;
    var product: []const u8 = "D2XP";
    var game_ver: []const u8 = "1.14.3.71";
    var sig_ok: u8 = 1;
    var keys_arg: ?[]const u8 = null; // "KEY1,KEY2" (26-char each)
    var login_arg: ?[]const u8 = null; // "account:password"
    var create_arg: ?[]const u8 = null; // "account:password" to register first
    var channel_arg: []const u8 = "Diablo II"; // channel to join
    var say_arg: ?[]const u8 = null; // chat message to send after joining
    var kick_arg: ?[]const u8 = null; // user to /kick after joining
    var listen_sec: u32 = 0; // stay in chat reading events for N seconds (chat-session mode)
    var delay_sec: u32 = 0; // wait N seconds after joining before say/kick (2-client ordering)
    var game_arg: ?[]const u8 = null; // --game <name>: create+join the game and enter it on the GS
    var gs_port: u16 = 4000; // GS game port (d2ingress public port)
    var ver_byte: u8 = 0; // GAMELOGON version byte (GetGameVersion)
    var pos: usize = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--sig0")) {
            sig_ok = 0;
        } else if (std.mem.eql(u8, a, "--keys")) {
            keys_arg = args.next();
        } else if (std.mem.eql(u8, a, "--login")) {
            login_arg = args.next();
        } else if (std.mem.eql(u8, a, "--create")) {
            create_arg = args.next();
        } else if (std.mem.eql(u8, a, "--channel")) {
            channel_arg = args.next() orelse channel_arg;
        } else if (std.mem.eql(u8, a, "--say")) {
            say_arg = args.next();
        } else if (std.mem.eql(u8, a, "--kick")) {
            kick_arg = args.next();
        } else if (std.mem.eql(u8, a, "--listen")) {
            listen_sec = std.fmt.parseInt(u32, args.next() orelse "0", 10) catch 0;
        } else if (std.mem.eql(u8, a, "--delay")) {
            delay_sec = std.fmt.parseInt(u32, args.next() orelse "0", 10) catch 0;
        } else if (std.mem.eql(u8, a, "--game")) {
            game_arg = args.next();
        } else if (std.mem.eql(u8, a, "--gs-port")) {
            gs_port = std.fmt.parseInt(u16, args.next() orelse "4000", 10) catch 4000;
        } else if (std.mem.eql(u8, a, "--verbyte")) {
            ver_byte = std.fmt.parseInt(u8, args.next() orelse "0", 10) catch 0;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            switch (pos) {
                0 => host = a,
                1 => product = a,
                2 => game_ver = a,
                else => {},
            }
            pos += 1;
        }
    }
    const h = host orelse {
        std.debug.print("usage: checkrev-probe <host> [product] [gameVersion] [--sig0] [--keys K1,K2] [--login acct:pass]\n", .{});
        return;
    };

    std.debug.print("== {s}:6112  product={s}  gameVer={s}  sigOk={d} ==\n", .{ h, product, game_ver, sig_ok });
    const fd = try connectResolved(gpa, h, 6112);
    defer _ = close(fd);
    try writeAll(fd, &[_]u8{0x01}); // protocol selector: BNCS

    // ── SID_AUTH_INFO ──
    var body: [128]u8 = undefined;
    var w: usize = 0;
    for ([_]u32{ 0, fourcc("IX86"), fourcc(product), 0x0E, 0, 0, 0, 0, 0 }) |v| {
        std.mem.writeInt(u32, body[w..][0..4], v, .little);
        w += 4;
    }
    for ("USA\x00United States\x00") |c| {
        body[w] = c;
        w += 1;
    }
    try send(fd, SID_AUTH_INFO, body[0..w]);

    var aibuf: [4096]u8 = undefined;
    const ai = try recvUntil(fd, SID_AUTH_INFO, &aibuf);
    if (ai.len < 20) return error.ShortAuthInfo;
    const stoken = std.mem.readInt(u32, ai[4..8], .little);
    const mpq = cstrAt(ai, 20);
    const challenge = cstrAt(ai, 20 + mpq.len + 1);
    std.debug.print("\n[AUTH_INFO] serverToken=0x{x:0>8}  mpq=\"{s}\"  challenge=\"{s}\"\n", .{ stoken, mpq, challenge });

    // ── compute the CheckRevision response with our portable core ──
    var full_buf: [64]u8 = undefined;
    const full = core.response(challenge, game_ver, sig_ok, &full_buf) orelse return error.ShortChallenge;
    // modern split: first 4 base64 bytes -> EXE Hash (u32 LE); rest -> EXE Info string; EXE Version = 0
    const exe_hash = std.mem.readInt(u32, full[0..4], .little);
    const exe_info = full[4..];
    std.debug.print("[checkrev] response=\"{s}\"  -> exeHash=0x{x:0>8}  exeInfo=\"{s}\"\n", .{ full, exe_hash, exe_info });

    // ── SID_AUTH_CHECK (with real CD-key blocks, computed clientless) ──
    var cb: [512]u8 = undefined;
    var cw: usize = 0;
    var nkeys: u32 = 0;
    var keyit = std.mem.tokenizeScalar(u8, keys_arg orelse "", ',');
    // header (we backfill numKeys after counting): clientToken, exeVersion(0), exeHash, numKeys, spawn(0)
    const hdr_keys_off = 12; // offset of the numKeys field in the header
    std.mem.writeInt(u32, cb[0..4], CLIENT_TOKEN, .little);
    std.mem.writeInt(u32, cb[4..8], 0, .little);
    std.mem.writeInt(u32, cb[8..12], exe_hash, .little);
    std.mem.writeInt(u32, cb[16..20], 0, .little); // spawn
    cw = 20;
    while (keyit.next()) |k| {
        const blk = cdkey.keyBlock26(k, CLIENT_TOKEN, stoken) orelse {
            std.debug.print("[keys] bad 26-char key: {s}\n", .{k});
            return;
        };
        var wire: [36]u8 = undefined;
        blk.writeWire(&wire);
        @memcpy(cb[cw .. cw + 36], &wire);
        cw += 36;
        nkeys += 1;
        std.debug.print("[keys] key[{d}] product=0x{x:0>8} public=0x{x:0>8}\n", .{ nkeys - 1, blk.product, blk.public });
    }
    std.mem.writeInt(u32, cb[hdr_keys_off..][0..4], nkeys, .little);
    @memcpy(cb[cw .. cw + exe_info.len], exe_info); // EXE Information string
    cw += exe_info.len;
    cb[cw] = 0;
    cw += 1;
    for ("probe\x00") |c| { // CD-key owner
        cb[cw] = c;
        cw += 1;
    }
    try send(fd, SID_AUTH_CHECK, cb[0..cw]);

    var acbuf: [1024]u8 = undefined;
    const ac = recvUntil(fd, SID_AUTH_CHECK, &acbuf) catch |e| {
        std.debug.print("\n[AUTH_CHECK] no reply ({s}) — server dropped the packet (malformed/keyless).\n", .{@errorName(e)});
        return;
    };
    if (ac.len < 4) return error.ShortAuthCheck;
    const result = std.mem.readInt(u32, ac[0..4], .little);
    std.debug.print("\n[AUTH_CHECK] result=0x{x:0>4}  info=\"{s}\"  => {s}\n", .{ result, cstrAt(ac, 4), authMeaning(result) });

    // ── SID_CREATEACCOUNT2 (register — single broken-SHA-1 of the password) ──
    if (create_arg) |ca| {
        const sep = std.mem.indexOfScalar(u8, ca, ':') orelse ca.len;
        const acct = ca[0..sep];
        const pass = if (sep < ca.len) ca[sep + 1 ..] else "";
        var lb: [64]u8 = undefined;
        const pwhash = xsha1.xsha1(lower(pass, &lb)); // single hash for CREATE (login uses double)
        var nb: [320]u8 = undefined;
        @memcpy(nb[0..20], &pwhash);
        @memcpy(nb[20 .. 20 + acct.len], acct);
        nb[20 + acct.len] = 0;
        try send(fd, SID_CREATEACCOUNT2, nb[0 .. 20 + acct.len + 1]);
        var nrbuf: [256]u8 = undefined;
        const nr = try recvUntil(fd, SID_CREATEACCOUNT2, &nrbuf);
        const st = if (nr.len >= 4) std.mem.readInt(u32, nr[0..4], .little) else 0xffffffff;
        std.debug.print("[CREATEACCOUNT2] account=\"{s}\" status={d}  => {s}\n", .{ acct, st, if (st == 0) "created" else "failed/exists" });
        if (login_arg == null) login_arg = create_arg; // auto-login as the freshly-created account
    }

    // ── SID_LOGONRESPONSE2 (OLS account login) ──
    if (login_arg) |la| {
        const sep = std.mem.indexOfScalar(u8, la, ':') orelse la.len;
        const acct = la[0..sep];
        const pass = if (sep < la.len) la[sep + 1 ..] else "";
        var lb: [64]u8 = undefined;
        const inner = xsha1.xsha1(lower(pass, &lb)); // xsha1(lowercase(password))
        const pwhash = xsha1.doubleHash(CLIENT_TOKEN, stoken, inner);
        var pb: [320]u8 = undefined;
        std.mem.writeInt(u32, pb[0..4], CLIENT_TOKEN, .little);
        std.mem.writeInt(u32, pb[4..8], stoken, .little);
        @memcpy(pb[8..28], &pwhash);
        @memcpy(pb[28 .. 28 + acct.len], acct);
        pb[28 + acct.len] = 0;
        try send(fd, SID_LOGONRESPONSE2, pb[0 .. 28 + acct.len + 1]);
        var lbuf: [256]u8 = undefined;
        const lr = try recvUntil(fd, SID_LOGONRESPONSE2, &lbuf);
        const lres = if (lr.len >= 4) std.mem.readInt(u32, lr[0..4], .little) else 0xffffffff;
        const meaning = switch (lres) {
            0 => "OK — account+password accepted",
            1 => "no such account",
            2 => "incorrect password",
            else => "other",
        };
        std.debug.print("[LOGONRESPONSE2] account=\"{s}\" result={d}  => {s}\n", .{ acct, lres, meaning });
        if (lres != 0) return; // can't query realms without a logged-in account

        // ── SID_QUERYREALMS2 — the realm list (EMPTY body; real bnet closes on a non-empty one) ──
        try send(fd, SID_QUERYREALMS2, &[_]u8{});
        var qbuf: [4096]u8 = undefined;
        const qr = try recvUntil(fd, SID_QUERYREALMS2, &qbuf);
        var first_realm: []const u8 = "";
        if (qr.len >= 8) {
            const count = std.mem.readInt(u32, qr[4..8], .little);
            std.debug.print("[QUERYREALMS2] {d} realm(s):\n", .{count});
            var off: usize = 8;
            var n: u32 = 0;
            while (n < count and off + 4 <= qr.len) : (n += 1) {
                off += 4; // per-realm unknown dword
                const title = cstrAt(qr, off);
                off += title.len + 1;
                const desc = cstrAt(qr, off);
                off += desc.len + 1;
                if (n == 0) first_realm = title;
                std.debug.print("  - \"{s}\"  ({s})\n", .{ title, desc });
            }
        }
        if (first_realm.len == 0) return;

        // ── SID_LOGONREALMEX — log on to the first realm (closed-bnet realm password = "password") ──
        const realm_pw = xsha1.doubleHash(CLIENT_TOKEN, stoken, xsha1.xsha1("password"));
        var rb: [128]u8 = undefined;
        std.mem.writeInt(u32, rb[0..4], CLIENT_TOKEN, .little);
        @memcpy(rb[4..24], &realm_pw);
        @memcpy(rb[24 .. 24 + first_realm.len], first_realm);
        rb[24 + first_realm.len] = 0;
        try send(fd, SID_LOGONREALMEX, rb[0 .. 24 + first_realm.len + 1]);
        var rrbuf: [256]u8 = undefined;
        const rr = try recvUntil(fd, SID_LOGONREALMEX, &rrbuf);
        // Dump the raw reply — real bnet's success layout differs from realmd's, so we read it
        // from the bytes rather than assuming a status DWORD at offset 4.
        std.debug.print("[LOGONREALMEX] realm=\"{s}\" reply {d} bytes:\n", .{ first_realm, rr.len });
        {
            var hi: usize = 0;
            while (hi < rr.len) : (hi += 1) std.debug.print("{x:0>2} ", .{rr[hi]});
            std.debug.print("\n", .{});
        }
        // Short reply (~8 bytes = cookie+status) is a real failure; a long reply carries the
        // MCP handoff (cookie, status, chunk1, ip, port, chunk2, unique name) = success.
        if (rr.len < 30) {
            const status = if (rr.len >= 8) std.mem.readInt(u32, rr[4..8], .little) else 0xffffffff;
            std.debug.print("  => realm logon FAILED (status=0x{x})\n", .{status});
            return;
        }
        std.debug.print("  => OK — MCP handoff ({d}-byte reply)\n", .{rr.len});

        // ── MCP (realm/character server) — connect to the addr the realm gave us ──
        const ip4 = rr[16..20];
        const mport = std.mem.readInt(u16, rr[20..22], .big);
        var ipstr: [20]u8 = undefined;
        const ipfmt = std.fmt.bufPrint(&ipstr, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] }) catch return;
        // Real bnet returns the d2cs server's PRIVATE (NATed) IP — unreachable externally.
        // Fall back to the gateway host (the addr we connected to), in case it proxies MCP.
        const priv = ip4[0] == 10 or (ip4[0] == 192 and ip4[1] == 168) or (ip4[0] == 172 and ip4[1] >= 16 and ip4[1] <= 31) or ip4[0] == 127 or ip4[0] == 0;
        const ips = if (priv) (host orelse ipfmt) else ipfmt;
        if (priv)
            std.debug.print("[MCP] realm returned PRIVATE ip {s}:{d} (Blizzard NAT) -> retrying via gateway {s}:{d}\n", .{ ipfmt, mport, ips, mport })
        else
            std.debug.print("[MCP] connecting to {s}:{d}\n", .{ ips, mport });
        const mfd = connectResolved(gpa, ips, mport) catch {
            std.debug.print("[MCP] connect failed\n", .{});
            return;
        };
        defer _ = close(mfd);
        mrxlen = 0;
        try writeAll(mfd, &[_]u8{0x01}); // MCP protocol selector

        // MCP_STARTUP: forward cookie+status+chunk1(8)+chunk2(48) from the realm reply
        var sb: [64]u8 = [_]u8{0} ** 64;
        @memcpy(sb[0..16], rr[0..16]);
        if (rr.len >= 72) @memcpy(sb[16..64], rr[24..72]);
        try mcpSend(mfd, MCP_STARTUP, &sb);
        var mb: [8192]u8 = undefined;
        const sr = mcpRecv(mfd, MCP_STARTUP, &mb) catch {
            std.debug.print("[MCP_STARTUP] no MCP reply from {s}:{d} — d2cs is unreachable (internal-only; realm logon succeeded but the char/game server is NATed)\n", .{ ips, mport });
            return;
        };
        const sres = if (sr.len >= 4) std.mem.readInt(u32, sr[0..4], .little) else 0xffffffff;
        std.debug.print("[MCP_STARTUP] result=0x{x}  => {s}\n", .{ sres, if (sres == 0) "session accepted (in the realm)" else "rejected" });
        if (sres != 0) return;

        // NOTE: the real 1.14d client does NOT send MCP_MOTD (0x12) here — its MCP
        // sequence is STARTUP -> CHARLIST2 -> CHARLOGON (captured via REALMD_TRACE).
        // The chat-screen MOTD arrives over BNCS SID_NEWS_INFO instead. Sending MCP_MOTD
        // derails real bnet's MCP (it goes silent after STARTUP).

        // MCP_CHARLIST2 — the account's characters on this realm
        var clreq: [4]u8 = undefined;
        std.mem.writeInt(u32, &clreq, 8, .little);
        try mcpSend(mfd, MCP_CHARLIST2, &clreq);
        const cl = mcpRecv(mfd, MCP_CHARLIST2, &mb) catch &[_]u8{};
        var cname_buf: [32]u8 = undefined;
        var cname_len: usize = 0;
        if (cl.len >= 8) {
            const total = std.mem.readInt(u32, cl[2..6], .little);
            const ret = std.mem.readInt(u16, cl[6..8], .little);
            std.debug.print("[MCP_CHARLIST2] total={d} returned={d}\n", .{ total, ret });
            var off2: usize = 8;
            var ci: usize = 0;
            while (ci < ret and off2 + 4 < cl.len) : (ci += 1) {
                off2 += 4; // expiry
                const name = cstrAt(cl, off2);
                off2 += name.len + 1;
                const stat = cstrAt(cl, off2);
                off2 += stat.len + 1;
                std.debug.print("  - char \"{s}\"\n", .{name});
                if (cname_len == 0 and name.len > 0 and name.len < cname_buf.len) {
                    @memcpy(cname_buf[0..name.len], name);
                    cname_len = name.len;
                }
            }
        }

        // ── MCP_CHARCREATE — make a character if the account has none ──
        if (cname_len == 0) {
            const newname = "Clientella"; // <=15 chars
            var ccb: [64]u8 = undefined;
            std.mem.writeInt(u32, ccb[0..4], 1, .little); // class 1 = Sorceress
            std.mem.writeInt(u16, ccb[4..6], 0x20, .little); // status: 0x20 = expansion (LoD), softcore
            @memcpy(ccb[6 .. 6 + newname.len], newname);
            ccb[6 + newname.len] = 0;
            try mcpSend(mfd, MCP_CHARCREATE, ccb[0 .. 7 + newname.len]);
            const ccr = mcpRecv(mfd, MCP_CHARCREATE, &mb) catch &[_]u8{};
            const ccres = if (ccr.len >= 4) std.mem.readInt(u32, ccr[0..4], .little) else 0xffffffff;
            std.debug.print("[MCP_CHARCREATE] \"{s}\" class=Sorceress(exp) result=0x{x}  => {s}\n", .{ newname, ccres, if (ccres == 0) "created" else "failed" });
            if (ccres == 0) {
                @memcpy(cname_buf[0..newname.len], newname);
                cname_len = newname.len;
            }
        }
        if (cname_len == 0) return;
        const charname = cname_buf[0..cname_len];

        // ── MCP_CHARLOGON — select the character ──
        var clb: [40]u8 = undefined;
        @memcpy(clb[0..cname_len], charname);
        clb[cname_len] = 0;
        try mcpSend(mfd, MCP_CHARLOGON, clb[0 .. cname_len + 1]);
        const clr = mcpRecv(mfd, MCP_CHARLOGON, &mb) catch &[_]u8{};
        const clres = if (clr.len >= 4) std.mem.readInt(u32, clr[0..4], .little) else 0xffffffff;
        std.debug.print("[MCP_CHARLOGON] \"{s}\" result=0x{x}  => {s}\n", .{ charname, clres, if (clres == 0) "logged onto char" else "failed" });

        // ── enter a GAME on the GS (clientless): CREATEGAME -> JOINGAME -> connect GS ->
        //    GAMELOGON(0x68) -> JOINGAME(0x6b) -> read the world stream. Real GS only. ──
        if (game_arg) |gname| {
            // MCP_CREATEGAME (0x03): reqid, flags(u32), unk(1), playerDiff, maxPlayers, name, pass, desc
            var cgb: [128]u8 = undefined;
            std.mem.writeInt(u16, cgb[0..2], 1, .little);
            std.mem.writeInt(u32, cgb[2..6], 0, .little); // flags: normal difficulty
            cgb[6] = 1;
            cgb[7] = 0;
            cgb[8] = 8;
            var co: usize = 9;
            @memcpy(cgb[co..][0..gname.len], gname);
            co += gname.len;
            cgb[co] = 0;
            co += 1;
            cgb[co] = 0;
            co += 1; // pass ""
            cgb[co] = 'd';
            cgb[co + 1] = 0;
            co += 2; // desc "d"
            try mcpSend(mfd, MCP_CREATEGAME, cgb[0..co]);
            const cgr = mcpRecv(mfd, MCP_CREATEGAME, &mb) catch &[_]u8{};
            // reply: u16 reqid, u16 token, u16 unk, u32 result
            const cg_token = if (cgr.len >= 4) std.mem.readInt(u16, cgr[2..4], .little) else 0;
            const cg_result = if (cgr.len >= 10) std.mem.readInt(u32, cgr[6..10], .little) else 0xffffffff;
            _ = cg_token;
            std.debug.print("[MCP_CREATEGAME] \"{s}\" result=0x{x}  => {s}\n", .{ gname, cg_result, if (cg_result == 0) "created" else "failed (no GS available?)" });
            if (cg_result != 0) return;

            // MCP_JOINGAME (0x04): reqid, name, pass
            var jgb: [64]u8 = undefined;
            std.mem.writeInt(u16, jgb[0..2], 2, .little);
            var jo: usize = 2;
            @memcpy(jgb[jo..][0..gname.len], gname);
            jo += gname.len;
            jgb[jo] = 0;
            jo += 1;
            jgb[jo] = 0;
            jo += 1; // pass ""
            try mcpSend(mfd, MCP_JOINGAME, jgb[0..jo]);
            const jgr = mcpRecv(mfd, MCP_JOINGAME, &mb) catch &[_]u8{};
            if (jgr.len < 18) {
                std.debug.print("[MCP_JOINGAME] short reply ({d} B)\n", .{jgr.len});
                return;
            }
            const gtoken = std.mem.readInt(u16, jgr[2..4], .little);
            const gsip = jgr[6..10];
            const ghash = std.mem.readInt(u32, jgr[10..14], .little);
            const jresult = std.mem.readInt(u32, jgr[14..18], .little);
            var gsipbuf: [20]u8 = undefined;
            const gsips = std.fmt.bufPrint(&gsipbuf, "{d}.{d}.{d}.{d}", .{ gsip[0], gsip[1], gsip[2], gsip[3] }) catch return;
            std.debug.print("[MCP_JOINGAME] token=0x{x} gs={s}:{d} hash=0x{x} result=0x{x}\n", .{ gtoken, gsips, gs_port, ghash, jresult });
            if (jresult != 0) return;

            // Connect to the GS game port (d2ingress) and play the entry sequence.
            const gsfd = connectResolved(gpa, gsips, gs_port) catch {
                std.debug.print("[GS] connect to {s}:{d} failed\n", .{ gsips, gs_port });
                return;
            };
            defer _ = close(gsfd);
            setRecvTimeout(gsfd, 5000);
            // GAMELOGON_MULTI (0x68), 37 bytes (D2GSPacketClt0x68 — raw, no framing).
            // Field layout (the d2ingress/edge rewrites nGameToken@5 -> gameid):
            //   [0]=id [1..5]=nGameHash [5..7]=nGameToken [7]=nCharClass [8..12]=nVerByte
            //   [12..16]=nVersionConstant(0xED5DCC50) [16..20]=nConstant(0x91A519B6)
            //   [20]=nLanguageCode [21..37]=szCharName[16].
            var gl: [37]u8 = [_]u8{0} ** 37;
            gl[0] = 0x68;
            std.mem.writeInt(u32, gl[1..5], ghash, .little); // nGameHash
            std.mem.writeInt(u16, gl[5..7], gtoken, .little); // nGameToken
            gl[7] = 1; // nCharClass (Sorceress — our EpicSorc char is class 1)
            std.mem.writeInt(u32, gl[8..12], if (ver_byte != 0) ver_byte else 0x0E, .little); // nVerByte
            std.mem.writeInt(u32, gl[12..16], 0xED5DCC50, .little); // nVersionConstant (expansion)
            std.mem.writeInt(u32, gl[16..20], 0x91A519B6, .little); // nConstant
            gl[20] = 0; // nLanguageCode
            @memcpy(gl[21..][0..@min(charname.len, 15)], charname[0..@min(charname.len, 15)]);
            try writeAll(gsfd, &gl);
            std.debug.print("[GS] -> GAMELOGON (0x68) token=0x{x} char=\"{s}\"\n", .{ gtoken, charname });
            var gbuf: [8192]u8 = undefined;
            const n1 = read(gsfd, gbuf[0..].ptr, gbuf.len);
            if (n1 <= 0) {
                std.debug.print("[GS] no response to GAMELOGON — refused/closed (try --verbyte)\n", .{});
                return;
            }
            std.debug.print("[GS] <- {d} bytes after GAMELOGON (GS accepted + streaming)\n", .{n1});
            // Server-driven load: GS streams AF00/AF01 -> 0x01 GameFlags -> (loads char) ->
            // 0x02 LoadSuccess. The JOINGAME (0x6b) must be sent ONLY AFTER 0x02 (char fully
            // loaded) — sending it earlier makes SrvJoinAct hit a save-load error (JOIN
            // REFUSED). Then 0x6a enters the world -> burst (0x59 AssignPlayer). Requires the
            // GS to run with --no-compress so the S->C frames are plaintext-parseable here.
            var jb: [65536]u8 = undefined;
            var have: usize = @intCast(n1);
            @memcpy(jb[0..have], gbuf[0..have]);
            var joined = false;
            var got_world = false;
            var got_flags = false;
            var timeouts: usize = 0;
            var rounds: usize = 0;
            while (rounds < 400) : (rounds += 1) {
                var i: usize = 0;
                while (i < have) {
                    const b0 = jb[i];
                    const is_hs = (b0 == 0xAF);
                    var total: usize = 0;
                    var idoff: usize = 1;
                    if (is_hs) {
                        total = 2;
                    } else if (b0 < 0xF0) {
                        total = b0;
                        idoff = 1;
                    } else {
                        if (i + 1 >= have) break;
                        total = (@as(usize, b0 & 0x0F) << 8) | jb[i + 1];
                        idoff = 2;
                    }
                    if (total == 0) total = 1;
                    if (i + total > have) break; // incomplete frame; wait for more bytes
                    if (!is_hs) {
                        const pid = jb[i + idoff];
                        if (pid == 0x01) got_flags = true;
                        if (pid == 0x02 and !joined) {
                            try writeAll(gsfd, &[_]u8{0x6b}); // JOINGAME
                            try writeAll(gsfd, &[_]u8{0x6a}); // enter world
                            joined = true;
                            std.debug.print("[GS] <- 0x02 LoadSuccess -> sent JOINGAME(0x6b)+ENTERWORLD(0x6a)\n", .{});
                        }
                        if (pid == 0x59) got_world = true;
                    }
                    i += total;
                }
                // keep the incomplete tail
                if (i > 0 and i <= have) {
                    const rem = have - i;
                    std.mem.copyForwards(u8, jb[0..rem], jb[i..have]);
                    have = rem;
                }
                if (got_world) break;
                const n = read(gsfd, jb[have..].ptr, jb.len - have);
                if (n <= 0) {
                    // char-load can lag behind GameFlags; tolerate a few recv timeouts.
                    timeouts += 1;
                    // Fallback: GameFlags arrived but LoadSuccess is slow -> prod the join anyway.
                    if (got_flags and !joined) {
                        try writeAll(gsfd, &[_]u8{0x6b});
                        try writeAll(gsfd, &[_]u8{0x6a});
                        joined = true;
                        std.debug.print("[GS] (fallback) GameFlags seen, 0x02 lagging -> sent 0x6b/0x6a\n", .{});
                    }
                    if (timeouts >= 4) break;
                    continue;
                }
                have += @intCast(n);
            }
            if (got_world)
                std.debug.print("[GS] => IN GAME — world burst (0x59 AssignPlayer) received\n", .{})
            else if (joined)
                std.debug.print("[GS] joined (0x6b/0x6a sent) but no 0x59 seen (check GS log SrvJoinAct ENTER)\n", .{})
            else
                std.debug.print("[GS] never saw 0x02 LoadSuccess (char load failed?)\n", .{});
            return;
        }

        // ── enter chat (BNCS), byte-for-byte like the real 1.14d client (captured via
        //    REALMD_TRACE): GETCHANNELLIST(product 4cc) -> ENTERCHAT(char + "realm,char")
        //    -> JOINCHANNEL(flags=5, "Diablo II"). The real client enters chat before
        //    accessing the ladder. ──
        var prodcode: [4]u8 = .{ 'P', 'X', '2', 'D' }; // D2XP reversed
        if (product.len == 4) prodcode = .{ product[3], product[2], product[1], product[0] };
        try send(fd, SID_GETCHANNELLIST, &prodcode);
        const ch = recvUntil(fd, SID_GETCHANNELLIST, &mb) catch &[_]u8{};
        if (ch.len > 1) std.debug.print("[SID_GETCHANNELLIST] first channel=\"{s}\"\n", .{cstrAt(ch, 0)});

        // SID_ENTERCHAT: username = char name, statstring = "<realm>,<charname>"
        var ecb: [128]u8 = undefined;
        var eo: usize = 0;
        @memcpy(ecb[eo..][0..cname_len], charname);
        eo += cname_len;
        ecb[eo] = 0;
        eo += 1;
        @memcpy(ecb[eo..][0..first_realm.len], first_realm);
        eo += first_realm.len;
        ecb[eo] = ',';
        eo += 1;
        @memcpy(ecb[eo..][0..cname_len], charname);
        eo += cname_len;
        ecb[eo] = 0;
        eo += 1;
        try send(fd, SID_ENTERCHAT, ecb[0..eo]);
        const ec = recvUntil(fd, SID_ENTERCHAT, &mb) catch &[_]u8{};
        if (ec.len > 0) std.debug.print("[SID_ENTERCHAT] unique name=\"{s}\" stat=\"{s}\"\n", .{ cstrAt(ec, 0), cstrAt(ec, cstrAt(ec, 0).len + 1) });

        // SID_JOINCHANNEL: flags=5 (D2 realm-lobby join)
        var jc: [48]u8 = undefined;
        std.mem.writeInt(u32, jc[0..4], 5, .little);
        @memcpy(jc[4 .. 4 + channel_arg.len], channel_arg);
        jc[4 + channel_arg.len] = 0;
        try send(fd, SID_JOINCHANNEL, jc[0 .. 5 + channel_arg.len]);

        // ── chat-session mode (--listen): stay connected, print every chat event, and
        //    optionally talk (--say) / kick (--kick) after --delay. Drives the 2-client demo. ──
        if (listen_sec > 0) {
            setRecvTimeout(fd, 400);
            const start = nowMs();
            const send_at = start + @as(i64, @intCast(delay_sec)) * 1000;
            const deadline = start + @as(i64, @intCast(listen_sec)) * 1000;
            var fired = (say_arg == null and kick_arg == null);
            std.debug.print("[chat] joined \"{s}\" — listening {d}s\n", .{ channel_arg, listen_sec });
            while (true) {
                const now = nowMs();
                if (!fired and now >= send_at) {
                    if (say_arg) |s| {
                        std.debug.print(">> SAY: \"{s}\"\n", .{s});
                        sendChat(fd, s);
                    }
                    if (kick_arg) |k| {
                        var kb: [128]u8 = undefined;
                        const kc = std.fmt.bufPrint(&kb, "/kick {s}", .{k}) catch k;
                        std.debug.print(">> CMD: \"{s}\"\n", .{kc});
                        sendChat(fd, kc);
                    }
                    fired = true;
                }
                if (now >= deadline) break;
                if (pumpEvents(fd) == 0) {
                    std.debug.print("[chat] *** socket closed — kicked or disconnected ***\n", .{});
                    break;
                }
            }
            return;
        }

        // Non-session: read a few chat events to show the channel state, then the ladder.
        var evi: usize = 0;
        while (evi < 10) : (evi += 1) {
            const cev = recvUntil(fd, SID_CHATEVENT, &mb) catch break;
            if (cev.len < 28) break;
            const eid = std.mem.readInt(u32, cev[0..4], .little);
            const uname = cstrAt(cev, 24);
            const text = cstrAt(cev, 24 + uname.len + 1);
            std.debug.print("[CHATEVENT] eid=0x{x} user=\"{s}\" text=\"{s}\"\n", .{ eid, uname, text });
        }

        // ── MCP_LADDERDATA (0x11) — the real client sends 3 bytes: mode 0x1b + u16(0)
        //    (captured via REALMD_TRACE). A 1-byte request makes real bnet reply 0x00. ──
        try mcpSend(mfd, MCP_LADDERDATA, &[_]u8{ 0x1b, 0, 0 });
        const ld = mcpRecv(mfd, MCP_LADDERDATA, &mb) catch &[_]u8{};
        if (ld.len < 19) {
            std.debug.print("[MCP_LADDERDATA] empty ladder (no ranked chars)\n", .{});
        } else {
            const count = std.mem.readInt(u32, ld[11..][0..4], .little);
            const esize = std.mem.readInt(u32, ld[15..][0..4], .little);
            std.debug.print("[MCP_LADDERDATA] {d} ranked entries (name width {d})\n", .{ count, esize });
            var lo: usize = 19;
            var li: usize = 0;
            while (li < count and lo + 12 + esize <= ld.len) : (li += 1) {
                lo += 8; // experience lo/hi
                const stats = std.mem.readInt(u32, ld[lo..][0..4], .little);
                lo += 4;
                const nm = cstrAt(ld, lo);
                lo += esize;
                std.debug.print("  #{d} \"{s}\" stats=0x{x}\n", .{ li + 1, nm, stats });
            }
        }
    }
}
