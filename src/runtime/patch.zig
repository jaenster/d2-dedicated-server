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

/// 5-byte CALL (E8) from `addr` to `target`.
pub fn writeCall(addr: usize, target: usize) bool {
    const rel = calcRelAddr(addr, target, 5);
    const rb: [4]u8 = @bitCast(rel);
    return writeBytesProtected(addr, &[5]BYTE{ 0xE8, rb[0], rb[1], rb[2], rb[3] });
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

// ── fluent patch builder ─────────────────────────────────────────────────────
// Charon-style `MemoryPatch(addr) << CALL(..) << NOP_TO(..)`, as a Zig method
// chain. Each step writes immediately at the cursor (which starts at `addr`) and
// returns the advanced builder, so call order == memory layout. `commit()`
// returns whether every step succeeded; originals are still saved for revertAll().
//
//   _ = MemoryPatch(0x47c4e4)
//       .pushad()
//       .movEcxEax()
//       .call(@intFromPtr(&SetPlayerCount))
//       .popad()
//       .nopTo(0x47c50e)
//       .commit();

/// Builder returned by MemoryPatch(addr). Value type — copy/return is free.
pub const Patch = struct {
    cursor: usize,
    ok: bool = true,

    const Self = @This();

    fn step(self: Self, wrote: bool, len: usize) Self {
        return .{ .cursor = self.cursor + len, .ok = self.ok and wrote };
    }

    /// Raw bytes at the cursor.
    pub fn bytes(self: Self, b: []const u8) Self {
        return self.step(writeBytes(self.cursor, b), b.len);
    }
    /// A single byte.
    pub fn byte(self: Self, v: u8) Self {
        return self.bytes(&[_]u8{v});
    }
    /// Little-endian raw bytes of any value (int/float/packed struct).
    pub fn data(self: Self, value: anytype) Self {
        const b: [@sizeOf(@TypeOf(value))]u8 = @bitCast(value);
        return self.bytes(&b);
    }
    /// 5-byte CALL rel32 to `target`.
    pub fn call(self: Self, target: usize) Self {
        return self.step(writeCall(self.cursor, target), 5);
    }
    /// 5-byte JMP rel32 to `target`.
    pub fn jump(self: Self, target: usize) Self {
        return self.step(writeJump(self.cursor, target), 5);
    }
    /// 6-byte near JZ (0F 84) to `target`.
    pub fn jumpEq(self: Self, target: usize) Self {
        return self.condJump(0x84, target);
    }
    /// 6-byte near JNZ (0F 85) to `target`.
    pub fn jumpNe(self: Self, target: usize) Self {
        return self.condJump(0x85, target);
    }
    fn condJump(self: Self, op2: u8, target: usize) Self {
        const rel = calcRelAddr(self.cursor, target, 6);
        const rb: [4]u8 = @bitCast(rel);
        return self.bytes(&[_]u8{ 0x0F, op2, rb[0], rb[1], rb[2], rb[3] });
    }
    /// `n` NOPs.
    pub fn nops(self: Self, n: usize) Self {
        return self.step(writeNops(self.cursor, n), n);
    }
    /// NOP-fill from the cursor up to `addr` (exclusive). No-op if already at/past it.
    pub fn nopTo(self: Self, addr: usize) Self {
        if (addr <= self.cursor) return self;
        return self.nops(addr - self.cursor);
    }
    /// Advance the cursor `n` bytes without writing (leave the originals intact).
    pub fn skip(self: Self, n: usize) Self {
        return .{ .cursor = self.cursor + n, .ok = self.ok };
    }
    /// Move the cursor back `n` bytes.
    pub fn rewind(self: Self, n: usize) Self {
        return .{ .cursor = self.cursor - n, .ok = self.ok };
    }

    // Readable shorthands for common one/two-byte ops (cf. Charon's ASM::*).
    pub fn pushad(self: Self) Self {
        return self.byte(0x60);
    }
    pub fn popad(self: Self) Self {
        return self.byte(0x61);
    }
    pub fn ret(self: Self) Self {
        return self.byte(0xC3);
    }
    /// `ret imm16` (C2) — callee stack cleanup of `imm` bytes.
    pub fn retImm(self: Self, imm: u16) Self {
        const b: [2]u8 = @bitCast(imm);
        return self.bytes(&[_]u8{ 0xC2, b[0], b[1] });
    }
    /// `xor eax,eax` — zero EAX (a common "return 0/NULL" prefix).
    pub fn xorEaxEax(self: Self) Self {
        return self.bytes(&[_]u8{ 0x31, 0xC0 });
    }
    pub fn movEcxEax(self: Self) Self {
        return self.bytes(&[_]u8{ 0x89, 0xC1 });
    }
    pub fn movEcxEdi(self: Self) Self {
        return self.bytes(&[_]u8{ 0x89, 0xF9 });
    }

    /// Finish the chain: true iff every step succeeded.
    pub fn commit(self: Self) bool {
        return self.ok;
    }
    /// The address the cursor ended at (to start a follow-on region).
    pub fn cursorAddr(self: Self) usize {
        return self.cursor;
    }
};

/// Start a fluent patch at `addr`. See `Patch`.
pub fn MemoryPatch(addr: usize) Patch {
    return .{ .cursor = addr };
}
