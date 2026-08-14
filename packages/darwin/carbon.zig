//! The Carbon Process Manager, and the two toolbox calls that stand next to it on the boot path.
//!
//! A headless server has no business in Carbon at all, so nothing is here speculatively. The process
//! calls are here because the game reaches them: a StormMac constructor and `PreInitApplication`
//! itself both ask who they are before doing anything else, and there is no way past that question.
//!
//! All of them have an honest answer for a process with no windowing session. A serial number is an
//! identity, and this process has exactly one to give. `TransformProcessType` and `SetFrontProcess`
//! move an application between the Dock and the background and put it in front — a process with no
//! Dock and no front is already where they would put it, so reporting success is describing the
//! state, not faking it. `GetProcessInformation` and `GetProcessBundleLocation` are asked where the
//! application lives, and the File Manager's volume root is that answer.
//!
//! `GetNewMBar` and `AEInstallEventHandler` are the two the caller already treats as optional: the
//! whole menu block sits behind `if (GetNewMBar(...) != 0)` and the Apple Event results are dropped
//! on the floor. Reporting "no menu bar" is therefore a supported outcome rather than a stub that
//! lies, and it is why no Menu Manager exists here.
//!
//! The clocks and the event pump are the opposite case, and the reason they are here at all: an
//! import whose entire job is to produce a value or to consume time cannot be answered with a bare
//! zero. `Microseconds` and `TickCount` read as stopped clocks rather than absent ones, and
//! `WaitNextEvent` returning without writing its record leaves the caller reading uninitialised
//! stack — which is how a loop that intended to idle ends up spinning a core instead.

const std = @import("std");
const files = @import("files.zig");

/// Carbon's 16-bit error type. Its 32-bit sibling, OSStatus, is the newer calls' return type.
pub const OSErr = i16;
pub const OSStatus = i32;

pub const noErr: OSStatus = 0;

/// Address of a normalised import name, or null if this package does not provide it.
pub fn address(name: []const u8) ?usize {
    const table = .{
        .{ "GetCurrentProcess", &getCurrentProcess },
        .{ "TransformProcessType", &transformProcessType },
        .{ "SetFrontProcess", &setFrontProcess },
        .{ "GetProcessInformation", &getProcessInformation },
        .{ "GetProcessBundleLocation", &getProcessBundleLocation },
        .{ "GetNewMBar", &getNewMBar },
        .{ "AEInstallEventHandler", &aeInstallEventHandler },
        .{ "SetEventMask", &setEventMask },
        .{ "FlushEvents", &flushEvents },
        .{ "InitCursor", &initCursor },
        .{ "Microseconds", &microseconds },
        .{ "TickCount", &tickCount },
        .{ "WaitNextEvent", &waitNextEvent },
        .{ "EventAvail", &eventAvail },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromPtr(entry[1]);
    }
    return null;
}

/// Two longs, high word first in the struct and meaningless on their own: a PSN is only ever
/// compared or passed back, never taken apart.
pub const ProcessSerialNumber = extern struct { high: u32, low: u32 };

/// `kCurrentProcess`. Real Carbon hands back a live serial number here; this one is the constant
/// that already means "the process asking", which is the only process this file knows about.
pub const kCurrentProcess: u32 = 2;

pub fn getCurrentProcess(psn: ?*ProcessSerialNumber) callconv(.c) OSErr {
    const out = psn orelse return -50; // paramErr
    out.* = .{ .high = 0, .low = kCurrentProcess };
    return 0;
}

/// Foreground, background, or UI element. There is no session to move between, so the request is
/// already satisfied however it was asked.
pub fn transformProcessType(psn: ?*const ProcessSerialNumber, kind: OSStatus) callconv(.c) OSStatus {
    _ = .{ psn, kind };
    return noErr;
}

pub fn setFrontProcess(psn: ?*const ProcessSerialNumber) callconv(.c) OSErr {
    _ = psn;
    return 0;
}

/// Sixty bytes, and the caller fills in `processInfoLength` and the two out-pointers before calling.
/// `processAppSpec` is the field the boot path is really after: `FLAMINGLOGO_SetWorkingDirectory`
/// takes its `parID` and chdir's there, which is how the game finds its own data.
/// The three pointer fields are held as 32-bit words rather than Zig pointers so the record is the
/// game's 60 bytes on any host, including the 64-bit one the tests run on.
pub const ProcessInfoRec = extern struct {
    processInfoLength: u32,
    processName: u32,
    processNumber: ProcessSerialNumber,
    processType: u32,
    processSignature: u32,
    processMode: u32,
    processLocation: u32,
    processSize: u32,
    processFreeMem: u32,
    processLauncher: ProcessSerialNumber,
    processLaunchDate: u32,
    processActiveTime: u32,
    processAppSpec: u32,
};

comptime {
    // The game passes 0x3c as processInfoLength and reads processAppSpec back out of offset 56, so
    // both are checked rather than assumed.
    std.debug.assert(@sizeOf(ProcessInfoRec) == 60);
    std.debug.assert(@offsetOf(ProcessInfoRec, "processSignature") == 20);
    std.debug.assert(@offsetOf(ProcessInfoRec, "processAppSpec") == 56);
}

/// The application's four-character creator code, as the Mac build's own resources carry it.
const app_signature: u32 = 0x4462_6c32; // 'Dbl2'

/// What the application is called on disk. There is no `.app` bundle in this process, and no caller
/// on the boot path opens this name — every one of them takes the containing directory instead — so
/// the leaf exists to make the spec well formed rather than to be resolved.
const app_name = "Diablo II";

/// The application file, as a path under the File Manager's volume root.
fn appPath(buf: []u8) []const u8 {
    const dir = files.dirPath(files.root_dir_id);
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 ..][0..app_name.len], app_name);
    return buf[0 .. dir.len + 1 + app_name.len];
}

pub fn getProcessInformation(psn: ?*const ProcessSerialNumber, info: ?*ProcessInfoRec) callconv(.c) OSErr {
    _ = psn;
    const out = info orelse return -50;
    out.processNumber = .{ .high = 0, .low = kCurrentProcess };
    out.processSignature = app_signature;
    if (out.processName != 0) {
        // Str255: a length byte and then the characters, no terminator.
        const name: [*]u8 = @ptrFromInt(out.processName);
        name[0] = app_name.len;
        @memcpy(name[1..][0..app_name.len], app_name);
    }
    if (out.processAppSpec != 0) {
        const spec: *files.FSSpec = @ptrFromInt(out.processAppSpec);
        var buf: [1024]u8 = undefined;
        files.specForPath(spec, appPath(&buf));
    }
    return 0;
}

pub fn getProcessBundleLocation(psn: ?*const ProcessSerialNumber, location: ?*files.FSRef) callconv(.c) OSErr {
    _ = psn;
    var buf: [1024]u8 = undefined;
    return files.refForPath(location orelse return -50, appPath(&buf));
}

/// A menu bar resource. There is no Resource Manager and no menu bar, and the caller asks in a form
/// that already allows for that: every menu call it would go on to make is inside the `!= 0` branch
/// this refuses to enter.
pub fn getNewMBar(menuBarID: i16) callconv(.c) ?*anyopaque {
    _ = menuBarID;
    return null;
}

/// Apple Events arrive over a Mach port this process does not have, so no handler installed here
/// could ever be called. The caller ignores all three results, which is what makes saying so
/// truthful rather than a silent failure.
pub fn aeInstallEventHandler(
    theAEEventClass: u32,
    theAEEventID: u32,
    handler: ?*anyopaque,
    handlerRefcon: u32,
    isSysHandler: u8,
) callconv(.c) OSErr {
    _ = .{ theAEEventClass, theAEEventID, handler, handlerRefcon, isSysHandler };
    return 0;
}

/// Which classic event types the Event Manager should queue. Nothing queues events here.
pub fn setEventMask(value: i16) callconv(.c) void {
    _ = value;
}

/// Discarding the events of the given types from a queue that is always empty.
pub fn flushEvents(whichMask: i16, stopMask: i16) callconv(.c) void {
    _ = .{ whichMask, stopMask };
}

/// Setting the cursor to the arrow. There is no cursor and no screen to put one on.
pub fn initCursor() callconv(.c) void {}

/// Carbon's 64-bit unsigned, low word first on a little-endian Mac.
pub const UnsignedWide = extern struct { lo: u32, hi: u32 };

/// The one toolbox call with no honest zero answer. A clock that always reads zero is not a clock
/// that is merely absent — every elapsed time computed from it is zero, and the game's bounded waits
/// (`SYSTEM_WaitWithTimeout` sleeps until 250 ms have passed) never end. It hung there.
///
/// Uptime, not wall clock: the game only ever subtracts two readings.
pub fn microseconds(out: ?*UnsignedWide) callconv(.c) void {
    const dest = out orelse return;
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &now) != 0) {
        dest.* = .{ .lo = 0, .hi = 0 };
        return;
    }
    const us: u64 = @as(u64, @intCast(now.sec)) *% 1_000_000 +% @as(u64, @intCast(now.nsec)) / 1000;
    dest.* = .{ .lo = @truncate(us), .hi = @truncate(us >> 32) };
}

/// Sixtieths of a second since boot. The same reasoning as `Microseconds`: a tick count frozen at
/// zero is not a missing clock but a wrong one, and it is the field every event is stamped with.
pub fn tickCount() callconv(.c) u32 {
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &now) != 0) return 0;
    const ticks: u64 = @as(u64, @intCast(now.sec)) *% 60 +% @as(u64, @intCast(now.nsec)) / ns_per_tick;
    return @truncate(ticks);
}

/// A tick is a sixtieth of a second, the unit both `TickCount` and `WaitNextEvent`'s wait are in.
const ns_per_tick = 16_666_667;

pub const Point = extern struct { v: i16, h: i16 };

/// Classic 68k packing: sixteen bytes with nothing aligned past the first field, which is why every
/// field carries `align(1)`. The layout is the game's own, not a reference book's — the record is a
/// stack local in `MACSETUP_RunEventLoop`, which switches on `what` at offset 0 and passes `where`
/// at offset 10 straight to `FindWindow`.
pub const EventRecord = extern struct {
    what: u16 align(1),
    message: u32 align(1),
    when: u32 align(1),
    where: Point align(1),
    modifiers: u16 align(1),
};

comptime {
    std.debug.assert(@sizeOf(EventRecord) == 16);
    std.debug.assert(@offsetOf(EventRecord, "what") == 0);
    std.debug.assert(@offsetOf(EventRecord, "message") == 2);
    std.debug.assert(@offsetOf(EventRecord, "when") == 6);
    std.debug.assert(@offsetOf(EventRecord, "where") == 10);
    std.debug.assert(@offsetOf(EventRecord, "modifiers") == 14);
}

/// `nullEvent`, the queue-is-empty answer — and the one the event pump is watching for, since
/// `MACSETUP_RunEventLoop` returns only when `what` reads zero.
pub const null_event: u16 = 0;

/// The record every one of these calls exists to produce. Writing it is the whole contract: a
/// caller that got `false` back still reads `what`, so leaving the record untouched does not mean
/// "no event", it means whatever the stack happened to hold.
fn reportNullEvent(event: ?*EventRecord) void {
    const out = event orelse return;
    out.* = .{
        .what = null_event,
        .message = 0,
        .when = tickCount(),
        .where = .{ .v = 0, .h = 0 },
        .modifiers = 0,
    };
}

/// The call the event pump is built around, and the second import with no honest zero answer. The
/// generic thunk returns 0 without touching the record, and `MACSETUP_RunEventLoop` loops until
/// `what` is zero — so the pump's exit condition was reading uninitialised stack.
///
/// `sleep` is a tick budget: permission to block that long waiting for an event. Nothing in this
/// process can ever queue one, so the entire budget is spent rather than returned from — a call
/// that was asked to wait and came back instantly is the shape that turns a paced loop into a spin.
/// At `sleep == 0` the call is defined as non-blocking and must not add a delay of its own; the
/// callers that pass 0 do their own pacing (`UI_DISPLAY_RunEventLoop` sleeps out the rest of its
/// 40 ms frame, `CLIENTMODE_RunFrameLoop` sleeps 10 ms), and stalling here would throttle the game
/// loop instead of the idle one.
pub fn waitNextEvent(eventMask: u16, event: ?*EventRecord, sleep: u32, mouseRgn: ?*anyopaque) callconv(.c) u8 {
    _ = .{ eventMask, mouseRgn };
    if (sleep != 0) {
        _ = usleep(@intCast(@as(u64, sleep) * ns_per_tick / 1000));
        spin_run = 0;
    } else throttleIfSpinning();
    reportNullEvent(event);
    return 0;
}

/// Why a correct `WaitNextEvent` is still not enough to idle, and what this does about it.
///
/// The loops that drive this pump all pace themselves — `CLIENTMODE_RunFrameLoop` sleeps 10 ms per
/// frame, `UI_DISPLAY_RunEventLoop` sleeps out the remainder of a 40 ms one — so on paper there is
/// nothing here to fix. The menu loop never reaches its sleep. It sits in
/// `if (SEVENT_ProcessNextMessage(..) == 0)`, and the sleep is in the "no message" arm; Storm's
/// queue reports a message on every single pass, because a timer whose period has elapsed is
/// re-reported until something consumes it and nothing headless ever does. Measured, that loop ran
/// 1.15 million iterations a second, all of them through here, none of them reaching a sleep.
///
/// Fixing that where it actually lives means changing Storm's timer semantics, which is a much
/// larger and riskier change than the one symptom warrants. So the throttle goes here instead, and
/// the thing it must not do is throttle a loop that was pacing itself correctly — the game loop has
/// to stay fast. The tell is the gap between calls, not the fact that there was no event: a caller
/// that slept a frame comes back milliseconds later, a caller in a tight loop comes back in under a
/// microsecond. Only a run of the latter earns a sleep, and one paced call resets it.
///
/// Single-threaded state by construction: the event pump is the main thread's, and this is only
/// ever reached from it. A race would cost one extra millisecond of sleep, not correctness.
var last_call_us: u64 = 0;
var spin_run: u32 = 0;

/// Comfortably under the shortest frame any of the driving loops sleeps for (10 ms), so a paced
/// caller can never be mistaken for a spinning one.
const spin_gap_us = 2_000;

/// Long enough that a short burst — an asset loader draining the pump between reads — is not read
/// as a spin. At the rate the menu loop was measured at, a real spin crosses this in under a
/// millisecond.
const spin_calls = 256;

/// Once engaged this holds the pump at roughly a thousand passes a second instead of 1.15 million,
/// which is still far more responsive than the 25 fps the loop was aiming for.
const idle_sleep_us = 1_000;

fn throttleIfSpinning() void {
    var w: UnsignedWide = undefined;
    microseconds(&w);
    const now = @as(u64, w.hi) << 32 | w.lo;
    defer last_call_us = now;

    if (last_call_us == 0 or now -% last_call_us >= spin_gap_us) {
        spin_run = 0;
        return;
    }
    if (spin_run < spin_calls) {
        spin_run += 1;
        return;
    }
    // Deliberately left engaged: sleeping one millisecond means the next call arrives inside the
    // spin gap too, so a loop that is still not pacing itself stays throttled instead of
    // oscillating back to a spin every 256 passes.
    _ = usleep(idle_sleep_us);
}

/// Looking at the queue without consuming it. Never blocks, by definition, so the only thing it
/// owes the caller is the same filled-in record.
pub fn eventAvail(eventMask: u16, event: ?*EventRecord) callconv(.c) u8 {
    _ = eventMask;
    reportNullEvent(event);
    return 0;
}

extern fn usleep(usec: u32) c_int;

const testing = std.testing;

test "the process manager answers, and the file and resource managers do not" {
    for ([_][]const u8{
        "GetCurrentProcess",       "TransformProcessType", "SetFrontProcess",
        "GetProcessInformation",   "GetProcessBundleLocation",
        "GetNewMBar",              "AEInstallEventHandler", "SetEventMask",
    }) |n| {
        try testing.expect(address(n).? != 0);
    }
    // The File Manager has its own package, and the Resource Manager stays with the thunks: a menu
    // or a resource cannot be answered honestly from here.
    for ([_][]const u8{
        "FSpOpenResFile", "FSMakeFSSpec", "FindFolder", "GetResource", "SetMenuBar", "GetMenuHandle",
    }) |n| try testing.expectEqual(@as(?usize, null), address(n));
}

test "the serial number is the current process and a null one is a parameter error" {
    var psn: ProcessSerialNumber = .{ .high = 0xdead, .low = 0xbeef };
    try testing.expectEqual(@as(OSErr, 0), getCurrentProcess(&psn));
    try testing.expectEqual(@as(u32, 0), psn.high);
    try testing.expectEqual(kCurrentProcess, psn.low);

    // Eight bytes, in the order the game's own PSN-typed locals are laid out.
    try testing.expectEqual(@as(usize, 8), @sizeOf(ProcessSerialNumber));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ProcessSerialNumber, "high"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(ProcessSerialNumber, "low"));

    try testing.expectEqual(@as(OSErr, -50), getCurrentProcess(null));

    try testing.expectEqual(noErr, transformProcessType(&psn, 1));
    try testing.expectEqual(noErr, transformProcessType(null, 0));
    try testing.expectEqual(@as(OSErr, 0), setFrontProcess(&psn));
}

test "the process spec names the application inside the volume root" {
    // The record's pointer fields are 32-bit, so filling them in only works where a pointer is.
    if (@sizeOf(usize) != 4) return error.SkipZigTest;
    files.setRoot("/game");

    var name: [256]u8 = undefined;
    var spec: files.FSSpec = undefined;
    var info: ProcessInfoRec = std.mem.zeroes(ProcessInfoRec);
    info.processInfoLength = @sizeOf(ProcessInfoRec);
    info.processName = @truncate(@intFromPtr(&name));
    info.processAppSpec = @truncate(@intFromPtr(&spec));

    try testing.expectEqual(@as(OSErr, 0), getProcessInformation(null, &info));
    try testing.expectEqual(app_signature, info.processSignature);
    try testing.expectEqual(kCurrentProcess, info.processNumber.low);
    try testing.expectEqualStrings(app_name, name[1..][0..name[0]]);

    // The parID is the whole point: it is what the caller chdir's to.
    try testing.expectEqualStrings("/game", files.dirPath(spec.parID));
    try testing.expectEqualStrings(app_name, spec.name[1..][0..spec.name[0]]);

    // And the bundle location has to agree with it, since the caller prefers that one.
    var ref: files.FSRef = undefined;
    try testing.expectEqual(@as(OSErr, 0), getProcessBundleLocation(null, &ref));
    var out: files.FSSpec = undefined;
    try testing.expectEqual(files.noErr, files.getCatalogSpec(&ref, &out));
    try testing.expectEqualStrings("/game", files.dirPath(out.parID));
}

test "the optional toolbox calls report the outcome the caller already handles" {
    try testing.expectEqual(@as(?*anyopaque, null), getNewMBar(0x81));
    try testing.expectEqual(@as(OSErr, 0), aeInstallEventHandler(0, 0, null, 0, 0));
    setEventMask(-1);
}

test "the microsecond clock is nonzero and moves forward" {
    // Low word first: the game reads the two halves as separate longs and reassembles them.
    try testing.expectEqual(@as(usize, 0), @offsetOf(UnsignedWide, "lo"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(UnsignedWide, "hi"));

    var first: UnsignedWide = undefined;
    microseconds(&first);
    const before = @as(u64, first.hi) << 32 | first.lo;
    try testing.expect(before != 0);

    // Spun rather than slept: microsecond resolution means the wait is over almost at once, and a
    // clock that never advances has to fail the test rather than hang it.
    var second: UnsignedWide = undefined;
    var after = before;
    var spins: usize = 0;
    while (after <= before and spins < 10_000_000) : (spins += 1) {
        microseconds(&second);
        after = @as(u64, second.hi) << 32 | second.lo;
    }
    try testing.expect(after > before);

    microseconds(null);
}

test "the event record is the game's sixteen 68k-packed bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(EventRecord));
    try testing.expectEqual(@as(usize, 0), @offsetOf(EventRecord, "what"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(EventRecord, "message"));
    try testing.expectEqual(@as(usize, 6), @offsetOf(EventRecord, "when"));
    try testing.expectEqual(@as(usize, 10), @offsetOf(EventRecord, "where"));
    try testing.expectEqual(@as(usize, 14), @offsetOf(EventRecord, "modifiers"));

    // `where` is passed to FindWindow as a Point, vertical coordinate first.
    try testing.expectEqual(@as(usize, 4), @sizeOf(Point));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Point, "v"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(Point, "h"));
}

test "an empty queue is reported by writing the record, not by leaving it alone" {
    for ([_][]const u8{ "WaitNextEvent", "EventAvail", "TickCount" }) |n| {
        try testing.expect(address(n).? != 0);
    }
    // Not imported by the image, so nothing here should claim to provide it.
    try testing.expectEqual(@as(?usize, null), address("GetNextEvent"));

    // Pre-filled with the kind of garbage a stack local holds: every field has to be overwritten,
    // because `what` staying non-zero is exactly what kept the event pump from ever returning.
    var event: EventRecord = .{
        .what = 0xbeef,
        .message = 0xdead_beef,
        .when = 0xdead_beef,
        .where = .{ .v = -1, .h = -1 },
        .modifiers = 0xbeef,
    };

    try testing.expectEqual(@as(u8, 0), waitNextEvent(0xffff, &event, 0, null));
    try testing.expectEqual(null_event, event.what);
    try testing.expectEqual(@as(u32, 0), event.message);
    try testing.expectEqual(@as(i16, 0), event.where.v);
    try testing.expectEqual(@as(i16, 0), event.where.h);
    try testing.expectEqual(@as(u16, 0), event.modifiers);
    try testing.expectEqual(tickCount(), event.when);

    event.what = 0xbeef;
    try testing.expectEqual(@as(u8, 0), eventAvail(0xffff, &event));
    try testing.expectEqual(null_event, event.what);

    // A null record is the caller's business, not a crash.
    try testing.expectEqual(@as(u8, 0), waitNextEvent(0xffff, null, 0, null));
    try testing.expectEqual(@as(u8, 0), eventAvail(0xffff, null));
}

test "a tight loop gets throttled and a paced caller does not" {
    const now = struct {
        fn us() u64 {
            var w: UnsignedWide = undefined;
            microseconds(&w);
            return @as(u64, w.hi) << 32 | w.lo;
        }
    }.us;

    var event: EventRecord = undefined;

    // A caller that paces itself is never slowed down, however many times it asks. Each call is
    // preceded by a gap longer than the spin threshold, which is exactly what the game loop does.
    spin_run = 0;
    last_call_us = 0;
    for (0..3) |_| {
        _ = usleep(spin_gap_us + 500);
        const start = now();
        _ = waitNextEvent(0xffff, &event, 0, null);
        try testing.expect(now() - start < idle_sleep_us);
        try testing.expectEqual(@as(u32, 0), spin_run);
    }

    // A caller that does not is, but only after a run long enough to rule out a burst.
    spin_run = 0;
    last_call_us = 0;
    const extra = 100;
    const start = now();
    for (0..spin_calls + extra) |_| _ = waitNextEvent(0xffff, &event, 0, null);
    // Only the calls past the threshold sleep, and each sleeps a millisecond.
    try testing.expect(now() - start >= (extra / 2) * idle_sleep_us);
    try testing.expectEqual(null_event, event.what);

    spin_run = 0;
    last_call_us = 0;
}

test "a non-zero tick budget is actually waited out" {
    // The point of the call: `sleep` is permission to block, and returning early from it is what
    // turns a loop that meant to idle into one that spins.
    const before = tickCount();
    const start_us = blk: {
        var w: UnsignedWide = undefined;
        microseconds(&w);
        break :blk @as(u64, w.hi) << 32 | w.lo;
    };

    var event: EventRecord = undefined;
    _ = waitNextEvent(0xffff, &event, 6, null); // six ticks = 100 ms

    var w: UnsignedWide = undefined;
    microseconds(&w);
    const elapsed_us = (@as(u64, w.hi) << 32 | w.lo) - start_us;

    // Generous on the upper bound: a loaded test host may oversleep, but it must not undersleep.
    try testing.expect(elapsed_us >= 90_000);
    try testing.expectEqual(null_event, event.what);
    try testing.expect(event.when >= before);
}
