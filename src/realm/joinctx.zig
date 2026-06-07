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

const Entry = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    token: u32 = 0,
    char: [16]u8 = undefined,
    char_len: usize = 0,
    account: [32]u8 = undefined,
    account_len: usize = 0,
};

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

/// Record realmd's account/char/token for an imminent join (last-wins ring).
pub fn remember(token: u32, charname: []const u8, account: []const u8) void {
    const slot = &entries[next % entries.len];
    next +%= 1;
    slot.ready.store(false, .release);
    const cn = @min(charname.len, slot.char.len);
    @memcpy(slot.char[0..cn], charname[0..cn]);
    slot.char_len = cn;
    const an = @min(account.len, slot.account.len);
    @memcpy(slot.account[0..an], account[0..an]);
    slot.account_len = an;
    slot.token = token;
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

/// Resolve the account for a join token. Returns null if unknown.
pub fn accountForToken(token: u32) ?[]const u8 {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.token == token) return slot.account[0..slot.account_len];
    }
    return null;
}
