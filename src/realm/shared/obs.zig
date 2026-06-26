//! Observability core — per-thread trace/span context for structured, correlatable
//! logs (and forward-compatible with OTLP/Tempo: ids are 128-bit trace / 64-bit span,
//! rendered as hex like the W3C/OTLP wire form).
//!
//! Model (distributed-tracing semantics):
//!   trace  — one logical operation, possibly spanning components (e.g. a client
//!            connection, or a game-join that crosses realmd → GS). Identified by a
//!            128-bit id that PROPAGATES across the d2cs/gslink wire (see adopt()).
//!   span   — a unit of work within a trace (fetch char, load player, place in room).
//!            Has its own 64-bit id and a parent; spans nest via enter()/exit().
//!
//! Each THREAD owns its context (`threadlocal`) — the engine ticks games on the server
//! thread, realmd serves one thread per connection, so a thread maps to a trace/work
//! unit naturally and there's no cross-thread races (unlike a single global). Loggers
//! read `current()` and stamp `trace`/`span` (+ domain fields) on every line.
//!
//! No allocation; portable across the GS (wine/x86) and realmd (musl/x86_64). The host
//! supplies a millisecond clock via `nowMsFn` (Windows vs libc differ) so this stays
//! target-agnostic.
const std = @import("std");

/// Host clock (unix milliseconds). Set once at startup by each binary; until then
/// durations read 0 (ids still work). GS: GetSystemTimeAsFileTime; realmd: time()*1000.
pub var nowMsFn: ?*const fn () u64 = null;

fn nowMs() u64 {
    return if (nowMsFn) |f| f() else 0;
}

/// Monotonic process-wide id source. u32 so the atomic RMW works on the 32-bit GS too
/// (x86 has no 64-bit atomics); 4B ids/process is plenty, and trace ids mix this with
/// the clock so independently-started traces don't collide before propagation wires
/// them together.
var seq = std.atomic.Value(u32).init(0);

fn nextId() u64 {
    return @as(u64, seq.fetchAdd(1, .monotonic)) +% 1;
}

/// The per-thread context. Empty (all-zero) = no active trace; loggers then stamp
/// nothing trace-related. Domain fields are a small fixed set the whole stack agrees
/// on; extend deliberately (every field is on every log line in that scope).
/// Process-stable GS id (hash of the pod/host name). Set once at boot; the SAME on
/// every thread, so it lives here (not in the per-thread Ctx — else only the boot
/// thread's lines would carry it).
pub var gsid: u32 = 0;

pub const Ctx = struct {
    trace_hi: u64 = 0,
    trace_lo: u64 = 0,
    span: u64 = 0,
    parent: u64 = 0,
    // ── domain context (0 / empty = absent) ──
    token: u32 = 0, // per-game trace token of the in-flight game on this thread
    acct_buf: [16]u8 = undefined, // the user this thread/connection is acting for
    acct_len: u8 = 0,

    pub fn hasTrace(self: *const Ctx) bool {
        return self.trace_hi != 0 or self.trace_lo != 0;
    }

    pub fn account(self: *const Ctx) []const u8 {
        return self.acct_buf[0..self.acct_len];
    }
};

threadlocal var ctx: Ctx = .{};

/// Set the user this thread is acting for — so every subsequent log line (realmd, and
/// once propagated, the GS) carries who it's about. Truncated to 16 chars.
pub fn setAccount(name: []const u8) void {
    const n = @min(name.len, ctx.acct_buf.len);
    @memcpy(ctx.acct_buf[0..n], name[0..n]);
    ctx.acct_len = @intCast(n);
}

/// Mark the current work as not-about-a-user (GS control, health, internal). Multiplexed
/// connections (d2dbs, gslink) default to this and switch to setAccount() per packet for
/// the user that packet concerns.
pub fn setSystem() void {
    setAccount("system");
}

/// The calling thread's live context (mutable — set domain fields directly).
pub fn current() *Ctx {
    return &ctx;
}

/// Begin a fresh root trace on this thread (new 128-bit trace id + root span).
/// Returns the trace id halves so a caller can propagate them to another component.
pub fn startTrace() struct { hi: u64, lo: u64 } {
    const t = nowMs();
    ctx.trace_hi = nextId();
    ctx.trace_lo = (t << 16) ^ nextId();
    ctx.span = nextId();
    ctx.parent = 0;
    return .{ .hi = ctx.trace_hi, .lo = ctx.trace_lo };
}

/// Continue a trace started elsewhere (cross-component propagation): adopt the remote
/// trace id and start a child span under the remote span. Use on the receiving side of
/// a wire message that carried trace context (e.g. the GS handling a realmd CREATEGAME).
pub fn adopt(trace_hi: u64, trace_lo: u64, parent_span: u64) void {
    ctx.trace_hi = trace_hi;
    ctx.trace_lo = trace_lo;
    ctx.parent = parent_span;
    ctx.span = nextId();
}

/// Clear this thread's trace context (end of a connection / work unit). gsid is a
/// process global, so it's unaffected.
pub fn clear() void {
    ctx = .{};
}

/// An active span. Created by enter(); end it with `defer sp.exit()`. Restores the
/// parent span on exit and emits a span-complete record via the host log sink (if set),
/// so span timings show up as structured events without a separate tracing backend.
pub const Span = struct {
    name: []const u8,
    prev_span: u64,
    prev_parent: u64,
    start_ms: u64,
    ended: bool = false,

    pub fn exit(self: *Span) void {
        if (self.ended) return;
        self.ended = true;
        if (spanSink) |sink| sink(self.name, self.span_dur());
        ctx.span = self.prev_span;
        ctx.parent = self.prev_parent;
    }

    fn span_dur(self: *const Span) u64 {
        const t = nowMs();
        return if (t >= self.start_ms) t - self.start_ms else 0;
    }
};

/// Enter a child span named `name`. The new span becomes current (its parent = the
/// span that was current); restore happens in Span.exit().
pub fn enter(name: []const u8) Span {
    const sp = Span{
        .name = name,
        .prev_span = ctx.span,
        .prev_parent = ctx.parent,
        .start_ms = nowMs(),
    };
    ctx.parent = ctx.span;
    ctx.span = nextId();
    return sp;
}

/// Optional sink for span-complete events (name + duration_ms). The logger module sets
/// this so a span exit emits a structured record carrying the current trace/span.
pub var spanSink: ?*const fn (name: []const u8, dur_ms: u64) void = null;

/// Render a 128-bit trace id as 32 lowercase hex chars into `out` (must be >= 32).
/// Returns the slice written. Used by loggers to stamp `"trace":"..."`.
pub fn traceHex(out: []u8, hi: u64, lo: u64) []const u8 {
    const hexd = "0123456789abcdef";
    var i: usize = 0;
    for ([_]u64{ hi, lo }) |word| {
        var shift: u6 = 60;
        while (true) {
            out[i] = hexd[@as(usize, @intCast((word >> shift) & 0xf))];
            i += 1;
            if (shift == 0) break;
            shift -= 4;
        }
    }
    return out[0..i];
}

test "trace + nested spans + hex" {
    const expect = std.testing.expect;
    nowMsFn = struct {
        fn f() u64 {
            return 5000;
        }
    }.f;
    clear();
    try expect(!current().hasTrace());

    const t = startTrace();
    try expect(current().hasTrace());
    try expect(current().parent == 0);
    const root_span = current().span;

    var outer = enter("outer");
    try expect(current().parent == root_span); // outer's parent is the root span
    const outer_span = current().span;
    {
        var inner = enter("inner");
        try expect(current().parent == outer_span); // nesting
        inner.exit();
    }
    try expect(current().span == outer_span); // inner.exit() restored outer
    outer.exit();
    try expect(current().span == root_span); // outer.exit() restored root

    var buf: [32]u8 = undefined;
    const hex = traceHex(&buf, t.hi, t.lo);
    try expect(hex.len == 32);

    adopt(0xABCD, 0x1234, 99);
    try expect(current().trace_hi == 0xABCD and current().parent == 99);
}
