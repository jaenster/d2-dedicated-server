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

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    var host: ?[]const u8 = null;
    var product: []const u8 = "D2XP";
    var game_ver: []const u8 = "1.14.3.71";
    var sig_ok: u8 = 1;
    var pos: usize = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--sig0")) {
            sig_ok = 0;
        } else switch (pos) {
            0 => host = a,
            1 => product = a,
            2 => game_ver = a,
            else => {},
        }
        if (!std.mem.startsWith(u8, a, "--")) pos += 1;
    }
    const h = host orelse {
        std.debug.print("usage: checkrev-probe <host> [product] [gameVersion] [--sig0]\n", .{});
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

    // ── compute the response with our portable core ──
    var full_buf: [64]u8 = undefined;
    const full = core.response(challenge, game_ver, sig_ok, &full_buf) orelse return error.ShortChallenge;
    const exe_hash = @as(u32, full[0]) | (@as(u32, full[1]) << 8) | (@as(u32, full[2]) << 16) | (@as(u32, full[3]) << 24);
    const exe_info = full[4..];
    std.debug.print("[compute] response=\"{s}\"  -> exeHash=0x{x:0>8}  exeInfo=\"{s}\"\n", .{ full, exe_hash, exe_info });

    // ── SID_AUTH_CHECK (modern layout, no CD keys) ──
    var cb: [256]u8 = undefined;
    var cw: usize = 0;
    for ([_]u32{
        0xCAFEBABE, // client token
        0, // EXE Version  (modern: dialog result = 0)
        exe_hash, // EXE Hash     (first 4 base64 bytes of the response)
        0, // number of CD keys
        0, // using spawn
    }) |v| {
        std.mem.writeInt(u32, cb[cw..][0..4], v, .little);
        cw += 4;
    }
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
        std.debug.print("\n[AUTH_CHECK] no reply ({s}) — server dropped the packet.\n", .{@errorName(e)});
        std.debug.print("  D2 expects a well-formed SID_AUTH_CHECK WITH CD-key block(s); a keyless/\n" ++
            "  wrong-layout packet is silently closed (no result code). Need a real-client\n" ++
            "  capture of the modern AUTH_CHECK to confirm the exact field layout + key structure.\n", .{});
        return;
    };
    if (ac.len < 4) return error.ShortAuthCheck;
    const result = std.mem.readInt(u32, ac[0..4], .little);
    const info = cstrAt(ac, 4);
    std.debug.print("\n[AUTH_CHECK] result=0x{x:0>4}  info=\"{s}\"\n", .{ result, info });
    std.debug.print("  => {s}\n", .{authMeaning(result)});
}
