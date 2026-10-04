//! The one millisecond clock of the game server process (d2gs.dll and the engine it hosts).
//!
//! GetTickCount moves in steps of the system tick, about 15.6 ms on Windows whatever timeBeginPeriod asks, and
//! 1.14d times its client tick, its ping and much else with it; timeGetTime (the local server's 25 Hz tick,
//! SrvProcessAllGames) is only as fine as the timer resolution. This clock counts whole milliseconds from
//! QueryPerformanceCounter instead, with the meaning of the call it replaces:
//!  - `tickCount64` starts at the real GetTickCount64 of the moment the clock is first read and runs on from
//!    there; `tickCount` is its low 32 bits, as GetTickCount is GetTickCount64's, so it wraps where GetTickCount
//!    wraps and every unsigned difference the game makes keeps its meaning;
//!  - `timeGetTime` is the same counter from the real timeGetTime of that moment (its own epoch, which the game
//!    only ever compares with itself);
//!  - neither ever goes backwards, from any thread.
//! `install114d` points 1.14d Game.exe's two import slots at these, so the game and our code read one clock;
//! code in the process reads the functions here, never kernel32's GetTickCount.
//!
//! Target-less: it compiles in the importer's context (x86-windows DLLs; the host for the tests).
const std = @import("std");
const builtin = @import("builtin");

/// Where a clock starts: the counter and its frequency then, and the milliseconds it reads then.
pub const Epoch = struct {
    qpc_at: i64,
    freq: i64,
    ms_at: u64,
};

/// The clock's milliseconds at counter value `qpc`: `ms_at` plus the whole milliseconds since `qpc_at`
/// (never before the start; no overflow however long the machine is up).
pub fn msAt(e: Epoch, qpc: i64) u64 {
    if (qpc <= e.qpc_at or e.freq <= 0) return e.ms_at;
    const d: u64 = @intCast(qpc - e.qpc_at);
    const f: u64 = @intCast(e.freq);
    return e.ms_at + d / f * 1000 + d % f * 1000 / f;
}

/// One clock: its epoch and the low 32 bits of the latest value it has handed out, so it never goes backwards
/// (32 bits so the guard is one lock cmpxchg on x86; wrap-around order, as GetTickCount's differences).
pub const Clock = struct {
    epoch: Epoch,
    last: std.atomic.Value(u32),

    pub fn init(e: Epoch) Clock {
        return .{ .epoch = e, .last = .init(@truncate(e.ms_at)) };
    }

    pub fn at(c: *Clock, qpc: i64) u64 {
        const v = msAt(c.epoch, qpc);
        const low: u32 = @truncate(v);
        var last = c.last.load(.monotonic);
        while (true) {
            const behind: i32 = @bitCast(low -% last);
            if (behind <= 0) return v + @as(u64, @intCast(-@as(i64, behind))); // the last value handed out
            last = c.last.cmpxchgWeak(last, low, .monotonic, .monotonic) orelse return v;
        }
    }
};

// ── The process's clocks ─────────────────────────────────────────────────────────────────────────

const windows = builtin.os.tag == .windows;

const w = struct {
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn GetModuleHandleA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new: u32, old: *u32) callconv(.winapi) i32;
};

const TimeFn = *const fn () callconv(.winapi) u32;
const PeriodFn = *const fn (u32) callconv(.winapi) u32;

var state: std.atomic.Value(u8) = .init(0); // 0 not started, 1 starting, 2 running
var tick_clock: Clock = undefined;
var time_clock: Clock = undefined;
var period_on = false;

fn winmm(name: [*:0]const u8) ?*const anyopaque {
    const m = w.GetModuleHandleA("winmm.dll") orelse w.LoadLibraryA("winmm.dll") orelse return null;
    return w.GetProcAddress(m, name);
}

fn counter() i64 {
    var c: i64 = 0;
    _ = w.QueryPerformanceCounter(&c);
    return c;
}

/// The clocks start on the first read, from whichever thread; the others wait the few instructions it takes.
fn running() void {
    if (state.load(.acquire) == 2) return;
    if (state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        var f: i64 = 0;
        _ = w.QueryPerformanceFrequency(&f);
        const now = counter();
        const real_time: u32 = if (winmm("timeGetTime")) |p| @as(TimeFn, @ptrCast(p))() else @truncate(w.GetTickCount64());
        tick_clock = .init(.{ .qpc_at = now, .freq = f, .ms_at = w.GetTickCount64() });
        time_clock = .init(.{ .qpc_at = now, .freq = f, .ms_at = real_time });
        state.store(2, .release);
        return;
    }
    while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

/// GetTickCount64's meaning: milliseconds since boot, to the millisecond.
pub fn tickCount64() u64 {
    if (!windows) @compileError("the process clock is Windows only");
    running();
    return tick_clock.at(counter());
}

/// GetTickCount's meaning: the low 32 bits of `tickCount64`.
pub fn tickCount() u32 {
    return @truncate(tickCount64());
}

/// timeGetTime's meaning, to the millisecond.
pub fn timeGetTime() u32 {
    if (!windows) @compileError("the process clock is Windows only");
    running();
    return @truncate(time_clock.at(counter()));
}

/// The two as the imports they replace.
pub fn tickCountImport() callconv(.winapi) u32 {
    return tickCount();
}

pub fn timeGetTimeImport() callconv(.winapi) u32 {
    return timeGetTime();
}

/// timeBeginPeriod(1), once: the process's waits (Sleep, the message waits) to the millisecond too.
pub fn timerPeriod1ms() void {
    if (period_on) return;
    const p = winmm("timeBeginPeriod") orelse return;
    period_on = @as(PeriodFn, @ptrCast(p))(1) == 0;
}

/// timeEndPeriod(1) for `timerPeriod1ms`, when the DLL goes.
pub fn timerPeriodEnd() void {
    if (!period_on) return;
    period_on = false;
    const p = winmm("timeEndPeriod") orelse return;
    _ = @as(PeriodFn, @ptrCast(p))(1);
}

// ── 1.14d Game.exe ───────────────────────────────────────────────────────────────────────────────

/// Every GetTickCount of 1.14d (Storm and Fog are linked in) goes through this import slot, a call [slot]
/// or a load of it then a call; nothing imports GetTickCount64. Every timeGetTime goes through the other.
pub const slot_get_tick_count_114d: usize = 0x006C_C260;
pub const slot_time_get_time_114d: usize = 0x006C_C544;

pub const Installed = struct { get_tick_count: bool, time_get_time: bool, period: bool };

fn redirect(slot: usize, dll: [*:0]const u8, name: [*:0]const u8, hook: *const anyopaque) bool {
    const m = w.GetModuleHandleA(dll) orelse return false;
    const real = w.GetProcAddress(m, name) orelse return false;
    const p: *usize = @ptrFromInt(slot);
    if (p.* != @intFromPtr(real)) return false;
    var old: u32 = 0;
    if (w.VirtualProtect(p, 4, 0x04, &old) == 0) return false; // PAGE_READWRITE
    @atomicStore(usize, p, @intFromPtr(hook), .release);
    _ = w.VirtualProtect(p, 4, old, &old);
    return true;
}

/// 1.14d's GetTickCount and timeGetTime slots onto this clock, and a 1 ms timer. A slot that does not hold the
/// system's function (another hook, another build) is left alone. Before the game's loops run.
pub fn install114d() Installed {
    running();
    timerPeriod1ms();
    return .{
        .get_tick_count = redirect(slot_get_tick_count_114d, "kernel32.dll", "GetTickCount", @ptrCast(&tickCountImport)),
        .time_get_time = redirect(slot_time_get_time_114d, "winmm.dll", "timeGetTime", @ptrCast(&timeGetTimeImport)),
        .period = period_on,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "whole milliseconds from the counter, on from the start" {
    const e: Epoch = .{ .qpc_at = 1_000_000, .freq = 10_000_000, .ms_at = 5000 };
    try testing.expectEqual(@as(u64, 5000), msAt(e, 1_000_000));
    try testing.expectEqual(@as(u64, 5000), msAt(e, 1_009_999));
    try testing.expectEqual(@as(u64, 5001), msAt(e, 1_010_000));
    try testing.expectEqual(@as(u64, 5040), msAt(e, 1_400_000));
    try testing.expectEqual(@as(u64, 5000), msAt(e, 999_999));
    // 100 days on a 3 GHz counter: count * 1000 alone would not fit in 64 bits
    const g: Epoch = .{ .qpc_at = 0, .freq = 3_000_000_000, .ms_at = 0 };
    const days: u64 = 100 * 24 * 3600;
    try testing.expectEqual(days * 1000 + 999, msAt(g, @intCast(days * 3_000_000_000 + 2_999_999_999)));
}

test "the 32-bit view wraps where GetTickCount wraps" {
    const e: Epoch = .{ .qpc_at = 0, .freq = 10_000_000, .ms_at = 0xFFFF_FFF0 };
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), @as(u32, @truncate(msAt(e, 150_000))));
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(msAt(e, 160_000))));
    try testing.expectEqual(@as(u32, 7), @as(u32, @truncate(msAt(e, 170_000))) -% @as(u32, @truncate(msAt(e, 100_000))));
}

test "never backwards" {
    var c: Clock = .init(.{ .qpc_at = 1000, .freq = 1000, .ms_at = 50 });
    try testing.expectEqual(@as(u64, 60), c.at(1010));
    try testing.expectEqual(@as(u64, 60), c.at(1005)); // a counter read earlier on another core
    try testing.expectEqual(@as(u64, 61), c.at(1011));
}

// The two 25 Hz gates of 1.14d, driven for many simulated seconds on the system's stepped clock and on this one:
// the same ticks in every second, only their moments differ.

const Sim = struct {
    per_second: [1000]u32 = @splat(0),
    seconds: u32 = 0,
    ticks: u32 = 0,
    min_gap_us: u64 = std.math.maxInt(u64),
    max_gap_us: u64 = 0,
};

const ClockKind = enum { stepped, precise };

/// Windows' GetTickCount (and timeGetTime at the default resolution): whole ms of 15.625 ms steps.
fn stepped(boot: u32, t_us: u64) u32 {
    return boot +% @as(u32, @truncate(t_us / 15625 * 15625 / 1000));
}

fn preciseAt(c: *Clock, t_us: u64) u32 {
    return @truncate(c.at(@intCast(t_us * 10))); // a 10 MHz counter
}

/// SrvProcessAllGames' gate (0x0052FC38): now = timeGetTime & 0x7fffffff; a tick when now - last >= 40, and last
/// becomes now minus the lateness, at most one period of it (one catch-up tick). The loop around it (d2gs's
/// framepace) sleeps to the next due frame, the sleep ending 0 to 1 ms late.
fn simulateServer(kind: ClockKind, boot: u32, seconds: u32, seed: u64) Sim {
    var sim: Sim = .{};
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    var clock: Clock = .init(.{ .qpc_at = 0, .freq = 10_000_000, .ms_at = boot });
    var last: u32 = 0;
    var t: u64 = 0;
    var first: u64 = 0;
    var prev: u64 = 0;
    const end: u64 = @as(u64, seconds) * 1_000_000;
    while (t < end) {
        const raw = if (kind == .stepped) stepped(boot, t) else preciseAt(&clock, t);
        const now = raw & 0x7fff_ffff;
        if (last == 0) last = now;
        const e = now -% last;
        if (@as(i32, @bitCast(e)) >= 40) {
            const late = @min(e - 40, 40);
            last = now -% late;
            if (sim.ticks == 0) first = t else {
                sim.min_gap_us = @min(sim.min_gap_us, t - prev);
                sim.max_gap_us = @max(sim.max_gap_us, t - prev);
            }
            const from = if (first >= 20_000) first - 20_000 else 0;
            const s: usize = @intCast((t - from) / 1_000_000);
            if (s < sim.per_second.len) sim.per_second[s] += 1;
            sim.ticks += 1;
            prev = t;
            t += 100 + r.uintLessThan(u64, 2000); // the frame's own work, 0.1 to 2.1 ms
        }
        // framepace.sleepToNextFrame: the wait to the next due frame, at least 1 ms
        const now2 = (if (kind == .stepped) stepped(boot, t) else preciseAt(&clock, t)) & 0x7fff_ffff;
        const due = (last +% 40) & 0x7fff_ffff;
        const wait: u64 = if (due > now2) due - now2 else 0;
        t += @max(wait, 1) * 1000 + r.uintLessThan(u64, 1000);
    }
    const from = if (first >= 20_000) first - 20_000 else 0;
    sim.seconds = @intCast(@min((end - from) / 1_000_000, sim.per_second.len));
    return sim;
}

fn all25(s: *const Sim) bool {
    if (s.seconds == 0) return false;
    for (s.per_second[0..s.seconds]) |n| if (n != 25) return false;
    return true;
}

test "the server's 25 Hz: the same 25 ticks in every second on both clocks, the precise one on time" {
    const a = simulateServer(.stepped, 12_345_678, 900, 7);
    const b = simulateServer(.precise, 12_345_678, 900, 7);
    try testing.expect(all25(&a));
    try testing.expect(all25(&b));
    try testing.expectEqual(a.seconds, b.seconds);
    try testing.expectEqualSlices(u32, a.per_second[0..a.seconds], b.per_second[0..b.seconds]);
    // precise: 40 ms apart within 2 ms (a 1 ms timer on a 1 ms clock); stepped: moved by more than 10 ms
    try testing.expect(b.min_gap_us >= 38_000 and b.max_gap_us <= 42_000);
    try testing.expect(a.max_gap_us - a.min_gap_us > 10_000);
}

test "the server's 25 Hz where its 31-bit masked clock rolls over: whatever the engine does there, both clocks alike" {
    // SrvProcessAllGames compares signed after the mask, so from the roll-over it waits until the masked clock
    // comes round again (24.8 days): the engine's own limit, the same on either clock. Up to it, 25 a second.
    const a = simulateServer(.stepped, 0x7FFF_FFFF - 60_000, 120, 3);
    const b = simulateServer(.precise, 0x7FFF_FFFF - 60_000, 120, 3);
    for (a.per_second[0..58], b.per_second[0..58]) |x, y| {
        try testing.expectEqual(@as(u32, 25), x);
        try testing.expectEqual(@as(u32, 25), y);
    }
    // both stop at the roll-over; the stepped clock, behind the true time, reaches it up to one tick later
    try testing.expect(a.ticks <= 1501 and b.ticks <= 1501 and @max(a.ticks, b.ticks) - @min(a.ticks, b.ticks) <= 1);
}
