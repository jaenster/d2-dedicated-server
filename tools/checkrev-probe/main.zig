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
const core = @import("checkrev_core");
const cdkey = @import("cdkey");
const xsha1 = @import("xsha1");

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

/// Read framed BNCS packets until one with id == want; auto-echo SID_PING.
fn recvUntil(fd: Socket, want: u8, out: []u8) ![]const u8 {
    while (true) {
        while (rxlen >= 4 and rxbuf[0] == 0xFF) {
            const id = rxbuf[1];
            const plen = std.mem.readInt(u16, rxbuf[2..4], .little);
            if (plen < 4 or plen > rxbuf.len) return error.BadFrame;
            if (rxlen < plen) break; // need more bytes
            const body = rxbuf[4..plen];
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
const MCP_STARTUP = 0x01;
const MCP_MOTD = 0x12;
const MCP_CHARLIST2 = 0x19;
const CLIENT_TOKEN: u32 = 0xCAFEBABE;

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
        if (rr.len < 24) return;
        const cookie = std.mem.readInt(u32, rr[0..4], .little);
        const status = std.mem.readInt(u32, rr[4..8], .little);
        std.debug.print("[LOGONREALMEX] realm=\"{s}\" cookie=0x{x:0>8} status=0x{x:0>8}  => {s}\n", .{ first_realm, cookie, status, if (status == 0) "OK — MCP handoff" else "realm logon failed" });
        if (status != 0) return;

        // ── MCP (realm/character server) — connect to the addr the realm gave us ──
        const ip4 = rr[16..20];
        const mport = std.mem.readInt(u16, rr[20..22], .big);
        var ipstr: [20]u8 = undefined;
        const ips = std.fmt.bufPrint(&ipstr, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] }) catch return;
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
        const sr = try mcpRecv(mfd, MCP_STARTUP, &mb);
        const sres = if (sr.len >= 4) std.mem.readInt(u32, sr[0..4], .little) else 0xffffffff;
        std.debug.print("[MCP_STARTUP] result=0x{x}  => {s}\n", .{ sres, if (sres == 0) "session accepted (in the realm)" else "rejected" });
        if (sres != 0) return;

        // MCP_MOTD — the realm's welcome/message-of-the-day text
        try mcpSend(mfd, MCP_MOTD, &[_]u8{});
        const mo = mcpRecv(mfd, MCP_MOTD, &mb) catch &[_]u8{};
        if (mo.len > 1) std.debug.print("[MCP_MOTD] \"{s}\"\n", .{cstrAt(mo, 1)});

        // MCP_CHARLIST2 — the account's characters on this realm
        var clreq: [4]u8 = undefined;
        std.mem.writeInt(u32, &clreq, 8, .little);
        try mcpSend(mfd, MCP_CHARLIST2, &clreq);
        const cl = mcpRecv(mfd, MCP_CHARLIST2, &mb) catch &[_]u8{};
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
            }
        }
    }
}
