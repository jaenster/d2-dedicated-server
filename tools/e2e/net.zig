//! Minimal libc TCP client + framing helpers for the clientless E2E harness.
//! Mirrors src/realm/server/net.zig: the 0.16 std.posix socket wrappers were
//! removed, so we call libc directly. No std.Thread.sleep / std.time on 0.16
//! either — sleeps go through usleep.
const std = @import("std");
const posix = std.posix;

pub const Socket = c_int;

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn usleep(usec: c_uint) c_int;

/// Connect to 127.0.0.1:port. Loopback only — the harness never talks off-box.
pub fn connectLocal(port: u16) !Socket {
    const fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = close(fd);
    var addr = std.mem.zeroes(posix.sockaddr.in);
    addr.family = posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7f00_0001); // 127.0.0.1, network order
    if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);
    if (connect(fd, &addr, @sizeOf(posix.sockaddr.in)) != 0) return error.ConnectFailed;
    return fd;
}

pub fn closeSocket(fd: Socket) void {
    _ = close(fd);
}

/// True if a connection to 127.0.0.1:port succeeds (used to poll for listeners).
pub fn portOpen(port: u16) bool {
    const fd = connectLocal(port) catch return false;
    _ = close(fd);
    return true;
}

pub fn writeAll(fd: Socket, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        const n = write(fd, buf.ptr + sent, buf.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

/// Read exactly buf.len bytes; loops over short reads. Errors on EOF.
pub fn readFull(fd: Socket, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = read(fd, buf.ptr + got, buf.len - got);
        if (n <= 0) return error.SocketClosed;
        got += @intCast(n);
    }
}

// --- byte writer: little-endian packer over a fixed buffer ---
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }
    pub fn u8v(self: *Writer, v: u8) void {
        self.buf[self.len] = v;
        self.len += 1;
    }
    pub fn u16v(self: *Writer, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], v, .little);
        self.len += 2;
    }
    pub fn u32v(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }
    pub fn bytes(self: *Writer, b: []const u8) void {
        @memcpy(self.buf[self.len..][0..b.len], b);
        self.len += b.len;
    }
    pub fn cstr(self: *Writer, b: []const u8) void {
        self.bytes(b);
        self.u8v(0);
    }
    pub fn zeros(self: *Writer, n: usize) void {
        @memset(self.buf[self.len..][0..n], 0);
        self.len += n;
    }
    pub fn slice(self: *Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

// --- little-endian readers over a body slice ---
pub fn rdU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
pub fn rdU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
