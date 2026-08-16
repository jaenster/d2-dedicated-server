//! Friend lists + presence for the realm: per-account friend lists plus a set of currently-online
//! accounts, so SID_FRIENDSLIST can report each friend's location. Spinlock-guarded — bnet
//! connections touch this from their own threads. Different lifetimes on purpose: PRESENCE is
//! per-run (restart clears it), the friend LIST is durable, written through to the per-account
//! key/value store under the same account-scoped keys the BNCS profile uses. The in-memory pair
//! table is the working set, seeded lazily on first touch after a restart.
const std = @import("std");
const Lock = @import("realm_infra").lock.Lock;
const store = @import("store.zig");
const chat = @import("chat.zig");


/// Key the friend list lives under, per account. The value is one name per line.
const friends_key = "friends\\list";

/// Longest serialized list: every name plus its newline.
const max_blob = max_friends * (max_name + 1);

pub const max_name = 16;
pub const max_friends = 50;

const Pair = struct {
    owner: [max_name]u8 = [_]u8{0} ** max_name,
    owner_len: u8 = 0,
    friend: [max_name]u8 = [_]u8{0} ** max_name,
    friend_len: u8 = 0,
    in_use: bool = false,

    fn ownerSlice(p: *const Pair) []const u8 {
        return p.owner[0..p.owner_len];
    }
    pub fn friendSlice(p: *const Pair) []const u8 {
        return p.friend[0..p.friend_len];
    }
};

const Presence = struct {
    name: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    in_use: bool = false,
};

var lock: Lock = .{};
var pairs: [4096]Pair = [_]Pair{.{}} ** 4096;
var online: [1024]Presence = [_]Presence{.{}} ** 1024;

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Accounts whose stored list has already been pulled into the pair table this run, so a
/// restart repopulates lazily and a miss doesn't re-read the store on every lookup.
var loaded: [1024]Presence = [_]Presence{.{}} ** 1024;

fn markLoadedLocked(account: []const u8) void {
    var slot: ?*Presence = null;
    for (&loaded) |*p| {
        if (p.in_use and eqi(p.name[0..p.name_len], account)) return;
        if (slot == null and !p.in_use) slot = p;
    }
    const p = slot orelse return;
    const n: u8 = @intCast(@min(account.len, max_name));
    @memcpy(p.name[0..n], account[0..n]);
    p.name_len = n;
    p.in_use = true;
}

fn isLoadedLocked(account: []const u8) bool {
    for (&loaded) |*p| {
        if (p.in_use and eqi(p.name[0..p.name_len], account)) return true;
    }
    return false;
}

fn addPairLocked(owner: []const u8, friend: []const u8) bool {
    var slot: ?*Pair = null;
    var n: usize = 0;
    for (&pairs) |*p| {
        if (p.in_use and eqi(p.ownerSlice(), owner)) {
            n += 1;
            if (eqi(p.friendSlice(), friend)) return false; // already a friend
        }
        if (slot == null and !p.in_use) slot = p;
    }
    if (n >= max_friends) return false;
    const pr = slot orelse return false;
    const on: u8 = @intCast(@min(owner.len, max_name));
    @memcpy(pr.owner[0..on], owner[0..on]);
    pr.owner_len = on;
    const fl: u8 = @intCast(@min(friend.len, max_name));
    @memcpy(pr.friend[0..fl], friend[0..fl]);
    pr.friend_len = fl;
    pr.in_use = true;
    return true;
}

/// Pull an account's stored list into the pair table, once per run. Caller holds the lock.
fn ensureLoadedLocked(account: []const u8) void {
    if (isLoadedLocked(account)) return;
    markLoadedLocked(account); // before reading, so a store miss doesn't retry forever
    var buf: [max_blob]u8 = undefined;
    const n = store.getUserData(account, friends_key, &buf);
    if (n == 0) return;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        _ = addPairLocked(account, line);
    }
}

/// Write an account's list back to the store. Caller holds the lock.
fn persistLocked(account: []const u8) void {
    var buf: [max_blob]u8 = undefined;
    var len: usize = 0;
    for (&pairs) |*p| {
        if (!p.in_use or !eqi(p.ownerSlice(), account)) continue;
        const f = p.friendSlice();
        if (len + f.len + 1 > buf.len) break;
        @memcpy(buf[len..][0..f.len], f);
        len += f.len;
        buf[len] = '\n';
        len += 1;
    }
    _ = store.setUserData(account, friends_key, buf[0..len]);
}

/// Mark `account` online (call on logon). Idempotent.
pub fn setOnline(account: []const u8) void {
    lock.lock();
    defer lock.unlock();
    var slot: ?*Presence = null;
    for (&online) |*p| {
        if (p.in_use and eqi(p.name[0..p.name_len], account)) return;
        if (slot == null and !p.in_use) slot = p;
    }
    const p = slot orelse return;
    const n: u8 = @intCast(@min(account.len, max_name));
    @memcpy(p.name[0..n], account[0..n]);
    p.name_len = n;
    p.in_use = true;
}

/// Mark `account` offline (call on disconnect).
pub fn setOffline(account: []const u8) void {
    lock.lock();
    defer lock.unlock();
    for (&online) |*p| {
        if (p.in_use and eqi(p.name[0..p.name_len], account)) {
            p.in_use = false;
            p.name_len = 0;
            return;
        }
    }
}

fn isOnlineLocked(account: []const u8) bool {
    for (&online) |*p| {
        if (p.in_use and eqi(p.name[0..p.name_len], account)) return true;
    }
    return false;
}

/// Add `friend` to `owner`'s list. Returns false if already present or table full.
pub fn add(owner: []const u8, friend: []const u8) bool {
    lock.lock();
    defer lock.unlock();
    ensureLoadedLocked(owner);
    if (!addPairLocked(owner, friend)) return false;
    persistLocked(owner);
    return true;
}

/// Remove `friend` from `owner`'s list. Returns false if not found.
pub fn remove(owner: []const u8, friend: []const u8) bool {
    lock.lock();
    defer lock.unlock();
    ensureLoadedLocked(owner);
    for (&pairs) |*p| {
        if (p.in_use and eqi(p.ownerSlice(), owner) and eqi(p.friendSlice(), friend)) {
            p.in_use = false;
            p.owner_len = 0;
            p.friend_len = 0;
            persistLocked(owner);
            return true;
        }
    }
    return false;
}

pub const FriendInfo = struct {
    name: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    online: bool = false,
    /// Where they are: the channel they are sitting in, or the game they went off to
    /// play. Empty when they are online but in neither.
    location: [32]u8 = [_]u8{0} ** 32,
    location_len: u8 = 0,
    /// True when `location` names a game rather than a channel.
    in_game: bool = false,
    away: bool = false,
    dnd: bool = false,

    pub fn nameSlice(f: *const FriendInfo) []const u8 {
        return f.name[0..f.name_len];
    }
    pub fn locationSlice(f: *const FriendInfo) []const u8 {
        return f.location[0..f.location_len];
    }
};

/// Snapshot `owner`'s friends into `out`, with where each one is. Returns the count.
///
/// Two passes on purpose: names come out under the friends lock, then presence is resolved with that
/// lock RELEASED, since it lives in the chat registry behind a different lock. Holding both would
/// work today and be a deadlock the first time anything took them in the other order.
pub fn list(owner: []const u8, out: []FriendInfo) usize {
    var n: usize = 0;
    {
        lock.lock();
        defer lock.unlock();
        ensureLoadedLocked(owner);
        for (&pairs) |*p| {
            if (n >= out.len) break;
            if (!p.in_use or !eqi(p.ownerSlice(), owner)) continue;
            var fi = FriendInfo{ .name_len = p.friend_len, .online = isOnlineLocked(p.friendSlice()) };
            @memcpy(fi.name[0..p.friend_len], p.friendSlice());
            out[n] = fi;
            n += 1;
        }
    }
    for (out[0..n]) |*fi| {
        const pres = chat.presenceOfAnywhere(fi.nameSlice()) orelse continue;
        fi.away = pres.away;
        fi.dnd = pres.dnd;
        fi.in_game = pres.in_game;
        const ch = pres.channelSlice();
        const cn: u8 = @intCast(@min(ch.len, fi.location.len));
        @memcpy(fi.location[0..cn], ch[0..cn]);
        fi.location_len = cn;
    }
    return n;
}

// tests
//
// The durable half is not unit-tested here any more, and deliberately not faked. A friend list
// lives in the account's profile, which is Postgres, and the only honest test of "it survives a
// restart" is one that restarts against a real Postgres — the e2e suite's `friends_persist`
// scenario, which does exactly that. A stand-in store here would have tested the stand-in.
