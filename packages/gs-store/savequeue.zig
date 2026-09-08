//! Saves the store would not take, kept until it will.
//!
//! A character save reaches redis or it does not exist. When `putChar` fails — the connection
//! dropped, a failover is in progress, the store is briefly out of memory — the bytes are in a
//! buffer the engine is about to reuse, and the old behaviour was to log a line and let them go.
//! That is a player's progress lost to a blip of a few hundred milliseconds, and the engine will
//! not offer the same save again: on the next autosave it builds a NEW one, which is fine, but on
//! the way out there is no next one.
//!
//! So a refused save is parked here and retried from the server's own tick. The queue is small and
//! bounded, holds at most one save per CHARACTER (a newer one supersedes an older — they are the
//! same character, and only the newest matters), and drops the OLDEST when it is full, because a
//! queue that refuses new entries under pressure keeps the least useful ones.
//!
//! "The same character" means the same ACCOUNT AND NAME, never the name alone. This realm does not
//! make character names globally unique — the create-time check is scoped to one account — so two
//! players can both have a "Bob". Keyed by name, one player's parked save would be treated as a
//! newer version of the other's and silently replace it, and a `drop` for one would discard the
//! other's before it was ever retried. That is a permanent, unlogged loss of somebody's session.
//!
//! Pure: no sockets, no engine. It is handed bytes and hands them back, which is what lets the
//! superseding and eviction rules below be asserted directly.

const std = @import("std");

/// How many characters can be waiting at once. A store that is down for longer than this many
/// distinct characters' saves is a store that is down, and the answer to that is not more memory.
pub const capacity = 8;

/// The largest save kept. Real saves are a few KB; this is what the engine itself will read back.
pub const max_bytes = 16 * 1024;

/// How long a refused save is worth retrying before it is dropped instead of written.
///
/// A queue with no age bound is itself a rollback mechanism. The save sitting here is a snapshot
/// of a moment; if this server's game has since ended and the player has gone on to play the same
/// character somewhere else, writing it lands OLD bytes on top of NEW ones — the retry causing
/// exactly what it exists to prevent. The realm's own character lock keeps a character in one game
/// at a time, so the exposure is only after this game ended, but "narrow" is not "closed".
///
/// Two minutes: comfortably longer than a redis failover (Sentinel promotes in seconds) and short
/// enough that a player cannot have got far with the character elsewhere. Past it the save is
/// stale enough that losing it is the safer of the two mistakes.
pub const max_age_ms: u64 = 120_000;

const name_max = 24;
const account_max = 32;

const Slot = struct {
    account: [account_max]u8 = @splat(0),
    account_len: usize = 0,
    name: [name_max]u8 = @splat(0),
    name_len: usize = 0,
    len: usize = 0,
    /// Which park this was, so eviction can take the oldest without comparing clocks.
    seq: u64 = 0,
    /// When it was parked, for the age bound. The caller supplies the clock: this file stays pure,
    /// and the three hosts that use it do not share one.
    parked_ms: u64 = 0,
    /// The store version this save is fenced against. A retry carries it too, so a queued save can
    /// no more overwrite a newer one than a fresh save can — the age bound below is a belt to this
    /// brace, not a substitute for it.
    expect: u64 = 0,
    used: bool = false,
};

var slots: [capacity]Slot = @splat(.{});
var bytes: [capacity][max_bytes]u8 = undefined;
var seq_next: u64 = 1;

/// How many saves are waiting. Zero on a healthy server, so it is worth reporting when it is not.
pub fn depth() usize {
    var n: usize = 0;
    for (&slots) |*s| {
        if (s.used) n += 1;
    }
    return n;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Does this slot hold the save of exactly this character? Account AND name — see the file
/// comment for why the name alone is not an identity here.
fn isChar(s: *const Slot, account: []const u8, charname: []const u8) bool {
    return s.used and
        eqlIgnoreCase(s.name[0..s.name_len], charname) and
        eqlIgnoreCase(s.account[0..s.account_len], account);
}

/// Keep a save the store refused, to be retried later.
///
/// False when it cannot be kept at all — a name or a save too big for the queue — which the caller
/// should report, because it is the one case where progress really is gone.
pub fn park(account: []const u8, charname: []const u8, save: []const u8, expect: u64, now_ms: u64) bool {
    if (account.len == 0 or account.len > account_max) return false;
    if (charname.len == 0 or charname.len > name_max) return false;
    if (save.len == 0 or save.len > max_bytes) return false;

    // This character's own slot first: a newer save of the same character REPLACES the older one.
    // Queueing both would retry a save that is already stale and then overwrite the good one with
    // it, which is a rollback produced by the machinery meant to prevent one.
    var target: ?usize = null;
    for (&slots, 0..) |*s, i| {
        if (isChar(s, account, charname)) {
            target = i;
            break;
        }
    }
    if (target == null) {
        for (&slots, 0..) |*s, i| {
            if (!s.used) {
                target = i;
                break;
            }
        }
    }
    if (target == null) {
        // Full. Evict the oldest: it is the save most likely to have been superseded by play the
        // player has since done anyway, and dropping the NEWEST would mean a busy server never
        // recovers the most recent state of anybody.
        var oldest: usize = 0;
        for (slots, 0..) |s, i| {
            if (s.seq < slots[oldest].seq) oldest = i;
        }
        target = oldest;
    }

    const i = target.?;
    @memcpy(bytes[i][0..save.len], save);
    slots[i] = .{ .used = true, .len = save.len, .seq = seq_next, .parked_ms = now_ms, .expect = expect };
    seq_next += 1;
    @memcpy(slots[i].account[0..account.len], account);
    slots[i].account_len = account.len;
    @memcpy(slots[i].name[0..charname.len], charname);
    slots[i].name_len = charname.len;
    return true;
}

pub const Parked = struct {
    account: []const u8,
    charname: []const u8,
    save: []const u8,
    /// The version this save must still be fenced against when it is retried.
    expect: u64,
};

/// The oldest waiting save, copied into the caller's buffers, or null if there is nothing to do.
///
/// It stays in the queue: a retry that fails must not lose what it was retrying, so the caller
/// calls `drop` only once the store has actually taken it. That is the whole point of the queue
/// and it is why this is not a pop.
pub fn peek(account_out: []u8, name_out: []u8, save_out: []u8, now_ms: u64) ?Parked {
    // Drop anything too old to be safe to write before choosing what to retry. See max_age_ms:
    // writing one of these could put old bytes over newer ones.
    for (&slots) |*s| {
        if (s.used and now_ms -% s.parked_ms > max_age_ms) {
            expired_count += 1;
            s.* = .{};
        }
    }
    var best: ?usize = null;
    for (&slots, 0..) |*s, i| {
        if (!s.used) continue;
        if (best == null or s.seq < slots[best.?].seq) best = i;
    }
    const i = best orelse return null;
    const s = &slots[i];
    if (s.account_len > account_out.len or s.name_len > name_out.len or s.len > save_out.len) {
        // Cannot hand it back through these buffers. Drop it rather than spin on it forever.
        s.* = .{};
        return null;
    }
    @memcpy(account_out[0..s.account_len], s.account[0..s.account_len]);
    @memcpy(name_out[0..s.name_len], s.name[0..s.name_len]);
    @memcpy(save_out[0..s.len], bytes[i][0..s.len]);
    return .{
        .account = account_out[0..s.account_len],
        .charname = name_out[0..s.name_len],
        .save = save_out[0..s.len],
        .expect = s.expect,
    };
}

/// Forget a character's parked save, because the store has taken it.
///
/// Matched by account, name AND length. The account is what keeps one player's `drop` from
/// discarding a same-named character belonging to somebody else; the length is what keeps it from
/// discarding a NEWER save of the same character that was parked while the retry was in flight.
pub fn drop(account: []const u8, charname: []const u8, save_len: usize) void {
    for (&slots) |*s| {
        if (isChar(s, account, charname) and s.len == save_len) s.* = .{};
    }
}

/// Saves this queue gave up on because they aged out. Non-zero means progress really was lost,
/// which is worth a line in a log even though the alternative was worse.
pub fn expired() u64 {
    return expired_count;
}

var expired_count: u64 = 0;

pub fn resetForTest() void {
    expired_count = 0;
    slots = @splat(.{});
    seq_next = 1;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn peekInto(a: *[account_max]u8, n: *[name_max]u8, s: *[max_bytes]u8) ?Parked {
    return peek(a, n, s, 0);
}

test "a parked save comes back with its account, name and bytes intact" {
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "the-save", 0, 0));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    const got = peekInto(&a, &n, &b).?;
    try testing.expectEqualStrings("jaenster", got.account);
    try testing.expectEqualStrings("Persist", got.charname);
    try testing.expectEqualStrings("the-save", got.save);
}

test "peek does not remove: a retry that fails must not lose what it was retrying" {
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "the-save", 0, 0));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    _ = peekInto(&a, &n, &b).?;
    try testing.expectEqual(@as(usize, 1), depth());
    _ = peekInto(&a, &n, &b).?;
    try testing.expectEqual(@as(usize, 1), depth());
    drop("jaenster", "Persist", "the-save".len);
    try testing.expectEqual(@as(usize, 0), depth());
    try testing.expect(peekInto(&a, &n, &b) == null);
}

test "a newer save of the same character replaces the older one" {
    // Retrying a stale save AFTER the newer one succeeded would overwrite good progress with old
    // progress — a rollback caused by the thing meant to prevent one.
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "old", 0, 0));
    try testing.expect(park("jaenster", "Persist", "newer", 0, 0));
    try testing.expectEqual(@as(usize, 1), depth());
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    try testing.expectEqualStrings("newer", peekInto(&a, &n, &b).?.save);
}

test "dropping only matches the save that was actually stored" {
    // A newer save parked while the retry was in flight must survive the drop for the old one.
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "old", 0, 0));
    try testing.expect(park("jaenster", "Persist", "much-newer", 0, 0));
    drop("jaenster", "Persist", "old".len); // the in-flight retry finished, but for the OLD bytes
    try testing.expectEqual(@as(usize, 1), depth());
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    try testing.expectEqualStrings("much-newer", peekInto(&a, &n, &b).?.save);
}

test "different characters queue independently" {
    resetForTest();
    try testing.expect(park("acct_a", "Alice", "a", 0, 0));
    try testing.expect(park("acct_b", "Bob", "b", 0, 0));
    try testing.expectEqual(@as(usize, 2), depth());
}

test "retries come back oldest first" {
    resetForTest();
    try testing.expect(park("acct_a", "First", "1", 0, 0));
    try testing.expect(park("acct_b", "Second", "2", 0, 0));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    try testing.expectEqualStrings("First", peekInto(&a, &n, &b).?.charname);
    drop("acct_a", "First", 1);
    try testing.expectEqualStrings("Second", peekInto(&a, &n, &b).?.charname);
}

test "a full queue drops the oldest, never the newest" {
    resetForTest();
    var nb: [8]u8 = undefined;
    for (0..capacity) |i| {
        try testing.expect(park("acct", std.fmt.bufPrint(&nb, "c{d}", .{i}) catch unreachable, "x", 0, 0));
    }
    try testing.expectEqual(capacity, depth());
    try testing.expect(park("acct", "Newcomer", "x", 0, 0));
    try testing.expectEqual(capacity, depth());

    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    // c0 was the oldest and is gone; the newcomer is still here.
    try testing.expectEqualStrings("c1", peekInto(&a, &n, &b).?.charname);
    var found_newcomer = false;
    for (&slots) |*s| {
        if (s.used and std.mem.eql(u8, s.name[0..s.name_len], "Newcomer")) found_newcomer = true;
    }
    try testing.expect(found_newcomer);
}

test "what cannot be kept is refused rather than half-kept" {
    resetForTest();
    try testing.expect(!park("", "Persist", "x", 0, 0));
    try testing.expect(!park("jaenster", "", "x", 0, 0));
    try testing.expect(!park("jaenster", "Persist", "", 0, 0));
    const too_big = [_]u8{0} ** (max_bytes + 1);
    try testing.expect(!park("jaenster", "Persist", &too_big, 0, 0));
    try testing.expectEqual(@as(usize, 0), depth());
}

test "a save exactly at the limit is kept" {
    resetForTest();
    const at_limit = [_]u8{7} ** max_bytes;
    try testing.expect(park("jaenster", "Persist", &at_limit, 0, 0));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    try testing.expectEqual(@as(usize, max_bytes), peekInto(&a, &n, &b).?.save.len);
}

test "a store that recovers drains the whole queue" {
    resetForTest();
    var nb: [8]u8 = undefined;
    for (0..capacity) |i| {
        try testing.expect(park("acct", std.fmt.bufPrint(&nb, "c{d}", .{i}) catch unreachable, "xx", 0, 0));
    }
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    var drained: usize = 0;
    while (peekInto(&a, &n, &b)) |p| {
        drop(p.account, p.charname, p.save.len);
        drained += 1;
        if (drained > capacity * 2) break; // guard against a peek/drop that cannot make progress
    }
    try testing.expectEqual(capacity, drained);
    try testing.expectEqual(@as(usize, 0), depth());
}

test "a save too old to be safe is dropped rather than written" {
    // The queue must not become the rollback. Past max_age_ms this server's game has ended and
    // the player may have taken the character elsewhere; writing our snapshot would land old
    // bytes on top of new ones.
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "stale", 0, 1000));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    // Still inside the window: retried.
    try testing.expect(peek(&a, &n, &b, 1000 + max_age_ms) != null);
    // Past it: gone, and counted rather than silently vanished.
    try testing.expect(peek(&a, &n, &b, 1000 + max_age_ms + 1) == null);
    try testing.expectEqual(@as(usize, 0), depth());
    try testing.expectEqual(@as(u64, 1), expired());
}

test "a fresh save is not dropped alongside a stale one" {
    resetForTest();
    try testing.expect(park("acct_a", "Old", "x", 0, 0));
    try testing.expect(park("acct_b", "New", "y", 0, max_age_ms));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    const got = peek(&a, &n, &b, max_age_ms + 1).?;
    try testing.expectEqualStrings("New", got.charname);
    try testing.expectEqual(@as(usize, 1), depth());
    try testing.expectEqual(@as(u64, 1), expired());
}

test "re-parking a character refreshes its age, because the bytes are new" {
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "v1", 0, 0));
    try testing.expect(park("jaenster", "Persist", "v2", 0, max_age_ms));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    const got = peek(&a, &n, &b, max_age_ms + 1).?;
    try testing.expectEqualStrings("v2", got.save);
}

test "two accounts with the same character name do not collide" {
    // Names are unique per account on this realm, not globally. Keyed by name alone, one player's
    // parked save would look like a newer version of the other's and replace it outright.
    resetForTest();
    try testing.expect(park("alice", "Bob", "alice-save", 0, 0));
    try testing.expect(park("bob_acct", "Bob", "bob-save", 0, 0));
    try testing.expectEqual(@as(usize, 2), depth());

    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    const first = peek(&a, &n, &b, 0).?;
    try testing.expectEqualStrings("alice", first.account);
    try testing.expectEqualStrings("alice-save", first.save);

    // Dropping one must not take the other with it, even at the same length.
    drop("alice", "Bob", "alice-save".len);
    try testing.expectEqual(@as(usize, 1), depth());
    const second = peek(&a, &n, &b, 0).?;
    try testing.expectEqualStrings("bob_acct", second.account);
    try testing.expectEqualStrings("bob-save", second.save);
}

test "a drop for the wrong account is ignored" {
    resetForTest();
    try testing.expect(park("alice", "Bob", "xxxx", 0, 0));
    drop("somebody_else", "Bob", 4);
    try testing.expectEqual(@as(usize, 1), depth());
}

test "a parked save keeps the version it must be fenced against" {
    // A retry that dropped the fence would be able to do exactly what the fence exists to stop:
    // land bytes from an old load on top of a newer save.
    resetForTest();
    try testing.expect(park("jaenster", "Persist", "bytes", 42, 0));
    var a: [account_max]u8 = undefined;
    var n: [name_max]u8 = undefined;
    var b: [max_bytes]u8 = undefined;
    try testing.expectEqual(@as(u64, 42), peek(&a, &n, &b, 0).?.expect);
}
