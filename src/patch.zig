//! Byte-patch util for the live Game.exe .text.
//! Self-contained: only needs kernel32 VirtualProtect. Addresses are absolute
//! against image base 0x00400000 (1.14d has no ASLR — confirmed at runtime).
const std = @import("std");

const DWORD = u32;
const BYTE = u8;
const BOOL = i32; // c_int; win.BOOL is an enum in zig 0.16

extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new_protect: DWORD, old_protect: *DWORD) callconv(.winapi) BOOL;

const PAGE_READWRITE: DWORD = 0x04;

const OriginalByte = struct { addr: usize, value: BYTE };

var original_bytes: [512]OriginalByte = undefined;
var original_count: usize = 0;

fn saveOriginal(addr: usize, value: BYTE) void {
    for (original_bytes[0..original_count]) |entry| {
        if (entry.addr == addr) return;
    }
    if (original_count < original_bytes.len) {
        original_bytes[original_count] = .{ .addr = addr, .value = value };
        original_count += 1;
    }
}

fn writeBytesProtected(addr: usize, bytes: []const BYTE) bool {
    var old_protect: DWORD = 0;
    const ptr: *anyopaque = @ptrFromInt(addr);
    if (VirtualProtect(ptr, bytes.len, PAGE_READWRITE, &old_protect) == 0) return false;
    const dest: [*]BYTE = @ptrFromInt(addr);
    for (bytes, 0..) |b, i| {
        saveOriginal(addr + i, dest[i]);
        dest[i] = b;
    }
    _ = VirtualProtect(ptr, bytes.len, old_protect, &old_protect);
    return true;
}

fn fillBytesProtected(addr: usize, value: BYTE, len: usize) bool {
    var old_protect: DWORD = 0;
    const ptr: *anyopaque = @ptrFromInt(addr);
    if (VirtualProtect(ptr, len, PAGE_READWRITE, &old_protect) == 0) return false;
    const dest: [*]BYTE = @ptrFromInt(addr);
    for (0..len) |i| {
        saveOriginal(addr + i, dest[i]);
        dest[i] = value;
    }
    _ = VirtualProtect(ptr, len, old_protect, &old_protect);
    return true;
}

pub fn calcRelAddr(from: usize, to: usize, insn_len: usize) i32 {
    return @as(i32, @intCast(@as(isize, @bitCast(to)) - @as(isize, @bitCast(from)) - @as(isize, @intCast(insn_len))));
}

/// 5-byte JMP (E9) from `addr` to `target`.
pub fn writeJump(addr: usize, target: usize) bool {
    const rel = calcRelAddr(addr, target, 5);
    const rb: [4]u8 = @bitCast(rel);
    return writeBytesProtected(addr, &[5]BYTE{ 0xE9, rb[0], rb[1], rb[2], rb[3] });
}

/// NOP fill.
pub fn writeNops(addr: usize, len: usize) bool {
    return fillBytesProtected(addr, 0x90, len);
}

/// Arbitrary bytes.
pub fn writeBytes(addr: usize, bytes: []const BYTE) bool {
    return writeBytesProtected(addr, bytes);
}

/// Revert all patched bytes.
pub fn revertAll() void {
    var i: usize = original_count;
    while (i > 0) {
        i -= 1;
        const entry = original_bytes[i];
        var old_protect: DWORD = 0;
        const ptr: *anyopaque = @ptrFromInt(entry.addr);
        if (VirtualProtect(ptr, 1, PAGE_READWRITE, &old_protect) != 0) {
            const dest: *BYTE = @ptrFromInt(entry.addr);
            dest.* = entry.value;
            _ = VirtualProtect(ptr, 1, old_protect, &old_protect);
        }
    }
    original_count = 0;
}
