//! What a game server says about itself over HTTP, for every engine this repo hosts.
//!
//! Pure rendering: a caller hands over a `Snapshot` of what it already knows and gets back bytes.
//! No sockets here on purpose — `d2gs` and `d2host` are Windows images and reach the network
//! through winsock, `d2gs-native` is a static Linux binary and reaches it through libc, and each
//! keeps its own listener. What must NOT differ between them is the vocabulary: a dashboard panel
//! or a probe that works against one engine has to work against all of them, and that is the thing
//! this file owns.
//!
//! The metric names are the ones `apps/d2gs/runtime/feature/stats.zig` already publishes, because
//! those are what the realm dashboard queries. Anything that engine can only answer with a hook
//! into its own game loop — items rolled, players joined, Fog pool managers — stays there and is
//! appended after this block. A host that cannot measure something omits the metric rather than
//! reporting zero: absent reads as "not measured here" in a query, where zero reads as "measured,
//! and it is none", and the two are very different when an engine goes quiet.
const std = @import("std");

/// Everything the shared block reports. A host fills in what it knows; `null` omits the metric.
pub const Snapshot = struct {
    /// The engine is still stepping. The ONLY input to liveness — a wedged server still accepts
    /// sockets and would otherwise answer 200 forever, which is the failure this exists to catch.
    alive: bool,
    /// This server is in the realm's fleet registry. Strictly narrower than alive: a live but
    /// unpublished server has nowhere for a routed game to land.
    published: bool,
    /// The engine tag, as the fleet publishes it ("1.09d", "1.14d"). Becomes a label so one scrape
    /// config covers a multi-era realm.
    engine: []const u8,
    /// This server's id in the fleet, for lining a scrape up with `realmd:gs:<id>` in the store.
    gsid: u32,
    uptime_s: u32,
    /// Ticks the host has run, and the rate over the last sample window in hundredths.
    ticks: u32,
    tick_rate_x100: u32,
    games_live: u32,
    /// What this server advertises it can host. Differs per engine and per deployment, so it is
    /// worth publishing next to the live count rather than assumed to be seven.
    games_max: u32,
    /// Game frames handed to the engine and flushed. Advances only while a game exists, so it is
    /// the one counter that distinguishes "idle" from "wedged with players in it".
    game_frames: ?u32 = null,
    /// Lifetime totals. A host that has no hook for one leaves it null rather than reporting zero:
    /// absent reads as "not measured here" in a query, zero reads as "measured, and it is none".
    games_created: ?u32 = null,
    games_destroyed: ?u32 = null,
    players_joined: ?u32 = null,
};

pub const Answer = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const ok_body = "ok\n";
const down_body = "down\n";
const notready_body = "not ready\n";

/// Route a request path to its answer. Anything unrecognised gets liveness, which is what the
/// original single-endpoint probe asked for and what a malformed request should still get.
///
/// `buf` is only touched for the rendered formats; the text answers are static.
pub fn route(path: []const u8, snap: Snapshot, buf: []u8) Answer {
    if (std.mem.eql(u8, path, "/metrics")) {
        return .{ .status = "200 OK", .content_type = "text/plain; version=0.0.4", .body = writeMetrics(snap, buf) };
    }
    if (std.mem.eql(u8, path, "/stats")) {
        return .{ .status = "200 OK", .content_type = "application/json", .body = writeJson(snap, buf) };
    }
    if (std.mem.eql(u8, path, "/readyz")) {
        return if (snap.alive and snap.published)
            .{ .status = "200 OK", .content_type = "text/plain", .body = ok_body }
        else
            .{ .status = "503 Service Unavailable", .content_type = "text/plain", .body = notready_body };
    }
    return if (snap.alive)
        .{ .status = "200 OK", .content_type = "text/plain", .body = ok_body }
    else
        .{ .status = "503 Service Unavailable", .content_type = "text/plain", .body = down_body };
}

/// The request path, as a slice of `req`. Anything unparseable reads as "/" so a malformed
/// request gets the liveness answer rather than an error.
pub fn pathOf(req: []const u8) []const u8 {
    var i: usize = 0;
    while (i < req.len and req[i] != ' ') : (i += 1) {}
    i += 1;
    if (i >= req.len) return "/";
    var j = i;
    while (j < req.len and req[j] != ' ' and req[j] != '?' and req[j] != '\r' and req[j] != '\n') : (j += 1) {}
    if (j == i) return "/";
    return req[i..j];
}

/// The shared metric block. `stats.zig` calls this and appends its engine-specific series, so the
/// names below have exactly one definition across every server.
pub fn writeMetrics(snap: Snapshot, buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };
    writeMetricsTo(&w, snap);
    return w.done();
}

pub fn writeMetricsTo(w: *Writer, snap: Snapshot) void {
    w.metric("d2gs_uptime_seconds", "gauge", "Seconds since this server started", snap.uptime_s);
    w.metric("d2gs_ticks_total", "counter", "Server ticks executed", snap.ticks);

    w.put("# HELP d2gs_tick_rate Server ticks per second, sampled each second\n# TYPE d2gs_tick_rate gauge\nd2gs_tick_rate ");
    w.fixed2(snap.tick_rate_x100);
    w.put("\n");

    w.metric("d2gs_ready", "gauge", "1 when this GS is registered with the realm", @intFromBool(snap.published));
    w.metric("d2gs_games_live", "gauge", "Games currently hosted", snap.games_live);
    w.metric("d2gs_games_max", "gauge", "Games this server advertises it can host", snap.games_max);
    if (snap.game_frames) |f| {
        w.metric("d2gs_game_frames_total", "counter", "Game frames processed and flushed", f);
    }
    if (snap.games_created) |v| w.metric("d2gs_games_created_total", "counter", "Games created on this GS", v);
    if (snap.games_destroyed) |v| w.metric("d2gs_games_destroyed_total", "counter", "Games destroyed on this GS", v);
    if (snap.players_joined) |v| w.metric("d2gs_players_joined_total", "counter", "Player joins seen", v);

    // The engine as a label on a constant, which is how a scrape tells five eras apart without a
    // scrape config per era. `gsid` rides along so a series can be lined up with the fleet record.
    w.put("# HELP d2gs_engine_info The engine this server runs\n# TYPE d2gs_engine_info gauge\nd2gs_engine_info{engine=\"");
    w.put(snap.engine);
    w.put("\",gsid=\"");
    w.num(snap.gsid);
    w.put("\"} 1\n");
}

pub fn writeJson(snap: Snapshot, buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };
    w.put("{\"engine\":\"");
    w.put(snap.engine);
    w.put("\",\"gsid\":");
    w.num(snap.gsid);
    w.put(",\"alive\":");
    w.put(if (snap.alive) "true" else "false");
    w.put(",\"ready\":");
    w.put(if (snap.alive and snap.published) "true" else "false");
    w.put(",\"uptime_s\":");
    w.num(snap.uptime_s);
    w.put(",\"ticks\":");
    w.num(snap.ticks);
    w.put(",\"tick_rate\":");
    w.fixed2(snap.tick_rate_x100);
    w.put(",\"games_live\":");
    w.num(snap.games_live);
    w.put(",\"games_max\":");
    w.num(snap.games_max);
    if (snap.game_frames) |f| {
        w.put(",\"game_frames\":");
        w.num(f);
    }
    w.put("}\n");
    return w.done();
}

/// The response head. Separate from the body so a host can send them with two writes and never
/// need a buffer big enough for both.
pub fn head(a: Answer, buf: []u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ a.status, a.content_type, a.body.len },
    ) catch buf[0..0];
}

/// Ticks per second in hundredths, from two samples. Kept here so every host measures the rate
/// the same way rather than each inventing a window.
pub fn tickRateX100(ticks_delta: u32, ms_delta: u32) u32 {
    if (ms_delta == 0) return 0;
    return @intCast(@min(@as(u64, ticks_delta) * 100_000 / ms_delta, std.math.maxInt(u32)));
}

/// Append-only writer over a caller-supplied buffer. Once full it drops the rest instead of
/// failing: the head of the document is the part that matters, and both formats are written
/// head-first, totals before any unbounded per-game list.
pub const Writer = struct {
    buf: []u8,
    n: usize = 0,

    pub fn put(self: *Writer, s: []const u8) void {
        const room = self.buf.len - self.n;
        const k = @min(room, s.len);
        @memcpy(self.buf[self.n..][0..k], s[0..k]);
        self.n += k;
    }

    pub fn num(self: *Writer, v: u32) void {
        var tmp: [12]u8 = undefined;
        self.put(std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return);
    }

    /// A value carried as hundredths, printed as a decimal ("2543" -> "25.43").
    pub fn fixed2(self: *Writer, v: u32) void {
        var tmp: [16]u8 = undefined;
        self.put(std.fmt.bufPrint(&tmp, "{d}.{d:0>2}", .{ v / 100, v % 100 }) catch return);
    }

    pub fn metric(self: *Writer, name: []const u8, kind: []const u8, help: []const u8, v: u32) void {
        self.put("# HELP ");
        self.put(name);
        self.put(" ");
        self.put(help);
        self.put("\n# TYPE ");
        self.put(name);
        self.put(" ");
        self.put(kind);
        self.put("\n");
        self.put(name);
        self.put(" ");
        self.num(v);
        self.put("\n");
    }

    pub fn done(self: *Writer) []const u8 {
        return self.buf[0..self.n];
    }
};

const testing = std.testing;

const sample = Snapshot{
    .alive = true,
    .published = true,
    .engine = "1.09d",
    .gsid = 10900,
    .uptime_s = 61,
    .ticks = 6100,
    .tick_rate_x100 = 9987,
    .games_live = 2,
    .games_max = 7,
    .game_frames = 4242,
    .games_created = 11,
    .games_destroyed = 9,
    .players_joined = 34,
};

test "a path is the second token, and anything else is liveness" {
    try testing.expectEqualStrings("/metrics", pathOf("GET /metrics HTTP/1.1\r\n"));
    try testing.expectEqualStrings("/readyz", pathOf("GET /readyz?x=1 HTTP/1.1\r\n"));
    try testing.expectEqualStrings("/", pathOf("GET"));
    try testing.expectEqualStrings("/", pathOf(""));
}

test "ready is narrower than alive" {
    var buf: [64]u8 = undefined;
    var s = sample;
    try testing.expectEqualStrings("200 OK", route("/readyz", s, &buf).status);
    s.published = false;
    try testing.expectEqualStrings("503 Service Unavailable", route("/readyz", s, &buf).status);
    // ...but an unpublished server is still ALIVE, and must not be restarted for it.
    try testing.expectEqualStrings("200 OK", route("/healthz", s, &buf).status);
    s.alive = false;
    try testing.expectEqualStrings("503 Service Unavailable", route("/healthz", s, &buf).status);
}

test "the shared metric block, in full" {
    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        \\# HELP d2gs_uptime_seconds Seconds since this server started
        \\# TYPE d2gs_uptime_seconds gauge
        \\d2gs_uptime_seconds 61
        \\# HELP d2gs_ticks_total Server ticks executed
        \\# TYPE d2gs_ticks_total counter
        \\d2gs_ticks_total 6100
        \\# HELP d2gs_tick_rate Server ticks per second, sampled each second
        \\# TYPE d2gs_tick_rate gauge
        \\d2gs_tick_rate 99.87
        \\# HELP d2gs_ready 1 when this GS is registered with the realm
        \\# TYPE d2gs_ready gauge
        \\d2gs_ready 1
        \\# HELP d2gs_games_live Games currently hosted
        \\# TYPE d2gs_games_live gauge
        \\d2gs_games_live 2
        \\# HELP d2gs_games_max Games this server advertises it can host
        \\# TYPE d2gs_games_max gauge
        \\d2gs_games_max 7
        \\# HELP d2gs_game_frames_total Game frames processed and flushed
        \\# TYPE d2gs_game_frames_total counter
        \\d2gs_game_frames_total 4242
        \\# HELP d2gs_games_created_total Games created on this GS
        \\# TYPE d2gs_games_created_total counter
        \\d2gs_games_created_total 11
        \\# HELP d2gs_games_destroyed_total Games destroyed on this GS
        \\# TYPE d2gs_games_destroyed_total counter
        \\d2gs_games_destroyed_total 9
        \\# HELP d2gs_players_joined_total Player joins seen
        \\# TYPE d2gs_players_joined_total counter
        \\d2gs_players_joined_total 34
        \\# HELP d2gs_engine_info The engine this server runs
        \\# TYPE d2gs_engine_info gauge
        \\d2gs_engine_info{engine="1.09d",gsid="10900"} 1
        \\
    , writeMetrics(sample, &buf));
}

test "a host that cannot measure game frames omits the series" {
    var buf: [2048]u8 = undefined;
    var s = sample;
    s.game_frames = null;
    const out = writeMetrics(s, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "d2gs_game_frames_total") == null);
    try testing.expect(std.mem.indexOf(u8, out, "d2gs_games_live 2") != null);
}

test "the json says the same things" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"engine\":\"1.09d\",\"gsid\":10900,\"alive\":true,\"ready\":true,\"uptime_s\":61," ++
            "\"ticks\":6100,\"tick_rate\":99.87,\"games_live\":2,\"games_max\":7,\"game_frames\":4242}\n",
        writeJson(sample, &buf),
    );
}

test "the head carries the rendered length" {
    var body: [2048]u8 = undefined;
    var hb: [160]u8 = undefined;
    const a = route("/healthz", sample, &body);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\n",
        head(a, &hb),
    );
}

test "the rate is hundredths of a tick per second" {
    try testing.expectEqual(@as(u32, 100), tickRateX100(1, 1000)); // 1 tick/s
    try testing.expectEqual(@as(u32, 10000), tickRateX100(100, 1000)); // 100 ticks/s
    try testing.expectEqual(@as(u32, 0), tickRateX100(5, 0)); // no window yet, no answer
}

test "a full buffer truncates rather than fails" {
    var tiny: [40]u8 = undefined;
    const out = writeMetrics(sample, &tiny);
    try testing.expectEqual(@as(usize, 40), out.len);
    try testing.expect(std.mem.startsWith(u8, out, "# HELP d2gs_uptime_seconds"));
}
