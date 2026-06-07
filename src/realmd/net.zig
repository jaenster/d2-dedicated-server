//! Plain blocking TCP — one thread per connection. The 0.16 std.posix socket
//! wrappers were removed in the async-Io migration, so we call libc directly
//! (stable across zig versions, identical on macOS dev / Linux deploy). We only
//! borrow the AF/SOCK/SOL/SO constants and the sockaddr layout from std.posix.
const std = @import("std");
const posix = std.posix;
const log = @import("log.zig");

pub const Socket = c_int;

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getpeername(fd: c_int, addr: *anyopaque, len: *c_uint) c_int;

/// The connected peer's IPv4 address (network-order octets), or zeros on error.
pub fn peerIp(fd: Socket) [4]u8 {
    var addr = std.mem.zeroes(posix.sockaddr.in);
    var l: c_uint = @sizeOf(posix.sockaddr.in);
    if (getpeername(fd, &addr, &l) != 0) return .{ 0, 0, 0, 0 };
    return @bitCast(addr.addr);
}

/// A connection handler: owns the fd for the life of the connection. The fd is
/// closed by the runner after this returns.
pub const Handler = *const fn (fd: Socket, tag: []const u8) void;

fn parseIp4(text: []const u8) ![4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        octets[i] = try std.fmt.parseInt(u8, part, 10);
    }
    if (i != 4) return error.InvalidIp;
    return octets;
}

/// Open a listening TCP socket bound to bind_ip:port (SO_REUSEADDR set).
pub fn listenTcp(bind_ip: []const u8, port: u16) !Socket {
    const fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = close(fd);

    const one: c_int = 1;
    _ = setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one, @sizeOf(c_int));

    const octets = try parseIp4(bind_ip);
    var addr = std.mem.zeroes(posix.sockaddr.in);
    addr.family = posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = @bitCast(octets); // already network byte order
    if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);

    if (bind(fd, &addr, @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
    if (listen(fd, 128) != 0) return error.ListenFailed;
    return fd;
}

/// Accept forever; spawn a detached thread per connection running `handler`.
pub fn serve(tag: []const u8, listen_fd: Socket, handler: Handler) void {
    while (true) {
        const cfd = accept(listen_fd, null, null);
        if (cfd < 0) {
            log.line(tag, "accept failed", .{});
            continue;
        }
        const t = std.Thread.spawn(.{}, connThread, .{ cfd, tag, handler }) catch {
            _ = close(cfd);
            continue;
        };
        t.detach();
    }
}

fn connThread(fd: Socket, tag: []const u8, handler: Handler) void {
    defer _ = close(fd);
    handler(fd, tag);
}

/// Read into `buf`; returns the number of bytes, or 0 on EOF/error.
pub fn readSome(fd: Socket, buf: []u8) usize {
    const n = read(fd, buf.ptr, buf.len);
    return if (n <= 0) 0 else @intCast(n);
}

/// Read exactly `buf.len` bytes (loops over short reads). False on EOF/error.
pub fn readFull(fd: Socket, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = read(fd, buf.ptr + got, buf.len - got);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

/// Write all bytes (loops over short writes). False on error.
pub fn writeAll(fd: Socket, buf: []const u8) bool {
    var sent: usize = 0;
    while (sent < buf.len) {
        const n = write(fd, buf.ptr + sent, buf.len - sent);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

/// Capture handler: hexdump everything the peer sends, never reply. Used in
/// REALMD_CAPTURE mode to reverse the wire protocol from real client traffic.
pub fn captureHandler(fd: Socket, tag: []const u8) void {
    log.line(tag, "connection opened", .{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = readSome(fd, &buf);
        if (n == 0) break;
        log.hexdump(tag, buf[0..n]);
    }
    log.line(tag, "connection closed", .{});
}
