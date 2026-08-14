//! The classic Memory Manager: handles, pointers, and the errors they report.
//!
//! A `Ptr` is malloc and nothing else. A `Handle` is the part that has no C equivalent: a pointer to
//! a master pointer, so the Memory Manager could move a block and fix every reference by updating
//! one word. Nothing moves here, but the indirection is still real — the game dereferences twice —
//! so a handle is a two-word record whose first word is the block and whose second is its size, and
//! the handle the game holds points at that first word.
//!
//! Locking, purging and compaction all existed to manage a heap that relocated blocks. This one does
//! not, which makes "the block is already locked and will not move" a description rather than a stub.

const std = @import("std");

pub const OSErr = i16;

pub const noErr: OSErr = 0;
pub const memFullErr: OSErr = -108;
pub const nilHandleErr: OSErr = -109;

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "NewHandle", &newHandle },
        .{ "DisposeHandle", &disposeHandle },
        .{ "GetHandleSize", &getHandleSize },
        .{ "SetHandleSize", &setHandleSize },
        .{ "HLock", &hLock },
        .{ "HLockHi", &hLock },
        .{ "TempNewHandle", &tempNewHandle },
        .{ "TempDisposeHandle", &tempDisposeHandle },
        .{ "TempHLock", &tempHLock },
        .{ "NewPtr", &newPtr },
        .{ "DisposePtr", &disposePtr },
        .{ "MemError", &memError },
        .{ "CompactMem", &compactMem },
        .{ "PurgeMem", &purgeMem },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

/// What a `Handle` points at. The block pointer comes first because that is the whole contract: the
/// game reads `**h` to reach the bytes, and never looks past it.
pub const Master = extern struct {
    block: ?[*]u8,
    size: usize,
};

pub const Handle = *Master;

/// The Memory Manager reports failures through a separate call, so the last result is kept. It is
/// per-process rather than per-thread, exactly as the original was.
var last_error: OSErr = noErr;

pub fn memError() callconv(.c) OSErr {
    return last_error;
}

extern fn malloc(size: usize) ?*anyopaque;
extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

pub fn newHandle(size: i32) callconv(.c) ?Handle {
    const want: usize = @intCast(@max(size, 0));
    const master: *Master = @ptrCast(@alignCast(malloc(@sizeOf(Master)) orelse {
        last_error = memFullErr;
        return null;
    }));
    // A zero-length handle is legal and not the same as a null one, so it still gets a block.
    const block = malloc(@max(want, 1)) orelse {
        free(master);
        last_error = memFullErr;
        return null;
    };
    master.* = .{ .block = @ptrCast(block), .size = want };
    last_error = noErr;
    return master;
}

pub fn disposeHandle(h: ?Handle) callconv(.c) void {
    const master = h orelse {
        last_error = nilHandleErr;
        return;
    };
    free(master.block);
    free(master);
    last_error = noErr;
}

pub fn getHandleSize(h: ?Handle) callconv(.c) i32 {
    const master = h orelse {
        last_error = nilHandleErr;
        return 0;
    };
    last_error = noErr;
    return @intCast(master.size);
}

pub fn setHandleSize(h: ?Handle, size: i32) callconv(.c) void {
    const master = h orelse {
        last_error = nilHandleErr;
        return;
    };
    const want: usize = @intCast(@max(size, 0));
    const block = realloc(master.block, @max(want, 1)) orelse {
        last_error = memFullErr;
        return;
    };
    master.block = @ptrCast(block);
    master.size = want;
    last_error = noErr;
}

/// Locking pins a block against a heap compaction that cannot happen here, so every block is already
/// in the state the caller is asking for.
pub fn hLock(h: ?Handle) callconv(.c) void {
    last_error = if (h == null) nilHandleErr else noErr;
}

/// The temporary-memory calls allocated out of the system heap rather than the application's, which
/// is a distinction one address space does not have. They report through an out-parameter instead of
/// `MemError`, and that is the only real difference.
pub fn tempNewHandle(size: i32, resultCode: ?*OSErr) callconv(.c) ?Handle {
    const h = newHandle(size);
    if (resultCode) |r| r.* = last_error;
    return h;
}

pub fn tempDisposeHandle(h: ?Handle, resultCode: ?*OSErr) callconv(.c) void {
    disposeHandle(h);
    if (resultCode) |r| r.* = last_error;
}

pub fn tempHLock(h: ?Handle, resultCode: ?*OSErr) callconv(.c) void {
    hLock(h);
    if (resultCode) |r| r.* = last_error;
}

pub fn newPtr(size: i32) callconv(.c) ?*anyopaque {
    const p = malloc(@intCast(@max(size, 1)));
    last_error = if (p == null) memFullErr else noErr;
    return p;
}

pub fn disposePtr(p: ?*anyopaque) callconv(.c) void {
    free(p);
    last_error = noErr;
}

/// How large a contiguous block the heap could produce after compacting it. Nothing is fragmented
/// here and nothing moves, so the answer is however much was asked for.
pub fn compactMem(cbNeeded: i32) callconv(.c) i32 {
    last_error = noErr;
    return cbNeeded;
}

/// Evicting purgeable blocks to make room. Nothing here is marked purgeable.
pub fn purgeMem(cbNeeded: i32) callconv(.c) void {
    _ = cbNeeded;
    last_error = noErr;
}

const testing = std.testing;

test "a handle is a master pointer the game dereferences twice" {
    const h = newHandle(64).?;
    defer disposeHandle(h);

    try testing.expectEqual(noErr, memError());
    try testing.expectEqual(@as(i32, 64), getHandleSize(h));
    // The block pointer has to be the first word, because `**h` is how the game reaches the bytes.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Master, "block"));
    const via_handle: *const ?[*]u8 = @ptrCast(@alignCast(h));
    try testing.expectEqual(h.block, via_handle.*);

    // Writing through the handle and reading it back is the only property that matters.
    h.block.?[0] = 0xd2;
    h.block.?[63] = 0x14;
    try testing.expectEqual(@as(u8, 0xd2), h.block.?[0]);
    try testing.expectEqual(@as(u8, 0x14), h.block.?[63]);
}

test "resizing keeps the contents and the reported size" {
    const h = newHandle(4).?;
    defer disposeHandle(h);
    h.block.?[0] = 0xab;

    setHandleSize(h, 4096);
    try testing.expectEqual(noErr, memError());
    try testing.expectEqual(@as(i32, 4096), getHandleSize(h));
    try testing.expectEqual(@as(u8, 0xab), h.block.?[0]);

    // A zero-length handle is legal, and it still has a block.
    const empty = newHandle(0).?;
    defer disposeHandle(empty);
    try testing.expectEqual(@as(i32, 0), getHandleSize(empty));
    try testing.expect(empty.block != null);
}

test "a null handle is an error the Memory Manager reports rather than a crash" {
    try testing.expectEqual(@as(i32, 0), getHandleSize(null));
    try testing.expectEqual(nilHandleErr, memError());
    setHandleSize(null, 16);
    try testing.expectEqual(nilHandleErr, memError());
    disposeHandle(null);
    try testing.expectEqual(nilHandleErr, memError());
    hLock(null);
    try testing.expectEqual(nilHandleErr, memError());

    // And the temporary-memory pair reports the same thing through its out-parameter.
    var err: OSErr = 12345;
    tempDisposeHandle(null, &err);
    try testing.expectEqual(nilHandleErr, err);
    const h = tempNewHandle(8, &err);
    try testing.expectEqual(noErr, err);
    tempDisposeHandle(h, &err);
    try testing.expectEqual(noErr, err);
}

test "a pointer is malloc, and compaction reports what was asked for" {
    const p = newPtr(128).?;
    try testing.expectEqual(noErr, memError());
    disposePtr(p);
    disposePtr(null); // free(NULL) is defined, and so is this.

    try testing.expectEqual(@as(i32, 4096), compactMem(4096));
    purgeMem(4096);
    try testing.expectEqual(noErr, memError());
}

test "the locking calls all resolve, since nothing here moves a block" {
    try testing.expectEqual(address("HLock"), address("HLockHi"));
    try testing.expect(address("NewHandle") != null);
    // `HUnlock` is not imported, so it is not answered either.
    try testing.expectEqual(@as(?usize, null), address("HUnlock"));
    // The Resource Manager's handles are not this package's business.
    try testing.expectEqual(@as(?usize, null), address("GetResource"));
}
