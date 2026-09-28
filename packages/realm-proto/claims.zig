//! A character's claim, as the realm and the game servers both read and write it in the shared
//! store. The realm takes the claim when it authorises a join; the game server that is about to
//! load the character into a game checks and marks it in the same store. Both sides run scripts
//! over the same keys, so the key names and the record format live here, once.
//!
//! Keys (all under `prefix`):
//!   charlock:<account>/<char>  = "game:<ref>"   who holds the character (a lease)
//!   charjoin:<account>/<char>  = "<ref>|<session>|<flags>|<ms>"   the claim is still pending
//!   charleft:<account>/<char>  = "<ref>"        a pending claim withdrawn as abandoned
//!   gamechars:<ref>            = set of "<account>/<char>" the game holds
//!   game:byid:<ref>            = the game's name, while it is listed
//! where <ref> is `GameRef.text`: "<gsid hex>.<gameid>". Engine gameids are per server.
//!
//! Pending-claim flags:
//!   'L'  this claim took over a pending claim on the SAME game; the first departure reported
//!        for the character is that earlier attempt's and is absorbed.
//!   'D'  a game server has loaded the character for this claim. The claim is no longer an
//!        abandoned join that anyone may take over: only its own departure, the game ending, or
//!        the longer loaded grace frees it.
const std = @import("std");

pub const prefix = "realmd:";

/// Lua: `parse_join(v)` -> gref, session, flags, ms (number), or nil. A record without the flags
/// field ("<ref>|<session>|<ms>") reads as having none.
pub const lua_parse_join =
    \\local function parse_join(v)
    \\  if not v then return nil end
    \\  local g, s, rest = string.match(v, '^([^|]+)|([^|]*)|(.*)$')
    \\  if not g then return nil end
    \\  local f, at = string.match(rest, '^([^|]*)|(%d+)$')
    \\  if not f then f, at = '', string.match(rest, '^(%d+)$') end
    \\  if not at then return nil end
    \\  return g, s, f, tonumber(at)
    \\end
    \\
;

/// What a game server's check at character load decided.
pub const Load = enum {
    /// The claim is this game's; it is now marked loaded.
    ours,
    /// Nothing held the character and this game is listed: the claim is this game's now.
    reclaimed,
    /// Nothing holds it and there is no game to give it to. The realm never claimed it (or the
    /// claim is gone); nothing contradicts the load.
    unclaimed,
    /// The claim points at another game. The load must be refused: the realm has since handed the
    /// character elsewhere, and loading it here would put it in two games.
    refused,
    /// The store did not answer. The caller decides; a server that cannot ask cannot know.
    unknown,

    pub fn allowed(l: Load) bool {
        return l != .refused;
    }
};

/// KEYS: charlock, charjoin. ARGV: gsid hex, gameid (decimal, '' when the host does not know it),
/// member, lock px, prefix, game ttl s.
const load_script = lua_parse_join ++
    \\local mine = 'game:' .. ARGV[1] .. '.'
    \\local holder = redis.call('GET', KEYS[1])
    \\if holder then
    \\  if ARGV[2] ~= '' then
    \\    if holder ~= mine .. ARGV[2] then return -1 end
    \\  elseif string.sub(holder, 1, string.len(mine)) ~= mine then
    \\    return -1
    \\  end
    \\  local g, s, f, at = parse_join(redis.call('GET', KEYS[2]))
    \\  if g and ('game:' .. g) == holder and not string.find(f, 'D', 1, true) then
    \\    redis.call('SET', KEYS[2], g .. '|' .. s .. '|' .. f .. 'D|' .. string.format('%d', at), 'KEEPTTL')
    \\  end
    \\  return 1
    \\end
    \\if ARGV[2] == '' then return 0 end
    \\local ref = ARGV[1] .. '.' .. ARGV[2]
    \\if redis.call('EXISTS', ARGV[5] .. 'game:byid:' .. ref) == 0 then return 0 end
    \\redis.call('SET', KEYS[1], 'game:' .. ref, 'PX', ARGV[4])
    \\local sk = ARGV[5] .. 'gamechars:' .. ref
    \\redis.call('SADD', sk, ARGV[3])
    \\redis.call('EXPIRE', sk, ARGV[6])
    \\redis.call('DEL', ARGV[5] .. 'charleft:' .. ARGV[3])
    \\return 2
;

/// How long a claim lasts without renewal, and how long a game's records last. The realm owns
/// both numbers; a game server taking a claim back uses the same ones.
pub const lock_ttl_s: u32 = 300;
pub const game_ttl_s: u32 = 21600;

/// The buffers one load check's arguments live in.
pub const LoadCall = struct {
    lock: [128]u8 = undefined,
    join: [128]u8 = undefined,
    gsid: [16]u8 = undefined,
    gameid: [16]u8 = undefined,
    member: [96]u8 = undefined,
    px: [16]u8 = undefined,
    ttl: [16]u8 = undefined,
    argv: [11][]const u8 = undefined,

    /// The EVAL command for checking and marking `account`/`charname` as loaded into game
    /// `gameid` (0 = the host cannot say which) on server `gsid`. Null if a name does not fit.
    pub fn command(c: *LoadCall, account: []const u8, charname: []const u8, gsid: u32, gameid: u32) ?[]const []const u8 {
        const member = std.fmt.bufPrint(&c.member, "{s}/{s}", .{ account, charname }) catch return null;
        c.argv = .{
            "EVAL",
            load_script,
            "2",
            std.fmt.bufPrint(&c.lock, prefix ++ "charlock:{s}", .{member}) catch return null,
            std.fmt.bufPrint(&c.join, prefix ++ "charjoin:{s}", .{member}) catch return null,
            std.fmt.bufPrint(&c.gsid, "{x}", .{gsid}) catch return null,
            if (gameid == 0) "" else std.fmt.bufPrint(&c.gameid, "{d}", .{gameid}) catch return null,
            member,
            std.fmt.bufPrint(&c.px, "{d}", .{@as(u64, lock_ttl_s) * 1000}) catch return null,
            prefix,
            std.fmt.bufPrint(&c.ttl, "{d}", .{game_ttl_s}) catch return null,
        };
        return &c.argv;
    }
};

/// The script's integer answer.
pub fn decodeLoad(v: i64) Load {
    return switch (v) {
        1 => .ours,
        2 => .reclaimed,
        0 => .unclaimed,
        -1 => .refused,
        else => .unknown,
    };
}

test "a load check names the claim's keys and this server" {
    var c = LoadCall{};
    const argv = c.command("acct", "Bob", 0xab10, 7400).?;
    try std.testing.expectEqualStrings("realmd:charlock:acct/Bob", argv[3]);
    try std.testing.expectEqualStrings("realmd:charjoin:acct/Bob", argv[4]);
    try std.testing.expectEqualStrings("ab10", argv[5]);
    try std.testing.expectEqualStrings("7400", argv[6]);
    try std.testing.expectEqualStrings("acct/Bob", argv[7]);
    const unknown = c.command("acct", "Bob", 0xab10, 0).?;
    try std.testing.expectEqualStrings("", unknown[6]);
}
