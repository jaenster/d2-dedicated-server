//! Join context — bridges the account gap in Game.exe's dedicated-server path.
//!
//! When realmd dispatches a join over the gs-link (JOINGAME), it tells us which
//! account owns the joining character and the join token. The engine's join path
//! (GAMELOGON -> SrvJoinGame -> fpGetDatabaseCharacter) only carries the char name
//! and token, never the account — so we stash realmd's authoritative mapping here
//! at dispatch time and resolve it (by char name or token) when the engine asks
//! us for the character save.
//!
//! Writer: the gs-link thread (src/realm/d2cs.zig handleJoinGame).
//! Reader: the engine network thread (src/engine/realm.zig fpGetDatabaseCharacter).
//! Entries publish via an atomic `ready` flag so the reader never sees a half
//! written slot; joins are rare so a small ring with last-wins is plenty.

const std = @import("std");

extern "kernel32" fn GetTickCount() callconv(.winapi) u32;

const Entry = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    consumed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    token: u32 = 0,
    tick_ms: u32 = 0,
    char: [16]u8 = undefined,
    char_len: usize = 0,
    account: [32]u8 = undefined,
    account_len: usize = 0,
    // Guild tag realmd resolved for this player (the cut Guild Halls feature). Empty
    // = not in a guild. The GS uses it for in-game guild display.
    guild: [4]u8 = undefined,
    guild_len: usize = 0,
};

/// Join-token TTL. Ported from D2Server.dll 1.00 `PlayerToken_ValidateAndConsume`,
/// which rejected token records older than 120001 ms (a GetTickCount window). We
/// mirror its exact 120001 ms (GetTickCount, u32 wrapping) so a stale/replayed
/// token can't be used to join.
pub const TOKEN_TTL_MS: u32 = 120_001;

var entries: [16]Entry = blk: {
    var e: [16]Entry = undefined;
    for (&e) |*slot| slot.* = .{};
    break :blk e;
};
var next: usize = 0;

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Record realmd's account/char/token (+ guild tag) for an imminent join (last-wins ring).
pub fn remember(token: u32, charname: []const u8, account: []const u8, guild_tag: []const u8) void {
    const slot = &entries[next % entries.len];
    next +%= 1;
    slot.ready.store(false, .release);
    const cn = @min(charname.len, slot.char.len);
    @memcpy(slot.char[0..cn], charname[0..cn]);
    slot.char_len = cn;
    const an = @min(account.len, slot.account.len);
    @memcpy(slot.account[0..an], account[0..an]);
    slot.account_len = an;
    const gn = @min(guild_tag.len, slot.guild.len);
    @memcpy(slot.guild[0..gn], guild_tag[0..gn]);
    slot.guild_len = gn;
    slot.token = token;
    slot.tick_ms = GetTickCount();
    slot.consumed.store(false, .release);
    slot.ready.store(true, .release);
}

/// Resolve the account for a joining character (case-insensitive). Returns a
/// slice into the cache (stable for the process) or null if unknown.
pub fn accountForChar(charname: []const u8) ?[]const u8 {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (eqlIgnoreCase(slot.char[0..slot.char_len], charname)) {
            return slot.account[0..slot.account_len];
        }
    }
    return null;
}

/// Resolve the guild tag for a joining character (case-insensitive). Returns the
/// tag (e.g. "HON") or null if the player is in no guild / is unknown.
pub fn guildForChar(charname: []const u8) ?[]const u8 {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (eqlIgnoreCase(slot.char[0..slot.char_len], charname)) {
            if (slot.guild_len == 0) return null;
            return slot.guild[0..slot.guild_len];
        }
    }
    return null;
}

/// Resolve the account for a join token. Returns null if unknown.
pub fn accountForToken(token: u32) ?[]const u8 {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.token == token) return slot.account[0..slot.account_len];
    }
    return null;
}

/// Non-consuming join-token validity check. Ported from D2Server.dll 1.00
/// `PlayerToken_ValidateAndConsume` (minus the consume): the token must be one the
/// realm issued (via `remember`), not already used, and within `TOKEN_TTL_MS`.
/// The GS calls this from fpFindPlayerToken to reject unknown/replayed/stale tokens.
pub fn validate(token: u32) bool {
    const now = GetTickCount();
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.consumed.load(.acquire)) continue;
        if (slot.token != token) continue;
        return (now -% slot.tick_ms) < TOKEN_TTL_MS; // u32 wrap, matches D2Server
    }
    return false;
}

/// Consume-once: mark the token's slot used so the same token can't be replayed to
/// join twice (D2Server unlinked the token node on validate). Call after a
/// successful `validate` when token enforcement is enabled.
pub fn consume(token: u32) void {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.token == token) {
            slot.consumed.store(true, .release);
            return;
        }
    }
}
