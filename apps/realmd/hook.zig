//! The realm's extension surface: where a downstream realm gets to change what this one does.
//!
//! An extension is a plain module that declares a `pub fn` named after a hook. There is no base
//! type and no vtable — a comptime `inline for` over the registry calls `ext.<hook>(...)` only
//! where `@hasDecl` finds it, so an unused hook costs nothing and a misspelled one is simply never
//! called. A wrong SIGNATURE is a compile error, which is the point: a hook that silently stopped
//! matching is the failure a runtime plugin registry hands you.
//!
//! The registry comes from the root file of whatever is being built, so extending the realm never
//! means editing this repo:
//!
//! ```zig
//! // your own main.zig
//! const realmd = @import("realmd");
//! pub const realm_extensions = .{ @import("ext/ladder.zig"), @import("ext/seasons.zig") };
//! pub fn main(init: std.process.Init.Minimal) !void { return realmd.run(init); }
//! ```
//!
//! Connections arrive as `anytype` rather than `*bncs.Conn`: this module is imported BY bncs and
//! d2cs, so naming their types here would close an import cycle. An extension still writes the
//! concrete type in its own signature and is checked against it at the call.
//!
//! Hooks come in three shapes, and which one a hook is says what an extension may do with it:
//!
//!   - OBSERVE (`void`): it already happened. `accountLogin`, `charLogon`, `charSave`.
//!   - VETO (`?Result`): the realm is about to allow something; return a refusal code to stop it,
//!     null to stay out of the way. First extension to answer wins. `charCreate`, `gameCreate`.
//!   - OVERRIDE (`?T`): the realm is about to DECIDE something; return the decision to make it,
//!     null to let the realm decide as it would have. `authenticate`, `pickGs`, `gameVisible`.
//!
//! Override is the one that makes a realm somebody else's rather than ours with additions: who may
//! log in, which server hosts a game, which games a player is shown, what gets said in a channel.
//! Each one has a stock answer that still runs when no extension claims it, so a realm built with
//! no extensions behaves exactly as it does today.
//!
//! Extensions get their own storage and their own configuration, namespaced by extension name:
//! `store.ext("ladder")` for durable + cached state, `cfg.ext("ladder")` for options out of the
//! environment. Neither can collide with the realm's own or with another extension's, which is
//! what makes an upstream upgrade safe for a realm that is carrying extensions.
const std = @import("std");
const root = @import("root");

/// What this realm was built with. Empty unless the root file says otherwise, so the stock binary
/// carries no extension code at all rather than a disabled one.
pub const registry = if (@hasDecl(root, "realm_extensions")) root.realm_extensions else .{};

/// Whether any extension is compiled in — for a startup log line worth printing once.
pub const any = registry.len > 0;

/// Names of the compiled-in extensions, for that log line. An extension may declare `pub const
/// name`; otherwise it is counted but unnamed.
pub fn logLoaded(comptime logFn: anytype, tag: []const u8) void {
    if (!any) return;
    inline for (registry) |ext| {
        const n = if (@hasDecl(ext, "name")) ext.name else "(unnamed)";
        logFn(tag, "extension loaded: {s}", .{n});
    }
}

/// The store is up and reachable, nothing is listening yet. Where an extension prepares whatever
/// it needs before the first client can arrive; returning an error aborts startup.
pub fn startup(cfg: anytype) !void {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "startup")) try ext.startup(cfg);
    }
}

/// Every BNCS packet, before the realm's own dispatch. Return false to consume it — the realm
/// then does nothing further with that packet, which is the escape hatch for protocol work this
/// repo does not model.
pub fn bncsPacket(c: anytype, id: u8, body: []const u8) bool {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "bncsPacket")) {
            if (!ext.bncsPacket(c, id, body)) return false;
        }
    }
    return true;
}

/// Every MCP (realm) packet, on the same terms as bncsPacket.
pub fn mcpPacket(c: anytype, id: u8, body: []const u8) bool {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "mcpPacket")) {
            if (!ext.mcpPacket(c, id, body)) return false;
        }
    }
    return true;
}

/// A chat line that the realm's own commands did not claim. Return true if the extension answered
/// it, and it is not passed on as channel talk — this is how a realm adds a `/command`.
pub fn chatCommand(c: anytype, tag: []const u8, text: []const u8) bool {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "chatCommand")) {
            if (ext.chatCommand(c, tag, text)) return true;
        }
    }
    return false;
}

/// What an extension answers `authenticate` with. `accept` also CREATES the account if the realm
/// has never seen it, because an external source of truth saying "this is a valid login" is the
/// realm learning about a player, not a login for a player it should refuse.
pub const Auth = enum { accept, reject_password, reject_no_account };

/// Everything the OLS password check is given, for an extension that wants to answer instead of
/// it. Both tokens are here because the client's hash is a double hash over them, so an extension
/// verifying a password itself needs them; one checking an external system ignores both.
pub const AuthRequest = struct {
    account: []const u8,
    client_token: u32,
    server_token: u32,
    /// The 20-byte hash the client sent (Blizzard's broken SHA-1 double hash).
    hash: [20]u8,
};

/// OVERRIDE: decide a login, instead of the realm's own password check. Null means "not mine" and
/// the stock check runs — so an extension can own only the accounts it knows about and leave the
/// rest alone. This is the hook for putting a realm behind an existing account database, a
/// launcher token, OAuth, or a ban list that must answer before the password does.
///
/// The realm still owns the wire: an extension returns a decision, not a packet.
pub fn authenticate(req: AuthRequest) ?Auth {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "authenticate")) {
            if (ext.authenticate(req)) |decision| return decision;
        }
    }
    return null;
}

/// VETO: an account is about to be created (explicitly, or by a permissive-auth first login).
/// Return false to refuse — reserved names, an invite-only realm, an external registry that has
/// to be the one issuing accounts.
pub fn accountCreate(account: []const u8) bool {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "accountCreate")) {
            if (!ext.accountCreate(account)) return false;
        }
    }
    return true;
}

/// An account finished logging on, `ok` false if it was refused. Observers only: the answer has
/// already been decided by `authenticate` or the password check.
pub fn accountLogin(account: []const u8, ok: bool) void {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "accountLogin")) ext.accountLogin(account, ok);
    }
}

/// A character is about to be created. Return an MCP result code to refuse it, null to allow —
/// where a realm enforces its own naming or class rules.
pub fn charCreate(account: []const u8, charname: []const u8, class: u8) ?u32 {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "charCreate")) {
            if (ext.charCreate(account, charname, class)) |result| return result;
        }
    }
    return null;
}

/// A character just entered the realm (selected at character select).
pub fn charLogon(account: []const u8, charname: []const u8) void {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "charLogon")) ext.charLogon(account, charname);
    }
}

/// A game is about to be created. Return an MCP result code to refuse it, null to allow.
pub fn gameCreate(account: []const u8, charname: []const u8, gamename: []const u8, difficulty: u8) ?u32 {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "gameCreate")) {
            if (ext.gameCreate(account, charname, gamename, difficulty)) |result| return result;
        }
    }
    return null;
}

/// A game is about to be joined, on the same terms as gameCreate.
pub fn gameJoin(account: []const u8, charname: []const u8, gamename: []const u8) ?u32 {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "gameJoin")) {
            if (ext.gameJoin(account, charname, gamename)) |result| return result;
        }
    }
    return null;
}

/// The game a server is being chosen for, and the fleet to choose from. `servers` is the live
/// snapshot — gsid, address, capacity and current load for every server the realm can see — so an
/// extension picks with the same information the stock chooser has.
pub const GsPick = struct {
    account: []const u8,
    charname: []const u8,
    gamename: []const u8,
    difficulty: u8,
    ladder: u8,
    expansion: bool,
    hardcore: bool,
    /// Zero-length when the fleet is empty, in which case there is nothing to pick and the realm
    /// will tell the player so.
    servers: []const GsInfo,
};

/// A game server as an extension sees it. Mirrors fleet.GsInfo; declared here so an extension
/// imports the hook module and nothing else.
pub const GsInfo = struct {
    gsid: u32,
    ip: [4]u8,
    port: u16,
    /// 0 means the server publishes no limit.
    maxgame: u32,
    live: u32,
};

/// OVERRIDE: choose which game server hosts a game. Return a gsid to place it there, null to let
/// the realm place it as it would (least-loaded with room).
///
/// This is the decision that turns one fleet into several: a realm routes hardcore to its own
/// servers, pins a guild to a machine, keeps a region local, or — with mixed engine versions in
/// one fleet — sends a game to a server that actually runs that version.
///
/// A returned gsid is still reserved atomically and can still lose the race, exactly as the stock
/// pick can. If that server turns out to be gone or full, the realm falls back to its own choice
/// rather than failing the create: an extension expressing a preference should not be able to make
/// a realm unable to host games.
pub fn pickGs(req: GsPick) ?u32 {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "pickGs")) {
            if (ext.pickGs(req)) |gsid| return gsid;
        }
    }
    return null;
}

/// OVERRIDE: whether `account` is shown a game in the join list. Return false to hide it, true to
/// show it, null to leave the answer to the realm. Hiding a game does not protect it — a player
/// who knows the name can still try to join, and `gameJoin` is where that is refused. This is for
/// what the list SAYS: a private league's games, a staging game, a channel-scoped lobby.
pub fn gameVisible(account: []const u8, gamename: []const u8, gameid: u32) ?bool {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "gameVisible")) {
            if (ext.gameVisible(account, gamename, gameid)) |v| return v;
        }
    }
    return null;
}

/// VETO: a line of channel talk, after the realm's commands and an extension's own have had it.
/// Return false to drop it — the moderation, mute and flood-control hook. The sender is not told;
/// an extension that wants to say something should say it before returning false.
pub fn chatSay(c: anytype, account: []const u8, channel: []const u8, text: []const u8) bool {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "chatSay")) {
            if (!ext.chatSay(c, account, channel, text)) return false;
        }
    }
    return true;
}

/// A character's save is on its way to the store. The bytes are the .d2s as the game server left
/// them; an extension may read them (a ladder counts levels here) but must not keep the slice.
pub fn charSave(account: []const u8, charname: []const u8, bytes: []const u8) void {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "charSave")) ext.charSave(account, charname, bytes);
    }
}

/// A port an extension wants served, and what serves it. `handler` is `net.Handler` — spelled out
/// here rather than imported so an extension needs only this module, and checked against the real
/// type where the realm binds it.
pub const Listener = struct {
    /// Log tag for this listener's connections.
    name: []const u8,
    port: u16,
    handler: *const fn (fd: c_int, tag: []const u8) void,
};

/// ADD: extra listeners to bind at startup, alongside the realm's own. This is how a realm grows
/// a login path the client never had — a launcher auth endpoint, a REST hook a website calls, a
/// metrics or admin surface of its own — without that traffic having to arrive as BNCS packets.
///
/// Collected at RUNTIME, after `startup`, into a caller-owned array. That ordering is the whole
/// point: an extension reads its port from configuration, and a set fixed at compile time would
/// force every realm to hardcode one — which makes a second instance unable to bind and a realm
/// that scales out stop scaling out. Return an empty slice to bind nothing.
///
/// The slice an extension returns must outlive startup: a `const` array, or static storage it
/// filled in `startup`. Returns how many were written; a full array is a truncated answer.
pub fn listeners(out: []Listener) usize {
    var n: usize = 0;
    inline for (registry) |ext| {
        if (@hasDecl(ext, "listeners")) {
            for (ext.listeners()) |l| {
                if (n < out.len) {
                    out[n] = l;
                    n += 1;
                }
            }
        }
    }
    return n;
}
