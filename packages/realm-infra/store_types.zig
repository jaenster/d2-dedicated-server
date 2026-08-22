//! Types shared by the persistence facade (store.zig) and its backends.
const std = @import("std");

pub const max_chars = 16;

pub const Name = struct {
    buf: [32]u8 = [_]u8{0} ** 32,
    len: u8 = 0,
    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

/// How an engine version is spelled everywhere it is compared: the same string a game server
/// publishes as its `v=` label, which is the name in `d2engine.version.spec()` ("1.09d", "1.14d").
/// Short and fixed because it is carried on records the store hands back by value.
pub const version_max = 12;

pub const VersionTag = struct {
    buf: [version_max]u8 = [_]u8{0} ** version_max,
    len: u8 = 0,
    pub fn slice(v: *const VersionTag) []const u8 {
        return v.buf[0..v.len];
    }
    pub fn set(v: *VersionTag, s: []const u8) void {
        const n = @min(s.len, version_max);
        @memcpy(v.buf[0..n], s[0..n]);
        v.len = @intCast(n);
    }
    /// An empty tag is "no engine recorded", which every caller must read as "no constraint"
    /// rather than as a mismatch — characters that predate the column have exactly this.
    pub fn known(v: *const VersionTag) bool {
        return v.len != 0;
    }
    /// Whether a character with this tag may be handed to something carrying `other`. Either side
    /// being unknown allows it: the realm refuses on a genuine disagreement, not on missing data.
    pub fn compatible(v: *const VersionTag, other: []const u8) bool {
        if (v.len == 0 or other.len == 0) return true;
        return std.mem.eql(u8, v.slice(), other);
    }
};

/// One character as the realm lists it: the name the client shows, and the engine it belongs to.
pub const CharRec = struct {
    name: Name = .{},
    version: VersionTag = .{},
};

/// Longest key an extension may address its own keyspace with. Generous next to `Name` because
/// nothing here is a D2 name — an extension keys by whatever it likes ("season:3:leader").
pub const ext_key_max = 96;

/// One key in an extension's keyspace, as returned by a listing. Fixed-size for the same reason
/// `Name` is: the store hands these back into a caller-owned array and allocates nothing.
pub const ExtKey = struct {
    buf: [ext_key_max]u8 = [_]u8{0} ** ext_key_max,
    len: u8 = 0,
    pub fn slice(k: *const ExtKey) []const u8 {
        return k.buf[0..k.len];
    }
    pub fn set(k: *ExtKey, s: []const u8) void {
        const n = @min(s.len, ext_key_max);
        @memcpy(k.buf[0..n], s[0..n]);
        k.len = @intCast(n);
    }
};

/// A hosted game as resolved from the store: engine gameid, the address clients dial,
/// and which GS in the fleet hosts it.
pub const GameRec = struct {
    gameid: u32,
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
    gsid: u32 = 0,
    /// Player count shown in the join-screen list. realmd seeds it optimistically on
    /// create/join; the hosting GS then overwrites it with its own client count, which
    /// is the only number that also goes DOWN when someone leaves.
    players: u16 = 0,
    /// The creator's character status bits (.d2s 0x24: hardcore 0x04, expansion 0x20,
    /// ladder 0x40) — what KIND of game this is. A joining character has to match, and
    /// the client has a distinct error message for each way it can fail to.
    status: u8 = 0,
    /// 0 Normal, 1 Nightmare, 2 Hell. A character has to have progressed far enough to be
    /// allowed in, and the client has a specific message for each way that can fail.
    difficulty: u8 = 0,
    /// Game join password (empty = open game). Stored with the record so any realmd
    /// instance can validate a join. D2 passwords are short alphanumeric (no spaces).
    password: [16]u8 = [_]u8{0} ** 16,
    pw_len: u8 = 0,
    /// The creator's game description, shown beside the name on the join screen. Sized to
    /// the engine's own `szGameDescription[32]`. Unlike the password it may contain spaces,
    /// so the flat-text backends store it last, as the remainder of the record.
    description: [32]u8 = [_]u8{0} ** 32,
    desc_len: u8 = 0,

    pub fn pw(g: *const GameRec) []const u8 {
        return g.password[0..g.pw_len];
    }
    pub fn setPw(g: *GameRec, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, g.password.len));
        @memcpy(g.password[0..n], s[0..n]);
        g.pw_len = n;
    }
    pub fn desc(g: *const GameRec) []const u8 {
        return g.description[0..g.desc_len];
    }
    pub fn setDesc(g: *GameRec, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, g.description.len));
        @memcpy(g.description[0..n], s[0..n]);
        g.desc_len = n;
    }
};

/// The backend GS a client's game traffic should be spliced to — keyed by the client's
/// source IP, recorded by realmd on JOINGAME and looked up by the d2ingress per connection.
pub const Route = struct {
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
};

/// Token-keyed route — the NAT-proof replacement for source-IP routing. realmd mints a
/// realm-globally-unique u16 token per CREATE/JOIN, hands it to the client, and records it here
/// against the owning GS plus the engine's real gameid. d2ingress reads the token off the
/// client's first GAMELOGON packet, rewrites it to `gameid`, and splices to gs_ip:gs_port.
pub const TokenRoute = struct {
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
    gameid: u32,
};

/// One game server as the whole realm sees it, rather than as the instance holding its control
/// connection sees it. Published by whichever realmd owns that connection and refreshed on the
/// link's own liveness traffic, so it expires by itself if that realmd dies with the socket.
///
/// This is the fleet's *view*, not its *reachability*: dispatch still travels the control socket,
/// so an instance can read a record here for a server it cannot itself talk to. What it buys is
/// that every instance sees the same capacity and load — without it a second realmd sees an empty
/// fleet and refuses every create.
pub const GsRec = struct {
    gsid: u32,
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
    /// Advertised capacity; 0 means the server did not say, i.e. unlimited.
    maxgame: u32 = 0,
    live_games: u32 = 0,
    /// The server itself answered "full" — it knows about slots still held by the reap window,
    /// which `live_games` cannot see.
    full: bool = false,
    /// What this server says it IS, as `k=v` pairs separated by newlines. A fleet is not
    /// interchangeable once it hosts more than one engine: a 1.10f client cannot be sent to a
    /// 1.13c server, so the realm has to be able to ask for one by what it is rather than take
    /// whichever has room.
    ///
    /// `v` is the engine version and the first label anything selects on (`v=1.10f`). Free-form on
    /// purpose — a server can publish whatever else it wants to be chosen by, and a realm that does
    /// not know a key simply never asks for it.
    ///
    /// Carried on the wire AFTER the fixed 15 bytes, which is what keeps an older reader working:
    /// it stops at 15 and never sees them, and the Lua that adjusts the live count preserves the
    /// tail (`string.sub(rec,15)`) rather than truncating it.
    labels: [labels_max]u8 = [_]u8{0} ** labels_max,
    labels_len: u8 = 0,

    pub fn setLabels(self: *GsRec, text: []const u8) void {
        const n = @min(text.len, labels_max);
        @memcpy(self.labels[0..n], text[0..n]);
        self.labels_len = @intCast(n);
    }

    /// The value of one label, or null when this server never published it. An absent label is not
    /// a mismatch — see `matchesLabel`.
    pub fn label(self: *const GsRec, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.labels[0..self.labels_len], '\n');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        return null;
    }

    /// Whether this server satisfies a `key=value` requirement.
    ///
    /// A server that does not publish the key at all does NOT match. That is deliberate: the
    /// alternative is a fleet where an unlabelled server answers every request, which is exactly
    /// the mistake that sends a 1.10f client to whatever happened to be free.
    pub fn matchesLabel(self: *const GsRec, key: []const u8, want: []const u8) bool {
        const have = self.label(key) orelse return false;
        return std.mem.eql(u8, have, want);
    }
};

/// Enough for a handful of short `k=v` pairs. Fixed rather than allocated: this record is written
/// on every heartbeat and every game create, on paths that do not allocate.
pub const labels_max = 96;

/// A game enumerated from the shared store (name + record) — used to serve /admin/games
/// when sessions/games live in redis/pg rather than the per-instance in-memory table.
pub const NamedGame = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    gameid: u32 = 0,
    gs_ip: [4]u8 = .{ 0, 0, 0, 0 },
    gs_port: u16 = 4000,
    gsid: u32 = 0,
    players: u16 = 0,
    /// The creator's character status bits — what KIND of game this is (hardcore 0x04,
    /// expansion 0x20, ladder 0x40). The join screen needs it for the same reason `GameRec`
    /// carries it: a listed game a character cannot legally enter should say so on the list
    /// rather than at the disconnect.
    status: u8 = 0,
    description: [32]u8 = [_]u8{0} ** 32,
    desc_len: u8 = 0,

    pub fn desc(g: *const NamedGame) []const u8 {
        return g.description[0..g.desc_len];
    }
    pub fn setDesc(g: *NamedGame, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, g.description.len));
        @memcpy(g.description[0..n], s[0..n]);
        g.desc_len = n;
    }
};


test "a server matches a label it published, and never one it did not" {
    var rec = GsRec{ .gsid = 1, .gs_ip = .{ 127, 0, 0, 1 } };
    rec.setLabels("v=1.10f\nrt=wine");

    try std.testing.expectEqualStrings("1.10f", rec.label("v").?);
    try std.testing.expectEqualStrings("wine", rec.label("rt").?);
    try std.testing.expect(rec.label("nope") == null);

    try std.testing.expect(rec.matchesLabel("v", "1.10f"));
    try std.testing.expect(!rec.matchesLabel("v", "1.13c"));
    // A prefix is not a match: 1.09b and 1.09d are different servers.
    try std.testing.expect(!rec.matchesLabel("v", "1.10"));

    // The case that matters most: a server that says nothing must NOT answer a request for a
    // specific engine. Matching an unlabelled server is how a 1.10f client ends up on a 1.13c
    // server, which does not degrade — it fails.
    var silent = GsRec{ .gsid = 2, .gs_ip = .{ 127, 0, 0, 1 } };
    try std.testing.expect(silent.label("v") == null);
    try std.testing.expect(!silent.matchesLabel("v", "1.10f"));
}
