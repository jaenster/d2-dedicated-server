//! The pthread imports that cannot be forwarded, and why each one cannot.
//!
//! POSIX threads port across almost unchanged — `pthread_create`, `pthread_self` and the mutex
//! calls are in libc.zig for exactly that reason. What does not port is anything where the game
//! owns the storage or reads back a constant, because Darwin and Linux picked different sizes and
//! different numbers for both:
//!
//!   pthread_cond_t       Darwin i386 28 bytes, glibc/musl i386 48. The game allocates 28, so a
//!                        forwarded `pthread_cond_init` writes 20 bytes into whatever follows.
//!   pthread_mutex_t      Darwin i386 44 bytes, glibc/musl i386 24. The other way round, so the
//!                        host writes inside the game's allocation and the mutex calls forward.
//!   pthread_mutexattr_t  Darwin i386 12 bytes, Linux 4. Forwards for the same reason.
//!   PTHREAD_MUTEX_*      RECURSIVE is 2 on Darwin and 1 on Linux, and ERRORCHECK is the mirror of
//!                        that, so an untranslated `settype` turns a recursive mutex into one that
//!                        fails the second lock.
//!
//! Return values here are Darwin's errno numbers, not the host's: the game compares against its own
//! `errno.h`, where ETIMEDOUT is 60 rather than Linux's 110.

const std = @import("std");
const builtin = @import("builtin");

/// Darwin's `struct _opaque_pthread_cond_t` as the i386 game lays it out: `long __sig` plus
/// `__PTHREAD_COND_SIZE__` opaque bytes, which is 24 on 32-bit.
pub const DarwinCond = extern struct { sig: i32, storage: [24]u8 };

/// Darwin's `struct _opaque_pthread_mutex_t`: `long __sig` plus `__PTHREAD_MUTEX_SIZE__`, 40 on
/// 32-bit. Bigger than the host's, which is what makes forwarding the mutex calls safe.
pub const DarwinMutex = extern struct { sig: i32, storage: [40]u8 };

/// glibc and musl agree on both of these for i386. Checked against std.c whenever the build target
/// is the one the game actually runs on.
pub const linux_i386_cond_size = 48;
pub const linux_i386_mutex_size = 24;

comptime {
    std.debug.assert(@sizeOf(DarwinCond) == 28);
    std.debug.assert(@sizeOf(DarwinMutex) == 44);
    if (builtin.os.tag == .linux and @sizeOf(usize) == 4) {
        std.debug.assert(@sizeOf(std.c.pthread_cond_t) == linux_i386_cond_size);
        std.debug.assert(@sizeOf(std.c.pthread_mutex_t) == linux_i386_mutex_size);
    }
}

/// Darwin i386's `struct timespec` is two 32-bit longs. musl's is 64-bit even on i386, so the
/// game's eight bytes cannot be read as the host's sixteen.
pub const DarwinTimespec = extern struct { sec: i32, nsec: i32 };

const EINVAL: c_int = 22;
const ENOMEM: c_int = 12;
const ETIMEDOUT: c_int = 60;

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "pthread_cond_init", &condInit },
        .{ "pthread_cond_wait", &condWait },
        .{ "pthread_cond_timedwait_relative_np", &condTimedwaitRelative },
        .{ "pthread_cond_broadcast", &condBroadcast },
        .{ "pthread_cond_destroy", &condDestroy },
        .{ "pthread_mutexattr_settype", &mutexattrSettype },
        .{ "pthread_setname_np", &setnameNp },
        .{ "pthread_getname_np", &getnameNp },
        .{ "pthread_get_stackaddr_np", &getStackaddrNp },
        .{ "pthread_get_stacksize_np", &getStacksizeNp },
        .{ "pthread_yield_np", &yieldNp },
        .{ "pthread_from_mach_thread_np", &fromMachThreadNp },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

// ── condition variables ──

/// What the shim keeps in the game's 28 bytes: a tag and the host condvar this package owns. The
/// object is ours, so its size is the host's and the game never sees it.
const Handle = extern struct {
    tag: u32,
    cond: ?*std.c.pthread_cond_t,
};

const tag_adopted: u32 = 0x4432_4356; // 'D2CV'

comptime {
    std.debug.assert(@sizeOf(Handle) <= @sizeOf(DarwinCond));
    // On the target both are long-aligned, so the handle lands where the game's `__sig` was. The
    // 64-bit build of this file exists only to run the tests.
    if (@sizeOf(usize) == 4) std.debug.assert(@alignOf(Handle) == @alignOf(DarwinCond));
}

/// Adoption is once per condvar object and contended by nothing else, so a spinlock costs less than
/// owning a real lock — and a real lock would need the same static-initialiser dance it prevents.
var adopt_lock: std.atomic.Value(u32) = .init(0);

/// A condvar can reach the shim without ever passing through `pthread_cond_init`, because Darwin's
/// PTHREAD_COND_INITIALIZER is a static one. Every entry point goes through here for that reason.
fn adopt(storage: *anyopaque) ?*std.c.pthread_cond_t {
    const h: *Handle = @ptrCast(@alignCast(storage));

    while (adopt_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer adopt_lock.store(0, .release);

    if (h.tag == tag_adopted) {
        if (h.cond) |c| return c;
    }
    const raw = std.c.malloc(@sizeOf(std.c.pthread_cond_t)) orelse return null;
    const c: *std.c.pthread_cond_t = @ptrCast(@alignCast(raw));
    if (condInitHost(c) != 0) {
        std.c.free(raw);
        return null;
    }
    h.* = .{ .tag = tag_adopted, .cond = c };
    return c;
}

extern fn pthread_cond_init(cond: *std.c.pthread_cond_t, attr: ?*const anyopaque) c_int;

fn condInitHost(c: *std.c.pthread_cond_t) c_int {
    return pthread_cond_init(c, null);
}

/// `attr` is ignored: the only Darwin condattr is the process-shared flag, which a single-process
/// game never sets.
pub fn condInit(cond: *anyopaque, attr: ?*const anyopaque) callconv(.c) c_int {
    _ = attr;
    const h: *Handle = @ptrCast(@alignCast(cond));
    // Re-initialising a live condvar is undefined, but re-initialising a dead one is routine, and
    // dropping the old object here is the difference between that and a leak per game.
    if (h.tag == tag_adopted) release(h);
    h.* = .{ .tag = 0, .cond = null };
    return if (adopt(cond) == null) ENOMEM else 0;
}

pub fn condDestroy(cond: *anyopaque) callconv(.c) c_int {
    const h: *Handle = @ptrCast(@alignCast(cond));
    if (h.tag == tag_adopted) release(h);
    return 0;
}

fn release(h: *Handle) void {
    if (h.cond) |c| {
        _ = std.c.pthread_cond_destroy(c);
        std.c.free(c);
    }
    h.* = .{ .tag = 0, .cond = null };
}

pub fn condWait(cond: *anyopaque, mutex: *anyopaque) callconv(.c) c_int {
    const c = adopt(cond) orelse return EINVAL;
    const m: *std.c.pthread_mutex_t = @ptrCast(@alignCast(mutex));
    return if (std.c.pthread_cond_wait(c, m) == .SUCCESS) 0 else EINVAL;
}

/// Darwin-only, and the timeout is RELATIVE. The host has only the absolute form, so the deadline is
/// built here from CLOCK_REALTIME — the same clock `pthread_cond_timedwait` measures against by
/// default on both platforms. Passing the relative value straight through would be a deadline in
/// 1970 and an instant ETIMEDOUT; passing an absolute one to Darwin's would be a wait until 2076.
pub fn condTimedwaitRelative(cond: *anyopaque, mutex: *anyopaque, rel: ?*const DarwinTimespec) callconv(.c) c_int {
    const c = adopt(cond) orelse return EINVAL;
    const m: *std.c.pthread_mutex_t = @ptrCast(@alignCast(mutex));

    // Darwin treats a null timeout as an indefinite wait.
    const t = rel orelse return if (std.c.pthread_cond_wait(c, m) == .SUCCESS) 0 else EINVAL;

    var abs: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &abs) != 0) return EINVAL;
    abs.sec += t.sec;
    abs.nsec += t.nsec;
    if (abs.nsec >= std.time.ns_per_s) {
        abs.nsec -= std.time.ns_per_s;
        abs.sec += 1;
    }
    return switch (std.c.pthread_cond_timedwait(c, m, &abs)) {
        .SUCCESS => 0,
        .TIMEDOUT => ETIMEDOUT,
        else => EINVAL,
    };
}

pub fn condBroadcast(cond: *anyopaque) callconv(.c) c_int {
    const c = adopt(cond) orelse return EINVAL;
    return if (std.c.pthread_cond_broadcast(c) == .SUCCESS) 0 else EINVAL;
}

// ── mutex attributes ──

extern fn pthread_mutexattr_settype(attr: *anyopaque, kind: c_int) c_int;

/// Darwin: NORMAL 0, ERRORCHECK 1, RECURSIVE 2. Linux: NORMAL 0, RECURSIVE 1, ERRORCHECK 2. Two of
/// the three swap, and the one that matters is RECURSIVE — the game locks the same mutex twice.
pub fn mutexattrSettype(attr: *anyopaque, kind: c_int) callconv(.c) c_int {
    const host = hostMutexType(kind) orelse return EINVAL;
    return pthread_mutexattr_settype(attr, host);
}

fn hostMutexType(darwin_kind: c_int) ?c_int {
    if (builtin.os.tag != .linux) return switch (darwin_kind) {
        0, 1, 2 => darwin_kind,
        else => null,
    };
    return switch (darwin_kind) {
        0 => 0,
        1 => 2,
        2 => 1,
        else => null,
    };
}

// ── the Darwin-only _np calls ──

const hostSetName = switch (builtin.os.tag) {
    .linux => struct {
        extern fn pthread_setname_np(thread: std.c.pthread_t, name: [*:0]const u8) c_int;
    }.pthread_setname_np,
    else => struct {
        extern fn pthread_setname_np(name: [*:0]const u8) c_int;
    }.pthread_setname_np,
};

/// Darwin's takes one argument and always names the calling thread; Linux's takes the thread too,
/// and rejects anything over 15 characters rather than truncating, so the truncation is done here.
pub fn setnameNp(name: [*:0]const u8) callconv(.c) c_int {
    if (builtin.os.tag != .linux) return hostSetName(name);

    var buf: [16]u8 = undefined;
    const n = @min(std.mem.len(name), buf.len - 1);
    @memcpy(buf[0..n], name[0..n]);
    buf[n] = 0;
    return hostSetName(std.c.pthread_self(), @ptrCast(&buf));
}

extern fn pthread_getname_np(thread: std.c.pthread_t, name: [*]u8, len: usize) c_int;

/// Same shape on both platforms, but it lives here rather than in the libc list to keep the whole
/// `_np` family in one place.
pub fn getnameNp(thread: std.c.pthread_t, name: [*]u8, len: usize) callconv(.c) c_int {
    return pthread_getname_np(thread, name, len);
}

const Stack = struct { base: usize, size: usize };

const linux_stack = struct {
    extern fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
    extern fn pthread_attr_getstack(attr: *const std.c.pthread_attr_t, addr: *usize, size: *usize) c_int;

    fn get(thread: std.c.pthread_t) ?Stack {
        var attr: std.c.pthread_attr_t = undefined;
        if (pthread_getattr_np(thread, &attr) != 0) return null;
        defer _ = std.c.pthread_attr_destroy(&attr);

        var base: usize = 0;
        var size: usize = 0;
        if (pthread_attr_getstack(&attr, &base, &size) != 0) return null;
        return .{ .base = base, .size = size };
    }
};

const darwin_stack = struct {
    extern fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
    extern fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;

    fn get(thread: std.c.pthread_t) ?Stack {
        const top = @intFromPtr(pthread_get_stackaddr_np(thread));
        const size = pthread_get_stacksize_np(thread);
        if (top < size) return null;
        return .{ .base = top - size, .size = size };
    }
};

const hostStack = if (builtin.os.tag == .linux) linux_stack.get else darwin_stack.get;

/// Darwin reports the high end of the stack, the address it grows down from. Linux reports the low
/// end plus a size, so the two are added back together here.
pub fn getStackaddrNp(thread: std.c.pthread_t) callconv(.c) ?*anyopaque {
    const s = hostStack(thread) orelse return null;
    return @ptrFromInt(s.base + s.size);
}

pub fn getStacksizeNp(thread: std.c.pthread_t) callconv(.c) usize {
    const s = hostStack(thread) orelse return 0;
    return s.size;
}

extern fn sched_yield() c_int;

pub fn yieldNp() callconv(.c) void {
    _ = sched_yield();
}

/// Mach ports do not exist here and there is nothing to map one onto, so this always fails. Callers
/// use it to reach a thread they only have a Mach name for, which on Linux means they cannot.
pub fn fromMachThreadNp(port: u32) callconv(.c) ?*anyopaque {
    _ = port;
    return null;
}

const testing = std.testing;

test "the sizes the shim exists to protect" {
    // Written as assertions rather than prose: these four numbers are the entire reason condvars are
    // owned here and mutexes are forwarded.
    try testing.expectEqual(@as(usize, 28), @sizeOf(DarwinCond));
    try testing.expectEqual(@as(usize, 44), @sizeOf(DarwinMutex));

    // The host's condvar does not fit in the game's, so it has to live somewhere else.
    try testing.expect(linux_i386_cond_size > @sizeOf(DarwinCond));
    try testing.expect(@sizeOf(std.c.pthread_cond_t) > @sizeOf(DarwinCond));

    // The host's mutex does fit in the game's, which is why pthread_mutex_* is forwarded untouched.
    try testing.expect(linux_i386_mutex_size <= @sizeOf(DarwinMutex));

    // And what the shim actually puts in the game's storage stays inside it.
    try testing.expect(@sizeOf(Handle) <= @sizeOf(DarwinCond));
}

test "the recursive constant is translated, not passed through" {
    try testing.expectEqual(@as(?c_int, if (builtin.os.tag == .linux) 1 else 2), hostMutexType(2));
    try testing.expectEqual(@as(?c_int, if (builtin.os.tag == .linux) 2 else 1), hostMutexType(1));
    try testing.expectEqual(@as(?c_int, 0), hostMutexType(0));
    try testing.expectEqual(@as(?c_int, null), hostMutexType(7));
}

test "a mutex made recursive through the shim locks twice from one thread" {
    var attr: AttrStorage = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutexattr_init(&attr));
    defer _ = pthread_mutexattr_destroy(&attr);

    // 2 is Darwin's PTHREAD_MUTEX_RECURSIVE, which is what the game passes.
    try testing.expectEqual(@as(c_int, 0), mutexattrSettype(&attr, 2));

    var m: std.c.pthread_mutex_t = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, &attr));
    defer _ = std.c.pthread_mutex_destroy(&m);

    // Without the translation this is an errorcheck mutex and the second lock fails instead.
    try testing.expectEqual(std.c.E.SUCCESS, std.c.pthread_mutex_lock(&m));
    try testing.expectEqual(std.c.E.SUCCESS, std.c.pthread_mutex_lock(&m));
    try testing.expectEqual(std.c.E.SUCCESS, std.c.pthread_mutex_unlock(&m));
    try testing.expectEqual(std.c.E.SUCCESS, std.c.pthread_mutex_unlock(&m));
}

extern fn pthread_mutexattr_init(attr: *anyopaque) c_int;
extern fn pthread_mutexattr_destroy(attr: *anyopaque) c_int;
extern fn pthread_mutex_init(mutex: *std.c.pthread_mutex_t, attr: ?*const anyopaque) c_int;

/// std.c does not model `pthread_mutexattr_t`, and the tests only need somewhere to put one. Darwin
/// i386's is 12 bytes and every host's is smaller, so anything this size is enough for both.
const AttrStorage = extern struct { bytes: [64]u8 align(16) = @splat(0) };

/// A condvar in the game's storage, so the tests exercise the same 28 bytes the game hands over.
const GameCond = extern struct {
    bytes: [@sizeOf(DarwinCond)]u8 align(@alignOf(Handle)) = @splat(0),
};

extern fn usleep(usec: u32) c_int;

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Rendezvous = struct {
    cond: GameCond = .{},
    mutex: std.c.pthread_mutex_t = undefined,
    ready: bool = false,

    fn signaller(self: *Rendezvous) void {
        _ = usleep(20_000);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        self.ready = true;
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        _ = condBroadcast(&self.cond);
    }
};

test "a broadcast from another thread wakes the waiter" {
    var r: Rendezvous = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&r.mutex, null));
    defer _ = std.c.pthread_mutex_destroy(&r.mutex);

    // Deliberately never initialised: Darwin's PTHREAD_COND_INITIALIZER is static, so the shim has
    // to adopt zeroed storage on first use.
    defer _ = condDestroy(&r.cond);

    const t = try std.Thread.spawn(.{}, Rendezvous.signaller, .{&r});
    defer t.join();

    _ = std.c.pthread_mutex_lock(&r.mutex);
    while (!r.ready) try testing.expectEqual(@as(c_int, 0), condWait(&r.cond, &r.mutex));
    _ = std.c.pthread_mutex_unlock(&r.mutex);
}

test "the relative timeout is relative" {
    var cond: GameCond = .{};
    try testing.expectEqual(@as(c_int, 0), condInit(&cond, null));
    defer _ = condDestroy(&cond);

    var m: std.c.pthread_mutex_t = undefined;
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&m, null));
    defer _ = std.c.pthread_mutex_destroy(&m);

    const rel: DarwinTimespec = .{ .sec = 0, .nsec = 60 * std.time.ns_per_ms };
    const started = monotonicNs();
    _ = std.c.pthread_mutex_lock(&m);
    const rc = condTimedwaitRelative(&cond, &m, &rel);
    _ = std.c.pthread_mutex_unlock(&m);
    const waited = monotonicNs() - started;

    try testing.expectEqual(ETIMEDOUT, rc);
    // Reading the value as an absolute deadline returns instantly; ignoring it never returns. The
    // window is wide because a loaded machine schedules late, but neither failure lands inside it.
    try testing.expect(waited >= 40 * std.time.ns_per_ms);
    try testing.expect(waited < 5 * std.time.ns_per_s);
}

test "a null timeout is not a zero timeout" {
    var r: Rendezvous = .{};
    try testing.expectEqual(@as(c_int, 0), pthread_mutex_init(&r.mutex, null));
    defer _ = std.c.pthread_mutex_destroy(&r.mutex);
    defer _ = condDestroy(&r.cond);

    const t = try std.Thread.spawn(.{}, Rendezvous.signaller, .{&r});
    defer t.join();

    _ = std.c.pthread_mutex_lock(&r.mutex);
    while (!r.ready) try testing.expectEqual(@as(c_int, 0), condTimedwaitRelative(&r.cond, &r.mutex, null));
    _ = std.c.pthread_mutex_unlock(&r.mutex);
}

test "the stack of the calling thread has the caller's frame inside it" {
    const self = std.c.pthread_self();
    const size = getStacksizeNp(self);
    const top = @intFromPtr(getStackaddrNp(self));
    try testing.expect(size > 0);
    try testing.expect(top > size);

    const frame = @intFromPtr(&self);
    try testing.expect(frame > top - size and frame <= top);
}

test "every provided name has a live address and nothing else does" {
    for ([_][]const u8{
        "pthread_cond_init",        "pthread_cond_wait",    "pthread_cond_timedwait_relative_np",
        "pthread_cond_broadcast",   "pthread_cond_destroy", "pthread_mutexattr_settype",
        "pthread_setname_np",       "pthread_getname_np",   "pthread_get_stackaddr_np",
        "pthread_get_stacksize_np", "pthread_yield_np",     "pthread_from_mach_thread_np",
    }) |n| try testing.expect(address(n).? != 0);

    // Forwarded, so it must not be answered here as well.
    try testing.expectEqual(@as(?usize, null), address("pthread_mutex_lock"));
    try testing.expectEqual(@as(?usize, null), address("pthread_cond_signal"));
}

test "yield and from_mach_thread" {
    yieldNp();
    try testing.expectEqual(@as(?*anyopaque, null), fromMachThreadNp(0));
}
