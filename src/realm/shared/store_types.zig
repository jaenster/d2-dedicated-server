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
    /// Game join password (empty = open game). Stored with the record so any realmd
    /// instance can validate a join. D2 passwords are short alphanumeric (no spaces).
    password: [16]u8 = [_]u8{0} ** 16,
    pw_len: u8 = 0,

    pub fn pw(g: *const GameRec) []const u8 {
        return g.password[0..g.pw_len];
    }
    pub fn setPw(g: *GameRec, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, g.password.len));
        @memcpy(g.password[0..n], s[0..n]);
        g.pw_len = n;
    }
};

/// The backend GS a client's game traffic should be spliced to — keyed by the client's
/// source IP, recorded by realmd on JOINGAME and looked up by the qqserver per connection.
pub const Route = struct {
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
};

/// Token-keyed route — the NAT-proof replacement for source-IP routing. realmd mints a
/// realm-globally-unique u16 token per CREATE/JOIN, hands it to the client, and records
/// it here against the GS that owns the game plus the engine's real gameid. The qqserver
/// reads the token from the client's first GAMELOGON packet, looks this up, rewrites the
/// token in the packet to `gameid`, and splices to gs_ip:gs_port. Globally-unique tokens
/// mean two clients behind one public IP never collide.
pub const TokenRoute = struct {
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
    gameid: u32,
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
};
