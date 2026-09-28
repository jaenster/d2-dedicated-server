//! Everything one e2e run occupies on the host, derived from a single number: E2E_PORT_BASE.
//!
//! Two runs on one machine must not share anything — a port, a store container, a data dir.
//! They used to share almost everything: the store containers had fixed names (and each run
//! began by `docker rm -f`-ing them, killing the other run's stores mid-scenario), the stores
//! and every secondary realmd sat on literal ports, and the data dirs were fixed paths. Moving
//! the bnet port alone isolated nothing.
//!
//! So every port, container name and data dir comes from here and nowhere else.
//!
//! The rule for choosing a base: a run owns the block [base, base + span). A base is valid when
//!   * it is a multiple of `span` (100), so two different valid bases can never overlap, or it
//!     is the default 6112 (what a plain `zig build e2e` uses);
//!   * its block fits below 65536 and starts at or above 1024;
//!   * its block does not overlap the default block [6112, 6212), i.e. 6100 and 6200 are refused.
//! Concurrent runs therefore just pick different multiples of 100: 23000, 27000, 30000, 34000.
const std = @import("std");

pub const default_base: u16 = 6112;
/// Ports one run may use: [base, base + span). Every offset below is < span.
pub const span: u16 = 100;
pub const min_base: u16 = 1024;
pub const max_base: u16 = 65535 - (span - 1);

/// The two ports a realmd binds (game_port is separate, and only the edge instance sets it).
pub const Realmd = struct { bnet: u16, health: u16 };

pub const Error = error{ NotANumber, OutOfRange, NotOnGrid, OverlapsDefault };

/// A NUL-terminated name kept inside the layout, so the layout can be a plain value.
pub const Name = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn init(comptime fmt: []const u8, args: anytype) Name {
        var n = Name{};
        const s = std.fmt.bufPrintZ(&n.buf, fmt, args) catch unreachable; // bounded: a u16 and a short literal
        n.len = s.len;
        return n;
    }

    pub fn get(self: *const Name) [:0]const u8 {
        return self.buf[0..self.len :0];
    }
};

pub const Layout = struct {
    base: u16,

    /// The harness's own realmd; clients dial `main.bnet` (MCP is muxed onto it).
    main: Realmd,
    redis: u16,
    postgres: u16,
    /// The standalone d2ingress in d2ingress_token_translate.
    ingress: u16,
    /// Two instances over one store: chat_across_instances and multi_instance (run one after
    /// the other, so they share the pair).
    peer_a: Realmd,
    peer_b: Realmd,
    /// The realmd whose embedded game edge embedded_game_edge drives, and that edge.
    edge: Realmd,
    edge_game: u16,
    /// banner_ad's dedicated instance.
    ad: Realmd,
    /// friends_persist: the instance that writes, and the cold one that must read it back.
    friends_writer: Realmd,
    friends_cold: Realmd,

    redis_container: Name,
    postgres_container: Name,
    data_dir: Name,
    friends_dir: Name,
    shared_dir: Name,
    edge_dir: Name,

    /// Every port this run binds or tells a child to bind.
    pub fn ports(self: *const Layout) [18]u16 {
        return .{
            self.main.bnet,           self.main.health,
            self.redis,               self.postgres,
            self.ingress,             self.peer_a.bnet,
            self.peer_a.health,       self.peer_b.bnet,
            self.peer_b.health,       self.edge.bnet,
            self.edge.health,         self.edge_game,
            self.ad.bnet,             self.ad.health,
            self.friends_writer.bnet, self.friends_writer.health,
            self.friends_cold.bnet,   self.friends_cold.health,
        };
    }
};

/// Check a base against the rule above.
pub fn validate(base: u16) Error!void {
    if (base < min_base or base > max_base) return error.OutOfRange;
    if (base == default_base) return;
    if (base % span != 0) return error.NotOnGrid;
    if (base < default_base + span and base + span > default_base) return error.OverlapsDefault;
}

pub fn forBase(base: u16) Error!Layout {
    try validate(base);
    const b = base;
    return .{
        .base = b,
        .main = .{ .bnet = b + 0, .health = b + 1 },
        .redis = b + 2,
        .postgres = b + 3,
        .ingress = b + 4,
        .peer_a = .{ .bnet = b + 10, .health = b + 11 },
        .peer_b = .{ .bnet = b + 12, .health = b + 13 },
        .edge = .{ .bnet = b + 14, .health = b + 15 },
        .edge_game = b + 16,
        .ad = .{ .bnet = b + 20, .health = b + 21 },
        .friends_writer = .{ .bnet = b + 22, .health = b + 23 },
        .friends_cold = .{ .bnet = b + 24, .health = b + 25 },
        .redis_container = Name.init("e2e-redis-{d}", .{b}),
        .postgres_container = Name.init("e2e-postgres-{d}", .{b}),
        .data_dir = Name.init("/tmp/e2e-realmd-{d}", .{b}),
        .friends_dir = Name.init("/tmp/e2e-realmd-friends-{d}", .{b}),
        .shared_dir = Name.init("/tmp/e2e-realmd-shared-{d}", .{b}),
        .edge_dir = Name.init("/tmp/e2e-realmd-edge-{d}", .{b}),
    };
}

/// The layout for E2E_PORT_BASE's value; null (unset) or empty means the default base.
pub fn fromEnv(value: ?[]const u8) Error!Layout {
    const v = value orelse return forBase(default_base);
    if (v.len == 0) return forBase(default_base);
    const base = std.fmt.parseInt(u16, v, 10) catch |e| return switch (e) {
        error.Overflow => error.OutOfRange,
        error.InvalidCharacter => error.NotANumber,
    };
    return forBase(base);
}

/// One line saying what is wrong with a base and what to pick instead.
pub fn explain(err: Error) []const u8 {
    return switch (err) {
        error.NotANumber => "E2E_PORT_BASE is not a number",
        error.OutOfRange => std.fmt.comptimePrint("E2E_PORT_BASE must be within [{d}, {d}] so the run's {d}-port block fits", .{ min_base, max_base, span }),
        error.NotOnGrid => std.fmt.comptimePrint("E2E_PORT_BASE must be a multiple of {d} (or {d}), so concurrent runs cannot overlap; e.g. 23000, 30000, 34000", .{ span, default_base }),
        error.OverlapsDefault => std.fmt.comptimePrint("E2E_PORT_BASE overlaps the default run's block [{d}, {d})", .{ default_base, default_base + span }),
    };
}

fn validBases(out: []u16) []u16 {
    var n: usize = 0;
    var b: u32 = 0;
    while (b <= 65535) : (b += 1) {
        validate(@intCast(b)) catch continue;
        out[n] = @intCast(b);
        n += 1;
    }
    return out[0..n];
}

test "every port of a run is distinct and inside its block" {
    var buf: [1024]u16 = undefined;
    const bases = validBases(&buf);
    try std.testing.expect(bases.len > 600);
    for (bases) |b| {
        const l = try forBase(b);
        const ps = l.ports();
        for (ps, 0..) |p, i| {
            try std.testing.expect(p >= b and p < @as(u32, b) + span);
            for (ps[i + 1 ..]) |q| try std.testing.expect(p != q);
        }
    }
}

test "no two valid bases share a port" {
    var buf: [1024]u16 = undefined;
    const bases = validBases(&buf); // ascending
    for (bases[0 .. bases.len - 1], bases[1..]) |lo, hi| {
        try std.testing.expect(@as(u32, lo) + span <= hi);
    }
    // And concretely, for the pair a concurrent check uses.
    const a = try forBase(30000);
    const b = try forBase(34000);
    for (a.ports()) |p| for (b.ports()) |q| try std.testing.expect(p != q);
    try std.testing.expect(!std.mem.eql(u8, a.redis_container.get(), b.redis_container.get()));
    try std.testing.expect(!std.mem.eql(u8, a.data_dir.get(), b.data_dir.get()));
}

test "bad bases are refused" {
    try std.testing.expectError(error.NotOnGrid, forBase(7112));
    try std.testing.expectError(error.NotOnGrid, forBase(30001));
    try std.testing.expectError(error.OverlapsDefault, forBase(6100));
    try std.testing.expectError(error.OverlapsDefault, forBase(6200));
    try std.testing.expectError(error.OutOfRange, forBase(1000));
    try std.testing.expectError(error.OutOfRange, forBase(0));
    try std.testing.expectError(error.OutOfRange, forBase(65500));
    try std.testing.expectError(error.OutOfRange, fromEnv("70000"));
    try std.testing.expectError(error.NotANumber, fromEnv("30k"));
    _ = try forBase(65400);
    _ = try forBase(6300);
}

test "unset keeps the default run" {
    const l = try fromEnv(null);
    try std.testing.expectEqual(@as(u16, 6112), l.main.bnet);
    try std.testing.expectEqualStrings("e2e-redis-6112", l.redis_container.get());
    try std.testing.expectEqualStrings("/tmp/e2e-realmd-6112", l.data_dir.get());
    const e = try fromEnv("");
    try std.testing.expectEqual(@as(u16, 6112), e.base);
}
