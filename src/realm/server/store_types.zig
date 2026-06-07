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
};

/// The backend GS a client's game traffic should be spliced to — keyed by the client's
/// source IP, recorded by realmd on JOINGAME and looked up by the qqserver per connection.
pub const Route = struct {
    gs_ip: [4]u8,
    gs_port: u16 = 4000,
};
