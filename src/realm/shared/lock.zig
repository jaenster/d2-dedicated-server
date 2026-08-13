//! A lock that waits by sleeping, not by burning a core. (0.16's Io migration took
//! std.Thread.Mutex and Futex out of std.Thread, so this is hand-rolled.)
//!
//! Callers hold it across IO -- redis for a whole command/reply round trip, fs across a disk
//! write, gslink's req_lock across a create/join the game server can take seconds to answer --
//! and a pure spinner waiting on one of those burns a full core for the entire wait. So back
//! off in three stages: spin as long as a genuinely short section could last, then yield in
//! case the holder just wants a core, then sleep in doubling steps. An uncontended take is
//! still one atomic swap.
const std = @import("std");

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn sched_yield() c_int;

// Long enough to cover a few-instruction critical section, short enough that a lock held
// across a syscall reaches the sleeping stage almost immediately.
const SPINS: u32 = 64;
const YIELDS: u32 = 8;
const SLEEP_MIN_US: c_uint = 50;
const SLEEP_MAX_US: c_uint = 1000;

pub const Lock = struct {
    held: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *Lock) void {
        if (self.tryLock()) return;
        var spins: u32 = 0;
        while (spins < SPINS) : (spins += 1) {
            std.atomic.spinLoopHint();
            if (self.tryLock()) return;
        }
        var yields: u32 = 0;
        while (yields < YIELDS) : (yields += 1) {
            _ = sched_yield();
            if (self.tryLock()) return;
        }
        var nap: c_uint = SLEEP_MIN_US;
        while (true) {
            _ = usleep(nap);
            if (self.tryLock()) return;
            if (nap < SLEEP_MAX_US) nap *= 2;
        }
    }

    pub fn unlock(self: *Lock) void {
        self.held.store(false, .release);
    }

    /// Take the lock if it is free, never waiting. Lets a caller with several equivalent
    /// resources (a connection pool) pick one nobody is using instead of queueing on one.
    ///
    /// Reads before swapping: a plain swap in the spin loop would bounce the cache line
    /// between every waiter on every iteration.
    pub fn tryLock(self: *Lock) bool {
        if (self.held.load(.monotonic)) return false;
        return !self.held.swap(true, .acquire);
    }
};

test "uncontended lock and unlock" {
    var l: Lock = .{};
    l.lock();
    try std.testing.expect(l.held.load(.monotonic));
    l.unlock();
    try std.testing.expect(!l.held.load(.monotonic));
    l.lock();
    l.unlock();
}

test "a held lock is not handed out twice" {
    var l: Lock = .{};
    l.lock();
    try std.testing.expect(!l.tryLock());
    l.unlock();
    try std.testing.expect(l.tryLock());
    l.unlock();
}

test "contended waiters each get the lock exactly once" {
    const Shared = struct {
        l: Lock = .{},
        counter: u32 = 0,
        fn bump(s: *@This()) void {
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                s.l.lock();
                defer s.l.unlock();
                s.counter += 1; // unsynchronised on purpose: the lock is what makes it safe
            }
        }
    };
    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.bump, .{&shared});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 4000), shared.counter);
}
