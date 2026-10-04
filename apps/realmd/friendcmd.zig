//! The classic Battle.net /f family as typed in chat: parsing the line and wording the replies.
//! Kept free of connections and storage so the text a player sees can be tested on its own.
const std = @import("std");

pub const Action = enum { list, add, remove, msg, promote, demote, usage };

pub const Cmd = struct { action: Action, arg: []const u8 };

const roots = [_][]const u8{ "/friends", "/friend", "/f" };

const Verb = struct { word: []const u8, action: Action };
const verbs = [_]Verb{
    .{ .word = "l", .action = .list },
    .{ .word = "list", .action = .list },
    .{ .word = "a", .action = .add },
    .{ .word = "add", .action = .add },
    .{ .word = "r", .action = .remove },
    .{ .word = "remove", .action = .remove },
    .{ .word = "del", .action = .remove },
    .{ .word = "delete", .action = .remove },
    .{ .word = "m", .action = .msg },
    .{ .word = "msg", .action = .msg },
    .{ .word = "message", .action = .msg },
    .{ .word = "p", .action = .promote },
    .{ .word = "promote", .action = .promote },
    .{ .word = "d", .action = .demote },
    .{ .word = "demote", .action = .demote },
};

/// Null when `text` is not one of /f, /friend, /friends. A bare root lists; an unknown verb is
/// `.usage` so the player is told rather than shown a list they did not ask for.
pub fn parse(text: []const u8) ?Cmd {
    var rest: []const u8 = "";
    var matched = false;
    for (roots) |root| {
        if (text.len < root.len or !std.ascii.eqlIgnoreCase(text[0..root.len], root)) continue;
        if (text.len > root.len and text[root.len] != ' ') continue;
        rest = std.mem.trim(u8, text[root.len..], " ");
        matched = true;
        break;
    }
    if (!matched) return null;
    if (rest.len == 0) return .{ .action = .list, .arg = "" };
    const sp = std.mem.indexOfScalar(u8, rest, ' ');
    const verb = if (sp) |s| rest[0..s] else rest;
    const arg = if (sp) |s| std.mem.trim(u8, rest[s + 1 ..], " ") else "";
    for (verbs) |v| {
        if (std.ascii.eqlIgnoreCase(verb, v.word)) return .{ .action = v.action, .arg = arg };
    }
    return .{ .action = .usage, .arg = "" };
}

pub const usage_lines = [_][]const u8{
    "Friends commands:",
    "  /f l                list your friends and where they are",
    "  /f a <account>      add a friend",
    "  /f r <account>      remove a friend",
    "  /f m <message>      whisper all friends that are online",
    "  /f p <account>      move a friend up the list",
    "  /f d <account>      move a friend down the list",
};

/// "<n>: <name>, <where>" — the line /f l prints per friend.
pub fn listLine(buf: []u8, n: usize, name: []const u8, online: bool, dnd: bool, away: bool, in_game: bool, location: []const u8) []const u8 {
    const where: []const u8 = if (!online)
        "offline"
    else if (dnd)
        "online (do not disturb)"
    else if (away)
        "online (away)"
    else if (location.len > 0 and in_game)
        "in the game"
    else if (location.len > 0)
        "online in"
    else
        "online";
    const withLoc = online and !dnd and !away and location.len > 0;
    return (if (withLoc)
        std.fmt.bufPrint(buf, "{d}: {s}, {s} {s}", .{ n, name, where, location })
    else
        std.fmt.bufPrint(buf, "{d}: {s}, {s}", .{ n, name, where })) catch buf[0..0];
}

test "friend verbs and their one-letter forms" {
    const t = std.testing;
    try t.expectEqual(Action.list, parse("/f l").?.action);
    try t.expectEqual(Action.list, parse("/f").?.action);
    try t.expectEqual(Action.list, parse("/friends list").?.action);
    try t.expectEqual(Action.add, parse("/f a Bob").?.action);
    try t.expectEqualStrings("Bob", parse("/f a Bob").?.arg);
    try t.expectEqual(Action.add, parse("/F ADD  Bob ").?.action);
    try t.expectEqualStrings("Bob", parse("/F ADD  Bob ").?.arg);
    try t.expectEqual(Action.remove, parse("/f r Bob").?.action);
    try t.expectEqual(Action.remove, parse("/friend remove Bob").?.action);
    try t.expectEqual(Action.msg, parse("/f m hello all").?.action);
    try t.expectEqualStrings("hello all", parse("/f m hello all").?.arg);
    try t.expectEqual(Action.promote, parse("/f p Bob").?.action);
    try t.expectEqual(Action.demote, parse("/f d Bob").?.action);
    try t.expectEqual(Action.usage, parse("/f zzz").?.action);
}

test "only the friends roots are friends commands" {
    const t = std.testing;
    try t.expect(parse("/ignore Bob") == null);
    try t.expect(parse("/fps") == null);
    try t.expect(parse("/friendly") == null);
    try t.expect(parse("hello") == null);
    try t.expect(parse("/w Bob hi") == null);
}

test "list lines say where a friend is" {
    const t = std.testing;
    var b: [96]u8 = undefined;
    try t.expectEqualStrings("1: Bob, offline", listLine(&b, 1, "Bob", false, false, false, false, ""));
    try t.expectEqualStrings("2: Eve, online in Diablo II", listLine(&b, 2, "Eve", true, false, false, false, "Diablo II"));
    try t.expectEqualStrings("3: Kim, in the game cows", listLine(&b, 3, "Kim", true, false, false, true, "cows"));
    try t.expectEqualStrings("4: Al, online (away)", listLine(&b, 4, "Al", true, false, true, false, "x"));
    try t.expectEqualStrings("5: Zed, online", listLine(&b, 5, "Zed", true, false, false, false, ""));
}
