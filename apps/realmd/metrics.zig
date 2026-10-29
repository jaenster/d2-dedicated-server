//! Prometheus text on the health port's `GET /metrics`. Atomics in static storage, labels from
//! closed sets only: never an account, a character or a game name, since a label per player is a
//! series per player. Every value is this instance's own; a realm of several replicas is the sum.
//!
//! Games are not here: they live in redis, so every replica would report the same realm-wide
//! number and a dashboard summing replicas would count each game once per replica.
const std = @import("std");

const Counter = std.atomic.Value(u64);
const Gauge = std.atomic.Value(i64);

/// Which listener a connection ended up on. MCP rides the BNCS port, told apart by the byte after
/// the protocol selector, so the two are counted where that split is made.
pub const Protocol = enum { bncs, mcp };

/// How a logon was decided, and what it came to. A closed table of the pairs the code can
/// actually produce, rather than a cross product that is mostly zeros.
pub const Logon = enum {
    /// SID_LOGONRESPONSE2 decided by the realm's own password check.
    password_ok,
    password_bad_password,
    password_no_account,
    /// SID_LOGONRESPONSE2 decided by an extension's `authenticate` (a launcher ticket, say).
    extension_ok,
    extension_bad_password,
    extension_no_account,
    /// MCP_STARTUP presenting the session SID_LOGONREALMEX handed out.
    mcp_session_ok,
    mcp_session_unknown_session,
    /// SID_AUTHACCOUNTLOGON: NLS/SRP, which this realm does not speak.
    nls_unsupported,

    fn method(l: Logon) []const u8 {
        const s = @tagName(l);
        inline for (.{ "password", "extension", "mcp_session", "nls" }) |m| {
            if (std.mem.startsWith(u8, s, m ++ "_")) return m;
        }
        unreachable;
    }
    fn result(l: Logon) []const u8 {
        const s = @tagName(l);
        return s[l.method().len + 1 ..];
    }
};

pub const CharLogon = enum { ok, incompatible };

/// MCP_CREATEGAME outcomes, one per refusal the realm distinguishes (the client is shown fewer).
pub const Create = enum { ok, invalid_name, refused, no_gs, name_taken, fleet_full, gs_refused, store_error };

/// MCP_JOINGAME outcomes.
pub const Join = enum { ok, not_found, bad_password, refused, not_member, status_mismatch, difficulty_locked, full, char_busy };

fn n(comptime E: type) usize {
    return @typeInfo(E).@"enum".field_names.len;
}

var connections: [n(Protocol)]Gauge = @splat(.init(0));
var sessions: [n(Protocol)]Gauge = @splat(.init(0));
var logons: [n(Logon)]Counter = @splat(.init(0));
var char_logons: [n(CharLogon)]Counter = @splat(.init(0));
var creates: [n(Create)]Counter = @splat(.init(0));
var joins: [n(Join)]Counter = @splat(.init(0));

/// Seconds from the request arriving to its answer being written: what a player waits at
/// "creating/joining game". Reaches past the realm's own GS wait on purpose.
const buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 };
const Histogram = struct {
    le: [buckets.len]Counter = @splat(.init(0)),
    count: Counter = .init(0),
    sum_us: Counter = .init(0),

    fn observe(h: *Histogram, us: u64) void {
        const s = @as(f64, @floatFromInt(us)) / 1e6;
        for (buckets, 0..) |b, j| if (s <= b) inc(&h.le[j]);
        inc(&h.count);
        _ = h.sum_us.fetchAdd(us, .monotonic);
    }
};
var create_seconds: Histogram = .{};
var join_seconds: Histogram = .{};

fn inc(c: *Counter) void {
    _ = c.fetchAdd(1, .monotonic);
}

extern "c" fn clock_gettime(clk: c_int, ts: *std.c.timespec) c_int;
const clock_monotonic: c_int = if (@import("builtin").target.os.tag.isDarwin()) 6 else 1;

/// Monotonic microseconds, from libc: 0.16's std clock needs an `Io` a connection thread lacks.
pub fn nowUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(clock_monotonic, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

pub fn connectionOpened(p: Protocol) void {
    _ = connections[@backingInt(p)].fetchAdd(1, .monotonic);
}
pub fn connectionClosed(p: Protocol) void {
    _ = connections[@backingInt(p)].fetchSub(1, .monotonic);
}
/// A connection's logged-in state changed from `was` to `now`.
pub fn sessionChanged(p: Protocol, was: bool, now: bool) void {
    if (was == now) return;
    _ = sessions[@backingInt(p)].fetchAdd(if (now) 1 else -1, .monotonic);
}
pub fn logon(l: Logon) void {
    inc(&logons[@backingInt(l)]);
}
pub fn charLogon(r: CharLogon) void {
    inc(&char_logons[@backingInt(r)]);
}
pub fn gameCreate(r: Create, start_us: u64) void {
    inc(&creates[@backingInt(r)]);
    create_seconds.observe(nowUs() -| start_us);
}
pub fn gameJoin(r: Join, start_us: u64) void {
    inc(&joins[@backingInt(r)]);
    join_seconds.observe(nowUs() -| start_us);
}

const W = struct {
    buf: []u8,
    n: usize = 0,
    fn p(w: *W, comptime fmt: []const u8, args: anytype) void {
        const s = std.mem.print(w.buf[w.n..], fmt, args) catch {
            w.n = w.buf.len;
            return;
        };
        w.n += s.len;
    }
};

fn labelled(w: *W, comptime name: []const u8, comptime kind: []const u8, comptime label: []const u8, comptime E: type, arr: anytype, help: []const u8) void {
    w.p("# HELP {s} {s}\n# TYPE {s} " ++ kind ++ "\n", .{ name, help, name });
    inline for (@typeInfo(E).@"enum".field_names, 0..) |field_name, i| {
        w.p("{s}{{{s}=\"{s}\"}} {d}\n", .{ name, label, field_name, arr[i].load(.monotonic) });
    }
}

fn histogram(w: *W, comptime name: []const u8, h: *Histogram, help: []const u8) void {
    w.p("# HELP {s} {s}\n# TYPE {s} histogram\n", .{ name, help, name });
    for (buckets, 0..) |b, j| w.p("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ name, b, h.le[j].load(.monotonic) });
    const count = h.count.load(.monotonic);
    w.p("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ name, count });
    w.p("{s}_sum {d}\n", .{ name, @as(f64, @floatFromInt(h.sum_us.load(.monotonic))) / 1e6 });
    w.p("{s}_count {d}\n", .{ name, count });
}

pub fn render(out: []u8) []const u8 {
    var w = W{ .buf = out };
    labelled(&w, "realmd_connections", "gauge", "protocol", Protocol, &connections, "Client connections open on this instance");
    labelled(&w, "realmd_sessions", "gauge", "protocol", Protocol, &sessions, "Open connections that have logged in");
    w.p("# HELP realmd_logons_total Account logons, by how they were decided and the answer\n# TYPE realmd_logons_total counter\n", .{});
    inline for (@typeInfo(Logon).@"enum".field_names, 0..) |_, i| {
        const l: Logon = @fromBackingInt(i);
        w.p("realmd_logons_total{{method=\"{s}\",result=\"{s}\"}} {d}\n", .{ l.method(), l.result(), logons[i].load(.monotonic) });
    }
    labelled(&w, "realmd_char_logons_total", "counter", "result", CharLogon, &char_logons, "Character selections (MCP_CHARLOGON)");
    labelled(&w, "realmd_game_creates_total", "counter", "result", Create, &creates, "Game creates (MCP_CREATEGAME)");
    labelled(&w, "realmd_game_joins_total", "counter", "result", Join, &joins, "Game joins (MCP_JOINGAME)");
    histogram(&w, "realmd_game_create_seconds", &create_seconds, "Time from a create request to its answer, the game server round trip included");
    histogram(&w, "realmd_game_join_seconds", &join_seconds, "Time from a join request to its answer, the waits for a create or a seat included");
    return out[0..w.n];
}

test "the exposition names every label value and counts what was recorded" {
    logon(.extension_ok);
    gameJoin(.full, nowUs() -| 30_000);
    connectionOpened(.mcp);
    sessionChanged(.mcp, false, true);
    var buf: [16384]u8 = undefined;
    const text = render(&buf);
    const has = struct {
        fn f(t: []const u8, s: []const u8) !void {
            if (std.mem.indexOf(u8, t, s) == null) {
                std.debug.print("missing: {s}\n", .{s});
                return error.Missing;
            }
        }
    }.f;
    try has(text, "realmd_logons_total{method=\"extension\",result=\"ok\"} 1\n");
    try has(text, "realmd_logons_total{method=\"mcp_session\",result=\"unknown_session\"} 0\n");
    try has(text, "realmd_logons_total{method=\"nls\",result=\"unsupported\"} 0\n");
    try has(text, "realmd_game_joins_total{result=\"full\"} 1\n");
    try has(text, "realmd_game_joins_total{result=\"ok\"} 0\n");
    try has(text, "realmd_game_creates_total{result=\"no_gs\"} 0\n");
    try has(text, "realmd_connections{protocol=\"mcp\"} 1\n");
    try has(text, "realmd_sessions{protocol=\"mcp\"} 1\n");
    try has(text, "realmd_sessions{protocol=\"bncs\"} 0\n");
    try has(text, "realmd_game_join_seconds_bucket{le=\"0.025\"} 0\n");
    try has(text, "realmd_game_join_seconds_bucket{le=\"0.05\"} 1\n");
    try has(text, "realmd_game_join_seconds_bucket{le=\"+Inf\"} 1\n");
    try has(text, "realmd_game_join_seconds_count 1\n");
    try has(text, "realmd_game_create_seconds_count 0\n");
    try std.testing.expect(text.len < buf.len);
}
