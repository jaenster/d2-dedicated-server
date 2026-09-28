//! Where the ladder's rows come from.
//!
//! The boards are read from the standings the store keeps beside every save (`store.ladderPage`),
//! which the save path writes in the same statement as the save itself. Opening a board is then an
//! index range over one board, and reads no save.
//!
//! `scan` is the other way to get the same answer: read every save on the realm and rank them
//! here. It is what the boards were before, and it stays as the definition the kept standings are
//! checked against (`check`, behind the admin API), not as something a player's request runs.
const std = @import("std");
const ladder = @import("ladder.zig");
const store = @import("store.zig");

/// One page of a board from the kept standings: `out.len` rows from zero-based rank `first` on.
pub fn page(b: ladder.Board, first: u32, out: []ladder.Entry) usize {
    var rows: [ladder.max_entries]store.LadderRow = undefined;
    const n = store.ladderPage(b, first, rows[0..@min(out.len, rows.len)]);
    for (rows[0..n], out[0..n]) |r, *e| e.* = entryOf(r);
    return n;
}

fn entryOf(r: store.LadderRow) ladder.Entry {
    var e = ladder.Entry{ .stats = r.standing.stats, .experience = r.standing.experience, .status = r.standing.status };
    const n = @min(r.name.len, ladder.name_width - 1);
    @memcpy(e.name[0..n], r.name.slice()[0..n]);
    return e;
}

/// The ranked rows of one board, from every save on the realm.
///
/// Every account, paged, rather than one buffer's worth: the accounts come back in name order, so
/// a fixed buffer would keep everyone past its end off the ladder for good. The saves are read
/// with `peekCharD2s`, which does not cache: this reads the whole realm.
pub fn scan(top: *ladder.Top) void {
    var accts: [256][32]u8 = undefined;
    var after: [32]u8 = .{0} ** 32;
    while (true) {
        const na = store.listAccountsAfter(std.mem.sliceTo(&after, 0), &accts);
        if (na == 0) break;
        for (accts[0..na]) |*acct_buf| {
            const acct = std.mem.sliceTo(acct_buf, 0);
            if (acct.len == 0) continue;
            var names: [store.max_chars]store.Name = [_]store.Name{.{}} ** store.max_chars;
            const nc = store.listChars(acct, &names);
            for (names[0..nc]) |nm| {
                // Big enough to reach the attribute section of a played save; the header
                // alone would give the level but never the experience.
                var save: [8192]u8 = undefined;
                const sz = store.peekCharD2s(acct, nm.slice(), &save);
                if (sz == 0) continue;
                top.offer(ladder.entryFromSave(nm.slice(), save[0..sz]) orelse continue);
            }
        }
        after = accts[na - 1];
    }
}

/// What `check` found: how many boards it compared, and the first that disagreed.
pub const Report = struct {
    boards: usize = 0,
    mismatches: usize = 0,
    first_mismatch: ?u8 = null,
};

/// Compare every board the client can ask for, as kept, with the same board from a scan.
pub fn check() Report {
    var rep = Report{};
    var t: u8 = 0;
    while (t < 0x23) : (t += 1) {
        const b = ladder.board(t) orelse continue;
        rep.boards += 1;
        var top = ladder.Top{ .board = b };
        scan(&top);
        var kept: [ladder.max_entries]ladder.Entry = undefined;
        const n = page(b, 0, &kept);
        if (!same(top.slice(), kept[0..n])) {
            rep.mismatches += 1;
            if (rep.first_mismatch == null) rep.first_mismatch = t;
        }
    }
    return rep;
}

fn same(a: []const ladder.Entry, b: []const ladder.Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, &x.name, &y.name) or x.stats != y.stats or x.experience != y.experience or x.status != y.status) return false;
    }
    return true;
}
