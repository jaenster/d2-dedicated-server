//! The other direction: what the engine exposes to a host.
//!
//! `callbacks.zig` is the table the host fills for the engine. This is the set the host *calls* —
//! create a game, hand back a character save, end everything. In the DLL era they are D2Game
//! exports; in the 1.14d monolith they are addresses in `Game.exe`. Same functions either way,
//! which is why they are described once here and located per version.
//!
//! Two independent sources agree on this set. Blizzard's own `D2Server.dll` (retail 1.00) imports
//! exactly 26 D2Game ordinals, which bounds it, and a third-party 1.13c server publishes a
//! `D2GSINTERFACE` of named pointers whose signatures give each one's arity. Where a name below is
//! quoted, it is theirs.

const std = @import("std");
const version = @import("version.zig");

/// Where a function lives for a given build: an export in the DLL era, an address in the monolith.
pub const Location = union(enum) {
    /// D2Game.dll export ordinal — resolve with GetProcAddress.
    ordinal: u16,
    /// Absolute address inside the loaded 1.14d Game.exe.
    address: usize,
};

/// `D2GSNewEmptyGame`. The game name buffer is written to, not just read: the engine appends a
/// disambiguating suffix when the name collides, so it cannot be given constant storage.
pub const CreateGameFn = fn (
    name: [*:0]u8,
    password: [*:0]const u8,
    description: [*:0]const u8,
    flags: u32,
    template: u8,
    max_level_diff: u8,
    max_players: u8,
    out_game_id: *u16,
) callconv(.winapi) i32;

/// `D2GSSendDatabaseCharacter` — the asynchronous half of `fpGetDatabaseCharacter`. That callback
/// discards its return value (1.10f @0x6fc37413), so the save is handed back here instead, from
/// outside the join call stack.
///
/// The last two arguments are the same on every version, which is worth stating because a
/// published third-party header names them `LPPLAYERINFO` and `dwReserved2` and that is wrong.
/// 1.10f's body (`CLIENTS_OnDatabaseCharacterReceived`) settles it:
///
///   - `file_times` is a pointer to **two dwords**, copied straight into `pClient+0x190` and
///     `pClient+0x194` — the `{FILETIME*, unk0x194}` pair 1.14d also passes.
///   - `container` is compared against `pClient[0x18]`, i.e. `pClient+0x60`, and a mismatch
///     **removes the client from the game**. It must be the container read off the client, so a
///     zero here is a failed join, not a harmless default.
///
/// `refuse` nonzero, or a zero `total`, likewise removes the client — which is how a character
/// that could not be fetched is answered rather than ignored ("Character size was zero").
pub const SendDatabaseCharacterFn = fn (
    client_id: u32,
    save: [*]const u8,
    chunk: u32, // this call's chunk; chunk == total delivers in one go
    total: u32,
    refuse: u32,
    reserved: u32,
    file_times: *const [2]u32,
    container: usize,
) callconv(.winapi) i32;

/// `D2GSSendClientChatMessage`.
pub const SendClientChatMessageFn = fn (
    client_id: u32,
    kind: ChatKind,
    colour: u32,
    name: [*:0]const u8,
    text: [*:0]const u8,
) callconv(.winapi) u32;

/// `D2GSEndAllGames`.
pub const EndAllGamesFn = fn () callconv(.winapi) void;

/// Chat kinds, from the same third-party header. `scroll` is the top-of-screen announcement a
/// server uses to talk to everyone at once.
pub const ChatKind = enum(u32) {
    chat = 0x01,
    whisper_to = 0x02,
    system = 0x04,
    whisper_from = 0x06,
    scroll = 0x07,
};

/// The longest message the engine will take.
pub const chat_message_max_len = 0x100;

/// Where each function is for `v`. Null means nobody has located it for that build yet — asking is
/// better than a plausible-looking address that is really another version's.
pub fn createGame(v: version.Version) ?Location {
    return switch (v) {
        .v100, .v106b, .v107, .v108, .v109d, .v110f, .v113c => .{ .ordinal = 10047 },
        .v114d => null, // not needed: the injected server is already inside the engine's own path
    };
}

pub fn sendDatabaseCharacter(v: version.Version) ?Location {
    return switch (v) {
        // RET 0x20 for eight stdcall args, and its body calls CLIENTS_AttachSaveFile.
        .v100, .v106b, .v107, .v108, .v109d, .v110f, .v113c => .{ .ordinal = 10007 },
        // CLIENT_OnDatabaseCharacterReceived, in daily use by apps/d2gs.
        .v114d => .{ .address = 0x005306e0 },
    };
}

pub fn sendClientChatMessage(v: version.Version) ?Location {
    return switch (v) {
        // The only five-argument ordinal in the host-facing set.
        .v100, .v106b, .v107, .v108, .v109d, .v110f, .v113c => .{ .ordinal = 10018 },
        .v114d => null,
    };
}

pub fn endAllGames(v: version.Version) ?Location {
    return switch (v) {
        .v100, .v106b, .v107, .v108, .v109d, .v110f, .v113c => .{ .ordinal = 10006 },
        .v114d => null,
    };
}

test "the DLL era shares one host API" {
    try std.testing.expectEqual(@as(u16, 10007), sendDatabaseCharacter(.v110f).?.ordinal);
    try std.testing.expectEqual(@as(u16, 10007), sendDatabaseCharacter(.v113c).?.ordinal);
    try std.testing.expectEqual(@as(u16, 10047), createGame(.v109d).?.ordinal);
}

test "1.14d locates the same function by address, not ordinal" {
    try std.testing.expectEqual(@as(usize, 0x005306e0), sendDatabaseCharacter(.v114d).?.address);
    try std.testing.expect(createGame(.v114d) == null);
}

test "chat kinds are the engine's own numbers" {
    try std.testing.expectEqual(@as(u32, 0x07), @intFromEnum(ChatKind.scroll));
    try std.testing.expectEqual(@as(u32, 0x04), @intFromEnum(ChatKind.system));
}
