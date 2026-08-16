//! The Mach imports: identity, the monotonic clock, virtual memory, and the crash handler.
//!
//! Identity and time have honest Linux equivalents: a thread's Mach port name is process-unique
//! (same as a tid; task/host ports are fixed small names, so constants fit), and
//! `mach_absolute_time` is a monotonic tick count whose `mach_timebase_info` unit is declared
//! 1/1 nanoseconds, i.e. CLOCK_MONOTONIC.
//!
//! `vm_allocate`/`vm_deallocate`/`vm_protect` are mmap/munmap/mprotect with reordered args, plus
//! page rounding (Mach rounds out to whole pages, Linux rejects misaligned ranges). Everything
//! else is Fog's crash handler asking for Mach exception ports; it fails on purpose since there's
//! no Mach IPC here and a faked success would leave the game believing in a handler that never runs.

const std = @import("std");
const builtin = @import("builtin");

pub const kern_return_t = c_int;
pub const mach_port_t = u32;

pub const KERN_SUCCESS: kern_return_t = 0;
pub const KERN_INVALID_ADDRESS: kern_return_t = 1;
pub const KERN_PROTECTION_FAILURE: kern_return_t = 2;
pub const KERN_NO_SPACE: kern_return_t = 3;
pub const KERN_INVALID_ARGUMENT: kern_return_t = 4;
pub const KERN_FAILURE: kern_return_t = 5;

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "mach_task_self_", &mach_task_self_ },
        .{ "mach_thread_self", &threadSelf },
        .{ "mach_host_self", &hostSelf },
        .{ "mach_absolute_time", &absoluteTime },
        .{ "mach_timebase_info", &timebaseInfo },
        .{ "host_page_size", &hostPageSize },
        .{ "vm_allocate", &vmAllocate },
        .{ "vm_deallocate", &vmDeallocate },
        .{ "vm_protect", &vmProtect },
        .{ "mach_vm_region", &machVmRegion },
        .{ "task_threads", &taskThreads },
        .{ "thread_suspend", &threadSuspend },
        .{ "thread_resume", &threadResume },
        .{ "mach_port_allocate", &portAllocate },
        .{ "mach_port_insert_right", &portInsertRight },
        .{ "task_get_exception_ports", &taskGetExceptionPorts },
        .{ "task_set_exception_ports", &taskSetExceptionPorts },
        .{ "thread_set_exception_ports", &threadSetExceptionPorts },
        .{ "thread_get_state", &threadGetState },
        .{ "thread_set_state", &threadSetState },
        .{ "mach_msg", &machMsg },
        .{ "mach_msg_server", &machMsgServer },
        .{ "exception_raise", &exceptionRaise },
        .{ "exception_raise_state", &exceptionRaiseState },
        .{ "exception_raise_state_identity", &exceptionRaiseStateIdentity },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

// identity

/// Data, not a function: `mach_task_self()` is a macro over this variable, so the image binds a
/// pointer straight at it. Any non-null name will do, because nothing here dereferences a port.
pub var mach_task_self_: mach_port_t = 0x0103;

const host_port: mach_port_t = 0x0203;

const hostThreadId = switch (builtin.os.tag) {
    .linux => struct {
        fn get() u32 {
            return @bitCast(std.os.linux.gettid());
        }
    }.get,
    else => struct {
        extern fn pthread_mach_thread_np(thread: std.c.pthread_t) mach_port_t;
        fn get() u32 {
            return pthread_mach_thread_np(std.c.pthread_self());
        }
    }.get,
};

/// MACH_PORT_NULL is 0, so a caller reads a zero as "no thread". A tid is never 0.
pub fn threadSelf() callconv(.c) mach_port_t {
    const tid = hostThreadId();
    return if (tid == 0) mach_task_self_ else tid;
}

pub fn hostSelf() callconv(.c) mach_port_t {
    return host_port;
}

// time

/// Darwin's `mach_timebase_info_data_t`: the ratio that turns absolute ticks into nanoseconds.
pub const TimebaseInfo = extern struct { numer: u32, denom: u32 };

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn absoluteTime() callconv(.c) u64 {
    return monotonicNs();
}

/// 1/1, because absoluteTime() already counts nanoseconds. Anything else would need the two to
/// agree on a made-up unit for no gain.
pub fn timebaseInfo(info: ?*TimebaseInfo) callconv(.c) kern_return_t {
    const out = info orelse return KERN_INVALID_ARGUMENT;
    out.* = .{ .numer = 1, .denom = 1 };
    return KERN_SUCCESS;
}

// virtual memory

const PROT = struct {
    const READ: c_int = 1;
    const WRITE: c_int = 2;
    const EXEC: c_int = 4;
};

/// MAP_PRIVATE and MAP_FIXED happen to agree between the two platforms. MAP_ANONYMOUS does not.
const MAP = struct {
    const PRIVATE: c_int = 0x02;
    const FIXED: c_int = 0x10;
    const ANONYMOUS: c_int = if (builtin.os.tag == .linux) 0x20 else 0x1000;
};

const VM_FLAGS_ANYWHERE: c_int = 0x0001;

/// VM_PROT_READ/WRITE/EXECUTE are 1/2/4, the same three bits PROT_* uses. The rest of the field is
/// Mach-only — VM_PROT_NO_CHANGE 0x08 and VM_PROT_COPY 0x10, which mach_override sets — and has no
/// Linux meaning, so it is masked off rather than passed on as a bogus protection.
fn hostProt(vm_prot: c_int) c_int {
    return vm_prot & (PROT.READ | PROT.WRITE | PROT.EXEC);
}

extern fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern fn munmap(addr: ?*anyopaque, len: usize) c_int;
extern fn mprotect(addr: ?*anyopaque, len: usize, prot: c_int) c_int;
extern fn getpagesize() c_int;

const map_failed = ~@as(usize, 0);

/// `address` is in/out: the hint on the way in when `flags` does not say anywhere, the result on the
/// way out. Mach zero-fills what it hands back, and so does an anonymous mapping.
pub fn vmAllocate(task: mach_port_t, addr: ?*usize, size: usize, flags: c_int) callconv(.c) kern_return_t {
    _ = task;
    const out = addr orelse return KERN_INVALID_ARGUMENT;
    if (size == 0) return KERN_INVALID_ARGUMENT;

    const anywhere = flags & VM_FLAGS_ANYWHERE != 0;
    const hint: ?*anyopaque = if (anywhere) null else @ptrFromInt(out.*);
    const map_flags = MAP.PRIVATE | MAP.ANONYMOUS | @as(c_int, if (anywhere) 0 else MAP.FIXED);

    const p = mmap(hint, size, PROT.READ | PROT.WRITE, map_flags, -1, 0) orelse return KERN_NO_SPACE;
    if (@intFromPtr(p) == map_failed) return KERN_NO_SPACE;
    out.* = @intFromPtr(p);
    return KERN_SUCCESS;
}

pub fn vmDeallocate(task: mach_port_t, addr: usize, size: usize) callconv(.c) kern_return_t {
    _ = task;
    // Mach treats an empty range as nothing to do; munmap calls it EINVAL.
    if (size == 0) return KERN_SUCCESS;
    return if (munmap(@ptrFromInt(addr), size) == 0) KERN_SUCCESS else KERN_INVALID_ADDRESS;
}

/// `set_maximum` asks for the ceiling rather than the current protection, which Linux fixes at map
/// time and cannot raise afterwards. The current protection is the only one there is here, so both
/// forms set it — a caller raising the ceiling then raising the protection gets what it wanted.
pub fn vmProtect(
    task: mach_port_t,
    addr: usize,
    size: usize,
    set_maximum: c_int,
    new_protection: c_int,
) callconv(.c) kern_return_t {
    _ = task;
    _ = set_maximum;
    if (size == 0) return KERN_SUCCESS;

    const r = pageRange(addr, size) orelse return KERN_INVALID_ADDRESS;
    return if (mprotect(@ptrFromInt(r.start), r.len, hostProt(new_protection)) == 0)
        KERN_SUCCESS
    else
        KERN_PROTECTION_FAILURE;
}

const PageRange = struct { start: usize, len: usize };

/// Mach rounds a range out to whole pages; mprotect rejects one that is not already aligned. The
/// callers that matter here hand over a function address and a handful of bytes.
fn pageRange(addr: usize, size: usize) ?PageRange {
    const page: usize = @intCast(getpagesize());
    const start = std.mem.alignBackward(usize, addr, page);
    const end_unaligned = std.math.add(usize, addr, size) catch return null;
    const end = std.mem.alignForward(usize, end_unaligned, page);
    if (end < start) return null;
    return .{ .start = start, .len = end - start };
}

/// The addresses are 64-bit even in a 32-bit task, which is the whole point of the `mach_vm_` family.
/// Answering it needs /proc/self/maps and a region model this process has no other use for, so it
/// fails: the caller asked what the kernel thinks of an address, and here the answer is unknown.
pub fn machVmRegion(
    task: mach_port_t,
    addr: ?*u64,
    size: ?*u64,
    flavor: c_int,
    info: ?*anyopaque,
    info_count: ?*u32,
    object_name: ?*mach_port_t,
) callconv(.c) kern_return_t {
    _ = .{ task, addr, size, flavor, info, info_count, object_name };
    return KERN_INVALID_ADDRESS;
}

// the crash handler, deliberately unavailable

/// Enumerating threads by port is only useful to something that will then act on them through Mach,
/// which nothing here can do.
pub fn taskThreads(task: mach_port_t, list: ?*?[*]mach_port_t, count: ?*u32) callconv(.c) kern_return_t {
    _ = .{ task, list };
    if (count) |c| c.* = 0;
    return KERN_FAILURE;
}

pub fn threadSuspend(thread: mach_port_t) callconv(.c) kern_return_t {
    _ = thread;
    return KERN_FAILURE;
}

pub fn threadResume(thread: mach_port_t) callconv(.c) kern_return_t {
    _ = thread;
    return KERN_FAILURE;
}

/// A port with no IPC behind it is a number the caller would then send messages to. Failing here is
/// what stops the exception-port dance at its first step rather than three calls later.
pub fn portAllocate(task: mach_port_t, right: c_int, name: ?*mach_port_t) callconv(.c) kern_return_t {
    _ = .{ task, right };
    if (name) |n| n.* = 0;
    return KERN_FAILURE;
}

pub fn portInsertRight(task: mach_port_t, name: mach_port_t, poly: mach_port_t, poly_type: c_int) callconv(.c) kern_return_t {
    _ = .{ task, name, poly, poly_type };
    return KERN_FAILURE;
}

/// The old handler the caller would restore on the way out. Reporting none is both true and the
/// answer that leaves nothing for it to restore.
pub fn taskGetExceptionPorts(
    task: mach_port_t,
    mask: u32,
    masks: ?[*]u32,
    count: ?*u32,
    old_handlers: ?[*]mach_port_t,
    old_behaviors: ?[*]c_int,
    old_flavors: ?[*]c_int,
) callconv(.c) kern_return_t {
    _ = .{ task, mask, masks, old_handlers, old_behaviors, old_flavors };
    if (count) |c| c.* = 0;
    return KERN_SUCCESS;
}

pub fn taskSetExceptionPorts(
    task: mach_port_t,
    mask: u32,
    new_port: mach_port_t,
    behavior: c_int,
    flavor: c_int,
) callconv(.c) kern_return_t {
    _ = .{ task, mask, new_port, behavior, flavor };
    return KERN_FAILURE;
}

pub fn threadSetExceptionPorts(
    thread: mach_port_t,
    mask: u32,
    new_port: mach_port_t,
    behavior: c_int,
    flavor: c_int,
) callconv(.c) kern_return_t {
    _ = .{ thread, mask, new_port, behavior, flavor };
    return KERN_FAILURE;
}

/// Reading another thread's registers is ptrace territory on Linux, and the caller only wants them
/// to write a crash report for a crash this process reports through its own panic path instead.
pub fn threadGetState(
    thread: mach_port_t,
    flavor: c_int,
    state: ?[*]u32,
    count: ?*u32,
) callconv(.c) kern_return_t {
    _ = .{ thread, flavor, state };
    if (count) |c| c.* = 0;
    return KERN_FAILURE;
}

pub fn threadSetState(thread: mach_port_t, flavor: c_int, state: ?[*]const u32, count: u32) callconv(.c) kern_return_t {
    _ = .{ thread, flavor, state, count };
    return KERN_FAILURE;
}

/// MACH_SEND_INVALID_DEST. Not a kern_return_t at all — mach_msg returns mach_msg_return_t, and this
/// is the code for "the port you are sending to is not one", which is precisely true of every port
/// this file hands out.
const MACH_SEND_INVALID_DEST: c_int = 0x1000000d;

pub fn machMsg(
    msg: ?*anyopaque,
    option: c_int,
    send_size: u32,
    rcv_size: u32,
    rcv_name: mach_port_t,
    timeout: u32,
    notify: mach_port_t,
) callconv(.c) c_int {
    _ = .{ msg, option, send_size, rcv_size, rcv_name, timeout, notify };
    return MACH_SEND_INVALID_DEST;
}

/// Normally never returns: it is the exception thread's receive loop. Returning ends that thread,
/// which is the right outcome when there is nothing for it to receive.
pub fn machMsgServer(demux: ?*const anyopaque, max_size: u32, rcv_name: mach_port_t, options: c_int) callconv(.c) c_int {
    _ = .{ demux, max_size, rcv_name, options };
    return MACH_SEND_INVALID_DEST;
}

pub fn exceptionRaise(port: mach_port_t, thread: mach_port_t, task: mach_port_t, kind: c_int, code: ?[*]const u32, code_count: u32) callconv(.c) kern_return_t {
    _ = .{ port, thread, task, kind, code, code_count };
    return KERN_FAILURE;
}

pub fn exceptionRaiseState(port: mach_port_t, kind: c_int, code: ?[*]const u32, code_count: u32, flavor: ?*c_int, in_state: ?[*]const u32, in_count: u32, out_state: ?[*]u32, out_count: ?*u32) callconv(.c) kern_return_t {
    _ = .{ port, kind, code, code_count, flavor, in_state, in_count, out_state };
    if (out_count) |c| c.* = 0;
    return KERN_FAILURE;
}

pub fn exceptionRaiseStateIdentity(port: mach_port_t, thread: mach_port_t, task: mach_port_t, kind: c_int, code: ?[*]const u32, code_count: u32, flavor: ?*c_int, in_state: ?[*]const u32, in_count: u32, out_state: ?[*]u32, out_count: ?*u32) callconv(.c) kern_return_t {
    _ = .{ port, thread, task, kind, code, code_count, flavor, in_state, in_count, out_state };
    if (out_count) |c| c.* = 0;
    return KERN_FAILURE;
}

// page size

pub fn hostPageSize(host: mach_port_t, out: ?*usize) callconv(.c) kern_return_t {
    _ = host;
    const p = out orelse return KERN_INVALID_ARGUMENT;
    p.* = @intCast(getpagesize());
    return KERN_SUCCESS;
}

const testing = std.testing;

extern fn usleep(usec: u32) c_int;

test "every provided name has a live address and nothing else does" {
    for ([_][]const u8{
        "mach_task_self_",            "mach_thread_self",          "mach_host_self",
        "mach_absolute_time",         "mach_timebase_info",        "host_page_size",
        "vm_allocate",                "vm_deallocate",             "vm_protect",
        "mach_vm_region",             "task_threads",              "thread_suspend",
        "thread_resume",              "mach_port_allocate",        "mach_port_insert_right",
        "task_get_exception_ports",   "task_set_exception_ports",  "thread_set_exception_ports",
        "thread_get_state",           "thread_set_state",          "mach_msg",
        "mach_msg_server",            "exception_raise",           "exception_raise_state",
        "exception_raise_state_identity",
    }) |n| try testing.expect(address(n).? != 0);

    // The trailing underscore is part of the name; `mach_task_self` alone is a macro and never binds.
    try testing.expectEqual(@as(?usize, null), address("mach_task_self"));
    try testing.expectEqual(@as(?usize, null), address("mach_port_deallocate"));
}

test "the identity ports are distinct and never null" {
    const t = threadSelf();
    try testing.expect(t != 0);
    try testing.expect(hostSelf() != 0);
    try testing.expect(mach_task_self_ != 0);
    try testing.expect(hostSelf() != mach_task_self_);

    // Same thread, same name; another thread, another name.
    try testing.expectEqual(t, threadSelf());

    const Other = struct {
        fn run(out: *mach_port_t) void {
            out.* = threadSelf();
        }
    };
    var other: mach_port_t = 0;
    const th = try std.Thread.spawn(.{}, Other.run, .{&other});
    th.join();
    try testing.expect(other != 0);
    try testing.expect(other != t);
}

test "absolute time counts nanoseconds forward at a 1/1 timebase" {
    var tb: TimebaseInfo = undefined;
    try testing.expectEqual(KERN_SUCCESS, timebaseInfo(&tb));
    try testing.expectEqual(@as(u32, 1), tb.numer);
    try testing.expectEqual(@as(u32, 1), tb.denom);
    try testing.expectEqual(KERN_INVALID_ARGUMENT, timebaseInfo(null));

    const before = absoluteTime();
    _ = usleep(2_000);
    const after = absoluteTime();
    try testing.expect(after > before);
    // If the unit were anything but nanoseconds this window would be out by three orders of magnitude.
    try testing.expect(after - before >= std.time.ns_per_ms);
    try testing.expect(after - before < std.time.ns_per_s);
}

test "vm_allocate hands back zeroed pages and vm_deallocate gives them up" {
    var addr: usize = 0;
    try testing.expectEqual(KERN_SUCCESS, vmAllocate(mach_task_self_, &addr, 8192, VM_FLAGS_ANYWHERE));
    try testing.expect(addr != 0);

    const p: [*]u8 = @ptrFromInt(addr);
    for (p[0..8192]) |b| try testing.expectEqual(@as(u8, 0), b);
    p[0] = 0x42;
    try testing.expectEqual(@as(u8, 0x42), p[0]);

    try testing.expectEqual(KERN_SUCCESS, vmDeallocate(mach_task_self_, addr, 8192));
    // An empty range is nothing to do, not an error, and a null out-pointer is not a place to write.
    try testing.expectEqual(KERN_SUCCESS, vmDeallocate(mach_task_self_, addr, 0));
    try testing.expectEqual(KERN_INVALID_ARGUMENT, vmAllocate(mach_task_self_, null, 4096, VM_FLAGS_ANYWHERE));
    try testing.expectEqual(KERN_INVALID_ARGUMENT, vmAllocate(mach_task_self_, &addr, 0, VM_FLAGS_ANYWHERE));
}

test "vm_protect rounds an unaligned range out to whole pages" {
    const page: usize = @intCast(getpagesize());

    var addr: usize = 0;
    try testing.expectEqual(KERN_SUCCESS, vmAllocate(mach_task_self_, &addr, 2 * page, VM_FLAGS_ANYWHERE));
    defer _ = vmDeallocate(mach_task_self_, addr, 2 * page);

    // What mach_override does: a function address partway into a page, and a handful of bytes of
    // it. An unrounded mprotect would fail this with EINVAL. Read-write rather than the RWX
    // mach_override asks for, because a W^X host refuses that for reasons of its own.
    const unaligned = addr + 37;
    try testing.expectEqual(KERN_SUCCESS, vmProtect(mach_task_self_, unaligned, 8, 0, 1 | 2));

    const r = pageRange(unaligned, 8).?;
    try testing.expectEqual(addr, r.start);
    try testing.expectEqual(page, r.len);

    // A range straddling the page boundary rounds out to both pages.
    try testing.expectEqual(@as(usize, 2 * page), pageRange(page - 1, 2).?.len);
    try testing.expectEqual(@as(?PageRange, null), pageRange(addr, ~@as(usize, 0)));

    // Read-only means read-only, and putting it back means the deallocate below is safe.
    try testing.expectEqual(KERN_SUCCESS, vmProtect(mach_task_self_, addr, page, 0, 1));
    try testing.expectEqual(KERN_SUCCESS, vmProtect(mach_task_self_, addr, page, 0, 1 | 2));

    // The Mach-only bits are masked off rather than handed to mprotect as a protection.
    try testing.expectEqual(@as(c_int, 7), hostProt(7 | 0x10));
    try testing.expectEqual(@as(c_int, 0), hostProt(0x08));
    try testing.expectEqual(KERN_SUCCESS, vmProtect(mach_task_self_, addr, page, 0, 1 | 2 | 0x10));

    // An empty range is a no-op, not a failure.
    try testing.expectEqual(KERN_SUCCESS, vmProtect(mach_task_self_, addr, 0, 0, 1));
}

test "host_page_size reports the host's page" {
    var size: usize = 0;
    try testing.expectEqual(KERN_SUCCESS, hostPageSize(hostSelf(), &size));
    try testing.expectEqual(@as(usize, @intCast(getpagesize())), size);
    try testing.expect(std.math.isPowerOfTwo(size));
    try testing.expectEqual(KERN_INVALID_ARGUMENT, hostPageSize(hostSelf(), null));
}

test "the crash-handler calls fail and clear their out-counts" {
    var count: u32 = 0xdead;
    try testing.expectEqual(KERN_FAILURE, taskThreads(mach_task_self_, null, &count));
    try testing.expectEqual(@as(u32, 0), count);

    count = 0xdead;
    try testing.expectEqual(KERN_FAILURE, threadGetState(threadSelf(), 1, null, &count));
    try testing.expectEqual(@as(u32, 0), count);

    var port: mach_port_t = 0xdead;
    try testing.expectEqual(KERN_FAILURE, portAllocate(mach_task_self_, 1, &port));
    try testing.expectEqual(@as(mach_port_t, 0), port);

    try testing.expectEqual(KERN_FAILURE, taskSetExceptionPorts(mach_task_self_, 0xffff, 0, 1, 1));
    try testing.expectEqual(KERN_FAILURE, threadSetExceptionPorts(threadSelf(), 0xffff, 0, 1, 1));
    try testing.expectEqual(KERN_FAILURE, threadSuspend(threadSelf()));
    try testing.expectEqual(KERN_FAILURE, threadResume(threadSelf()));
    try testing.expectEqual(KERN_INVALID_ADDRESS, machVmRegion(mach_task_self_, null, null, 9, null, null, null));
    try testing.expect(machMsg(null, 0, 0, 0, 0, 0, 0) != KERN_SUCCESS);
    try testing.expect(machMsgServer(null, 0, 0, 0) != KERN_SUCCESS);

    // Querying the installed handler succeeds and reports none, so the caller has nothing to restore.
    count = 0xdead;
    try testing.expectEqual(KERN_SUCCESS, taskGetExceptionPorts(mach_task_self_, 0xffff, null, &count, null, null, null));
    try testing.expectEqual(@as(u32, 0), count);
}
