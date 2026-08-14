//! The imports the host libc can answer as-is.
//!
//! i386 Darwin and i386 Linux agree on cdecl, on the integer types, and on `char *`, so for a call
//! whose whole interface is scalars and bytes `_strlen` is simply `strlen` and there is nothing to
//! translate. That agreement is the decision this list encodes — and the reason it is a list rather
//! than "forward everything in libc": the moment a struct crosses the boundary the two platforms
//! disagree (`struct stat`, `sockaddr`, `sigaction`, `jmp_buf`, `struct tm`) and a forward is silent
//! corruption. Those names are absent on purpose, so they fall through to a naming thunk instead.
//!
//! Absent for the same reason, less obviously: `pthread_cond_*` (Darwin's `pthread_cond_t` is 28
//! bytes on i386, glibc's is 48, so glibc would write past the game's buffer) and
//! `pthread_mutexattr_settype` (PTHREAD_MUTEX_RECURSIVE is 2 on Darwin and 1 on Linux, so a
//! recursive mutex would come back as an errorcheck one and deadlock). Both want a translating shim,
//! not a forward.

const std = @import("std");
const builtin = @import("builtin");

/// Spelled as the host libc spells them: no leading underscore, no `$UNIX2003`/`$INODE64` suffix.
pub const names = [_][]const u8{
    "memcmp",
    "memcpy",
    "memmove",
    "memset",
    "bcopy",
    "strcasecmp",
    "strcat",
    "strchr",
    "strcmp",
    "strcpy",
    "strcspn",
    "strlen",
    "strncasecmp",
    "strncat",
    "strncmp",
    "strncpy",
    "strrchr",
    "strstr",
    "strtok",
    "strtol",
    "strtoul",
    "atoi",
    "malloc",
    "calloc",
    "realloc",
    "free",
    "qsort",
    "fopen",
    "fclose",
    "fflush",
    "fgetc",
    "fgets",
    "fprintf",
    "fputc",
    "fread",
    "fscanf",
    "fseek",
    "ftell",
    "fwrite",
    "snprintf",
    "sprintf",
    "sscanf",
    // va_list is a plain `char *` on both i386 ABIs, so the v-forms forward like any other call.
    "vfprintf",
    "vsnprintf",
    "vsprintf",
    "cos",
    "sin",
    "pow",
    "log",
    "log10",
    "floorf",
    "pthread_attr_destroy",
    "pthread_attr_init",
    "pthread_attr_setdetachstate",
    "pthread_attr_setstacksize",
    "pthread_create",
    "pthread_exit",
    "pthread_self",
    "pthread_sigmask",
    "pthread_mutex_destroy",
    "pthread_mutex_init",
    "pthread_mutex_lock",
    "pthread_mutex_unlock",
    "pthread_mutexattr_destroy",
    "pthread_mutexattr_init",
    "exit",
    "_Exit",
    "atexit",
    // The C++ static-destructor registration. musl means the same thing by it, including the dso
    // handle it ignores; the rest of the C++ ABI is in cxx.zig because no libc ships it.
    "__cxa_atexit",
    "raise",
    "kill",
    "getpid",
    "sleep",
    "usleep",
    "time",
    "close",
    "unlink",
    "mkdir",
    "chdir",
    "chmod",
    "mprotect",
    "msync",
    "socket",
    "listen",
    "send",
    "recv",
    // SOL_SOCKET and the SO_* values differ between the platforms; a wrong option fails the call
    // rather than corrupting anything, which is a translation the host can add when it matters.
    "setsockopt",
    "inet_addr",
    "inet_ntoa",
    "gethostname",
    "dlopen",
    "dlsym",
    "dlclose",
};

/// Darwin libc functions with no Linux counterpart, so this package is the counterpart.
pub const darwin_names = [_][]const u8{ "strlcpy", "strlcat", "malloc_size", "memset_pattern16" };

/// Address of a normalised import name, or null if nothing here provides it.
pub fn address(name: []const u8) ?usize {
    inline for (names) |n| {
        if (std.mem.eql(u8, name, n)) return @intFromPtr(@extern(*const anyopaque, .{ .name = n }));
    }
    if (std.mem.eql(u8, name, "strlcpy")) return @intFromPtr(&strlcpy);
    if (std.mem.eql(u8, name, "strlcat")) return @intFromPtr(&strlcat);
    if (std.mem.eql(u8, name, "malloc_size")) return @intFromPtr(&malloc_size);
    if (std.mem.eql(u8, name, "memset_pattern16")) return @intFromPtr(&memset_pattern16);
    return null;
}

/// Returns the length it *wanted* to write, which is how the caller detects truncation, and always
/// terminates. Returning the copied length instead is the classic misreading of this function.
pub fn strlcpy(dst: [*]u8, src: [*:0]const u8, size: usize) callconv(.c) usize {
    const len = std.mem.len(src);
    if (size != 0) {
        const n = @min(len, size - 1);
        @memcpy(dst[0..n], src[0..n]);
        dst[n] = 0;
    }
    return len;
}

/// Same contract as strlcpy. `dst` is measured within `size` rather than walked, so a buffer that is
/// full and unterminated is reported as `size + strlen(src)` instead of read off the end.
pub fn strlcat(dst: [*]u8, src: [*:0]const u8, size: usize) callconv(.c) usize {
    var dlen: usize = 0;
    while (dlen < size and dst[dlen] != 0) dlen += 1;
    const slen = std.mem.len(src);
    if (dlen == size) return size + slen;

    const n = @min(slen, size - dlen - 1);
    @memcpy(dst[dlen..][0..n], src[0..n]);
    dst[dlen + n] = 0;
    return dlen + slen;
}

// This file is also compiled on the development host, where the Linux spelling does not exist.
const usableSize = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => struct {
        extern fn malloc_size(?*const anyopaque) usize;
    }.malloc_size,
    else => struct {
        extern fn malloc_usable_size(?*anyopaque) usize;
    }.malloc_usable_size,
};

pub fn malloc_size(p: ?*const anyopaque) callconv(.c) usize {
    if (p == null) return 0;
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => usableSize(p),
        else => usableSize(@constCast(p)),
    };
}

/// Fills with repeats of the pattern and stops mid-pattern at the end, which is what makes it
/// usable for a length that is not a multiple of sixteen.
pub fn memset_pattern16(b: [*]u8, pattern: *const [16]u8, len: usize) callconv(.c) void {
    var off: usize = 0;
    while (off < len) {
        const n = @min(@as(usize, 16), len - off);
        @memcpy(b[off..][0..n], pattern[0..n]);
        off += n;
    }
}

const testing = std.testing;

test "every listed name has a live address" {
    for (names) |n| try testing.expect(address(n).? != 0);
    for (darwin_names) |n| try testing.expect(address(n).? != 0);
}

test "an address is the host libc's own" {
    try testing.expectEqual(@intFromPtr(@extern(*const anyopaque, .{ .name = "memcpy" })), address("memcpy").?);
    try testing.expectEqual(@intFromPtr(@extern(*const anyopaque, .{ .name = "pthread_create" })), address("pthread_create").?);
}

test "the ABI-sensitive names are deliberately absent" {
    for ([_][]const u8{ "stat", "connect", "select", "sigaction", "setjmp", "localtime_r", "realpath", "ioctl" }) |n| {
        try testing.expectEqual(@as(?usize, null), address(n));
    }
}

test "strlcpy reports the length it wanted and terminates anyway" {
    var buf: [8]u8 = undefined;

    @memset(&buf, 'x');
    try testing.expectEqual(@as(usize, 5), strlcpy(&buf, "hello", buf.len));
    try testing.expectEqualStrings("hello", buf[0..5]);
    try testing.expectEqual(@as(u8, 0), buf[5]);

    // Truncation: four characters plus a terminator, but the return says how much it needed.
    @memset(&buf, 'x');
    try testing.expectEqual(@as(usize, 11), strlcpy(&buf, "hello world", 5));
    try testing.expectEqualStrings("hell", buf[0..4]);
    try testing.expectEqual(@as(u8, 0), buf[4]);
    try testing.expectEqual(@as(u8, 'x'), buf[5]);

    // A zero size writes nothing at all, not even the terminator.
    @memset(&buf, 'x');
    try testing.expectEqual(@as(usize, 5), strlcpy(&buf, "hello", 0));
    try testing.expectEqual(@as(u8, 'x'), buf[0]);
}

test "strlcat measures the destination inside the size it was given" {
    var buf: [16]u8 = undefined;

    @memset(&buf, 'x');
    _ = strlcpy(&buf, "ab", buf.len);
    try testing.expectEqual(@as(usize, 5), strlcat(&buf, "cde", buf.len));
    try testing.expectEqualStrings("abcde", buf[0..5]);
    try testing.expectEqual(@as(u8, 0), buf[5]);

    @memset(&buf, 'x');
    _ = strlcpy(&buf, "ab", buf.len);
    try testing.expectEqual(@as(usize, 8), strlcat(&buf, "cdefgh", 5));
    try testing.expectEqualStrings("abcd", buf[0..4]);
    try testing.expectEqual(@as(u8, 0), buf[4]);

    // Destination already full and unterminated: nothing is appended and nothing is read past it.
    @memset(&buf, 'y');
    try testing.expectEqual(@as(usize, 7), strlcat(&buf, "abc", 4));
    try testing.expectEqual(@as(u8, 'y'), buf[0]);
    try testing.expectEqual(@as(u8, 'y'), buf[4]);
}

test "memset_pattern16 stops mid-pattern" {
    const pattern = "0123456789abcdef".*;
    var buf: [20]u8 = undefined;
    @memset(&buf, 'z');
    memset_pattern16(&buf, &pattern, 19);
    try testing.expectEqualStrings("0123456789abcdef012", buf[0..19]);
    try testing.expectEqual(@as(u8, 'z'), buf[19]);
}

test "malloc_size sees at least what was asked for" {
    const p = std.c.malloc(100) orelse return error.OutOfMemory;
    defer std.c.free(p);
    try testing.expect(malloc_size(p) >= 100);
    try testing.expectEqual(@as(usize, 0), malloc_size(null));
}
