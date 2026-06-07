//! Spinlock. std.Thread.Mutex moved/changed in 0.16's Io migration; a flag
//! spinlock has no such dependency and is fine for the short critical sections
//! here (session-table inserts/lookups).
const std = @import("std");

pub const Spinlock = struct {
    held: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *Spinlock) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *Spinlock) void {
        self.held.store(false, .release);
    }
};
