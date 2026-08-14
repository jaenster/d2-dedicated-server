//! What an import resolves to when nothing implements it.
//!
//! There are 626 of them and most will never be called: a headless server never opens a window,
//! never draws a menu, never plays a sound. Writing 626 stubs to find out which ones matter is the
//! wrong way round — instead every unresolved name gets ten bytes of generated code that names
//! itself when the game calls it, and the game tells us what it actually needs.
//!
//!     push <name>          ; cdecl argument
//!     call report          ; never returns
//!
//! Emitting code rather than sharing one stub is what preserves the name. A single shared trap
//! would report only that something unimplemented was called, which is the one detail already
//! known.

const std = @import("std");

pub const Error = error{ OutOfThunks, MapFailed };

const thunk_size = 10;

/// How the process is told an import went off the end of the shim. Replaced by the host so this
/// package does not decide how the server logs or dies.
pub const Reporter = *const fn (name: [*:0]const u8) callconv(.c) noreturn;

var reporter: Reporter = defaultReport;

/// Written straight to fd 2 rather than through a buffered writer: the process is about to die, and
/// a buffered report of why is a report nobody reads.
fn defaultReport(name: [*:0]const u8) callconv(.c) noreturn {
    const prefix = "unimplemented Darwin import called: ";
    _ = std.c.write(2, prefix, prefix.len);
    _ = std.c.write(2, name, std.mem.len(name));
    _ = std.c.write(2, "\n", 1);
    std.c.abort();
}

pub fn setReporter(r: Reporter) void {
    reporter = r;
}

fn dispatch(name: [*:0]const u8) callconv(.c) noreturn {
    reporter(name);
}

/// A slab of executable thunks, one per unresolved import.
pub const Thunks = struct {
    code: []align(std.heap.page_size_min) u8,
    used: usize = 0,

    pub fn init(capacity: usize) Error!Thunks {
        const size = std.mem.alignForward(usize, capacity * thunk_size, std.heap.page_size_min);
        const code = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return Error.MapFailed;
        return .{ .code = code };
    }

    pub fn deinit(self: *Thunks) void {
        std.posix.munmap(self.code);
    }

    /// `name` must outlive the process: the thunk holds a pointer to it, and the whole point is
    /// that it can still be printed hours later. Import names live in the mapped image, which
    /// satisfies that.
    pub fn add(self: *Thunks, name: [*:0]const u8) Error!usize {
        if (self.used + thunk_size > self.code.len) return Error.OutOfThunks;
        const at = self.code.ptr + self.used;
        const site = @intFromPtr(at);

        at[0] = 0x68; // push imm32
        std.mem.writeInt(u32, at[1..5], @truncate(@intFromPtr(name)), .little);
        at[5] = 0xe8; // call rel32
        const after = site + thunk_size;
        const rel: i32 = @truncate(@as(i64, @intCast(@intFromPtr(&dispatch))) - @as(i64, @intCast(after)));
        std.mem.writeInt(i32, at[6..10], rel, .little);

        self.used += thunk_size;
        return site;
    }

    /// Make the slab executable. Nothing may be added afterwards.
    pub fn seal(self: *Thunks) Error!void {
        if (std.c.mprotect(self.code.ptr, self.code.len, .{ .READ = true, .EXEC = true }) != 0) {
            return Error.MapFailed;
        }
    }

    pub fn count(self: *const Thunks) usize {
        return self.used / thunk_size;
    }
};

const testing = std.testing;

test "a thunk is ten bytes of push-and-call at the address it reports" {
    var t = try Thunks.init(4);
    defer t.deinit();

    const name: [*:0]const u8 = "_CFBundleGetMainBundle";
    const a = try t.add(name);
    const b = try t.add("_aglSwapBuffers");

    try testing.expectEqual(@as(usize, 2), t.count());
    try testing.expectEqual(a + thunk_size, b);

    const code: [*]const u8 = @ptrFromInt(a);
    try testing.expectEqual(@as(u8, 0x68), code[0]);
    try testing.expectEqual(@as(u32, @truncate(@intFromPtr(name))), std.mem.readInt(u32, code[1..5], .little));
    try testing.expectEqual(@as(u8, 0xe8), code[5]);

    // The relative displacement has to land exactly on the dispatcher, which is the part that is
    // easy to get one instruction wrong.
    const rel = std.mem.readInt(i32, code[6..10], .little);
    const target: i64 = @as(i64, @intCast(a + thunk_size)) + rel;
    try testing.expectEqual(@as(i64, @intCast(@intFromPtr(&dispatch))), target);
}

test "the slab refuses to overflow into memory it does not own" {
    var t = try Thunks.init(1);
    defer t.deinit();
    // init rounds up to a page, so the real capacity is a page's worth rather than one.
    const capacity = t.code.len / thunk_size;
    for (0..capacity) |_| _ = try t.add("_x");
    try testing.expectError(Error.OutOfThunks, t.add("_y"));
}
