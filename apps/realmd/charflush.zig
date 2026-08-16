//! Moves characters from the redis cache to the store of record.
//!
//! Every realmd runs one of these, and they do not coordinate. They do not need to: the dirty set
//! holds NAMES, and a flush reads whatever bytes are current, so two instances flushing the same
//! character both write the newest save. Duplicated work is wasted, not wrong — which is why
//! there is no queue, no consumer group, no acknowledgement and no lock on this path.
//!
//! What it must never do is clear the dirty flag for a save it did not persist. A save landing
//! while a flush is in flight bumps the version, the compare-and-clear then refuses, and the
//! character stays dirty for the next pass. Everything else here is a retry loop around that one
//! guarantee.
//!
//! A crash anywhere leaves the character dirty, so the next instance — or this one after a
//! restart — picks it up. That is the whole recovery story; there is no journal to replay.
const std = @import("std");
const log = @import("realm_infra").log;
const store = @import("store.zig");

/// How many characters one pass moves. Small: a pass holds a redis connection per lookup, and
/// falling behind is harmless where stalling logins is not.
const batch = 16;

/// Gap between passes when there was nothing to do. Durability lag, not a correctness property —
/// a save is safe in redis the moment it lands; this only decides how long until Postgres agrees.
const idle_sleep_ms: u64 = 1000;

/// Gap after a pass that moved something, so a backlog drains without waiting a second per batch.
const busy_sleep_ms: u64 = 50;

const tag = "charflush";

pub fn run() void {
    var names: [batch][96]u8 = undefined;
    var slices: [batch][]u8 = undefined;
    var lens: [batch]usize = undefined;

    while (true) {
        for (&slices, 0..) |*s, i| s.* = &names[i];
        const n = store.dirtyChars(&slices, &lens);
        var moved: usize = 0;
        for (0..n) |i| {
            const member = names[i][0..lens[i]];
            // Members are "<account>/<charname>"; a character name cannot contain a slash, so the
            // FIRST separator splits it.
            const sep = std.mem.indexOfScalar(u8, member, '/') orelse continue;
            const account = member[0..sep];
            const charname = member[sep + 1 ..];
            if (account.len == 0 or charname.len == 0) continue;

            // Read the version BEFORE the bytes. The other order would let a save land in between
            // and be cleared by a version that already covers it.
            const ver = store.charVersion(account, charname);
            if (ver == 0) continue;
            if (!store.flushCharToDurable(account, charname)) {
                log.line(tag, "could not persist {s}/{s}; leaving it dirty", .{ account, charname });
                continue;
            }
            if (store.clearDirtyIfUnchanged(account, charname, ver)) moved += 1;
            // A refused clear is not an error: it means a newer save arrived while this one was
            // being written, and the next pass will carry it.
        }
        if (moved > 0) log.line(tag, "persisted {d} character(s)", .{moved});
        sleepMs(if (n > 0) busy_sleep_ms else idle_sleep_ms);
    }
}

extern "c" fn usleep(usec: c_uint) c_int;

fn sleepMs(ms: u64) void {
    _ = usleep(@intCast(ms * 1000));
}
