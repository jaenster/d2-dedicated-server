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
//! Extensions have no store of their own yet. Anything an extension must persist has to go
//! through `store`, in that schema, which means an upstream schema change can break it — a
//! namespaced per-extension keyspace is the next thing this needs.
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

/// An account finished logging on, `ok` false if it was refused. Observers only: the answer has
/// already been decided by the password check.
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

/// A character's save is on its way to the store. The bytes are the .d2s as the game server left
/// them; an extension may read them (a ladder counts levels here) but must not keep the slice.
pub fn charSave(account: []const u8, charname: []const u8, bytes: []const u8) void {
    inline for (registry) |ext| {
        if (@hasDecl(ext, "charSave")) ext.charSave(account, charname, bytes);
    }
}
