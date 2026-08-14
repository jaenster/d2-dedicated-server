//! What a Darwin import name resolves to in this process.
//!
//! There are only two answers, and that is the decision here: either the host libc means the same
//! thing by the name and the binding gets the real function, or it does not and the binding gets ten
//! bytes that say the name out loud when the game finally calls them. Nothing is stubbed to a
//! `return 0` in between, because a stub that lies is indistinguishable from one that works until
//! the frame it corrupts is three seconds downstream.
//!
//! Only 626 names come out of the image and most are windows, menus and sound. Which of them a
//! headless server actually touches is a question the game answers, not this file.

const std = @import("std");

pub const unimplemented = @import("unimplemented.zig");
pub const libc = @import("libc.zig");
pub const pthread = @import("pthread.zig");
pub const mach = @import("mach.zig");
pub const cxx = @import("cxx.zig");
pub const carbon = @import("carbon.zig");
pub const files = @import("files.zig");
pub const memory = @import("memory.zig");
pub const compat = @import("compat.zig");

/// `_close$UNIX2003` -> `close`, `_stat$INODE64` -> `stat`, `_realpath$DARWIN_EXTSN` -> `realpath`.
///
/// The underscore is the Mach-O C prefix. The suffix is Darwin's symbol-level versioning, where one
/// name carries several generations of a function; they collapse to one here because the shim has
/// only ever got one implementation to offer, and it is the current one.
pub fn normalise(name: []const u8) []const u8 {
    const unprefixed = if (name.len > 0 and name[0] == '_') name[1..] else name;
    const end = std.mem.indexOfScalar(u8, unprefixed, '$') orelse unprefixed.len;
    return unprefixed[0..end];
}

pub const Resolver = struct {
    thunks: unimplemented.Thunks,
    /// One thunk per distinct name, not per bind site: a name appears in both the eager and the lazy
    /// stream and at many slots, and the slab is sized by the import count.
    minted: std.StringHashMapUnmanaged(usize) = .empty,
    /// The map lives exactly as long as the process does, so there is nothing for a general-purpose
    /// allocator to do here.
    gpa: std.mem.Allocator = std.heap.page_allocator,
    sealed: bool = false,

    /// Bindings answered — by the host libc or by a shim here — and bindings sent to a thunk. Both
    /// count sites, not names; `thunks.count()` is the number of distinct unimplemented imports.
    libc_hits: usize = 0,
    thunk_hits: usize = 0,

    pub fn init(capacity: usize) !Resolver {
        return .{ .thunks = try unimplemented.Thunks.init(capacity) };
    }

    pub fn deinit(self: *Resolver) void {
        self.minted.deinit(self.gpa);
        self.thunks.deinit();
    }

    /// `name` must be NUL-terminated at `name.ptr[name.len]` and must outlive the process: an
    /// unresolved name is handed to a thunk that prints it whenever the game gets round to calling
    /// it, possibly hours later. Names sliced out of the mapped image satisfy both, which is why the
    /// bind walker can pass its `[]const u8` straight in.
    ///
    /// Null means the slab is full, not that the name is unknown — an unknown name is what a thunk
    /// is for.
    pub fn resolve(self: *Resolver, name: []const u8) ?usize {
        std.debug.assert(!self.sealed);
        std.debug.assert(name.ptr[name.len] == 0);

        // compat is keyed on the spelling in the image, before normalise() gets at it: `___error`
        // and `__DefaultRuneLocale` carry underscores that are part of the name, not the prefix.
        if (compat.address(name)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        const norm = normalise(name);
        // pthread before libc: the names the shim owns must not also be in the forwarded list, and
        // this is the order that makes a mistake there loud rather than silent.
        if (pthread.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        if (mach.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        if (cxx.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        if (carbon.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        if (files.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        if (memory.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }
        if (libc.address(norm)) |addr| {
            self.libc_hits += 1;
            return addr;
        }

        self.thunk_hits += 1;
        if (self.minted.get(name)) |site| return site;
        const site = self.thunks.add(@ptrCast(name.ptr)) catch return null;
        self.minted.put(self.gpa, name, site) catch return null;
        return site;
    }

    /// Make the thunks executable. No resolving afterwards.
    pub fn seal(self: *Resolver) !void {
        try self.thunks.seal();
        self.sealed = true;
    }
};

const testing = std.testing;

test "normalisation strips the Mach-O prefix and the symbol version" {
    try testing.expectEqualStrings("close", normalise("_close$UNIX2003"));
    try testing.expectEqualStrings("stat", normalise("_stat$INODE64"));
    try testing.expectEqualStrings("realpath", normalise("_realpath$DARWIN_EXTSN"));
    try testing.expectEqualStrings("malloc", normalise("_malloc"));
    // Only one underscore comes off: `__Exit` is C99 `_Exit`, and `___bzero` is not `bzero`.
    try testing.expectEqualStrings("_Exit", normalise("__Exit"));
    try testing.expectEqualStrings("__bzero", normalise("___bzero"));
    // Not every import is C-prefixed.
    try testing.expectEqualStrings("dyld_stub_binder", normalise("dyld_stub_binder"));
    try testing.expectEqualStrings("", normalise(""));
}

test "a libc name resolves to the host libc's own address" {
    var r = try Resolver.init(8);
    defer r.deinit();

    const memcpy_addr = r.resolve("_memcpy").?;
    try testing.expect(memcpy_addr != 0);
    try testing.expectEqual(@intFromPtr(@extern(*const anyopaque, .{ .name = "memcpy" })), memcpy_addr);

    // Reached through the versioned spelling, which is how the image actually asks for it.
    try testing.expectEqual(@intFromPtr(@extern(*const anyopaque, .{ .name = "close" })), r.resolve("_close$UNIX2003").?);

    try testing.expectEqual(@as(usize, 2), r.libc_hits);
    try testing.expectEqual(@as(usize, 0), r.thunk_hits);
    try testing.expectEqual(@as(usize, 0), r.thunks.count());
}

test "the shims answer before the libc list, on the name the image uses" {
    var r = try Resolver.init(8);
    defer r.deinit();

    // normalise() would make these `__error` and `_DefaultRuneLocale`, so the lookup has to happen
    // on the original spelling — and the data symbol has to come back as an address, not a thunk.
    try testing.expectEqual(@intFromPtr(&compat.errorLocation), r.resolve("___error").?);
    try testing.expectEqual(@intFromPtr(&compat.DefaultRuneLocale), r.resolve("__DefaultRuneLocale").?);
    try testing.expectEqual(@intFromPtr(&compat.udivdi3), r.resolve("___udivdi3").?);

    // And the pthread shims are reached through the versioned spelling the image actually binds.
    try testing.expectEqual(@intFromPtr(&pthread.condInit), r.resolve("_pthread_cond_init$UNIX2003").?);
    try testing.expectEqual(@intFromPtr(&pthread.condWait), r.resolve("_pthread_cond_wait$UNIX2003").?);
    try testing.expectEqual(@intFromPtr(&pthread.mutexattrSettype), r.resolve("_pthread_mutexattr_settype").?);

    // Including the Mach data symbol, which the game binds a pointer at rather than calls.
    try testing.expectEqual(@intFromPtr(&mach.mach_task_self_), r.resolve("_mach_task_self_").?);
    try testing.expectEqual(@intFromPtr(&mach.threadSelf), r.resolve("_mach_thread_self").?);
    try testing.expectEqual(@intFromPtr(&cxx.guardAcquire), r.resolve("___cxa_guard_acquire").?);

    // The mutex itself still forwards, because Darwin's is the bigger of the two.
    const host_lock = @intFromPtr(@extern(*const anyopaque, .{ .name = "pthread_mutex_lock" }));
    try testing.expectEqual(host_lock, r.resolve("_pthread_mutex_lock").?);

    try testing.expectEqual(@as(usize, 0), r.thunk_hits);
    try testing.expectEqual(@as(usize, 0), r.thunks.count());
}

test "an unimplemented name gets one thunk of its own" {
    var r = try Resolver.init(8);
    defer r.deinit();

    const cf = r.resolve("_CFRelease").?;
    const agl = r.resolve("_aglSwapBuffers").?;
    try testing.expect(cf != agl);

    // The same name at another bind site is the same thunk, or the slab would run out.
    try testing.expectEqual(cf, r.resolve("_CFRelease").?);
    try testing.expectEqual(@as(usize, 2), r.thunks.count());
    try testing.expectEqual(@as(usize, 3), r.thunk_hits);

    // A name whose layout differs between the platforms is unimplemented, not forwarded.
    try testing.expect(r.resolve("_stat$INODE64").? != 0);
    try testing.expectEqual(@as(usize, 0), r.libc_hits);
    try testing.expectEqual(@as(usize, 3), r.thunks.count());
}
