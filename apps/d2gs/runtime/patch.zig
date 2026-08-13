//! Byte-patch util for the live Game.exe .text.
//! Self-contained: only needs kernel32 VirtualProtect. Addresses are absolute
//! against image base 0x00400000 (1.14d has no ASLR — confirmed at runtime).
//!
//! Patching code that another thread is *running* is the interesting part. The engine's
//! out-of-game message pump is an infinite loop, and the pacing patch rewrites 23 bytes
//! in the middle of it — so the main thread is always somewhere in the bytes being
//! replaced. Left unsynchronised that lost roughly two boots in three: the thread would
//! resume one byte into an instruction that no longer started there and die reading
//! 0x1a. So a patch here is applied whole, with every other thread stopped and none of
//! them standing on the bytes (see quiesce below).
const std = @import("std");

const DWORD = u32;
const BYTE = u8;
const BOOL = i32; // c_int; win.BOOL is an enum in zig 0.16

extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new_protect: DWORD, old_protect: *DWORD) callconv(.winapi) BOOL;

const PAGE_READWRITE: DWORD = 0x04;

// ── stopping the world for the length of one patch ───────────────────────────
// Nothing in here may log, allocate, or take a lock: the other threads are frozen,
// and one of them owns the logger's file handle.

const HANDLE = ?*anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const TH32CS_SNAPTHREAD: DWORD = 0x00000004;
const THREAD_SUSPEND_RESUME: DWORD = 0x0002;
const THREAD_GET_CONTEXT: DWORD = 0x0008;
/// CONTEXT_i386 | CONTEXT_CONTROL — Ebp/Eip/SegCs/EFlags/Esp/SegSs, which is all we read.
const CONTEXT_CONTROL: DWORD = 0x00010001;

const THREADENTRY32 = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ThreadID: DWORD,
    th32OwnerProcessID: DWORD,
    tpBasePri: i32,
    tpDeltaPri: i32,
    dwFlags: DWORD,
};

/// x86 CONTEXT. Declared here rather than taken from std: this DLL is i386-windows and
/// only the control registers are ever read, but the buffer must still be the full size
/// the kernel expects to write.
const CONTEXT_X86 = extern struct {
    ContextFlags: DWORD,
    Dr0: DWORD,
    Dr1: DWORD,
    Dr2: DWORD,
    Dr3: DWORD,
    Dr6: DWORD,
    Dr7: DWORD,
    FloatSave: [112]u8,
    SegGs: DWORD,
    SegFs: DWORD,
    SegEs: DWORD,
    SegDs: DWORD,
    Edi: DWORD,
    Esi: DWORD,
    Ebx: DWORD,
    Edx: DWORD,
    Ecx: DWORD,
    Eax: DWORD,
    Ebp: DWORD,
    Eip: DWORD,
    SegCs: DWORD,
    EFlags: DWORD,
    Esp: DWORD,
    SegSs: DWORD,
    ExtendedRegisters: [512]u8,
};

extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Thread32First(snap: HANDLE, entry: *THREADENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn Thread32Next(snap: HANDLE, entry: *THREADENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn OpenThread(access: DWORD, inherit: BOOL, tid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn SuspendThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn GetThreadContext(h: HANDLE, ctx: *CONTEXT_X86) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn FlushInstructionCache(proc: HANDLE, base: ?*const anyopaque, size: usize) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

const max_frozen = 64;

/// Threads suspended by the in-progress quiesce, so resumeWorld can let them go again.
var frozen: [max_frozen]HANDLE = undefined;
var frozen_n: usize = 0;

/// Suspend every thread of this process except our own. Returns false (having resumed
/// whatever it had already stopped) if any thread is executing inside
/// [`lo`,`hi`) — patching under such a thread is what corrupts its instruction stream.
fn stopWorld(lo: usize, hi: usize) bool {
    frozen_n = 0;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == null or snap == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(snap);

    const me = GetCurrentThreadId();
    const pid = GetCurrentProcessId();
    var entry: THREADENTRY32 = undefined;
    entry.dwSize = @sizeOf(THREADENTRY32);
    if (Thread32First(snap, &entry) == 0) return false;

    while (true) {
        if (entry.th32OwnerProcessID == pid and entry.th32ThreadID != me and frozen_n < max_frozen) {
            if (OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, 0, entry.th32ThreadID)) |h| {
                if (SuspendThread(h) != @as(DWORD, @bitCast(@as(i32, -1)))) {
                    frozen[frozen_n] = h;
                    frozen_n += 1;
                    // A suspended thread's EIP is only meaningful once the suspend has
                    // actually taken effect, which GetThreadContext guarantees.
                    var ctx: CONTEXT_X86 align(16) = undefined;
                    ctx.ContextFlags = CONTEXT_CONTROL;
                    if (GetThreadContext(h, &ctx) != 0) {
                        const eip: usize = ctx.Eip;
                        if (eip >= lo and eip < hi) {
                            resumeWorld();
                            return false;
                        }
                    }
                } else _ = CloseHandle(h);
            }
        }
        entry.dwSize = @sizeOf(THREADENTRY32);
        if (Thread32Next(snap, &entry) == 0) break;
    }
    return true;
}

fn resumeWorld() void {
    var i: usize = frozen_n;
    while (i > 0) {
        i -= 1;
        _ = ResumeThread(frozen[i]);
        _ = CloseHandle(frozen[i]);
    }
    frozen_n = 0;
}

/// Run `apply` with every other thread stopped and none of them standing inside
/// [`addr`, `addr+len`). Retries while a thread is in the way — the loops we patch
/// spend nearly all their wall-clock inside Sleep(), so a clear moment comes quickly.
/// Falls back to patching anyway rather than never patching at all: a GS that boots
/// with a rare instruction-stream race beats a GS that reliably refuses to start.
fn withWorldStopped(addr: usize, len: usize, apply: *const fn () void) void {
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (stopWorld(addr, addr + len)) {
            apply();
            _ = FlushInstructionCache(GetCurrentProcess(), @ptrFromInt(addr), len);
            resumeWorld();
            return;
        }
        Sleep(2);
    }
    apply();
    _ = FlushInstructionCache(GetCurrentProcess(), @ptrFromInt(addr), len);
}

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

// ── staged application ───────────────────────────────────────────────────────
// A chain stages its bytes here and commit() writes them in one go, so live code is
// never half-patched. The staging area is module state rather than part of the (copied,
// value-type) builder: patches are built and committed by one expression on one thread
// at install time, and MemoryPatch() resets it.

const max_stage = 256;

var stage_base: usize = 0;
var stage_bytes: [max_stage]BYTE = undefined;
var stage_set: [max_stage]bool = undefined;
var stage_len: usize = 0;

fn stageReset(base: usize) void {
    stage_base = base;
    stage_len = 0;
    @memset(&stage_set, false);
}

/// Stage `bytes` at `addr`. False if it falls outside the staging window, in which case
/// the caller writes it immediately — a patch too big to stage is still better applied
/// than dropped.
fn stageWrite(addr: usize, bytes: []const BYTE) bool {
    if (addr < stage_base) return false;
    const off = addr - stage_base;
    if (off + bytes.len > max_stage) return false;
    for (bytes, 0..) |b, i| {
        stage_bytes[off + i] = b;
        stage_set[off + i] = true;
    }
    if (off + bytes.len > stage_len) stage_len = off + bytes.len;
    return true;
}

var stage_ok: bool = true;

/// Write every staged run. Runs with the world stopped — no logging, no allocation.
fn applyStaged() void {
    var i: usize = 0;
    while (i < stage_len) {
        if (!stage_set[i]) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < stage_len and stage_set[j]) : (j += 1) {}
        if (!writeBytesProtected(stage_base + i, stage_bytes[i..j])) stage_ok = false;
        i = j;
    }
}

/// One-shot write of `bytes` at `addr`, with the world stopped for its duration.
fn writeLive(addr: usize, bytes: []const BYTE) bool {
    stageReset(addr);
    if (!stageWrite(addr, bytes)) return writeBytesProtected(addr, bytes);
    stage_ok = true;
    withWorldStopped(addr, bytes.len, &applyStaged);
    return stage_ok;
}

/// 5-byte JMP (E9) from `addr` to `target`.
pub fn writeJump(addr: usize, target: usize) bool {
    const rel = calcRelAddr(addr, target, 5);
    const rb: [4]u8 = @bitCast(rel);
    return writeLive(addr, &[5]BYTE{ 0xE9, rb[0], rb[1], rb[2], rb[3] });
}

/// 5-byte CALL (E8) from `addr` to `target`.
pub fn writeCall(addr: usize, target: usize) bool {
    const rel = calcRelAddr(addr, target, 5);
    const rb: [4]u8 = @bitCast(rel);
    return writeLive(addr, &[5]BYTE{ 0xE8, rb[0], rb[1], rb[2], rb[3] });
}

/// NOP fill.
pub fn writeNops(addr: usize, len: usize) bool {
    if (len > max_stage) return fillBytesProtected(addr, 0x90, len);
    var buf: [max_stage]BYTE = undefined;
    @memset(buf[0..len], 0x90);
    return writeLive(addr, buf[0..len]);
}

/// Arbitrary bytes.
pub fn writeBytes(addr: usize, bytes: []const BYTE) bool {
    return writeLive(addr, bytes);
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

    /// Raw bytes at the cursor. Staged, not written — commit() applies the whole chain
    /// at once, so no thread can ever run a partly-rewritten instruction.
    pub fn bytes(self: Self, b: []const u8) Self {
        const staged = stageWrite(self.cursor, b) or writeBytesProtected(self.cursor, b);
        return self.step(staged, b.len);
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
        const rel = calcRelAddr(self.cursor, target, 5);
        const rb: [4]u8 = @bitCast(rel);
        return self.bytes(&[5]BYTE{ 0xE8, rb[0], rb[1], rb[2], rb[3] });
    }
    /// 5-byte JMP rel32 to `target`.
    pub fn jump(self: Self, target: usize) Self {
        const rel = calcRelAddr(self.cursor, target, 5);
        const rb: [4]u8 = @bitCast(rel);
        return self.bytes(&[5]BYTE{ 0xE9, rb[0], rb[1], rb[2], rb[3] });
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
        if (n > max_stage) return self.step(fillBytesProtected(self.cursor, 0x90, n), n);
        var buf: [max_stage]BYTE = undefined;
        @memset(buf[0..n], 0x90);
        return self.bytes(buf[0..n]);
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

    /// Finish the chain: apply everything it staged, with the world stopped, and report
    /// whether every step succeeded.
    pub fn commit(self: Self) bool {
        if (stage_len == 0) return self.ok;
        stage_ok = true;
        withWorldStopped(stage_base, stage_len, &applyStaged);
        const applied = stage_ok;
        stage_len = 0;
        return self.ok and applied;
    }
    /// The address the cursor ended at (to start a follow-on region).
    pub fn cursorAddr(self: Self) usize {
        return self.cursor;
    }
};

/// Start a fluent patch at `addr`. See `Patch`.
pub fn MemoryPatch(addr: usize) Patch {
    stageReset(addr);
    return .{ .cursor = addr };
}
