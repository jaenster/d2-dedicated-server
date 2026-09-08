//! Which character saves have already been sent to the store, so identical ones are not resent.
//!
//! The Mac engine persists a character by writing `<save path><charname>.d2s` on its own timer —
//! roughly every 10 seconds for a character that changed and every 45 otherwise. Nothing reads
//! those files back (loads come from the realm), so this server watches them instead and uploads
//! what it finds. Polling a file cannot tell "written again" from "written again with the same
//! bytes", and the engine rewrites unchanged saves, so without a memory of what was last sent
//! every seated player would push a redundant save to redis every 45 seconds and mark themselves
//! dirty for the realm's flush worker — turning an idle server into a steady write load on
//! Postgres for no new information.
//!
//! Deliberately NOT an mtime check. A save rewritten with identical content still gets a new
//! mtime, and a save written twice inside the filesystem's timestamp granularity does not — the
//! first is a wasted upload and the second is a LOST one, which is the direction that costs a
//! player their progress. The bytes are the only honest answer, so the fingerprint is taken over
//! the bytes.
//!
//! Pure: it is handed bytes and answers yes or no. Reading files and talking to redis belong to
//! the caller, which is what lets the rule below be tested without an engine or a store.

const std = @import("std");

/// One seat's worth of characters; the engine admits eight clients per game and this server hosts
/// several games, so this is sized to hold every character that can be in a world at once. A
/// character that does not fit is uploaded EVERY time rather than dropped — forgetting costs
/// bandwidth, and the alternative costs saves.
pub const capacity = 64;

const name_max = 24;

/// FNV-1a over the save. Not a checksum against corruption — the .d2s carries its own — just a
/// cheap way to notice that these are the same bytes as last time.
fn fingerprint(bytes: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |c| {
        h ^= c;
        h *%= 0x0000_0100_0000_01b3;
    }
    return h;
}

const Entry = struct {
    name: [name_max]u8 = @splat(0),
    len: usize = 0,
    /// Size and hash together: a hash alone is a collision away from silently dropping a save.
    bytes_len: usize = 0,
    hash: u64 = 0,
    used: bool = false,

    fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.len];
    }
};

var entries: [capacity]Entry = @splat(.{});
/// Round-robin replacement for a full table. There is no better policy available here and it does
/// not need one: the cost of evicting the wrong entry is one redundant upload.
var next: usize = 0;

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Should these bytes be sent to the store?
///
/// True the first time a character is seen, and thereafter only when its save actually differs
/// from the last one accepted. Recording happens here rather than in a separate call so there is
/// no path where a caller asks and forgets to tell us what it did.
///
/// An empty save is never worth sending: it is a file the engine has opened and not yet finished
/// writing, and storing it would replace a character with nothing.
pub fn shouldUpload(charname: []const u8, bytes: []const u8) bool {
    if (charname.len == 0 or charname.len > name_max or bytes.len == 0) return false;
    const h = fingerprint(bytes);
    for (&entries) |*e| {
        if (!e.used or !eqlIgnoreCase(e.nameSlice(), charname)) continue;
        if (e.bytes_len == bytes.len and e.hash == h) return false;
        e.bytes_len = bytes.len;
        e.hash = h;
        return true;
    }
    // First sight of this character. Claim a slot, preferring a free one.
    const slot = for (&entries) |*e| {
        if (!e.used) break e;
    } else blk: {
        const e = &entries[next % entries.len];
        next +%= 1;
        break :blk e;
    };
    slot.* = .{ .used = true, .bytes_len = bytes.len, .hash = h, .len = charname.len };
    @memcpy(slot.name[0..charname.len], charname);
    return true;
}

/// Forget a character, so its next save is uploaded whatever it contains.
///
/// Called when a player leaves. Their save has to be re-sent on the next session even if it is
/// byte-identical to the one we remember, because the realm may have been handed a different copy
/// in between — an admin edit, a restore, another server. Remembering across sessions would make
/// this server refuse to correct that.
pub fn forget(charname: []const u8) void {
    for (&entries) |*e| {
        if (e.used and eqlIgnoreCase(e.nameSlice(), charname)) e.* = .{};
    }
}

pub fn resetForTest() void {
    entries = @splat(.{});
    next = 0;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a character's first save is always uploaded" {
    resetForTest();
    try testing.expect(shouldUpload("Persist", "aaaa"));
}

test "the same bytes are not uploaded twice" {
    resetForTest();
    try testing.expect(shouldUpload("Persist", "aaaa"));
    try testing.expect(!shouldUpload("Persist", "aaaa"));
    try testing.expect(!shouldUpload("Persist", "aaaa"));
}

test "changed bytes are uploaded, and then not again" {
    resetForTest();
    try testing.expect(shouldUpload("Persist", "aaaa"));
    try testing.expect(shouldUpload("Persist", "aaab"));
    try testing.expect(!shouldUpload("Persist", "aaab"));
    // ...including a change back to something seen before: only the LAST accepted save is
    // remembered, because that is the one the store holds.
    try testing.expect(shouldUpload("Persist", "aaaa"));
}

test "a change of length alone counts, even if the hash somehow did not" {
    resetForTest();
    try testing.expect(shouldUpload("Persist", "aaaa"));
    try testing.expect(shouldUpload("Persist", "aaaaa"));
}

test "characters are tracked independently and matched case-insensitively" {
    resetForTest();
    try testing.expect(shouldUpload("Alice", "x"));
    try testing.expect(shouldUpload("Bob", "x")); // same bytes, different character
    try testing.expect(!shouldUpload("alice", "x"));
    try testing.expect(!shouldUpload("ALICE", "x"));
}

test "an empty save is never uploaded" {
    // A file the engine has created and not finished writing. Storing it would replace a
    // character with nothing, which is the one outcome worse than a missed save.
    resetForTest();
    try testing.expect(!shouldUpload("Persist", ""));
    // ...and it must not be remembered either, or the real save that follows would be skipped.
    try testing.expect(shouldUpload("Persist", "aaaa"));
}

test "a name that cannot be tracked is refused rather than half-recorded" {
    resetForTest();
    try testing.expect(!shouldUpload("", "aaaa"));
    try testing.expect(!shouldUpload("a" ** (name_max + 1), "aaaa"));
}

test "leaving forgets the character, so the next session re-uploads" {
    // The realm may have been handed a different copy while the player was away; remembering
    // across sessions would make this server refuse to correct it.
    resetForTest();
    try testing.expect(shouldUpload("Persist", "aaaa"));
    try testing.expect(!shouldUpload("Persist", "aaaa"));
    forget("Persist");
    try testing.expect(shouldUpload("Persist", "aaaa"));
}

test "a full table keeps working, at worst by re-uploading" {
    resetForTest();
    var nb: [8]u8 = undefined;
    for (0..capacity) |i| {
        const n = std.fmt.bufPrint(&nb, "c{d}", .{i}) catch unreachable;
        try testing.expect(shouldUpload(n, "aaaa"));
        try testing.expect(!shouldUpload(n, "aaaa"));
    }
    // One past capacity evicts somebody, which costs a redundant upload and nothing else. What
    // must NOT happen is the newcomer being dropped.
    try testing.expect(shouldUpload("overflow", "aaaa"));
    try testing.expect(!shouldUpload("overflow", "aaaa"));
}

test "every distinct save of a long session is uploaded exactly once" {
    resetForTest();
    var buf: [64]u8 = undefined;
    var uploads: usize = 0;
    for (0..200) |i| {
        // The engine rewrites the save on its timer whether or not it changed; here it changes
        // every fifth write.
        const save = std.fmt.bufPrint(&buf, "save-{d}", .{i / 5}) catch unreachable;
        if (shouldUpload("Persist", save)) uploads += 1;
    }
    try testing.expectEqual(@as(usize, 40), uploads);
}
