//! What an import resolves to when nothing implements it.
//!
//! There are 626 of them and most will never be called: a headless server never opens a window,
//! never draws a menu, never plays a sound. Writing 626 stubs to find out which ones matter is the
//! wrong way round — instead every unresolved name gets sixteen bytes of generated code that names
//! itself and returns zero, so the game both tells us what it needs and carries on without it.
//!
//!     push <name>          ; cdecl argument
//!     call dispatch        ; reports once, returns 0
//!     add  esp, 4
//!     ret
//!
//! Emitting code rather than sharing one stub is what preserves the name. A single shared stub
//! would report only that something unimplemented was called, which is the one detail already
//! known.

const std = @import("std");

pub const Error = error{ OutOfThunks, MapFailed };

const thunk_size = 16;

/// Returning zero is what makes an unimplemented import survivable, and it is not a guess: nearly
/// every Carbon and CoreFoundation entry point here returns an OSErr or a pointer, and `noErr` is 0.
/// So a call the shim does not implement reads as "succeeded, nothing to report" and the game goes
/// on — which is how far more of the boot gets reached than by implementing them one at a time.
///
/// Safe for any signature because Darwin i386 is uniformly cdecl: the caller cleans its own
/// arguments, so a callee that ignores them and returns 0 in EAX cannot corrupt the stack.
///
/// `strict` turns that off and aborts on the first one instead — the mode to use when a failure has
/// to be traced to its cause rather than absorbed.
pub var strict = false;

/// Where the one-line reports go. Stderr by default; negative silences them.
pub var report_fd: c_int = 2;

/// Names already reported, so a call in a loop does not bury the log. Fixed-size and lock-free:
/// entries are unique name pointers, and a lost race costs a duplicate line, not correctness.
var seen: [1024]usize = @splat(0);

fn reportOnce(name: [*:0]const u8) void {
    const key = @intFromPtr(name);
    var i = (key >> 3) % seen.len;
    for (0..seen.len) |_| {
        if (seen[i] == key) return;
        if (seen[i] == 0) {
            seen[i] = key;
            break;
        }
        i = (i + 1) % seen.len;
    }
    // A raw descriptor, not a buffered writer: if this call is about to take the process down, a
    // buffered account of why is one nobody reads. The host can point it somewhere else, and a
    // negative value silences it.
    if (report_fd < 0) return;
    const prefix = "darwin: unimplemented import ";
    _ = std.c.write(report_fd, prefix, prefix.len);
    _ = std.c.write(report_fd, name, std.mem.len(name));
    _ = std.c.write(report_fd, "\n", 1);
}

fn dispatch(name: [*:0]const u8) callconv(.c) c_int {
    reportOnce(name);
    if (strict) std.c.abort();
    return 0;
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

        at[0] = 0x68; // push imm32 — the name, as dispatch's cdecl argument
        std.mem.writeInt(u32, at[1..5], @truncate(@intFromPtr(name)), .little);
        at[5] = 0xe8; // call rel32
        // Displacement is measured from the end of the call, not the end of the thunk.
        const after_call = site + 10;
        const rel: i32 = @truncate(@as(i64, @intCast(@intFromPtr(&dispatch))) - @as(i64, @intCast(after_call)));
        std.mem.writeInt(i32, at[6..10], rel, .little);
        // Drop the pushed name and return dispatch's zero to the game.
        at[10] = 0x83; // add esp, 4
        at[11] = 0xc4;
        at[12] = 0x04;
        at[13] = 0xc3; // ret
        at[14] = 0x90;
        at[15] = 0x90;

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

test "a thunk names itself, then returns zero to its caller" {
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

    // The displacement has to land exactly on the dispatcher, and it is measured from the end of
    // the call — not the end of the thunk, which is the easy way to get it one instruction wrong.
    const rel = std.mem.readInt(i32, code[6..10], .little);
    const target: i64 = @as(i64, @intCast(a + 10)) + rel;
    try testing.expectEqual(@as(i64, @intCast(@intFromPtr(&dispatch))), target);

    // Without the stack fixup and the return, an unimplemented call takes the process with it
    // instead of reading as noErr.
    try testing.expectEqualSlices(u8, &.{ 0x83, 0xc4, 0x04, 0xc3 }, code[10..14]);
}

test "an unimplemented import reads as success, and names itself only once" {
    report_fd = -1; // the build runner owns this process's stderr while tests run
    defer report_fd = 2;
    // 0 is noErr, and that is the whole reason the boot gets past several hundred Carbon calls
    // nobody has implemented.
    try testing.expectEqual(@as(c_int, 0), dispatch("_SomeCarbonCallNobodyImplemented"));
    try testing.expectEqual(@as(c_int, 0), dispatch("_SomeCarbonCallNobodyImplemented"));
}

test "the slab refuses to overflow into memory it does not own" {
    var t = try Thunks.init(1);
    defer t.deinit();
    // init rounds up to a page, so the real capacity is a page's worth rather than one.
    const capacity = t.code.len / thunk_size;
    for (0..capacity) |_| _ = try t.add("_x");
    try testing.expectError(Error.OutOfThunks, t.add("_y"));
}
