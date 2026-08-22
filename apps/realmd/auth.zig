//! Logging in, as one surface.
//!
//! Everything the realm knows about a login attempt, and every primitive it uses to decide one, in
//! a single place an extension can be built against. The `authenticate` hook is the decision; this
//! file is what you decide WITH.
//!
//! There are two ways to own logins, and a realm usually wants both:
//!
//! **Own the passwords.** Keep accounts wherever you already keep them, hash with `passwordHash`,
//! and answer `authenticate` with `verify(your_stored_hash, req)`. The client's part of the
//! exchange is a double hash over two per-connection tokens, so a stored hash alone is never
//! enough to log in with — which is also why an extension cannot do this check by hand without
//! reimplementing Blizzard's broken SHA-1.
//!
//! **Skip the password.** Something outside the game — a launcher, a website, a Discord bot — has
//! already established who the player is. It calls `issueTicket`, hands the ticket to the client
//! as its password, and `authenticate` answers with `redeemTicket`. Tickets are single-use and
//! expire, so the thing that issues them stays the authority rather than becoming a password
//! vendor.
//!
//! Neither path touches the realm's own account table unless you ask it to.
const std = @import("std");
const store = @import("store.zig");
const xsha1 = @import("libd2").bnet.xsha1;

/// What the client sent, and what the realm knows about the connection it sent it on.
pub const Request = struct {
    account: []const u8,
    /// The two per-connection nonces the double hash is salted with. An extension needs them only
    /// to pass them back into `verify`.
    client_token: u32,
    server_token: u32,
    /// `doubleHash(client_token, server_token, passwordHash(password))` as the client computed it.
    hash: [20]u8,
    /// The engine this client is running ("1.13c"), empty when the realm could not name it. See
    /// `version.zig` — an unmapped client is not an error, it is an unknown.
    client_version: []const u8 = "",
    /// What the client actually said it was, for a realm that wants to decide for itself.
    exe_version: u32 = 0,
    verbyte: u8 = 0,
    /// Where it connected from. Zero when the realm could not determine it.
    ip: [4]u8 = .{ 0, 0, 0, 0 },
};

/// How `authenticate` answers. `accept` also creates an account the realm has never seen: the
/// extension saying yes IS the authority that the player is real.
pub const Decision = enum { accept, reject_password, reject_no_account };

/// The hash the realm stores for a password — Blizzard's broken SHA-1 over the lowercased text.
/// Use it to seed your own account table with something `verify` will accept.
pub fn passwordHash(plaintext: []const u8) [20]u8 {
    return xsha1.passwordHash(plaintext);
}

/// Whether this request proves knowledge of the password behind `stored`.
pub fn verify(stored: [20]u8, req: Request) bool {
    const expect = xsha1.doubleHash(req.client_token, req.server_token, stored);
    return std.mem.eql(u8, &expect, &req.hash);
}

/// The same check against the realm's own account table. Null when it has no such account, which
/// an extension reads as "mine to answer" rather than as a refusal.
pub fn verifyStored(req: Request) ?bool {
    var stored: [20]u8 = undefined;
    const has_pw = store.accountPwHash(req.account, &stored) orelse return null;
    if (!has_pw) return true; // password-less account: nothing to prove
    return verify(stored, req);
}

/// A stored hash no client can produce the answer to — what an account gets when something other
/// than a password vouched for it.
///
/// The alternative, a null hash, means "no password set", and the realm's own check waves those
/// through whatever the client sends. So an account created by an extension accepting a login once
/// would be an account anybody could then log into. This closes it: the extension that vouched
/// stays the only way in, which is what it asked for by vouching.
///
/// Null when the system has no entropy. The caller must then refuse the login — an account that
/// cannot be created closed must not be created open.
pub fn unusablePassword() ?[20]u8 {
    var h: [20]u8 = undefined;
    if (getentropy(&h, h.len) != 0) return null;
    return h;
}

/// Longest ticket `issueTicket` produces, and the buffer `redeemTicket` needs.
pub const ticket_max = 32;

/// Mint a single-use password for `account`, valid for `ttl_s` seconds, and return it.
///
/// Give it to the client as its password. Anything that can reach this realm's store can issue
/// one, which is the point: the decision about who may log in moves to whatever already made it.
/// The OS entropy source. `std.crypto.random` is gone in 0.16 — randomness there goes through an
/// `std.Io`, which this path does not carry — and libc's is the one both platforms this builds for
/// agree on. A ticket that cannot be made unguessable is not made at all, which is why the failure
/// here returns null rather than falling back to something weaker.
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

pub fn issueTicket(account: []const u8, ttl_s: u32, out: *[ticket_max]u8) ?[]const u8 {
    // Tickets get read aloud and typed in, so l/1/o/0 are out. Exactly 32 symbols, which is a
    // whole number of bits per character — a 33-symbol alphabet would make the mapping biased.
    const alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
    comptime std.debug.assert(alphabet.len == 32);
    var raw: [ticket_max]u8 = undefined;
    if (getentropy(&raw, raw.len) != 0) return null;
    for (&raw, out) |r, *o| o.* = alphabet[r & 31];
    const ticket = out[0..ticket_max];
    if (!store.putLoginTicket(account, ticket, ttl_s)) return null;
    return ticket;
}

/// Consume the outstanding ticket for this account and check the request against it.
///
/// Consuming happens whether or not the hash matches, and that is deliberate: a ticket that
/// survives a wrong guess is a ticket that can be guessed at.
pub fn redeemTicket(req: Request) bool {
    var buf: [ticket_max]u8 = undefined;
    const n = store.takeLoginTicket(req.account, &buf);
    if (n == 0) return false;
    return verify(passwordHash(buf[0..n]), req);
}

test "verify accepts the hash the client would have sent, and nothing else" {
    const stored = passwordHash("hunter2");
    const req: Request = .{
        .account = "someone",
        .client_token = 0x11112222,
        .server_token = 0x33334444,
        .hash = xsha1.doubleHash(0x11112222, 0x33334444, stored),
    };
    try std.testing.expect(verify(stored, req));
    try std.testing.expect(!verify(passwordHash("hunter3"), req));
}

test "the tokens are part of the proof, so a hash from another connection does not carry" {
    const stored = passwordHash("hunter2");
    const req: Request = .{
        .account = "someone",
        .client_token = 1,
        .server_token = 2,
        .hash = xsha1.doubleHash(1, 999, stored),
    };
    try std.testing.expect(!verify(stored, req));
}
