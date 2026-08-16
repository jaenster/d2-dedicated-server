//! Types shared by the persistence facade (store.zig) and its backends.
pub const max_chars = 16;

pub const Name = struct {
    buf: [32]u8 = [_]u8{0} ** 32,
    len: u8 = 0,
    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
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
};

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
