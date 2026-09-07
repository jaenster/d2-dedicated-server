//! Which account owns a character seated on this game server, for as long as it is seated.
//!
//! Every save the engine makes is keyed by ACCOUNT, and the engine never carries one: its join
//! path (GAMELOGON -> join -> the character fetch) has the character name and a token and nothing
//! else. The realm's JOINGAME is the only place the pairing is ever stated, so it is stashed here
//! and read back when the engine asks for a save.
//!
//! It is asked TWICE, and the second time is what makes the lifetime a correctness property rather
//! than a convenience. The character fetch asks on the way in; the save callback asks again on
//! every save for the rest of the session — every ~20 seconds once the autosave interval is
//! shortened, and again on the way out. A character whose entry is gone by then is saved under the
//! WRONG KEY: a well-formed save at an address no login path reads, reported as a success, leaving
//! the player rolled back to their last correctly-keyed save with nothing in the log. So an entry
//! belongs to the player for as long as they are seated, and only a player who has left may be
//! evicted to make room.
//!
//! Shared by both servers on purpose. `apps/d2gs` (the 1.14d DLL) and `apps/d2gs-native` (the Mac
//! image) have the same gap and used to be one table and no table respectively; two of these
//! drifting apart is two different rollback bugs.
//!
//! Writers: the realm queue thread (JOINGAME) and the engine thread (seat/release). Readers: the
//! engine's threads. Entries publish via an atomic `ready` flag so a reader never sees a
//! half-written slot, and reads COPY the account out rather than borrowing it — a slice into the
//! table is only valid until the slot is reused.

const std = @import("std");
const builtin = @import("builtin");

const windows = struct {
    extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
};

/// Milliseconds since boot, from whatever this host has. Windows gets the engine's own clock; the
/// Mac host and the tests get a counter, which is what lets the TTL and eviction rules below be
/// asserted without an engine at all.
var soft_ticks: u32 = 0;

fn ticks() u32 {
    return if (builtin.os.tag == .windows) windows.GetTickCount() else soft_ticks;
}

/// Advance the software clock. On a non-Windows host this IS the clock, so the Mac server calls it
/// from its own tick; the tests use it to age entries without waiting.
pub fn advanceClock(ms: u32) void {
    soft_ticks +%= ms;
}

/// Longest account name the realm issues. Anything longer cannot be keyed and is refused rather
/// than truncated: a truncated account is a save written where nobody looks.
pub const max_account = 31;
/// Longest character name D2 allows (15 + terminator).
pub const max_char = 15;

const Entry = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    consumed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The player holds a seat in a game on this server, so their account is still needed by
    /// every save the engine makes for them. Set when the character save is fetched, cleared
    /// when the engine reports them gone. Only a cleared entry may be recycled.
    seated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    token: u32 = 0,
    /// The engine gameid realmd authorized this join for. Kept BESIDE the token because the
    /// two are different namespaces and only the gameid reaches the engine: d2ingress rewrites
    /// the client's realm token to it before the GS sees the packet, so fpFindPlayerToken is
    /// handed a gameid. See validateGame.
    gameid: u32 = 0,
    tick_ms: u32 = 0,
    /// The store version this character's save was read at, and the one the next save is fenced
    /// against. Kept HERE because it is per-session state with exactly the same lifetime as the
    /// account: both are established at the fetch and both are needed by every save afterwards.
    /// 0 = we never loaded it, so nothing may be fenced on it.
    ver: u64 = 0,
    /// When this entry stopped being needed — set when the player leaves. It orders eviction, and
    /// it is deliberately NOT `tick_ms`: that one is the join's TTL, and reusing it here would
    /// extend the window a token stays valid for every time somebody left a game.
    idle_since_ms: u32 = 0,
    char: [max_char]u8 = undefined,
    char_len: usize = 0,
    account: [max_account]u8 = undefined,
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

/// One per seat this server can hold: the engine admits eight clients per game and Fog's pool
/// managers cap the server at eight games, so sixty-four is every player who can be in a game
/// here at once. The old table held sixteen and was a plain round-robin ring, which meant the
/// seventeenth JOINGAME overwrote a player who was still in a game — and the first save after
/// that went to `realmd:char:<CharName>:<CharName>`, a key nothing reads. That is the rollback.
const capacity = 64;

var entries: [capacity]Entry = blk: {
    var e: [capacity]Entry = undefined;
    for (&e) |*slot| slot.* = .{};
    break :blk e;
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn find(charname: []const u8) ?*Entry {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (eqlIgnoreCase(slot.char[0..slot.char_len], charname)) return slot;
    }
    return null;
}

/// Is `charname` currently seated here for some account OTHER than `account`?
///
/// This realm does not make character names globally unique — the create-time check is
/// `getCharD2s(account, name)`, scoped to one account — so two players really can both have a
/// "Sorc". Everything downstream of here keys a character by NAME: this table, the save-dedupe
/// table, and, on the Mac server, the engine's own `<save path><charname>.d2s`. Two of them in one
/// server at the same time is not a rollback, it is a character swap: one player's save filed
/// under the other's account.
///
/// So the name is treated as exclusive FOR AS LONG AS SOMEBODY IS PLAYING IT HERE, and the second
/// join is refused. A name whose player has left is free again — the entry is only a mapping at
/// that point, and the realm's own character lock is what stops the same character being in two
/// games at once.
fn seatedForOtherAccount(charname: []const u8, account: []const u8) bool {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (!slot.seated.load(.acquire)) continue;
        if (!eqlIgnoreCase(slot.char[0..slot.char_len], charname)) continue;
        if (!eqlIgnoreCase(slot.account[0..slot.account_len], account)) return true;
    }
    return false;
}

/// Where a `remember` for this character may go: its own entry if it has one (a rejoin replaces
/// its mapping rather than consuming a second seat), then any never-used entry, then the oldest
/// entry whose player has left. Null when every seat is held by somebody still in a game — which
/// is a full server, and the join is refused rather than served by throwing a live player's
/// account away.
fn slotFor(charname: []const u8) ?*Entry {
    if (find(charname)) |own| return own;
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) return slot;
    }
    // Longest gone wins. Ordering by the JOIN time would take the entry of the player who has
    // been on this server longest — who is also the one with the most to lose — the moment they
    // stepped out of a game.
    var oldest: ?*Entry = null;
    const now = ticks();
    for (&entries) |*slot| {
        if (slot.seated.load(.acquire)) continue;
        const idle = now -% slot.idle_since_ms;
        if (oldest) |o| {
            if (idle <= now -% o.idle_since_ms) continue;
        }
        oldest = slot;
    }
    return oldest;
}

/// Record realmd's account/char/token/gameid (+ guild tag) for an imminent join.
///
/// False when the name does not fit or every seat is taken by a player still in a game; the
/// caller refuses the join, because a join whose account we cannot keep is a join whose saves
/// will be lost.
pub fn remember(token: u32, gameid: u32, charname: []const u8, account: []const u8, guild_tag: []const u8) bool {
    if (charname.len == 0 or charname.len > max_char) return false;
    if (account.len == 0 or account.len > max_account) return false;
    // Someone else is playing a character by this name here right now. See seatedForOtherAccount:
    // admitting both would file one player's saves under the other's account.
    if (seatedForOtherAccount(charname, account)) return false;
    const slot = slotFor(charname) orelse return false;
    slot.ready.store(false, .release);
    @memcpy(slot.char[0..charname.len], charname);
    slot.char_len = charname.len;
    @memcpy(slot.account[0..account.len], account);
    slot.account_len = account.len;
    const gn = @min(guild_tag.len, slot.guild.len);
    @memcpy(slot.guild[0..gn], guild_tag[0..gn]);
    slot.guild_len = gn;
    slot.token = token;
    slot.gameid = gameid;
    slot.tick_ms = ticks();
    slot.idle_since_ms = slot.tick_ms;
    // A fresh authorisation, so nothing has been loaded for it yet. Carrying the previous
    // session's version over would fence this session's saves against a number that has since
    // moved, and every one of them would be refused.
    slot.ver = 0;
    slot.consumed.store(false, .release);
    slot.ready.store(true, .release);
    return true;
}

/// Record the store version a character's save was loaded at.
///
/// Every later save is refused by the store unless it still matches, so this is what makes a
/// rollback impossible rather than merely unlikely: bytes built from version N can only ever land
/// on a store still at version N.
pub fn setVersion(charname: []const u8, ver: u64) void {
    if (find(charname)) |slot| slot.ver = ver;
}

/// The version to fence this character's next save against, 0 if unknown.
pub fn version(charname: []const u8) u64 {
    const slot = find(charname) orelse return 0;
    return slot.ver;
}

/// The character is in a game on this server: hold its account until it leaves. Called once the
/// engine has actually taken the save, which is the point from which it will ask us to save it
/// back.
pub fn seat(charname: []const u8) void {
    if (find(charname)) |slot| slot.seated.store(true, .release);
}

/// The character left. The entry STAYS — the engine's last save for a departing player runs
/// after the leave is reported, and dropping the mapping here would lose exactly the save that
/// matters most — it just becomes the first thing a later join may recycle.
pub fn release(charname: []const u8) void {
    if (find(charname)) |slot| {
        slot.idle_since_ms = ticks();
        slot.seated.store(false, .release);
    }
}

/// Every character this server is still responsible for, with the account it belongs to.
///
/// Includes players who have LEFT but whose entry has not yet been recycled, which is deliberate:
/// the engine writes a departing player's last save after the leave, and a caller that only walked
/// the seated ones would stop watching a character one poll before its most important save.
///
/// The slices are borrowed for the duration of the call. That is safe for exactly the reason the
/// eviction rule exists — a seated entry is never recycled — and for a departed one the window is
/// a single synchronous callback.
pub fn forEachRemembered(ctx: anytype, f: *const fn (@TypeOf(ctx), charname: []const u8, account: []const u8) void) void {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.char_len == 0 or slot.account_len == 0) continue;
        f(ctx, slot.char[0..slot.char_len], slot.account[0..slot.account_len]);
    }
}

/// Release every seat held for `gameid` — the game ended, so nobody in it is still playing here.
///
/// For a server that is told a game emptied but not which characters were in it. The mapping is
/// kept, exactly as `release` keeps it: the last save of the last player out is written after the
/// game is gone, and it still has to be filed under the right account.
pub fn releaseByGame(gameid: u32) usize {
    var n: usize = 0;
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.gameid != gameid) continue;
        if (!slot.seated.load(.acquire)) continue;
        slot.idle_since_ms = ticks();
        slot.seated.store(false, .release);
        n += 1;
    }
    return n;
}

/// Resolve the account for a character (case-insensitive), copied into `out`. Null if unknown.
///
/// Copied, not borrowed: the table is written by other threads, so a slice into it can be
/// rewritten under a caller that is still holding it — and the value being rewritten is the one
/// that decides which key a save lands under.
pub fn accountForChar(charname: []const u8, out: []u8) ?[]const u8 {
    const slot = find(charname) orelse return null;
    if (slot.account_len == 0 or slot.account_len > out.len) return null;
    @memcpy(out[0..slot.account_len], slot.account[0..slot.account_len]);
    // Re-check: a `remember` that landed between the find and the copy leaves `out` holding a
    // torn value, and a torn account is a lost save.
    if (!eqlIgnoreCase(slot.char[0..slot.char_len], charname)) return null;
    return out[0..slot.account_len];
}

/// Resolve the guild tag for a character (case-insensitive), copied into `out`. Null if the
/// player is in no guild / is unknown.
pub fn guildForChar(charname: []const u8, out: []u8) ?[]const u8 {
    const slot = find(charname) orelse return null;
    if (slot.guild_len == 0 or slot.guild_len > out.len) return null;
    @memcpy(out[0..slot.guild_len], slot.guild[0..slot.guild_len]);
    return out[0..slot.guild_len];
}

/// True when the realm issued a join for this character that is still inside
/// `TOKEN_TTL_MS`. This is what authorizes releasing the seat that character still
/// holds from an earlier game: only realmd writes these entries, so a client can't
/// name someone else's character to have them thrown out of the game they are in.
pub fn hasFreshJoin(charname: []const u8) bool {
    const now = ticks();
    const slot = find(charname) orelse return false;
    return (now -% slot.tick_ms) < TOKEN_TTL_MS; // u32 wrap, as validate()
}

/// Resolve the account for a join token, copied into `out`. Null if unknown.
pub fn accountForToken(token: u32, out: []u8) ?[]const u8 {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.token != token) continue;
        if (slot.account_len == 0 or slot.account_len > out.len) return null;
        @memcpy(out[0..slot.account_len], slot.account[0..slot.account_len]);
        return out[0..slot.account_len];
    }
    return null;
}

/// Non-consuming validity check for what the ENGINE presents at join time. Ported from
/// D2Server.dll 1.00 `PlayerToken_ValidateAndConsume` (minus the consume): the join must be one
/// the realm issued (via `remember`), not already used, and within `TOKEN_TTL_MS`.
///
/// Matches on the GAMEID, not the realm token: d2ingress REWRITES the token in the client's
/// GAMELOGON to the engine gameid (`GAME_CreateBattleNetGame`'s out-param, the 1024-slot nToken)
/// before the GS sees it, so matching a gameid against stored realm tokens would compare two
/// unrelated namespaces.
pub fn validateGame(gameid: u32) bool {
    const now = ticks();
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.consumed.load(.acquire)) continue;
        if (slot.gameid != gameid) continue;
        return (now -% slot.tick_ms) < TOKEN_TTL_MS; // u32 wrap, matches D2Server
    }
    return false;
}

/// Consume-once: mark the join's slot used so the same authorization can't be replayed
/// (D2Server unlinked the token node on validate). Call after a successful `validateGame`
/// when token enforcement is enabled.
pub fn consumeGame(gameid: u32) void {
    for (&entries) |*slot| {
        if (!slot.ready.load(.acquire)) continue;
        if (slot.gameid == gameid) {
            slot.consumed.store(true, .release);
            return;
        }
    }
}

/// Test-only: empty the table between cases.
pub fn resetForTest() void {
    for (&entries) |*slot| slot.* = .{};
    soft_ticks = 0;
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// These are the rollback regression. The table's only job is to still know a player's account at
// the moment the engine hands us their save, which happens minutes after the join and again on
// the way out — so every case below is about an entry SURVIVING something, not about it being
// written correctly in the first place.

const testing = std.testing;

fn nameFor(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "c{d}", .{i}) catch unreachable;
}

fn acct(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "acct{d}", .{i}) catch unreachable;
}

test "an account round-trips, and the character name is matched case-insensitively" {
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "jaenster", ""));

    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("jaenster", accountForChar("Sorc", &out).?);
    try testing.expectEqualStrings("jaenster", accountForChar("sorc", &out).?);
    try testing.expectEqualStrings("jaenster", accountForChar("SORC", &out).?);
    try testing.expect(accountForChar("Barb", &out) == null);
}

test "a seated player's account survives a full table of later joins" {
    // The bug: the table was a 16-slot round-robin ring, so the 17th JOINGAME overwrote a player
    // who was still in a game. Their next save — up to 5.5 minutes later — was written under the
    // fallback account and lost, and they logged back in rolled back to before that session.
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "jaenster", ""));
    seat("Sorc");

    var nb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    var admitted: usize = 0;
    for (0..capacity * 4) |i| {
        if (remember(@intCast(i + 2), 200, nameFor(&nb, i), acct(&ab, i), "")) admitted += 1;
        advanceClock(1000);
    }
    try testing.expect(admitted > capacity); // they were served, not merely refused

    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("jaenster", accountForChar("Sorc", &out).?);
}

test "a rejoin replaces the character's own entry instead of taking a second seat" {
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "jaenster", ""));
    seat("Sorc");
    // Same character, new game, new token: the realm re-authorised it, so the mapping updates.
    try testing.expect(remember(2, 101, "Sorc", "jaenster", ""));

    // If that had consumed a second slot, 63 more distinct seated characters would not fit.
    var nb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    for (0..capacity - 1) |i| {
        try testing.expect(remember(@intCast(i + 3), 200, nameFor(&nb, i), acct(&ab, i), ""));
        seat(nameFor(&nb, i));
    }
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("jaenster", accountForChar("Sorc", &out).?);
}

test "a join is refused, not served by evicting somebody still in a game" {
    resetForTest();
    var nb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    for (0..capacity) |i| {
        try testing.expect(remember(@intCast(i + 1), 200, nameFor(&nb, i), acct(&ab, i), ""));
        seat(nameFor(&nb, i));
    }
    // Every seat is held by a player in a game. Taking one would silently break their saves.
    try testing.expect(!remember(999, 300, "Latecomer", "someone", ""));

    var out: [max_account]u8 = undefined;
    for (0..capacity) |i| {
        try testing.expectEqualStrings(acct(&ab, i), accountForChar(nameFor(&nb, i), &out).?);
    }
}

test "a departed player's account is still there for the save that follows the leave" {
    // The engine's last save for a client runs from CleanUpClient, AFTER the leave is reported.
    // Releasing the seat must not take the mapping with it.
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "jaenster", ""));
    seat("Sorc");
    release("Sorc");

    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("jaenster", accountForChar("Sorc", &out).?);
}

test "eviction takes the longest-gone entry, not the longest-joined" {
    // Ordering by join time would recycle the player who has been on this server longest — the
    // one with the most to lose — the moment they stepped out of a game.
    resetForTest();
    try testing.expect(remember(1, 100, "Early", "early_acct", "")); // joined first
    seat("Early");
    advanceClock(10_000);
    try testing.expect(remember(2, 100, "Late", "late_acct", "")); // joined second
    seat("Late");

    advanceClock(10_000);
    release("Late"); // ...but left first
    advanceClock(10_000);
    release("Early");

    // Fill the rest with players who are still in games, so eviction has only these two to pick from.
    var nb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    for (0..capacity - 2) |i| {
        try testing.expect(remember(@intCast(i + 3), 200, nameFor(&nb, i), acct(&ab, i), ""));
        seat(nameFor(&nb, i));
    }

    try testing.expect(remember(500, 300, "Newcomer", "new_acct", ""));

    var out: [max_account]u8 = undefined;
    try testing.expect(accountForChar("Late", &out) == null); // gone longest, recycled
    try testing.expectEqualStrings("early_acct", accountForChar("Early", &out).?);
    try testing.expectEqualStrings("new_acct", accountForChar("Newcomer", &out).?);
}

test "a name that does not fit is refused rather than truncated" {
    // A truncated account is a save written where nobody looks — the same silent rollback the
    // fallback used to cause, one step further along.
    resetForTest();
    try testing.expect(!remember(1, 100, "", "jaenster", ""));
    try testing.expect(!remember(1, 100, "Sorc", "", ""));
    try testing.expect(!remember(1, 100, "ThisNameIsFarTooLong", "jaenster", ""));
    try testing.expect(!remember(1, 100, "Sorc", "a" ** (max_account + 1), ""));
    try testing.expect(remember(1, 100, "a" ** max_char, "a" ** max_account, ""));
}

test "accountForChar refuses a buffer the account does not fit in" {
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "jaenster", ""));
    var small: [4]u8 = undefined;
    try testing.expect(accountForChar("Sorc", &small) == null);
}

test "the guild tag rides along and is optional" {
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "jaenster", "HON"));
    try testing.expect(remember(2, 101, "Barb", "jaenster", ""));
    var out: [8]u8 = undefined;
    try testing.expectEqualStrings("HON", guildForChar("Sorc", &out).?);
    try testing.expect(guildForChar("Barb", &out) == null);
}

test "a join is valid only until the token TTL runs out" {
    resetForTest();
    try testing.expect(remember(1, 0xabc, "Sorc", "jaenster", ""));
    try testing.expect(validateGame(0xabc));
    try testing.expect(hasFreshJoin("Sorc"));
    try testing.expect(!validateGame(0xdef)); // never issued

    advanceClock(TOKEN_TTL_MS);
    try testing.expect(!validateGame(0xabc));
    try testing.expect(!hasFreshJoin("Sorc"));
    // Expiry is about authorising a join. The account outlives it, because the saves do.
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("jaenster", accountForChar("Sorc", &out).?);
}

test "a consumed join cannot be replayed" {
    resetForTest();
    try testing.expect(remember(1, 0xabc, "Sorc", "jaenster", ""));
    try testing.expect(validateGame(0xabc));
    consumeGame(0xabc);
    try testing.expect(!validateGame(0xabc));
}

test "a token resolves an account too" {
    resetForTest();
    try testing.expect(remember(0x1234, 100, "Sorc", "jaenster", ""));
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("jaenster", accountForToken(0x1234, &out).?);
    try testing.expect(accountForToken(0x9999, &out) == null);
}

test "iteration covers departed players, whose last save has not been written yet" {
    resetForTest();
    try testing.expect(remember(1, 100, "Stayer", "acct_a", ""));
    seat("Stayer");
    try testing.expect(remember(2, 100, "Leaver", "acct_b", ""));
    seat("Leaver");
    release("Leaver");

    const Seen = struct {
        var chars: [8][16]u8 = undefined;
        var n: usize = 0;
        fn visit(_: void, charname: []const u8, account: []const u8) void {
            _ = account;
            @memcpy(chars[n][0..charname.len], charname);
            chars[n][charname.len] = 0;
            n += 1;
        }
    };
    Seen.n = 0;
    forEachRemembered({}, Seen.visit);
    try testing.expectEqual(@as(usize, 2), Seen.n);
}

test "closing a game releases its seats without forgetting who they were" {
    resetForTest();
    try testing.expect(remember(1, 700, "InGame", "acct_a", ""));
    seat("InGame");
    try testing.expect(remember(2, 701, "Elsewhere", "acct_b", ""));
    seat("Elsewhere");

    try testing.expectEqual(@as(usize, 1), releaseByGame(700));
    // The account survives: the engine's last save for a departing player lands after this.
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("acct_a", accountForChar("InGame", &out).?);

    // ...and the other game is untouched, so its player still cannot be evicted.
    var nb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    for (0..capacity) |i| _ = remember(@intCast(i + 3), 800, nameFor(&nb, i), acct(&ab, i), "");
    try testing.expectEqualStrings("acct_b", accountForChar("Elsewhere", &out).?);
}

test "releasing a game that holds nothing is not an error" {
    resetForTest();
    try testing.expectEqual(@as(usize, 0), releaseByGame(12345));
}

test "a second account's same-named character is refused while the first is playing" {
    // Character names are unique per ACCOUNT on this realm, not globally, and everything that
    // keys a character by name alone — this table, the save dedupe, the Mac engine's own
    // <charname>.d2s — would otherwise file one player's save under the other's account.
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "alice", ""));
    seat("Sorc");
    try testing.expect(!remember(2, 101, "Sorc", "bob", ""));

    // Alice keeps hers, unambiguously.
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("alice", accountForChar("Sorc", &out).?);
}

test "the same account's character is not blocked by the rule" {
    // A rejoin is the common case and must still work.
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "alice", ""));
    seat("Sorc");
    try testing.expect(remember(2, 101, "Sorc", "alice", ""));
    try testing.expect(remember(3, 102, "SORC", "ALICE", "")); // and case does not change that
}

test "a name is free again once its player has left" {
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "alice", ""));
    seat("Sorc");
    release("Sorc");
    try testing.expect(remember(2, 101, "Sorc", "bob", ""));
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("bob", accountForChar("Sorc", &out).?);
}

test "a name collision cannot make one player's save land under another's account" {
    // The property that matters, stated directly: whatever the table admits, a lookup by name
    // never returns an account that does not own a SEATED character by that name.
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "alice", ""));
    seat("Sorc");
    _ = remember(2, 101, "Sorc", "bob", "");
    _ = remember(3, 102, "Sorc", "carol", "");
    var out: [max_account]u8 = undefined;
    try testing.expectEqualStrings("alice", accountForChar("Sorc", &out).?);
}

test "the load version is remembered for the session and cleared by a new one" {
    resetForTest();
    try testing.expect(remember(1, 100, "Sorc", "alice", ""));
    try testing.expectEqual(@as(u64, 0), version("Sorc")); // nothing loaded yet
    setVersion("Sorc", 7);
    try testing.expectEqual(@as(u64, 7), version("Sorc"));
    seat("Sorc");
    setVersion("Sorc", 8); // a save succeeded and moved it on
    try testing.expectEqual(@as(u64, 8), version("Sorc"));

    // A new authorisation starts over: the store may have moved while they were away, and fencing
    // against the old number would have every save this session refused.
    try testing.expect(remember(2, 101, "Sorc", "alice", ""));
    try testing.expectEqual(@as(u64, 0), version("Sorc"));
}

test "an unknown character has no version to fence on" {
    resetForTest();
    try testing.expectEqual(@as(u64, 0), version("Nobody"));
    setVersion("Nobody", 5); // must not create an entry
    try testing.expectEqual(@as(u64, 0), version("Nobody"));
}
