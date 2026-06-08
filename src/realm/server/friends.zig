//! Friend lists + presence for the realm. Per-account friend lists (who you added)
//! and a set of currently-online accounts, so SID_FRIENDSLIST can report each friend's
//! online/offline location. Guarded by a spinlock — bnet connections touch this from
//! their own threads. In-memory for now (persists for the realmd run); fs/redis-backed
//! persistence is a follow-up.
const std = @import("std");
const Spinlock = @import("realm_infra").lock.Spinlock;

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

var lock: Spinlock = .{};
var pairs: [4096]Pair = [_]Pair{.{}} ** 4096;
var online: [1024]Presence = [_]Presence{.{}} ** 1024;

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
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
    const fn_: u8 = @intCast(@min(friend.len, max_name));
    @memcpy(pr.friend[0..fn_], friend[0..fn_]);
    pr.friend_len = fn_;
    pr.in_use = true;
    return true;
}

/// Remove `friend` from `owner`'s list. Returns false if not found.
pub fn remove(owner: []const u8, friend: []const u8) bool {
    lock.lock();
    defer lock.unlock();
    for (&pairs) |*p| {
        if (p.in_use and eqi(p.ownerSlice(), owner) and eqi(p.friendSlice(), friend)) {
            p.in_use = false;
            p.owner_len = 0;
            p.friend_len = 0;
            return true;
        }
    }
    return false;
}

pub const FriendInfo = struct {
    name: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    online: bool = false,
    pub fn nameSlice(f: *const FriendInfo) []const u8 {
        return f.name[0..f.name_len];
    }
};

/// Snapshot `owner`'s friends (with online status) into `out`. Returns the count.
pub fn list(owner: []const u8, out: []FriendInfo) usize {
    lock.lock();
    defer lock.unlock();
    var n: usize = 0;
    for (&pairs) |*p| {
        if (n >= out.len) break;
        if (!p.in_use or !eqi(p.ownerSlice(), owner)) continue;
        var fi = FriendInfo{ .name_len = p.friend_len, .online = isOnlineLocked(p.friendSlice()) };
        @memcpy(fi.name[0..p.friend_len], p.friendSlice());
        out[n] = fi;
        n += 1;
    }
    return n;
}
