//! bnftp-probe — a clientless BNFTP discovery client.
//!
//! BNFTP (Battle.net File Transfer, protocol selector 0x02) is UNAUTHENTICATED:
//! no CD-key, no SRP, no login. To discover what a real server serves we do two
//! CD-key-free steps:
//!
//!   1. Connect 0x01 → SID_AUTH_INFO. The reply is unconditional and names the
//!      version-check MPQ (filename + filetime) the server wants. Hexdump it.
//!   2. Open a fresh 0x02 connection → BNFTP-request that filename. Hexdump the
//!      raw reply and save the file bytes so we can diff the header layout (and
//!      the MPQ contents) against our own src/realm/server/bnftp.zig.
//!
//! Egress can go through a SOCKS5 proxy (`--socks5 host:port`) so the probe
//! reaches the target from a chosen IP — e.g. an `ssh -D 1080 hetzner` dynamic
//! forward, or a standalone proxy on a Hetzner box. With SOCKS5 the proxy does
//! the DNS, so the target host is sent as a domain name.
//!
//!   zig build bnftp-probe -- [opts] <target-host> [product] [filename]
//!   opts: --socks5 H:P  --socks5-auth U:P  --port N (default 6112)
//!         --proto-ver 0xNNNN (BNFTP version, default 0x0100)
//!   product: 4CC, default D2XP (LoD). Use D2DV for classic.
const std = @import("std");

// ── libc sockets (native host target; std.posix socket wrappers are gone in 0.16) ──
const Socket = c_int;
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
// open is variadic in C — MUST declare `...` or the mode arg lands wrong on arm64.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;

const SOCK_STREAM: c_int = 1;

/// Create/truncate `path` and write `data`. Uses libc directly (std.fs is
/// reworked under the 0.16 Io interface and std.posix.open is gone).
fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const flags: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    const fd = open(path, flags, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    try writeAll(fd, data);
}

var recv_timeout_ms: u32 = 20000; // SO_RCVTIMEO default; --timeout overrides

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

fn readFull(fd: Socket, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = read(fd, buf.ptr + got, buf.len - got);
        if (n <= 0) return error.SocketClosed;
        got += @intCast(n);
    }
}

/// Read up to buf.len, stopping at EOF/timeout. Returns the bytes read.
fn readSome(fd: Socket, buf: []u8) usize {
    const n = read(fd, buf.ptr, buf.len);
    return if (n <= 0) 0 else @intCast(n);
}

/// TCP-connect to host:port, resolving via libc getaddrinfo.
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
            setRecvTimeout(fd, recv_timeout_ms);
            return fd;
        }
        _ = close(fd);
    }
    return error.ConnectFailed;
}

// ── SOCKS5 client (RFC 1928 / 1929) ───────────────────────────────────────────
const Proxy = struct { host: []const u8, port: u16, user: []const u8 = "", pass: []const u8 = "" };

fn socks5Connect(fd: Socket, px: Proxy, target: []const u8, tport: u16) !void {
    // Greeting: offer no-auth and (if creds given) user/pass.
    var greet: [4]u8 = undefined;
    greet[0] = 0x05;
    if (px.user.len > 0) {
        greet[1] = 2;
        greet[2] = 0x00;
        greet[3] = 0x02;
        try writeAll(fd, greet[0..4]);
    } else {
        greet[1] = 1;
        greet[2] = 0x00;
        try writeAll(fd, greet[0..3]);
    }
    var sel: [2]u8 = undefined;
    try readFull(fd, &sel);
    if (sel[0] != 0x05) return error.Socks5BadVersion;
    switch (sel[1]) {
        0x00 => {}, // no auth
        0x02 => {
            if (px.user.len == 0) return error.Socks5AuthRequired;
            var ab: [600]u8 = undefined;
            var n: usize = 0;
            ab[n] = 0x01;
            n += 1;
            ab[n] = @intCast(px.user.len);
            n += 1;
            @memcpy(ab[n..][0..px.user.len], px.user);
            n += px.user.len;
            ab[n] = @intCast(px.pass.len);
            n += 1;
            @memcpy(ab[n..][0..px.pass.len], px.pass);
            n += px.pass.len;
            try writeAll(fd, ab[0..n]);
            var ar: [2]u8 = undefined;
            try readFull(fd, &ar);
            if (ar[1] != 0x00) return error.Socks5AuthFailed;
        },
        else => return error.Socks5NoAcceptableAuth,
    }
    // CONNECT request, ATYP=domain so the proxy resolves DNS.
    var req: [600]u8 = undefined;
    var n: usize = 0;
    req[n] = 0x05;
    n += 1; // ver
    req[n] = 0x01;
    n += 1; // CONNECT
    req[n] = 0x00;
    n += 1; // rsv
    req[n] = 0x03;
    n += 1; // ATYP domain
    req[n] = @intCast(target.len);
    n += 1;
    @memcpy(req[n..][0..target.len], target);
    n += target.len;
    std.mem.writeInt(u16, req[n..][0..2], tport, .big);
    n += 2;
    try writeAll(fd, req[0..n]);
    // Reply: VER REP RSV ATYP BND.ADDR BND.PORT
    var head: [4]u8 = undefined;
    try readFull(fd, &head);
    if (head[0] != 0x05) return error.Socks5BadVersion;
    if (head[1] != 0x00) {
        std.debug.print("socks5 CONNECT failed, REP=0x{x:0>2}\n", .{head[1]});
        return error.Socks5ConnectRejected;
    }
    const bnd_len: usize = switch (head[3]) {
        0x01 => 4, // IPv4
        0x04 => 16, // IPv6
        0x03 => blk: { // domain: 1 len byte + that many
            var l: [1]u8 = undefined;
            try readFull(fd, &l);
            break :blk l[0];
        },
        else => return error.Socks5BadAtyp,
    };
    var skip: [16 + 2]u8 = undefined;
    try readFull(fd, skip[0 .. bnd_len + 2]); // bnd addr + port, discarded
}

/// Dial target:port either directly or through the SOCKS5 proxy.
fn dial(gpa: std.mem.Allocator, target: []const u8, tport: u16, proxy: ?Proxy) !Socket {
    if (proxy) |px| {
        const fd = try connectResolved(gpa, px.host, px.port);
        errdefer _ = close(fd);
        try socks5Connect(fd, px, target, tport);
        return fd;
    }
    return connectResolved(gpa, target, tport);
}

// ── BNCS framing: <0xFF, id, u16 len> + body ──────────────────────────────────
fn bncsSend(fd: Socket, id: u8, body: []const u8) !void {
    var hdr: [4]u8 = .{ 0xFF, id, 0, 0 };
    std.mem.writeInt(u16, hdr[2..4], @intCast(4 + body.len), .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, body);
}

const Pkt = struct { id: u8, body: []const u8 };
fn bncsRecv(fd: Socket, buf: []u8) !Pkt {
    var hdr: [4]u8 = undefined;
    try readFull(fd, &hdr);
    if (hdr[0] != 0xFF) return error.BncsBadMagic;
    const len = std.mem.readInt(u16, hdr[2..4], .little);
    if (len < 4 or len > buf.len) return error.BncsBadLen;
    const blen = len - 4;
    try readFull(fd, buf[0..blen]);
    return .{ .id = hdr[1], .body = buf[0..blen] };
}

// little-endian 4CC: 'D2XP' is stored "PX2D", i.e. the chars reversed.
fn fourcc(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| v = (v << 8) | c; // big-endian of the chars == LE dword of reversed
    return v;
}

fn hexdump(label: []const u8, data: []const u8) void {
    std.debug.print("--- {s} ({d} bytes) ---\n", .{ label, data.len });
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        const row = data[off..@min(off + 16, data.len)];
        std.debug.print("{x:0>4}  ", .{off});
        for (0..16) |i| {
            if (i < row.len) std.debug.print("{x:0>2} ", .{row[i]}) else std.debug.print("   ", .{});
            if (i == 7) std.debug.print(" ", .{});
        }
        std.debug.print(" |", .{});
        for (row) |c| std.debug.print("{c}", .{if (c >= 0x20 and c < 0x7f) c else '.'});
        std.debug.print("|\n", .{});
    }
}

fn cstrAt(b: []const u8, off: usize) []const u8 {
    if (off >= b.len) return "";
    const end = std.mem.indexOfScalarPos(u8, b, off, 0) orelse b.len;
    return b[off..end];
}

const SID_AUTH_INFO = 0x50;
const SID_AUTH_CHECK = 0x51;
const SID_PING = 0x25;

/// Receive BNCS packets until one with id == want. Real bnet sends SID_PING
/// (0x25) on connect — echo its cookie back (servers gate further replies on it)
/// and keep reading. Unrelated packets are hexdumped and skipped.
fn recvUntil(fd: Socket, buf: []u8, want: u8) !Pkt {
    while (true) {
        const r = try bncsRecv(fd, buf);
        if (r.id == want) return r;
        if (r.id == SID_PING) {
            std.debug.print("  <- SID_PING, echoing cookie\n", .{});
            try bncsSend(fd, SID_PING, r.body);
            continue;
        }
        std.debug.print("  <- unexpected id=0x{x:0>2}, skipping\n", .{r.id});
        hexdump("skipped packet", r.body);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var proxy: ?Proxy = null;
    var port: u16 = 6112;
    var proto_ver: u16 = 0x0100;
    var product: []const u8 = "D2XP";
    var out_dir: ?[]const u8 = null;
    var find_patch = false;
    var old_ver: u32 = 1; // deliberately-old EXE version to provoke "must upgrade"
    var head_only = false; // read only the BNFTP reply header (size), skip the body
    var bnftp_only = false; // skip the AUTH_INFO handshake (BNFTP needs no auth)
    var positional: [3][]const u8 = undefined;
    var npos: usize = 0;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--socks5")) {
            const hp = it.next() orelse return err("--socks5 wants HOST:PORT");
            const c = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return err("--socks5 wants HOST:PORT");
            proxy = .{ .host = try gpa.dupe(u8, hp[0..c]), .port = try std.fmt.parseInt(u16, hp[c + 1 ..], 10) };
        } else if (std.mem.eql(u8, a, "--socks5-auth")) {
            const up = it.next() orelse return err("--socks5-auth wants USER:PASS");
            const c = std.mem.indexOfScalar(u8, up, ':') orelse return err("--socks5-auth wants USER:PASS");
            if (proxy) |*px| {
                px.user = try gpa.dupe(u8, up[0..c]);
                px.pass = try gpa.dupe(u8, up[c + 1 ..]);
            } else return err("--socks5-auth before --socks5");
        } else if (std.mem.eql(u8, a, "--port")) {
            port = try std.fmt.parseInt(u16, it.next() orelse return err("--port wants N"), 10);
        } else if (std.mem.eql(u8, a, "--proto-ver")) {
            proto_ver = try parseIntAuto(it.next() orelse return err("--proto-ver wants 0xNNNN"));
        } else if (std.mem.eql(u8, a, "--out-dir")) {
            out_dir = try gpa.dupe(u8, it.next() orelse return err("--out-dir wants DIR"));
        } else if (std.mem.eql(u8, a, "--find-patch")) {
            find_patch = true;
        } else if (std.mem.eql(u8, a, "--head")) {
            head_only = true;
        } else if (std.mem.eql(u8, a, "--bnftp-only")) {
            bnftp_only = true;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            recv_timeout_ms = try std.fmt.parseInt(u32, it.next() orelse return err("--timeout wants MS"), 10);
        } else if (std.mem.eql(u8, a, "--old-ver")) {
            old_ver = try std.fmt.parseInt(u32, it.next() orelse return err("--old-ver wants N"), 0);
        } else if (npos < positional.len) {
            positional[npos] = try gpa.dupe(u8, a);
            npos += 1;
        }
    }
    if (npos == 0) return err("usage: bnftp-probe [opts] <target-host> [product] [filename]");
    const host = positional[0];
    if (npos >= 2) product = positional[1];
    const filename: ?[]const u8 = if (npos >= 3) positional[2] else null;

    if (proxy) |px| {
        std.debug.print("== via SOCKS5 {s}:{d}{s} ==\n", .{ px.host, px.port, if (px.user.len > 0) " (auth)" else "" });
    }
    std.debug.print("== target {s}:{d}  product={s}  protoVer=0x{x:0>4} ==\n", .{ host, port, product, proto_ver });

    // ── Step 1: SID_AUTH_INFO to learn the MPQ filename (CD-key-free) ──
    // Skipped with --bnftp-only (BNFTP is unauthenticated; one conn per file).
    var rxbuf: [8192]u8 = undefined;
    var mpq_name_buf: [256]u8 = undefined;
    var mpq_name_len: usize = 0;
    if (!bnftp_only) {
        const fd = try dial(gpa, host, port, proxy);
        defer _ = close(fd);
        try writeAll(fd, &[_]u8{0x01}); // protocol selector

        var body: [128]u8 = undefined;
        var w: usize = 0;
        inline for (.{
            @as(u32, 0), // protocol id
            fourcc("IX86"), // platform
            fourcc(product), // product
            @as(u32, 0x0E), // version byte (D2)
            @as(u32, 0), // product language
            @as(u32, 0), // local IP
            @as(u32, 0), // tz bias
            @as(u32, 0), // locale id
            @as(u32, 0), // language id
        }) |v| {
            std.mem.writeInt(u32, body[w..][0..4], v, .little);
            w += 4;
        }
        for ("USA\x00United States\x00") |c| {
            body[w] = c;
            w += 1;
        }
        try bncsSend(fd, SID_AUTH_INFO, body[0..w]);

        const r = try recvUntil(fd, &rxbuf, SID_AUTH_INFO);
        std.debug.print("\n[1] SID_AUTH_INFO reply: id=0x{x:0>2}\n", .{r.id});
        hexdump("AUTH_INFO body", r.body);
        if (r.id == SID_AUTH_INFO and r.body.len >= 20) {
            const logon = std.mem.readInt(u32, r.body[0..4], .little);
            const stoken = std.mem.readInt(u32, r.body[4..8], .little);
            const filetime = std.mem.readInt(u64, r.body[12..20], .little);
            const fname = cstrAt(r.body, 20);
            const value = cstrAt(r.body, 20 + fname.len + 1);
            std.debug.print("  logonType=0x{x}  serverToken=0x{x:0>8}  mpqFiletime=0x{x}\n", .{ logon, stoken, filetime });
            std.debug.print("  MPQ filename = \"{s}\"\n", .{fname});
            std.debug.print("  value/formula = \"{s}\"\n", .{value});
            if (fname.len > 0 and fname.len < mpq_name_buf.len) {
                @memcpy(mpq_name_buf[0..fname.len], fname);
                mpq_name_len = fname.len;
            }
        } else {
            std.debug.print("  (unexpected reply id / too short — server may have changed the handshake)\n", .{});
        }

        // ── Optional: provoke the version gauntlet to reveal the forced patch ──
        // SID_AUTH_CHECK with an OLD exe version → result 0x100/0x102 "old version"
        // whose additional-info string is the patch file to BNFTP-download. This
        // is checked before CD-key validation, so still no key needed.
        if (find_patch) {
            var cb: [256]u8 = undefined;
            var cw: usize = 0;
            inline for (.{
                @as(u32, 0xCAFEBABE), // client token
                old_ver, // EXE version (old → "must upgrade")
                @as(u32, 0), // EXE hash (checkrevision result; wrong, irrelevant for ver-fail)
                @as(u32, 0), // number of CD keys in this packet
                @as(u32, 0), // using spawn key
            }) |v| {
                std.mem.writeInt(u32, cb[cw..][0..4], v, .little);
                cw += 4;
            }
            for ("Game.exe 04/14/15 22:07:36 4022272\x00probe\x00") |c| {
                cb[cw] = c;
                cw += 1;
            }
            try bncsSend(fd, SID_AUTH_CHECK, cb[0..cw]);
            const cr = try recvUntil(fd, &rxbuf, SID_AUTH_CHECK);
            std.debug.print("\n[1b] SID_AUTH_CHECK reply (old_ver=0x{x}):\n", .{old_ver});
            hexdump("AUTH_CHECK body", cr.body);
            if (cr.body.len >= 4) {
                const result = std.mem.readInt(u32, cr.body[0..4], .little);
                const info = cstrAt(cr.body, 4);
                std.debug.print("  result=0x{x:0>4}  additionalInfo=\"{s}\"\n", .{ result, info });
                std.debug.print("  ({s})\n", .{authCheckMeaning(result)});
                // For "old version" results the info string is the patch filename.
                if ((result == 0x100 or result == 0x102) and info.len > 0 and info.len < mpq_name_buf.len) {
                    @memcpy(mpq_name_buf[0..info.len], info);
                    mpq_name_len = info.len;
                    std.debug.print("  -> will BNFTP-download the patch: \"{s}\"\n", .{info});
                }
            }
        }
    }

    const file_to_get = filename orelse (if (mpq_name_len > 0) mpq_name_buf[0..mpq_name_len] else return err("no filename: AUTH_INFO gave none and none passed on cmdline"));

    // ── Step 2: BNFTP download (0x02 connection, unauthenticated) ──
    {
        const fd = try dial(gpa, host, port, proxy);
        defer _ = close(fd);

        var req: [512]u8 = undefined;
        var w: usize = 0;
        w += 2; // [0x00] reqLen u16, filled below
        std.mem.writeInt(u16, req[w..][0..2], proto_ver, .little);
        w += 2;
        std.mem.writeInt(u32, req[w..][0..4], fourcc("IX86"), .little);
        w += 4; // platform
        std.mem.writeInt(u32, req[w..][0..4], fourcc(product), .little);
        w += 4; // product
        std.mem.writeInt(u32, req[w..][0..4], 0, .little);
        w += 4; // bannerId
        std.mem.writeInt(u32, req[w..][0..4], 0, .little);
        w += 4; // bannerExt
        std.mem.writeInt(u32, req[w..][0..4], 0, .little);
        w += 4; // startPos
        std.mem.writeInt(u64, req[w..][0..8], 0, .little);
        w += 8; // local filetime
        @memcpy(req[w..][0..file_to_get.len], file_to_get);
        w += file_to_get.len;
        req[w] = 0;
        w += 1; // cstr null
        std.mem.writeInt(u16, req[0..2], @intCast(w), .little); // reqLen = whole header

        try writeAll(fd, &[_]u8{0x02}); // BNFTP protocol selector
        try writeAll(fd, req[0..w]);
        std.debug.print("\n[2] BNFTP request for \"{s}\" ({d}-byte header)\n", .{ file_to_get, w });
        if (!head_only) hexdump("BNFTP request", req[0..w]);

        // --head: read only enough for the reply header (size + name), then stop.
        // The reply leads with u32 headerLen, u32 fileSize — so existence/size is
        // known without pulling the (multi-MB) body. Good for sweeping filenames.
        if (head_only) {
            var hb: [256]u8 = undefined;
            var got: usize = 0;
            while (got < hb.len) {
                const n = readSome(fd, hb[got..]);
                if (n == 0) break;
                got += n;
            }
            if (got >= 8) {
                const hlen = std.mem.readInt(u32, hb[0..4], .little);
                const fsize = std.mem.readInt(u32, hb[4..8], .little);
                const rname = if (hlen >= 0x19 and 0x18 < got) cstrAt(hb[0..got], 0x18) else "";
                std.debug.print("  HEAD: fileSize={d}  headerLen={d}  name=\"{s}\"  {s}\n", .{ fsize, hlen, rname, if (fsize == 0) "NOT HOSTED" else "EXISTS" });
            } else {
                std.debug.print("  HEAD: short reply ({d} bytes) — not hosted\n", .{got});
            }
            std.debug.print("\ndone.\n", .{});
            return;
        }

        // Read the whole reply (header + file) up to a cap (patches are ~10 MB).
        const cap = 64 << 20;
        const reply = try gpa.alloc(u8, cap);
        var total: usize = 0;
        while (total < cap) {
            const n = readSome(fd, reply[total..]);
            if (n == 0) break;
            total += n;
        }
        const data = reply[0..total];
        std.debug.print("\n[2] BNFTP reply: {d} bytes total\n", .{total});
        hexdump("BNFTP reply header (first 64)", data[0..@min(64, data.len)]);

        if (data.len >= 8) {
            const hlen = std.mem.readInt(u32, data[0..4], .little);
            const fsize = std.mem.readInt(u32, data[4..8], .little);
            std.debug.print("  parsed: headerLen={d}  fileSize={d}\n", .{ hlen, fsize });
            if (hlen >= 0x18 and hlen <= data.len) {
                const ftime = std.mem.readInt(u64, data[0x10..0x18], .little);
                const rname = cstrAt(data, 0x18);
                std.debug.print("  filetime=0x{x}  filename=\"{s}\"\n", .{ ftime, rname });
                const body = data[hlen..];
                // Save the file payload for inspection.
                // With --out-dir, store under the real filename (drop straight
                // into realmd-data/bnftp/ so our server serves the authentic file).
                // Otherwise save to cwd as bnftp-<name> for ad-hoc inspection.
                const out = if (out_dir) |d|
                    try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d, basename(file_to_get) }, 0)
                else
                    try std.fmt.allocPrintSentinel(gpa, "bnftp-{s}", .{basename(file_to_get)}, 0);
                try writeFile(out.ptr, body[0..@min(body.len, fsize)]);
                std.debug.print("  saved {d} file bytes -> {s}\n", .{ @min(body.len, fsize), out });
                if (body.len >= 4) std.debug.print("  first 4 file bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2} (MPQ magic 'MPQ\\x1a' = 4d 50 51 1a)\n", .{ body[0], body[1], body[2], body[3] });
            } else {
                std.debug.print("  headerLen 0x{x} out of range — dumping more:\n", .{hlen});
                hexdump("BNFTP reply (first 256)", data[0..@min(256, data.len)]);
            }
        }
    }
    std.debug.print("\ndone.\n", .{});
}

fn authCheckMeaning(result: u32) []const u8 {
    return switch (result) {
        0x000 => "passed",
        0x100 => "old game version (info = patch file)",
        0x101 => "invalid version",
        0x102 => "game version must be downgraded (info = patch file)",
        0x200 => "invalid CD key",
        0x201 => "CD key in use",
        0x202 => "banned key",
        0x203 => "wrong product",
        else => "unknown / version-code in low byte",
    };
}

fn basename(p: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, p, "/\\") orelse return p;
    return p[slash + 1 ..];
}

fn parseIntAuto(s: []const u8) !u16 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
        return std.fmt.parseInt(u16, s[2..], 16);
    return std.fmt.parseInt(u16, s, 10);
}

fn err(msg: []const u8) anyerror {
    std.debug.print("error: {s}\n", .{msg});
    return error.BadUsage;
}
