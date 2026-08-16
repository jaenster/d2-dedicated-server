//! The parts of the Itanium C++ ABI that no libc ships.
//!
//! `__cxa_atexit` is forwarded because musl means the same thing by it. The rest (function-local
//! static guards for the image's constructors) live in libstdc++/libc++abi, which this process
//! links neither of, so they're written out here. The exception half — `__cxa_begin_catch`,
//! `__cxa_rethrow`, `__gxx_personality_v0`, `_Unwind_Resume`, the two `__cxxabiv1` vtables — is
//! deliberately absent: a shim can't fake unwinding i386 Mach-O frames without the real personality
//! routine, and a throw should fail loudly rather than corrupt.

const std = @import("std");

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "__cxa_guard_acquire", &guardAcquire },
        .{ "__cxa_guard_release", &guardRelease },
        .{ "__cxa_guard_abort", &guardAbort },
        .{ "__cxa_pure_virtual", &pureVirtual },
        .{ "__cxa_demangle", &demangle },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

// function-local static guards

/// The ABI's guard object is eight bytes on x86 and only the first is the ABI's business: non-zero
/// means the static behind it is already constructed. The rest belongs to the runtime, and this one
/// keeps nothing there.
pub const Guard = extern struct { initialised: u8, runtime: [7]u8 };

comptime {
    std.debug.assert(@sizeOf(Guard) == 8);
}

/// Recursive, because a static's constructor routinely touches another static in the same
/// translation unit and would otherwise wait on the lock its own thread holds. Contention is a
/// handful of constructors at startup, so a spinlock costs less than a mutex that would itself need
/// initialising before any of this ran.
var owner: std.atomic.Value(u32) = .init(0);
var depth: u32 = 0;

/// A per-thread number that is never zero, which is what the free/held distinction rests on.
const selfId = @import("mach.zig").threadSelf;

fn lock() void {
    const me = selfId();
    if (owner.load(.monotonic) == me) {
        depth += 1;
        return;
    }
    while (owner.cmpxchgWeak(0, me, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    depth = 1;
}

fn unlock() void {
    depth -= 1;
    if (depth == 0) owner.store(0, .release);
}

/// Non-zero means the caller must run the constructor and then call release or abort; zero means
/// someone else already did. The lock is taken on the way out of a non-zero return and handed to
/// that caller, which is what makes this pair look unbalanced and be correct.
pub fn guardAcquire(g: *Guard) callconv(.c) c_int {
    if (@atomicLoad(u8, &g.initialised, .acquire) != 0) return 0;
    lock();
    if (@atomicLoad(u8, &g.initialised, .acquire) != 0) {
        unlock();
        return 0;
    }
    return 1;
}

pub fn guardRelease(g: *Guard) callconv(.c) void {
    @atomicStore(u8, &g.initialised, 1, .release);
    unlock();
}

/// The constructor threw. The static stays unconstructed so the next caller tries again.
pub fn guardAbort(g: *Guard) callconv(.c) void {
    _ = g;
    unlock();
}

// the rest

/// A call through a vtable slot that has no implementation. There is no correct return, and
/// returning at all resumes a program that has already lost.
pub fn pureVirtual() callconv(.c) noreturn {
    @panic("pure virtual function called");
}

/// Only ever reached from a crash report, and only to make a name readable. Failing to demangle
/// leaves the caller printing the mangled name, which is the same information.
pub fn demangle(mangled: ?[*:0]const u8, buf: ?[*]u8, len: ?*usize, status: ?*c_int) callconv(.c) ?[*:0]u8 {
    _ = .{ mangled, buf, len };
    // -1 is the ABI's memory-allocation failure, which is the honest one: nothing was produced.
    if (status) |s| s.* = -1;
    return null;
}

const testing = std.testing;

test "every provided name has a live address and the exception half is not one" {
    for ([_][]const u8{
        "__cxa_guard_acquire", "__cxa_guard_release", "__cxa_guard_abort",
        "__cxa_pure_virtual",  "__cxa_demangle",
    }) |n| try testing.expect(address(n).? != 0);

    // Forwarded to the host, so it must not be answered here as well.
    try testing.expectEqual(@as(?usize, null), address("__cxa_atexit"));
    // Left to a thunk on purpose.
    for ([_][]const u8{
        "__cxa_begin_catch", "__cxa_end_catch",   "__cxa_rethrow",
        "_Unwind_Resume",    "__gxx_personality_v0",
    }) |n| try testing.expectEqual(@as(?usize, null), address(n));
}

test "a guard admits one initialiser and turns the rest away" {
    var g: Guard = .{ .initialised = 0, .runtime = @splat(0) };

    try testing.expectEqual(@as(c_int, 1), guardAcquire(&g));
    // Still holding the lock, and the same thread may guard another static inside this one.
    var inner: Guard = .{ .initialised = 0, .runtime = @splat(0) };
    try testing.expectEqual(@as(c_int, 1), guardAcquire(&inner));
    guardRelease(&inner);

    guardRelease(&g);
    try testing.expectEqual(@as(u8, 1), g.initialised);
    try testing.expectEqual(@as(c_int, 0), guardAcquire(&g));
    try testing.expectEqual(@as(u32, 0), owner.load(.monotonic));

    // An aborted constructor leaves the static unconstructed and the lock free.
    var failed: Guard = .{ .initialised = 0, .runtime = @splat(0) };
    try testing.expectEqual(@as(c_int, 1), guardAcquire(&failed));
    guardAbort(&failed);
    try testing.expectEqual(@as(u8, 0), failed.initialised);
    try testing.expectEqual(@as(u32, 0), owner.load(.monotonic));
    try testing.expectEqual(@as(c_int, 1), guardAcquire(&failed));
    guardRelease(&failed);
}

test "one thread constructs and the others wait for it" {
    const Once = struct {
        guard: Guard = .{ .initialised = 0, .runtime = @splat(0) },
        constructed: std.atomic.Value(u32) = .init(0),
        saw: std.atomic.Value(u32) = .init(0),

        fn run(self: *@This()) void {
            if (guardAcquire(&self.guard) != 0) {
                _ = self.constructed.fetchAdd(1, .monotonic);
                guardRelease(&self.guard);
            }
            // Whatever this thread's route through the guard was, the static is built by now.
            if (self.guard.initialised == 1) _ = self.saw.fetchAdd(1, .monotonic);
        }
    };

    var once: Once = .{};
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Once.run, .{&once});
    for (&threads) |*t| t.join();

    try testing.expectEqual(@as(u32, 1), once.constructed.load(.monotonic));
    try testing.expectEqual(@as(u32, threads.len), once.saw.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), owner.load(.monotonic));
}

test "demangle reports that it produced nothing" {
    var status: c_int = 0;
    try testing.expectEqual(@as(?[*:0]u8, null), demangle("_ZN3FooC1Ev", null, null, &status));
    try testing.expectEqual(@as(c_int, -1), status);
    try testing.expectEqual(@as(?[*:0]u8, null), demangle("_ZN3FooC1Ev", null, null, null));
}
