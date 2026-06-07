//! D2DBS client — fetch/save character data from PvPGN's D2DBS.
//!
//! The GS opens an outbound TCP connection to D2DBS and requests a character's
//! save bytes (GET_DATA_REQUEST 0x31 → GET_DATA_REPLY 0x31, datatype CHARSAVE).
//! Same 8-byte LE header as the D2CS link. Source: pvpgn-server src/d2dbs/dbspacket.h.
//!
//! This is the "fetch the chars" half: when the engine needs a character on join
//! (fpGetDatabaseCharacter), we fetch it here and hand the bytes to the engine.

const std = @import("std");
const p = @import("protocol.zig");
const log = @import("../log.zig");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;

const sockaddr_in = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8 = .{0} ** 8,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, t: i32, proto: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn htons(v: u16) callconv(.winapi) u16;
extern "ws2_32" fn inet_addr(cp: [*:0]const u8) callconv(.winapi) u32;

const TYPE_SAVE: u16 = 0x30;
const TYPE_GET: u16 = 0x31;
const DATATYPE_CHARSAVE: u16 = 0x01;
const INADDR_NONE: u32 = 0xffff_ffff;

var sock: SOCKET = INVALID_SOCKET;
var seqno: u32 = 0;

fn sendAll(bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(sock, bytes.ptr + off, @intCast(bytes.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn recvAll(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(sock, buf.ptr + off, @intCast(buf.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Connect to D2DBS. `host` is dotted-quad IPv4. Returns true on success.
pub fn connectTo(host: [*:0]const u8, port: u16) bool {
    var wsa: [512]u8 = undefined;
    _ = WSAStartup(0x0202, &wsa);
    const addr = inet_addr(host);
    if (addr == INADDR_NONE) {
        log.print("d2dbs: bad host (dotted-quad IPv4 only)");
        return false;
    }
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) return false;
    const sa = sockaddr_in{ .family = AF_INET, .port = htons(port), .addr = addr };
    if (connect(sock, &sa, @sizeOf(sockaddr_in)) != 0) {
        log.print("d2dbs: connect failed");
        _ = closesocket(sock);
        sock = INVALID_SOCKET;
        return false;
    }
    log.print("d2dbs: connected");
    return true;
}

/// Close the D2DBS connection (if open). Safe to call when already closed.
pub fn disconnect() void {
    if (sock != INVALID_SOCKET) {
        _ = closesocket(sock);
        sock = INVALID_SOCKET;
    }
}

/// Fetch a character's save bytes into `out`. Returns the number of bytes written
/// (0 on failure). The reply also carries createtime / allowladder (logged).
pub fn fetchCharSave(account: []const u8, charname: []const u8, out: []u8) usize {
    if (sock == INVALID_SOCKET) return 0;
    seqno +%= 1;

    // Build GET_DATA_REQUEST: header + datatype + account\0 + char\0
    var req: [320]u8 = undefined;
    var n: usize = p.HEADER_LEN;
    std.mem.writeInt(u16, req[n..][0..2], DATATYPE_CHARSAVE, .little);
    n += 2;
    @memcpy(req[n..][0..account.len], account);
    n += account.len;
    req[n] = 0;
    n += 1;
    @memcpy(req[n..][0..charname.len], charname);
    n += charname.len;
    req[n] = 0;
    n += 1;
    const h = p.Header{ .size = @intCast(n), .type = TYPE_GET, .seqno = seqno };
    @memcpy(req[0..p.HEADER_LEN], std.mem.asBytes(&h));
    if (!sendAll(req[0..n])) return 0;
    log.print("d2dbs: sent GET_DATA_REQUEST (charsave)");

    // Read reply header, then body.
    var hbuf: [p.HEADER_LEN]u8 = undefined;
    if (!recvAll(&hbuf)) return 0;
    const rh: *const p.Header = @ptrCast(@alignCast(&hbuf));
    if (rh.type != TYPE_GET or rh.size < p.HEADER_LEN) return 0;
    const blen: usize = rh.size - p.HEADER_LEN;
    var body: [8192]u8 = undefined;
    if (blen > body.len) return 0;
    if (blen > 0 and !recvAll(body[0..blen])) return 0;

    // Parse: result(4) createtime(4) allowladder(4) datatype(2) datalen(2) charname\0 data
    if (blen < 16) return 0;
    const result = std.mem.readInt(u32, body[0..4], .little);
    const datalen = std.mem.readInt(u16, body[14..16], .little);
    log.hex("d2dbs: GET reply result=0x", result);
    if (result != 0) {
        log.print("d2dbs: char fetch failed (not found / locked)");
        return 0;
    }
    var off: usize = 16;
    _ = p.readCStr(body[0..blen], &off); // charname
    const avail = blen - off;
    const take = @min(@min(datalen, avail), out.len);
    @memcpy(out[0..take], body[off..][0..take]);
    log.hex("d2dbs: fetched char save, bytes=0x", take);
    return take;
}
