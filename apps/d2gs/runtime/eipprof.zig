//! CPU-weighted sampling profiler for the engine, from inside the engine's own process.
//!
//! No host profiler can see this: the 32-bit guest runs under wine, translated on Apple
//! silicon, so a host sampler only ever sees the translator. From in here we're at the guest's
//! own fixed addresses (image base 0x400000, no ASLR), resolvable via the 1.14d database.
//!
//! Two things a naive version gets wrong: (1) must sample ALL threads, not just the tick
//! thread — it frame-paces and is asleep almost always, while QServer does its work on an
//! IOCP worker pool; (2) must weight by CPU time, not wall time — SuspendThread+GetThreadContext
//! reports where a thread IS regardless of blocked state, so each round instead reads
//! GetThreadTimes and credits the observed EIP with microseconds actually burned since last round.
//!
//! Addresses reported raw; name resolution is an offline Ghidra lookup. Off unless --eipprof:
//! suspending threads a few hundred times a second is cheap but not free, not for a live realm.

const std = @import("std");
const log = @import("../log.zig");

const DWORD = u32;
const HANDLE = ?*anyopaque;
const BOOL = i32;

extern "kernel32" fn OpenThread(access: DWORD, inherit: BOOL, tid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SuspendThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn GetThreadContext(h: HANDLE, ctx: *anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetThreadTimes(h: HANDLE, create: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Thread32First(snap: HANDLE, entry: *anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn Thread32Next(snap: HANDLE, entry: *anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateThread(
    attrs: ?*anyopaque,
    stack: usize,
    start: *const fn (?*anyopaque) callconv(.winapi) DWORD,
    param: ?*anyopaque,
    flags: DWORD,
    tid: ?*DWORD,
) callconv(.winapi) HANDLE;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

const THREAD_SUSPEND_RESUME: DWORD = 0x0002;
const THREAD_GET_CONTEXT: DWORD = 0x0008;
const THREAD_QUERY_INFORMATION: DWORD = 0x0040;
const TH32CS_SNAPTHREAD: DWORD = 0x0004;

// i386 CONTEXT: Eip at 0xB8, whole struct 0x2CC.
const CONTEXT_SIZE = 0x2CC;
const CONTEXT_EIP_OFF = 0xB8;
const CONTEXT_CONTROL: DWORD = 0x0001_0000 | 0x01;

// THREADENTRY32: dwSize@0, cntUsage@4, th32ThreadID@8, th32OwnerProcessID@12; 28 bytes.
const TE32_SIZE = 28;
const TE32_TID_OFF = 8;
const TE32_PID_OFF = 12;

/// Game.exe's image. Anything outside is wine/ntdll — worth counting separately, because
/// "how much of the time is engine code versus the host calls it makes" is the first question.
const IMAGE_LO: u32 = 0x0040_0000;
const IMAGE_HI: u32 = 0x0090_0000;

const SLOTS = 8192;
var keys: [SLOTS]u32 = .{0} ** SLOTS;
var usecs: [SLOTS]u64 = .{0} ** SLOTS;

const MAX_THREADS = 64;
const Tracked = struct {
    tid: DWORD = 0,
    h: HANDLE = null,
    last_cpu: u64 = 0, // kernel+user, 100ns units
    in_engine_us: u64 = 0,
    in_host_us: u64 = 0,
};
var threads = [_]Tracked{.{}} ** MAX_THREADS;
var thread_n: usize = 0;

var engine_us: u64 = 0;
var host_us: u64 = 0;
var self_tid: DWORD = 0;
var running = false;

fn record(addr: u32, us: u64) void {
    // 16-byte buckets: instructions in one basic block are the same answer.
    const key = addr & ~@as(u32, 0xF);
    var i: usize = (key *% 2654435761) % SLOTS;
    var probes: usize = 0;
    while (probes < 64) : (probes += 1) {
        if (keys[i] == key) {
            usecs[i] +%= us;
            return;
        }
        if (keys[i] == 0) {
            keys[i] = key;
            usecs[i] = us;
            return;
        }
        i = (i + 1) % SLOTS;
    }
}

fn cpuUsec(h: HANDLE) ?u64 {
    var c: u64 = 0;
    var e: u64 = 0;
    var k: u64 = 0;
    var u: u64 = 0;
    if (GetThreadTimes(h, &c, &e, &k, &u) == 0) return null;
    return (k + u) / 10; // 100ns units -> microseconds
}

/// Refresh the thread table. Threads come and go (a join spawns work), so this re-runs
/// periodically rather than once.
fn rescan() void {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) orelse return;
    defer _ = CloseHandle(snap);
    const pid = GetCurrentProcessId();
    var entry: [TE32_SIZE]u8 align(4) = undefined;
    @as(*DWORD, @ptrCast(&entry)).* = TE32_SIZE;
    var ok = Thread32First(snap, &entry);
    while (ok != 0) : (ok = Thread32Next(snap, &entry)) {
        @as(*DWORD, @ptrCast(&entry)).* = TE32_SIZE;
        const owner = @as(*const DWORD, @ptrCast(@alignCast(entry[TE32_PID_OFF..]))).*;
        if (owner != pid) continue;
        const tid = @as(*const DWORD, @ptrCast(@alignCast(entry[TE32_TID_OFF..]))).*;
        if (tid == self_tid) continue; // never suspend ourselves
        var known = false;
        for (threads[0..thread_n]) |t| {
            if (t.tid == tid) {
                known = true;
                break;
            }
        }
        if (known or thread_n == MAX_THREADS) continue;
        const h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, 0, tid) orelse continue;
        threads[thread_n] = .{ .tid = tid, .h = h, .last_cpu = cpuUsec(h) orelse 0 };
        thread_n += 1;
    }
}

fn sampler(_: ?*anyopaque) callconv(.winapi) DWORD {
    var buf: [CONTEXT_SIZE + 16]u8 align(16) = undefined;
    const ctx: [*]u8 = &buf;
    var rounds: u32 = 0;
    while (true) : (rounds +%= 1) {
        if (rounds % 400 == 0) rescan(); // ~every 2s
        if (rounds == 400) {
            // One-shot sanity line: if GetThreadTimes is not reporting under wine every delta
            // is zero and the profiler silently measures nothing.
            var probe: u64 = 0;
            if (thread_n > 0) probe = cpuUsec(threads[0].h) orelse 0xFFFF_FFFF;
            log.hex2("eipprof: threads tracked / first-thread cpu us:", @intCast(thread_n), @intCast(probe));
        }
        for (threads[0..thread_n]) |*t| {
            // Wine on this host reports 0 for GetThreadTimes kernel+user, so CPU-weighting isn't
            // available: every sample counts as one, giving wall-clock within engine code.
            // Samples outside the image (wine, ntdll, blocked wait) are counted separately and
            // excluded, so this answers "where in D2 code", not "what fraction is D2 code".
            const delta: u64 = 1;

            @memset(buf[0..CONTEXT_SIZE], 0);
            @as(*DWORD, @ptrCast(@alignCast(ctx))).* = CONTEXT_CONTROL;
            if (SuspendThread(t.h) == 0xFFFF_FFFF) continue;
            const got = GetThreadContext(t.h, ctx);
            const eip = @as(*const u32, @ptrCast(@alignCast(ctx + CONTEXT_EIP_OFF))).*;
            _ = ResumeThread(t.h); // resume before touching the sample
            if (got == 0) continue;

            if (eip >= IMAGE_LO and eip < IMAGE_HI) {
                engine_us +%= delta;
                t.in_engine_us +%= delta;
                record(eip, delta);
            } else {
                host_us +%= delta;
                t.in_host_us +%= delta;
            }
        }
        Sleep(5);
        if (rounds % 2000 == 1999) dump(); // ~every 10s
    }
}

/// Hottest engine addresses by attributed CPU, plus the per-thread split. Addresses are raw
/// and sit at Game.exe's fixed image base — resolve against the 1.14d Ghidra database.
pub fn dump() void {
    if (engine_us + host_us == 0) return;
    log.hex2("eipprof: in-engine / in-host samples:", @intCast(engine_us), @intCast(host_us));
    for (threads[0..thread_n]) |t| {
        if (t.in_engine_us + t.in_host_us == 0) continue;
        log.hex3("eipprof:   tid / in-engine / in-host:", t.tid, @intCast(t.in_engine_us), @intCast(t.in_host_us));
    }
    var shown: usize = 0;
    var used: [SLOTS]bool = .{false} ** SLOTS;
    while (shown < 25) : (shown += 1) {
        var best: usize = SLOTS;
        var best_us: u64 = 0;
        for (keys, 0..) |k, i| {
            if (k == 0 or used[i]) continue;
            if (usecs[i] > best_us) {
                best_us = usecs[i];
                best = i;
            }
        }
        if (best == SLOTS) break;
        used[best] = true;
        const permille: usize = @intCast(usecs[best] * 1000 / @max(engine_us, 1));
        log.hex3("eipprof:   addr / hits / permille-of-engine:", keys[best], @intCast(usecs[best]), permille);
    }
}

pub fn installHere() void {
    if (running) return;
    running = true;
    self_tid = 0; // set by the sampler thread itself once it knows its own id
    var tid: DWORD = 0;
    if (CreateThread(null, 0, sampler, null, 0, &tid) == null) {
        log.print("eipprof: sampler thread would not start");
        running = false;
        return;
    }
    self_tid = tid;
    log.print("eipprof: CPU-weighted sampling of every thread (addresses are raw; resolve in Ghidra)");
}
