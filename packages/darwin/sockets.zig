//! BSD sockets, translated from Darwin's ABI to the host's. A call wrong by a constant fails
//! somewhere else entirely: sockaddr (Darwin byte0=sa_len byte1=sa_family vs Linux 16-bit
//! family; translate both bytes both directions on every address-carrying call), SOL_SOCKET
//! (0xffff Darwin / 1 Linux, every SO_* differs — untranslated setsockopt fails rather than
//! corrupts, but refused SO_REUSEADDR still blocks a restart), MSG_* (only OOB/PEEK/DONTROUTE
//! agree; WAITALL is 0x40 Darwin / 0x100 Linux where 0x40 means DONTWAIT), struct timeval
//! (Darwin i386 = two 32-bit longs; musl has two different structs under that name, see
//! `HostTimeval`/`SelectTimeval` below), errno (game reads via `___error` against its own
//! errno.h: EWOULDBLOCK=35, EINPROGRESS=36 vs Linux 11/115 — translated on every failing call
//! except forwards in libc.zig). `fd_set` needs no translation: Darwin's 32 `__int32_t` and
//! musl's `unsigned long fds_bits[...]` are both 128 bytes, same bit per fd on little-endian.
//! FIONBIO not fcntl: the image imports no fcntl, so O_NONBLOCK (4 Darwin / 0x800 Linux) never
//! crosses this boundary.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "socket", &socket },
        .{ "bind", &bind },
        .{ "connect", &connect },
        .{ "listen", &listen },
        .{ "accept", &accept },
        .{ "send", &send },
        .{ "recv", &recv },
        .{ "sendto", &sendto },
        .{ "recvfrom", &recvfrom },
        .{ "select", &select },
        .{ "setsockopt", &setsockopt },
        .{ "getsockname", &getsockname },
        .{ "getpeername", &getpeername },
        .{ "ioctl", &ioctl },
        .{ "gethostbyname", &gethostbyname },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

// the constants, both platforms

/// Darwin's numbers, as the game was compiled against them.
pub const darwin = struct {
    pub const AF_UNSPEC: c_int = 0;
    pub const AF_UNIX: c_int = 1;
    pub const AF_INET: c_int = 2;
    pub const AF_INET6: c_int = 30;

    pub const SOL_SOCKET: c_int = 0xffff;
    pub const IPPROTO_IP: c_int = 0;
    pub const IPPROTO_TCP: c_int = 6;
    pub const IPPROTO_UDP: c_int = 17;

    pub const SO_DEBUG: c_int = 0x0001;
    pub const SO_ACCEPTCONN: c_int = 0x0002;
    pub const SO_REUSEADDR: c_int = 0x0004;
    pub const SO_KEEPALIVE: c_int = 0x0008;
    pub const SO_DONTROUTE: c_int = 0x0010;
    pub const SO_BROADCAST: c_int = 0x0020;
    pub const SO_LINGER: c_int = 0x0080;
    pub const SO_OOBINLINE: c_int = 0x0100;
    pub const SO_REUSEPORT: c_int = 0x0200;
    pub const SO_SNDBUF: c_int = 0x1001;
    pub const SO_RCVBUF: c_int = 0x1002;
    pub const SO_SNDLOWAT: c_int = 0x1003;
    pub const SO_RCVLOWAT: c_int = 0x1004;
    pub const SO_SNDTIMEO: c_int = 0x1005;
    pub const SO_RCVTIMEO: c_int = 0x1006;
    pub const SO_ERROR: c_int = 0x1007;
    pub const SO_TYPE: c_int = 0x1008;
    /// Apple-only, and there is no Linux option with this meaning — only MSG_NOSIGNAL per send.
    pub const SO_NOSIGPIPE: c_int = 0x1022;

    pub const MSG_OOB: c_int = 0x01;
    pub const MSG_PEEK: c_int = 0x02;
    pub const MSG_DONTROUTE: c_int = 0x04;
    pub const MSG_EOR: c_int = 0x08;
    pub const MSG_TRUNC: c_int = 0x10;
    pub const MSG_CTRUNC: c_int = 0x20;
    pub const MSG_WAITALL: c_int = 0x40;
    pub const MSG_DONTWAIT: c_int = 0x80;

    /// `_IOW('f', 126, int)` and `_IOR('f', 127, int)`: the direction, the payload size and the
    /// letter are all encoded in the request, so nothing about these numbers survives the crossing.
    pub const FIONBIO: c_ulong = 0x8004667e;
    pub const FIONREAD: c_ulong = 0x4004667f;

    pub const EINVAL: c_int = 22;
    pub const EAGAIN: c_int = 35;
    pub const EINPROGRESS: c_int = 36;
    pub const ENOPROTOOPT: c_int = 42;
    pub const EAFNOSUPPORT: c_int = 47;
    pub const ETIMEDOUT: c_int = 60;
    pub const ECONNREFUSED: c_int = 61;
};

/// The host's numbers when the host is Linux. Kept as literals rather than read out of std.c so the
/// two tables can be read side by side, and cross-checked below against what std actually says.
const linux = struct {
    const AF_UNSPEC: c_int = 0;
    const AF_UNIX: c_int = 1;
    const AF_INET: c_int = 2;
    const AF_INET6: c_int = 10;

    const SOL_SOCKET: c_int = 1;

    const SO_DEBUG: c_int = 1;
    const SO_REUSEADDR: c_int = 2;
    const SO_TYPE: c_int = 3;
    const SO_ERROR: c_int = 4;
    const SO_DONTROUTE: c_int = 5;
    const SO_BROADCAST: c_int = 6;
    const SO_SNDBUF: c_int = 7;
    const SO_RCVBUF: c_int = 8;
    const SO_KEEPALIVE: c_int = 9;
    const SO_OOBINLINE: c_int = 10;
    const SO_LINGER: c_int = 13;
    const SO_REUSEPORT: c_int = 15;
    const SO_RCVLOWAT: c_int = 18;
    const SO_SNDLOWAT: c_int = 19;
    const SO_ACCEPTCONN: c_int = 30;

    /// The timeout options come in two flavours and the flavour is chosen by the size of the timeval
    /// the libc passes: the _OLD pair takes two longs, the _NEW pair takes two 64-bit words. musl on
    /// a 32-bit target is time64, so it is the _NEW pair there and the _OLD pair on 64-bit.
    const SO_RCVTIMEO: c_int = if (@sizeOf(c_long) == 4) 66 else 20;
    const SO_SNDTIMEO: c_int = if (@sizeOf(c_long) == 4) 67 else 21;

    const MSG_OOB: c_int = 0x0001;
    const MSG_PEEK: c_int = 0x0002;
    const MSG_DONTROUTE: c_int = 0x0004;
    const MSG_CTRUNC: c_int = 0x0008;
    const MSG_TRUNC: c_int = 0x0020;
    const MSG_DONTWAIT: c_int = 0x0040;
    const MSG_EOR: c_int = 0x0080;
    const MSG_WAITALL: c_int = 0x0100;
    const MSG_NOSIGNAL: c_int = 0x4000;

    const FIONBIO: c_ulong = 0x5421;
    const FIONREAD: c_ulong = 0x541b;
};

comptime {
    if (builtin.os.tag == .linux) {
        std.debug.assert(linux.AF_INET == std.c.AF.INET);
        std.debug.assert(linux.AF_INET6 == std.c.AF.INET6);
        std.debug.assert(linux.SOL_SOCKET == std.c.SOL.SOCKET);
        std.debug.assert(linux.SO_REUSEADDR == std.c.SO.REUSEADDR);
        std.debug.assert(linux.SO_LINGER == std.c.SO.LINGER);
        std.debug.assert(linux.SO_ERROR == std.c.SO.ERROR);
        std.debug.assert(linux.MSG_WAITALL == std.c.MSG.WAITALL);
        std.debug.assert(linux.MSG_NOSIGNAL == std.c.MSG.NOSIGNAL);
    }
}

/// Whether the constants have to be translated at all. On the development host Darwin is the host, so
/// every table below is the identity and `--dry-run` exercises the same code without double-mapping.
const translating = builtin.os.tag == .linux;

// struct sockaddr

/// `struct sockaddr_in` as the game lays it out. The port and address are network order and stay that
/// way; only the first two bytes are Darwin's own idea.
pub const DarwinSockaddrIn = extern struct {
    len: u8 = 16,
    family: u8 = @intCast(darwin.AF_INET),
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};

/// The same address on Linux: no length byte, and the family takes both bytes.
pub const LinuxSockaddrIn = extern struct {
    family: u16 = @intCast(linux.AF_INET),
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};

comptime {
    // The two are the same size, which is what lets one buffer hold either form.
    std.debug.assert(@sizeOf(DarwinSockaddrIn) == 16);
    std.debug.assert(@sizeOf(LinuxSockaddrIn) == 16);
    std.debug.assert(@offsetOf(DarwinSockaddrIn, "port") == 2);
    std.debug.assert(@offsetOf(LinuxSockaddrIn, "port") == 2);
}

/// `sockaddr_storage`, which is the largest address either platform names.
pub const sockaddr_max = 128;

fn familyToLinux(family: c_int) ?c_int {
    return switch (family) {
        darwin.AF_UNSPEC => linux.AF_UNSPEC,
        darwin.AF_UNIX => linux.AF_UNIX,
        darwin.AF_INET => linux.AF_INET,
        darwin.AF_INET6 => linux.AF_INET6,
        else => null,
    };
}

fn familyToDarwin(family: c_int) ?c_int {
    return switch (family) {
        linux.AF_UNSPEC => darwin.AF_UNSPEC,
        linux.AF_UNIX => darwin.AF_UNIX,
        linux.AF_INET => darwin.AF_INET,
        linux.AF_INET6 => darwin.AF_INET6,
        else => null,
    };
}

/// Rewrites a Darwin sockaddr into `out` as a Linux one. Returns the length written, which is the
/// length in — the two layouts differ only in how the first two bytes are spelled.
pub fn sockaddrToLinux(src: []const u8, out: []u8) ?usize {
    if (src.len < 2 or out.len < src.len) return null;
    const family = familyToLinux(src[1]) orelse return null;
    std.mem.writeInt(u16, out[0..2], @intCast(family), builtin.cpu.arch.endian());
    @memcpy(out[2..src.len], src[2..src.len]);
    return src.len;
}

/// The other direction. `sa_len` is filled in from the length the host reported, which is the field's
/// definition — a caller that reads it and gets a zero walks off the end of the address.
pub fn sockaddrToDarwin(src: []const u8, out: []u8) ?usize {
    if (src.len < 2 or out.len < src.len) return null;
    const raw = std.mem.readInt(u16, src[0..2], builtin.cpu.arch.endian());
    const family = familyToDarwin(raw) orelse return null;
    out[0] = @intCast(@min(src.len, 255));
    out[1] = @intCast(family);
    @memcpy(out[2..src.len], src[2..src.len]);
    return src.len;
}

fn copyThrough(src: []const u8, out: []u8) ?usize {
    if (out.len < src.len) return null;
    @memcpy(out[0..src.len], src);
    return src.len;
}

fn toHostAddr(src: []const u8, out: []u8) ?usize {
    return if (translating) sockaddrToLinux(src, out) else copyThrough(src, out);
}

fn toGameAddr(src: []const u8, out: []u8) ?usize {
    return if (translating) sockaddrToDarwin(src, out) else copyThrough(src, out);
}

/// Reads an address the host wrote back into the caller's Darwin buffer. `len` is in-out on both
/// platforms: it arrives as the buffer's capacity and leaves as the address's true length, so an
/// address that did not fit is reported as truncated rather than as short.
fn writeBackAddr(scratch: []const u8, host_len: u32, addr: ?[*]u8, len: ?*u32) void {
    const out = addr orelse return;
    const cap = len orelse return;
    var converted: [sockaddr_max]u8 align(8) = undefined;
    const have: usize = @min(host_len, @as(u32, sockaddr_max));
    const n = toGameAddr(scratch[0..have], &converted) orelse {
        cap.* = 0;
        return;
    };
    const fits: usize = @min(n, @as(usize, cap.*));
    @memcpy(out[0..fits], converted[0..fits]);
    cap.* = @intCast(n);
}

// errno

const ErrnoPair = struct { darwin: c_int, linux: c_int };

/// Every code the two platforms number differently. Scanned in order, so the first entry for a given
/// Linux number wins: EOPNOTSUPP is listed before ENOTSUP because 95 coming back from a socket call
/// means the operation, not the type.
const errno_pairs = [_]ErrnoPair{
    .{ .darwin = 11, .linux = 35 }, // EDEADLK
    .{ .darwin = 35, .linux = 11 }, // EAGAIN / EWOULDBLOCK
    .{ .darwin = 36, .linux = 115 }, // EINPROGRESS
    .{ .darwin = 37, .linux = 114 }, // EALREADY
    .{ .darwin = 38, .linux = 88 }, // ENOTSOCK
    .{ .darwin = 39, .linux = 89 }, // EDESTADDRREQ
    .{ .darwin = 40, .linux = 90 }, // EMSGSIZE
    .{ .darwin = 41, .linux = 91 }, // EPROTOTYPE
    .{ .darwin = 42, .linux = 92 }, // ENOPROTOOPT
    .{ .darwin = 43, .linux = 93 }, // EPROTONOSUPPORT
    .{ .darwin = 44, .linux = 94 }, // ESOCKTNOSUPPORT
    .{ .darwin = 46, .linux = 96 }, // EPFNOSUPPORT
    .{ .darwin = 47, .linux = 97 }, // EAFNOSUPPORT
    .{ .darwin = 48, .linux = 98 }, // EADDRINUSE
    .{ .darwin = 49, .linux = 99 }, // EADDRNOTAVAIL
    .{ .darwin = 50, .linux = 100 }, // ENETDOWN
    .{ .darwin = 51, .linux = 101 }, // ENETUNREACH
    .{ .darwin = 52, .linux = 102 }, // ENETRESET
    .{ .darwin = 53, .linux = 103 }, // ECONNABORTED
    .{ .darwin = 54, .linux = 104 }, // ECONNRESET
    .{ .darwin = 55, .linux = 105 }, // ENOBUFS
    .{ .darwin = 56, .linux = 106 }, // EISCONN
    .{ .darwin = 57, .linux = 107 }, // ENOTCONN
    .{ .darwin = 58, .linux = 108 }, // ESHUTDOWN
    .{ .darwin = 59, .linux = 109 }, // ETOOMANYREFS
    .{ .darwin = 60, .linux = 110 }, // ETIMEDOUT
    .{ .darwin = 61, .linux = 111 }, // ECONNREFUSED
    .{ .darwin = 62, .linux = 40 }, // ELOOP
    .{ .darwin = 63, .linux = 36 }, // ENAMETOOLONG
    .{ .darwin = 64, .linux = 112 }, // EHOSTDOWN
    .{ .darwin = 65, .linux = 113 }, // EHOSTUNREACH
    .{ .darwin = 66, .linux = 39 }, // ENOTEMPTY
    .{ .darwin = 68, .linux = 87 }, // EUSERS
    .{ .darwin = 69, .linux = 122 }, // EDQUOT
    .{ .darwin = 70, .linux = 116 }, // ESTALE
    .{ .darwin = 71, .linux = 66 }, // EREMOTE
    .{ .darwin = 77, .linux = 37 }, // ENOLCK
    .{ .darwin = 78, .linux = 38 }, // ENOSYS
    .{ .darwin = 84, .linux = 75 }, // EOVERFLOW
    .{ .darwin = 89, .linux = 125 }, // ECANCELED
    .{ .darwin = 90, .linux = 43 }, // EIDRM
    .{ .darwin = 91, .linux = 42 }, // ENOMSG
    .{ .darwin = 92, .linux = 84 }, // EILSEQ
    .{ .darwin = 94, .linux = 74 }, // EBADMSG
    .{ .darwin = 95, .linux = 72 }, // EMULTIHOP
    .{ .darwin = 96, .linux = 61 }, // ENODATA
    .{ .darwin = 97, .linux = 67 }, // ENOLINK
    .{ .darwin = 98, .linux = 63 }, // ENOSR
    .{ .darwin = 99, .linux = 60 }, // ENOSTR
    .{ .darwin = 100, .linux = 71 }, // EPROTO
    .{ .darwin = 101, .linux = 62 }, // ETIME
    .{ .darwin = 102, .linux = 95 }, // EOPNOTSUPP
    .{ .darwin = 45, .linux = 95 }, // ENOTSUP, which Linux does not distinguish from EOPNOTSUPP
    .{ .darwin = 104, .linux = 131 }, // ENOTRECOVERABLE
    .{ .darwin = 105, .linux = 130 }, // EOWNERDEAD
};

/// Falls through to the number itself for anything unlisted, which covers 1..34 — where the two agree
/// except for the EDEADLK/EAGAIN swap above — and leaves the Linux-only codes no socket call produces
/// as themselves rather than as a plausible-looking lie.
pub fn errnoToDarwin(code: c_int) c_int {
    for (errno_pairs) |p| {
        if (p.linux == code) return p.darwin;
    }
    return code;
}

pub fn errnoToLinux(code: c_int) c_int {
    for (errno_pairs) |p| {
        if (p.darwin == code) return p.linux;
    }
    return code;
}

/// Rewrites what the host left in errno as the game's own number, in place. Called once on the
/// failure path of each entry point — twice would translate a translation.
fn reportHostErrno() void {
    if (!translating) return;
    const slot = compat.errorLocation();
    slot.* = errnoToDarwin(slot.*);
}

fn fail(code: c_int) c_int {
    compat.errorLocation().* = code;
    return -1;
}

fn checked(rc: c_int) c_int {
    if (rc < 0) reportHostErrno();
    return rc;
}

fn checkedSize(rc: isize) isize {
    if (rc < 0) reportHostErrno();
    return rc;
}

// flags and options

const FlagPair = struct { darwin: c_int, host: c_int };

const msg_flags = [_]FlagPair{
    .{ .darwin = darwin.MSG_OOB, .host = linux.MSG_OOB },
    .{ .darwin = darwin.MSG_PEEK, .host = linux.MSG_PEEK },
    .{ .darwin = darwin.MSG_DONTROUTE, .host = linux.MSG_DONTROUTE },
    .{ .darwin = darwin.MSG_EOR, .host = linux.MSG_EOR },
    .{ .darwin = darwin.MSG_TRUNC, .host = linux.MSG_TRUNC },
    .{ .darwin = darwin.MSG_CTRUNC, .host = linux.MSG_CTRUNC },
    .{ .darwin = darwin.MSG_WAITALL, .host = linux.MSG_WAITALL },
    .{ .darwin = darwin.MSG_DONTWAIT, .host = linux.MSG_DONTWAIT },
};

/// Bit by bit, because the two sets overlap wrongly: Darwin's WAITALL is Linux's DONTWAIT and Darwin's
/// DONTWAIT is Linux's EOR. A flag with no counterpart is dropped rather than passed through.
pub fn msgFlagsToHost(flags: c_int) c_int {
    if (!translating) return flags;
    var out: c_int = 0;
    for (msg_flags) |f| {
        if (flags & f.darwin != 0) out |= f.host;
    }
    return out;
}

const OptionPair = struct { darwin: c_int, host: c_int };

const socket_options = [_]OptionPair{
    .{ .darwin = darwin.SO_DEBUG, .host = linux.SO_DEBUG },
    .{ .darwin = darwin.SO_ACCEPTCONN, .host = linux.SO_ACCEPTCONN },
    .{ .darwin = darwin.SO_REUSEADDR, .host = linux.SO_REUSEADDR },
    .{ .darwin = darwin.SO_KEEPALIVE, .host = linux.SO_KEEPALIVE },
    .{ .darwin = darwin.SO_DONTROUTE, .host = linux.SO_DONTROUTE },
    .{ .darwin = darwin.SO_BROADCAST, .host = linux.SO_BROADCAST },
    .{ .darwin = darwin.SO_LINGER, .host = linux.SO_LINGER },
    .{ .darwin = darwin.SO_OOBINLINE, .host = linux.SO_OOBINLINE },
    .{ .darwin = darwin.SO_REUSEPORT, .host = linux.SO_REUSEPORT },
    .{ .darwin = darwin.SO_SNDBUF, .host = linux.SO_SNDBUF },
    .{ .darwin = darwin.SO_RCVBUF, .host = linux.SO_RCVBUF },
    .{ .darwin = darwin.SO_SNDLOWAT, .host = linux.SO_SNDLOWAT },
    .{ .darwin = darwin.SO_RCVLOWAT, .host = linux.SO_RCVLOWAT },
    .{ .darwin = darwin.SO_SNDTIMEO, .host = linux.SO_SNDTIMEO },
    .{ .darwin = darwin.SO_RCVTIMEO, .host = linux.SO_RCVTIMEO },
    .{ .darwin = darwin.SO_ERROR, .host = linux.SO_ERROR },
    .{ .darwin = darwin.SO_TYPE, .host = linux.SO_TYPE },
};

/// Only SOL_SOCKET moves. The IPPROTO_* levels are IANA protocol numbers, so TCP_NODELAY and the rest
/// arrive at the same level under the same option number on both platforms. A level with no meaning
/// on Darwin is refused whatever this file was compiled for, since the caller is always the game.
pub fn levelToHost(level: c_int) ?c_int {
    return switch (level) {
        darwin.SOL_SOCKET => if (translating) linux.SOL_SOCKET else level,
        darwin.IPPROTO_IP, darwin.IPPROTO_TCP, darwin.IPPROTO_UDP => level,
        else => null,
    };
}

pub fn socketOptionToHost(option: c_int) ?c_int {
    for (socket_options) |o| {
        if (o.darwin == option) return if (translating) o.host else o.darwin;
    }
    return null;
}

// timeval and fd_set

/// Darwin i386's `struct timeval`: `time_t` and `suseconds_t` are both 32-bit longs there.
pub const DarwinTimeval = extern struct { sec: i32, usec: i32 };

/// musl's own `struct timeval`, which is time64 on every architecture: both fields are 64-bit even
/// on i386. `std.os.linux.timeval` models the kernel's struct rather than musl's, so it cannot be
/// used here. This is the one `setsockopt` reads, and SO_RCVTIMEO_NEW is the option that goes with
/// it — measured on i386 musl, where the OLD number or an eight-byte payload is refused outright.
pub const HostTimeval = switch (builtin.os.tag) {
    .linux => extern struct { sec: i64, usec: i64 },
    else => extern struct { sec: c_long, usec: i32 },
};

/// What `select` reads, which on i386 musl is NOT the struct above. musl's time64 transition
/// redirects C callers to `__select_time64` (takes `HostTimeval`), but the exported `select`
/// symbol keeps the legacy `{long, long}` (8 bytes on i386); a Zig `extern fn` binds by name so
/// it always hits the legacy one. Passing 16 bytes there reads tv_usec from tv_sec's high half,
/// so every timeout is zero and a blocking thread busy-loops forever. `setsockopt` has no second
/// entry point, so it keeps `HostTimeval` — the two structs really do differ.
pub const SelectTimeval = switch (builtin.os.tag) {
    .linux => extern struct { sec: c_long, usec: c_long },
    else => extern struct { sec: c_long, usec: i32 },
};

comptime {
    std.debug.assert(@sizeOf(DarwinTimeval) == 8);
    if (builtin.os.tag == .linux) {
        std.debug.assert(@sizeOf(HostTimeval) == 16);
        std.debug.assert(@sizeOf(SelectTimeval) == 2 * @sizeOf(c_long));
    }
}

/// 1024 bits either way. Darwin stores them as 32 `__int32_t`; musl as `unsigned long` words, so 32 of
/// them on i386 and 16 on x86_64. Same 128 bytes, and on a little-endian host fd N is the same
/// physical bit whichever width splits them — so a game fd_set is passed to the host untouched.
pub const FdSet = extern struct { bits: [128]u8 align(8) };

comptime {
    std.debug.assert(@sizeOf(FdSet) == 128);
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

// SO_NOSIGPIPE

const nosigpipe_fds = 1024;

/// Which sockets asked not to be killed by a dead peer. Linux has no such option — the request is
/// per-send there — so the answer is remembered here and turned into MSG_NOSIGNAL by send/sendto.
/// Cleared when a descriptor number is handed out again, so a reused fd does not inherit it.
var nosigpipe: [nosigpipe_fds / 32]std.atomic.Value(u32) = @splat(.init(0));

fn setNoSigpipe(fd: c_int, on: bool) void {
    if (fd < 0 or fd >= nosigpipe_fds) return;
    const word = &nosigpipe[@intCast(@divTrunc(fd, 32))];
    const bit = @as(u32, 1) << @intCast(@mod(fd, 32));
    if (on) _ = word.fetchOr(bit, .monotonic) else _ = word.fetchAnd(~bit, .monotonic);
}

fn hasNoSigpipe(fd: c_int) bool {
    if (fd < 0 or fd >= nosigpipe_fds) return false;
    const bit = @as(u32, 1) << @intCast(@mod(fd, 32));
    return nosigpipe[@intCast(@divTrunc(fd, 32))].load(.monotonic) & bit != 0;
}

fn sendFlags(fd: c_int, flags: c_int) c_int {
    const host_flags = msgFlagsToHost(flags);
    if (!translating or !hasNoSigpipe(fd)) return host_flags;
    return host_flags | linux.MSG_NOSIGNAL;
}

// the host libc

pub const Hostent = extern struct {
    name: ?[*:0]u8,
    aliases: ?[*]?[*:0]u8,
    addrtype: c_int,
    length: c_int,
    addr_list: ?[*]?[*]u8,
};

const host = struct {
    extern fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern fn listen(fd: c_int, backlog: c_int) c_int;
    extern fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern fn send(fd: c_int, buf: ?*const anyopaque, len: usize, flags: c_int) isize;
    extern fn recv(fd: c_int, buf: ?*anyopaque, len: usize, flags: c_int) isize;
    extern fn sendto(
        fd: c_int,
        buf: ?*const anyopaque,
        len: usize,
        flags: c_int,
        addr: ?*const anyopaque,
        alen: u32,
    ) isize;
    extern fn recvfrom(
        fd: c_int,
        buf: ?*anyopaque,
        len: usize,
        flags: c_int,
        addr: ?*anyopaque,
        alen: ?*u32,
    ) isize;
    extern fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;
    extern fn getpeername(fd: c_int, addr: *anyopaque, len: *u32) c_int;
    extern fn setsockopt(fd: c_int, level: c_int, option: c_int, value: ?*const anyopaque, len: u32) c_int;
    extern fn select(nfds: c_int, r: ?*anyopaque, w: ?*anyopaque, e: ?*anyopaque, t: ?*SelectTimeval) c_int;
    /// Declared variadic because it is: a fixed third parameter would put the argument in the wrong
    /// place on any ABI that passes variadic arguments differently.
    extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern fn gethostbyname(name: [*:0]const u8) ?*Hostent;
};

// the entry points

pub fn socket(domain: c_int, kind: c_int, protocol: c_int) callconv(.c) c_int {
    const host_domain = familyToLinux(domain) orelse return fail(darwin.EAFNOSUPPORT);
    // SOCK_STREAM/DGRAM/RAW are 1/2/3 on both, and a protocol is an IANA number on both.
    const fd = host.socket(if (translating) host_domain else domain, kind, protocol);
    if (fd < 0) return checked(fd);
    setNoSigpipe(fd, false);
    return fd;
}

pub fn bind(fd: c_int, addr: ?[*]const u8, len: u32) callconv(.c) c_int {
    var buf: [sockaddr_max]u8 align(8) = undefined;
    const src = addr orelse return fail(darwin.EINVAL);
    if (len > sockaddr_max) return fail(darwin.EINVAL);
    const n = toHostAddr(src[0..len], &buf) orelse return fail(darwin.EAFNOSUPPORT);
    return checked(host.bind(fd, &buf, @intCast(n)));
}

pub fn connect(fd: c_int, addr: ?[*]const u8, len: u32) callconv(.c) c_int {
    var buf: [sockaddr_max]u8 align(8) = undefined;
    const src = addr orelse return fail(darwin.EINVAL);
    if (len > sockaddr_max) return fail(darwin.EINVAL);
    const n = toHostAddr(src[0..len], &buf) orelse return fail(darwin.EAFNOSUPPORT);
    return checked(host.connect(fd, &buf, @intCast(n)));
}

pub fn listen(fd: c_int, backlog: c_int) callconv(.c) c_int {
    return checked(host.listen(fd, backlog));
}

pub fn accept(fd: c_int, addr: ?[*]u8, len: ?*u32) callconv(.c) c_int {
    var buf: [sockaddr_max]u8 align(8) = undefined;
    var host_len: u32 = sockaddr_max;
    // The address and its length are one argument in two halves: passing one without the other is
    // what the host rejects, so both go or neither does.
    const accepted = if (addr == null) host.accept(fd, null, null) else host.accept(fd, &buf, &host_len);
    if (accepted < 0) return checked(accepted);
    setNoSigpipe(accepted, false);
    writeBackAddr(&buf, host_len, addr, len);
    return accepted;
}

pub fn send(fd: c_int, buf: ?*const anyopaque, len: usize, flags: c_int) callconv(.c) isize {
    return checkedSize(host.send(fd, buf, len, sendFlags(fd, flags)));
}

pub fn recv(fd: c_int, buf: ?*anyopaque, len: usize, flags: c_int) callconv(.c) isize {
    return checkedSize(host.recv(fd, buf, len, msgFlagsToHost(flags)));
}

pub fn sendto(
    fd: c_int,
    buf: ?*const anyopaque,
    len: usize,
    flags: c_int,
    addr: ?[*]const u8,
    alen: u32,
) callconv(.c) isize {
    const host_flags = sendFlags(fd, flags);
    // A null address is how sendto degrades to send, and it is legal on a connected socket.
    const src = addr orelse return checkedSize(host.sendto(fd, buf, len, host_flags, null, 0));
    if (alen > sockaddr_max) return fail(darwin.EINVAL);
    var converted: [sockaddr_max]u8 align(8) = undefined;
    const n = toHostAddr(src[0..alen], &converted) orelse return fail(darwin.EAFNOSUPPORT);
    return checkedSize(host.sendto(fd, buf, len, host_flags, &converted, @intCast(n)));
}

pub fn recvfrom(
    fd: c_int,
    buf: ?*anyopaque,
    len: usize,
    flags: c_int,
    addr: ?[*]u8,
    alen: ?*u32,
) callconv(.c) isize {
    var scratch: [sockaddr_max]u8 align(8) = undefined;
    var host_len: u32 = sockaddr_max;
    const want_addr = addr != null;
    const rc = host.recvfrom(
        fd,
        buf,
        len,
        msgFlagsToHost(flags),
        if (want_addr) &scratch else null,
        if (want_addr) &host_len else null,
    );
    if (rc < 0) return checkedSize(rc);
    writeBackAddr(&scratch, host_len, addr, alen);
    return rc;
}

pub fn getsockname(fd: c_int, addr: ?[*]u8, len: ?*u32) callconv(.c) c_int {
    return localName(&host.getsockname, fd, addr, len);
}

pub fn getpeername(fd: c_int, addr: ?[*]u8, len: ?*u32) callconv(.c) c_int {
    return localName(&host.getpeername, fd, addr, len);
}

fn localName(
    call: *const fn (c_int, *anyopaque, *u32) callconv(.c) c_int,
    fd: c_int,
    addr: ?[*]u8,
    len: ?*u32,
) c_int {
    if (addr == null or len == null) return fail(darwin.EINVAL);
    var buf: [sockaddr_max]u8 align(8) = undefined;
    var host_len: u32 = sockaddr_max;
    const rc = call(fd, &buf, &host_len);
    if (rc < 0) return checked(rc);
    writeBackAddr(&buf, host_len, addr, len);
    return 0;
}

/// The timeout options carry a `struct timeval`, which is the one option payload that is not just an
/// int; SO_LINGER's `struct linger` is two ints on both platforms and passes through.
pub fn setsockopt(fd: c_int, level: c_int, option: c_int, value: ?*const anyopaque, len: u32) callconv(.c) c_int {
    if (level == darwin.SOL_SOCKET and option == darwin.SO_NOSIGPIPE) {
        if (!translating) return checked(host.setsockopt(fd, level, option, value, len));
        const on = readInt(value, len) orelse return fail(darwin.EINVAL);
        setNoSigpipe(fd, on != 0);
        return 0;
    }

    const host_level = levelToHost(level) orelse return fail(darwin.ENOPROTOOPT);
    if (level != darwin.SOL_SOCKET) return checked(host.setsockopt(fd, host_level, option, value, len));

    const host_option = socketOptionToHost(option) orelse return fail(darwin.ENOPROTOOPT);
    if (option == darwin.SO_SNDTIMEO or option == darwin.SO_RCVTIMEO) {
        if (len != @sizeOf(DarwinTimeval)) return fail(darwin.EINVAL);
        const src: *const DarwinTimeval = @ptrCast(@alignCast(value orelse return fail(darwin.EINVAL)));
        var t: HostTimeval = .{ .sec = src.sec, .usec = src.usec };
        return checked(host.setsockopt(fd, host_level, host_option, &t, @sizeOf(HostTimeval)));
    }
    return checked(host.setsockopt(fd, host_level, host_option, value, len));
}

fn readInt(value: ?*const anyopaque, len: u32) ?c_int {
    if (len != @sizeOf(c_int)) return null;
    const p: *const c_int = @ptrCast(@alignCast(value orelse return null));
    return p.*;
}

/// Darwin leaves the timeout struct alone and Linux writes the remaining time back into it, so the
/// host is given a copy: the game's eight bytes come out of this exactly as they went in.
pub fn select(
    nfds: c_int,
    readfds: ?*FdSet,
    writefds: ?*FdSet,
    exceptfds: ?*FdSet,
    timeout: ?*DarwinTimeval,
) callconv(.c) c_int {
    var t: SelectTimeval = undefined;
    var tp: ?*SelectTimeval = null;
    if (timeout) |d| {
        t = .{ .sec = d.sec, .usec = d.usec };
        tp = &t;
    }
    return checked(host.select(nfds, readfds, writefds, exceptfds, tp));
}

/// Only the two the game can reach through a socket. An unrecognised request is refused rather than
/// forwarded: Darwin encodes the direction and the payload size into the number, so it is never a
/// Linux request by accident.
pub fn ioctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) callconv(.c) c_int {
    const host_request: c_ulong = switch (request) {
        darwin.FIONBIO => if (translating) linux.FIONBIO else request,
        darwin.FIONREAD => if (translating) linux.FIONREAD else request,
        else => return fail(darwin.EINVAL),
    };
    return checked(host.ioctl(fd, host_request, arg));
}

/// `struct hostent` is five pointer-or-int fields in the same order on both platforms, so on i386 the
/// host's object can be handed back as it stands — and `h_addrtype` is AF_INET, which is 2 on both.
/// The comptime assertions below are what makes that a checked claim rather than a hope.
pub fn gethostbyname(name: ?[*:0]const u8) callconv(.c) ?*Hostent {
    const n = name orelse return null;
    const entry = host.gethostbyname(n) orelse return null;
    if (translating and familyToDarwin(entry.addrtype) == null) return null;
    return entry;
}

comptime {
    std.debug.assert(@offsetOf(Hostent, "addrtype") == 2 * @sizeOf(usize));
    std.debug.assert(@offsetOf(Hostent, "length") == 2 * @sizeOf(usize) + 4);
    std.debug.assert(darwin.AF_INET == linux.AF_INET);
}

const testing = std.testing;

test "a Darwin sockaddr_in survives the round trip with its length byte intact" {
    const src: DarwinSockaddrIn = .{
        .len = @sizeOf(DarwinSockaddrIn),
        .family = @intCast(darwin.AF_INET),
        // 6112 and 127.0.0.1, both already network order, which is what must not be touched.
        .port = std.mem.nativeToBig(u16, 6112),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
        .zero = @splat(0),
    };

    var linux_bytes: [sockaddr_max]u8 align(8) = undefined;
    const n = sockaddrToLinux(std.mem.asBytes(&src), &linux_bytes).?;
    try testing.expectEqual(@as(usize, 16), n);

    const as_linux: *const LinuxSockaddrIn = @ptrCast(@alignCast(&linux_bytes));
    try testing.expectEqual(@as(u16, @intCast(linux.AF_INET)), as_linux.family);
    try testing.expectEqual(std.mem.nativeToBig(u16, 6112), as_linux.port);
    try testing.expectEqual(std.mem.nativeToBig(u32, 0x7f00_0001), as_linux.addr);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &as_linux.zero);
    // The port is big-endian on the wire, so the low byte of 6112 (0x17e0) leads.
    try testing.expectEqual(@as(u8, 0x17), linux_bytes[2]);
    try testing.expectEqual(@as(u8, 0xe0), linux_bytes[3]);

    var back: [sockaddr_max]u8 align(8) = undefined;
    try testing.expectEqual(@as(usize, 16), sockaddrToDarwin(linux_bytes[0..n], &back).?);
    const as_darwin: *const DarwinSockaddrIn = @ptrCast(@alignCast(&back));
    try testing.expectEqual(src.len, as_darwin.len);
    try testing.expectEqual(src.family, as_darwin.family);
    try testing.expectEqual(src.port, as_darwin.port);
    try testing.expectEqual(src.addr, as_darwin.addr);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&src), back[0..16]);
}

test "the address families that are not the same number on both sides" {
    // AF_INET is 2 either way, which is the one the game uses, but IPv6 is 30 against 10.
    try testing.expectEqual(@as(?c_int, 2), familyToLinux(darwin.AF_INET));
    try testing.expectEqual(@as(?c_int, 2), familyToDarwin(linux.AF_INET));
    try testing.expectEqual(@as(?c_int, 10), familyToLinux(darwin.AF_INET6));
    try testing.expectEqual(@as(?c_int, 30), familyToDarwin(linux.AF_INET6));
    try testing.expectEqual(@as(?c_int, 0), familyToLinux(darwin.AF_UNSPEC));
    try testing.expectEqual(@as(?c_int, 1), familyToLinux(darwin.AF_UNIX));

    // A family with no counterpart is refused, not guessed at.
    try testing.expectEqual(@as(?c_int, null), familyToLinux(28));
    var out: [sockaddr_max]u8 align(8) = undefined;
    try testing.expectEqual(@as(?usize, null), sockaddrToLinux(&[_]u8{ 16, 28 }, &out));
    // And an address too short to hold a family is not an address.
    try testing.expectEqual(@as(?usize, null), sockaddrToLinux(&[_]u8{2}, &out));
}

test "sa_len comes from the length the host reported, not from the buffer" {
    // A unix-domain address is as long as its path, so the length byte is not a constant.
    var linux_bytes: [sockaddr_max]u8 align(8) = @splat(0);
    std.mem.writeInt(u16, linux_bytes[0..2], @intCast(linux.AF_UNIX), .little);
    @memcpy(linux_bytes[2..7], "/tmp\x00");

    var out: [sockaddr_max]u8 align(8) = undefined;
    try testing.expectEqual(@as(usize, 7), sockaddrToDarwin(linux_bytes[0..7], &out).?);
    try testing.expectEqual(@as(u8, 7), out[0]);
    try testing.expectEqual(@as(u8, @intCast(darwin.AF_UNIX)), out[1]);
    try testing.expectEqualStrings("/tmp", out[2..6]);
}

test "the option constants are translated rather than passed through" {
    // The level itself, which is the one that would make every setsockopt fail.
    try testing.expectEqual(@as(c_int, 0xffff), darwin.SOL_SOCKET);
    try testing.expectEqual(@as(?c_int, if (translating) 1 else 0xffff), levelToHost(darwin.SOL_SOCKET));
    // TCP_NODELAY's level is an IANA protocol number, so it does not move.
    try testing.expectEqual(@as(?c_int, darwin.IPPROTO_TCP), levelToHost(darwin.IPPROTO_TCP));
    try testing.expectEqual(@as(?c_int, null), levelToHost(0x1234));

    const expected = [_]OptionPair{
        .{ .darwin = 0x0001, .host = 1 }, // SO_DEBUG
        .{ .darwin = 0x0002, .host = 30 }, // SO_ACCEPTCONN
        .{ .darwin = 0x0004, .host = 2 }, // SO_REUSEADDR
        .{ .darwin = 0x0008, .host = 9 }, // SO_KEEPALIVE
        .{ .darwin = 0x0010, .host = 5 }, // SO_DONTROUTE
        .{ .darwin = 0x0020, .host = 6 }, // SO_BROADCAST
        .{ .darwin = 0x0080, .host = 13 }, // SO_LINGER
        .{ .darwin = 0x0100, .host = 10 }, // SO_OOBINLINE
        .{ .darwin = 0x0200, .host = 15 }, // SO_REUSEPORT
        .{ .darwin = 0x1001, .host = 7 }, // SO_SNDBUF
        .{ .darwin = 0x1002, .host = 8 }, // SO_RCVBUF
        .{ .darwin = 0x1003, .host = 19 }, // SO_SNDLOWAT
        .{ .darwin = 0x1004, .host = 18 }, // SO_RCVLOWAT
        .{ .darwin = 0x1007, .host = 4 }, // SO_ERROR
        .{ .darwin = 0x1008, .host = 3 }, // SO_TYPE
    };
    for (expected) |e| {
        try testing.expectEqual(@as(?c_int, if (translating) e.host else e.darwin), socketOptionToHost(e.darwin));
    }
    // The timeout pair is chosen by the width of the host's own timeval, not by the architecture.
    const rcvtimeo: c_int = if (@sizeOf(c_long) == 4) 66 else 20;
    try testing.expectEqual(
        @as(?c_int, if (translating) rcvtimeo else darwin.SO_RCVTIMEO),
        socketOptionToHost(darwin.SO_RCVTIMEO),
    );
    // An option this shim does not know is refused rather than sent through as itself.
    try testing.expectEqual(@as(?c_int, null), socketOptionToHost(0x1024));
}

test "the message flags that mean each other's meaning" {
    if (!translating) {
        try testing.expectEqual(darwin.MSG_WAITALL, msgFlagsToHost(darwin.MSG_WAITALL));
        return;
    }
    // The whole reason send/recv cannot be forwarded: these three collide across the boundary.
    try testing.expectEqual(@as(c_int, 0x100), msgFlagsToHost(darwin.MSG_WAITALL));
    try testing.expectEqual(@as(c_int, 0x040), msgFlagsToHost(darwin.MSG_DONTWAIT));
    try testing.expectEqual(@as(c_int, 0x080), msgFlagsToHost(darwin.MSG_EOR));
    try testing.expectEqual(@as(c_int, 0x008), msgFlagsToHost(darwin.MSG_CTRUNC));
    try testing.expectEqual(@as(c_int, 0x020), msgFlagsToHost(darwin.MSG_TRUNC));

    // And the three that do agree.
    try testing.expectEqual(darwin.MSG_OOB, msgFlagsToHost(darwin.MSG_OOB));
    try testing.expectEqual(darwin.MSG_PEEK, msgFlagsToHost(darwin.MSG_PEEK));
    try testing.expectEqual(darwin.MSG_DONTROUTE, msgFlagsToHost(darwin.MSG_DONTROUTE));

    // Composed, with an unknown bit dropped rather than passed through: WAITALL becomes Linux's
    // 0x100 and PEEK stays 0x02, while 0x40000 has no counterpart and contributes nothing.
    try testing.expectEqual(@as(c_int, 0x102), msgFlagsToHost(darwin.MSG_WAITALL | darwin.MSG_PEEK | 0x40000));
    try testing.expectEqual(@as(c_int, 0), msgFlagsToHost(0));
}

test "the errno numbers the game compares against" {
    // The five the network code actually branches on.
    try testing.expectEqual(@as(c_int, 35), errnoToDarwin(11)); // EWOULDBLOCK
    try testing.expectEqual(@as(c_int, 36), errnoToDarwin(115)); // EINPROGRESS
    try testing.expectEqual(@as(c_int, 61), errnoToDarwin(111)); // ECONNREFUSED
    try testing.expectEqual(@as(c_int, 60), errnoToDarwin(110)); // ETIMEDOUT
    try testing.expectEqual(@as(c_int, 54), errnoToDarwin(104)); // ECONNRESET

    try testing.expectEqual(@as(c_int, 11), errnoToLinux(35));
    try testing.expectEqual(@as(c_int, 115), errnoToLinux(36));
    try testing.expectEqual(@as(c_int, 111), errnoToLinux(61));
    try testing.expectEqual(@as(c_int, 110), errnoToLinux(60));
    try testing.expectEqual(@as(c_int, 104), errnoToLinux(54));

    // EDEADLK and EAGAIN swap places, which is why the low range is not simply passed through.
    try testing.expectEqual(@as(c_int, 11), errnoToDarwin(35));
    try testing.expectEqual(@as(c_int, 35), errnoToLinux(11));

    // Every pair round-trips, except that Linux does not distinguish ENOTSUP from EOPNOTSUPP.
    for (errno_pairs) |p| {
        try testing.expectEqual(p.linux, errnoToLinux(p.darwin));
        if (p.darwin == 45) continue;
        try testing.expectEqual(p.darwin, errnoToDarwin(p.linux));
    }
    try testing.expectEqual(@as(c_int, 95), errnoToLinux(45));
    try testing.expectEqual(@as(c_int, 102), errnoToDarwin(95));

    // The codes both platforms agree on stay themselves.
    for ([_]c_int{ 1, 4, 9, 12, 13, 14, 22, 32 }) |code| {
        try testing.expectEqual(code, errnoToDarwin(code));
        try testing.expectEqual(code, errnoToLinux(code));
    }
}

test "the ioctl requests carry their direction and payload size" {
    // _IOW('f', 126, int) and _IOR('f', 127, int). Nothing about these survives untranslated.
    try testing.expectEqual(@as(c_ulong, 0x8004667e), darwin.FIONBIO);
    try testing.expectEqual(@as(c_ulong, 0x4004667f), darwin.FIONREAD);
    try testing.expectEqual(@as(c_ulong, 0x5421), linux.FIONBIO);
    // An unknown request is a refusal, and it leaves a Darwin errno behind.
    try testing.expectEqual(@as(c_int, -1), ioctl(-1, 0x1234, null));
    try testing.expectEqual(darwin.EINVAL, compat.errorLocation().*);
}

test "the layouts that need no translation, stated rather than assumed" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(FdSet));
    try testing.expectEqual(@as(usize, 8), @sizeOf(DarwinTimeval));
    // The one that does — and it is two structs, not one: setsockopt reads musl's time64 timeval,
    // while the exported select symbol still reads the legacy pair of longs.
    if (translating) {
        try testing.expectEqual(@as(usize, 16), @sizeOf(HostTimeval));
        try testing.expectEqual(2 * @sizeOf(c_long), @sizeOf(SelectTimeval));
    }

    // struct hostent is the same five fields in the same order, so the host's object is the answer.
    try testing.expectEqual(2 * @sizeOf(usize), @offsetOf(Hostent, "addrtype"));
    try testing.expectEqual(3 * @sizeOf(usize), @offsetOf(Hostent, "addr_list"));
}

test "every name this package answers to has a live address" {
    for ([_][]const u8{
        "socket",     "bind",        "connect",     "listen",   "accept",
        "send",       "recv",        "sendto",      "recvfrom", "select",
        "setsockopt", "getsockname", "getpeername", "ioctl",    "gethostbyname",
    }) |n| try testing.expect(address(n).? != 0);

    // Scalar in, scalar out, and the same on both platforms: these stay forwarded in libc.zig.
    try testing.expectEqual(@as(?usize, null), address("inet_addr"));
    try testing.expectEqual(@as(?usize, null), address("inet_ntoa"));
    try testing.expectEqual(@as(?usize, null), address("gethostname"));
    // Not imported by the image, so not implemented here.
    try testing.expectEqual(@as(?usize, null), address("getsockopt"));
    try testing.expectEqual(@as(?usize, null), address("fcntl"));
    try testing.expectEqual(@as(?usize, null), address("shutdown"));
}

// Loopback, through this file's own entry points rather than the host's, because the point is that
// the translated address is the one the kernel binds and connects to. Skipped where the sandbox will
// not open a socket at all; every wait is bounded so a refusal cannot hang the suite.
test "a real connection over the shim's own sockaddr translation" {
    const listener = socket(darwin.AF_INET, 1, 0);
    if (listener < 0) return error.SkipZigTest;
    defer _ = std.c.close(listener);

    const on: c_int = 1;
    _ = setsockopt(listener, darwin.SOL_SOCKET, darwin.SO_REUSEADDR, &on, @sizeOf(c_int));

    // Port zero: the kernel picks, and getsockname is how the shim's read-back path is exercised.
    var addr: DarwinSockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
    if (bind(listener, @ptrCast(&addr), @sizeOf(DarwinSockaddrIn)) < 0) return error.SkipZigTest;
    if (listen(listener, 4) < 0) return error.SkipZigTest;

    var bound: DarwinSockaddrIn = undefined;
    var bound_len: u32 = @sizeOf(DarwinSockaddrIn);
    try testing.expectEqual(@as(c_int, 0), getsockname(listener, @ptrCast(&bound), &bound_len));
    try testing.expectEqual(@as(u32, 16), bound_len);
    try testing.expectEqual(@as(u8, 16), bound.len);
    try testing.expectEqual(@as(u8, @intCast(darwin.AF_INET)), bound.family);
    try testing.expect(bound.port != 0);
    try testing.expectEqual(std.mem.nativeToBig(u32, 0x7f00_0001), bound.addr);

    const client = socket(darwin.AF_INET, 1, 0);
    if (client < 0) return error.SkipZigTest;
    defer _ = std.c.close(client);

    // A second of patience on a loopback accept is a failure, not a slow machine.
    const patience: DarwinTimeval = .{ .sec = 1, .usec = 0 };
    _ = setsockopt(listener, darwin.SOL_SOCKET, darwin.SO_RCVTIMEO, &patience, @sizeOf(DarwinTimeval));
    _ = setsockopt(client, darwin.SOL_SOCKET, darwin.SO_RCVTIMEO, &patience, @sizeOf(DarwinTimeval));

    try testing.expectEqual(@as(c_int, 0), connect(client, @ptrCast(&bound), @sizeOf(DarwinSockaddrIn)));

    var peer: DarwinSockaddrIn = undefined;
    var peer_len: u32 = @sizeOf(DarwinSockaddrIn);
    const served = accept(listener, @ptrCast(&peer), &peer_len);
    try testing.expect(served >= 0);
    defer _ = std.c.close(served);
    // The accepted address came back through the same translation, so its length byte is Darwin's.
    try testing.expectEqual(@as(u8, 16), peer.len);
    try testing.expectEqual(@as(u8, @intCast(darwin.AF_INET)), peer.family);

    // getpeername on the client has to name the listener, port and all, or the translation moved it.
    var named: DarwinSockaddrIn = undefined;
    var named_len: u32 = @sizeOf(DarwinSockaddrIn);
    try testing.expectEqual(@as(c_int, 0), getpeername(client, @ptrCast(&named), &named_len));
    try testing.expectEqual(bound.port, named.port);
    try testing.expectEqual(bound.addr, named.addr);

    _ = setsockopt(client, darwin.SOL_SOCKET, darwin.SO_NOSIGPIPE, &on, @sizeOf(c_int));
    const payload = "GS";
    try testing.expectEqual(@as(isize, 2), send(client, payload, payload.len, 0));

    // MSG_WAITALL is the flag that becomes MSG_DONTWAIT if nobody translates it.
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 2), recv(served, &buf, 2, darwin.MSG_WAITALL));
    try testing.expectEqualStrings("GS", buf[0..2]);

    // And select sees the descriptor the game handed it, with the game's own eight-byte timeout.
    try testing.expectEqual(@as(isize, 2), send(served, payload, payload.len, 0));
    var readable: FdSet = .{ .bits = @splat(0) };
    readable.bits[@intCast(@divTrunc(client, 8))] |= @as(u8, 1) << @intCast(@mod(client, 8));
    var wait: DarwinTimeval = .{ .sec = 1, .usec = 0 };
    try testing.expectEqual(@as(c_int, 1), select(client + 1, &readable, null, null, &wait));
    // Darwin does not write the remaining time back, and neither does the shim.
    try testing.expectEqual(@as(i32, 1), wait.sec);
    try testing.expectEqual(@as(isize, 2), recv(client, &buf, 2, 0));
}

/// Monotonic milliseconds, for the one test that has to prove a call actually blocked.
fn monotonicMs() ?i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return null;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

test "a select with nothing to wait for waits anyway" {
    // The bug this exists for: a timeout struct handed to a host entry point that reads it narrower
    // than it was written puts tv_usec in the padding, so every timeout is zero. Nothing fails —
    // select just returns 0 the instant it is called, and the caller's loop spins at a million
    // iterations a second. Only elapsed time can tell the two apart.
    const t0 = monotonicMs() orelse return error.SkipZigTest;
    var empty: FdSet = .{ .bits = @splat(0) };
    var wait: DarwinTimeval = .{ .sec = 0, .usec = 150_000 };
    try testing.expectEqual(@as(c_int, 0), select(0, &empty, null, null, &wait));
    const elapsed = (monotonicMs() orelse return error.SkipZigTest) - t0;
    try testing.expect(elapsed >= 100);
}

test "a failed call leaves a Darwin errno behind" {
    // -1 is never a socket, so this is EBADF (9 on both) — what is asserted is that the shim wrote
    // through compat's errno location at all, which is where the game reads.
    compat.errorLocation().* = 0;
    try testing.expectEqual(@as(c_int, -1), listen(-1, 1));
    try testing.expectEqual(@as(c_int, 9), compat.errorLocation().*);

    // A family the shim cannot map never reaches the host, and reports Darwin's EAFNOSUPPORT.
    try testing.expectEqual(@as(c_int, -1), socket(28, 1, 0));
    try testing.expectEqual(darwin.EAFNOSUPPORT, compat.errorLocation().*);

    // As does an option this shim has no translation for: it never reaches the host at all.
    const value: c_int = 1;
    try testing.expectEqual(@as(c_int, -1), setsockopt(-1, darwin.SOL_SOCKET, 0x1024, &value, 4));
    try testing.expectEqual(darwin.ENOPROTOOPT, compat.errorLocation().*);
    try testing.expectEqual(@as(c_int, -1), setsockopt(-1, 0x1234, darwin.SO_REUSEADDR, &value, 4));
    try testing.expectEqual(darwin.ENOPROTOOPT, compat.errorLocation().*);
}
