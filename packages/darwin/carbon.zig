//! The Carbon Process Manager, and only that.
//!
//! A headless server has no business in Carbon at all, so nothing is here speculatively. These
//! three are here because the game reaches them: a StormMac constructor and `PreInitApplication`
//! itself both ask who they are before doing anything else, and there is no way past that question.
//!
//! All three have an honest answer for a process with no windowing session. A serial number is an
//! identity, and this process has exactly one to give. `TransformProcessType` and `SetFrontProcess`
//! move an application between the Dock and the background and put it in front — a process with no
//! Dock and no front is already where they would put it, so reporting success is describing the
//! state, not faking it.
//!
//! The rest of what PreInitApplication wants — the File Manager, the Resource Manager, the Menu
//! Manager, Apple Events — is not here and is not a stub away.

const std = @import("std");

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

const testing = std.testing;

test "the process manager answers, and nothing else in Carbon does" {
    for ([_][]const u8{ "GetCurrentProcess", "TransformProcessType", "SetFrontProcess" }) |n| {
        try testing.expect(address(n).? != 0);
    }
    // The File, Resource and Menu Managers stay with the thunks: they cannot be answered honestly.
    for ([_][]const u8{
        "FSpOpenResFile", "FSMakeFSSpec", "FindFolder", "GetResource", "GetNewMBar",
        "AEInstallEventHandler", "GetProcessBundleLocation",
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
