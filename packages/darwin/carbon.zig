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
