//! Which engine the client on the other end of a connection is running.
//!
//! A realm that hosts one engine never needs this. A realm that hosts several does, and for a
//! blunt reason: a 1.09d client cannot play a 1.13c character or join a 1.13c game — the save
//! format and the wire framing both moved between them. So the realm has to know what it is
//! talking to before it hands anything over.
//!
//! The vocabulary is the game server's: the tag here is the same string a server publishes as its
//! `v=` label, which is `d2engine.version.spec().name` ("1.09d", "1.13c", "1.14d"). One spelling on
//! both sides of the fleet, so routing is a string compare and not a translation table.
//!
//! The MAP from what a client sends to that tag is configuration, not code, and deliberately.
//! Blizzard's per-patch EXE version numbers are not derivable from anything in this repo, and a
//! table of half-remembered build numbers is worse than no table: it silently sends a player to
//! the wrong engine. So exactly one entry ships — the 1.14d one this repo can show its work for —
//! and an unrecognised client resolves to no tag at all, which every caller reads as "no
//! constraint" and behaves exactly as the realm did before any of this existed.
//!
//! Filling the rest in is meant to be copy-paste: an unknown client is logged once, with the
//! setting that would name it.
const std = @import("std");
const log = @import("realm_infra").log;

/// The one mapping this repo can source: `tools/e2e-engines.sh` and `tools/checkrev-probe` both
/// drive a 1.14d client as "1.14.3.71", and that is the version dword it sends.
const builtin_map = [_]Entry{
    .{ .exe_version = pack(1, 14, 3, 71), .tag = "1.14d" },
};

const max_entries = 32;

const Entry = struct {
    /// The EXE version dword from SID_AUTH_CHECK, or 0 when this entry keys on the version byte.
    exe_version: u32 = 0,
    /// The product version byte from SID_AUTH_INFO, or 0 when this entry keys on the dword.
    verbyte: u8 = 0,
    tag: []const u8,
};

var configured: [max_entries]Entry = undefined;
var configured_n: usize = 0;
var tag_store: [max_entries * 16]u8 = undefined;
var tag_used: usize = 0;

pub fn pack(a: u8, b: u8, c: u8, d: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | d;
}

/// Render a version dword the way Blizzard writes it, for logs and for the setting the operator
/// has to paste it into.
pub fn quad(exe_version: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(exe_version >> 24)),
        @as(u8, @truncate(exe_version >> 16)),
        @as(u8, @truncate(exe_version >> 8)),
        @as(u8, @truncate(exe_version)),
    }) catch buf[0..0];
}

/// Load `REALMD_CLIENT_VERSIONS`: comma-separated `<what>=<tag>`, where `<what>` is either a
/// version quad (`1.13.0.60`), a raw dword (`0x01000e3f`), or a version byte (`vb:14`).
///
///     REALMD_CLIENT_VERSIONS=1.13.0.60=1.13c,1.0.10.39=1.10f,vb:10=1.09d
///
/// A configured entry wins over the built-in one, so a realm that knows better can say so.
pub fn configure(spec: []const u8) void {
    configured_n = 0;
    tag_used = 0;
    var it = std.mem.tokenizeAny(u8, spec, ", \t");
    while (it.next()) |pair| {
        if (configured_n >= max_entries) {
            log.line("version", "REALMD_CLIENT_VERSIONS: more than {d} entries, ignoring the rest", .{max_entries});
            return;
        }
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            log.line("version", "REALMD_CLIENT_VERSIONS: '{s}' is not <version>=<tag>, ignored", .{pair});
            continue;
        };
        const what = pair[0..eq];
        const tag = pair[eq + 1 ..];
        if (tag.len == 0 or tag.len > 16 or tag_used + tag.len > tag_store.len) {
            log.line("version", "REALMD_CLIENT_VERSIONS: bad tag in '{s}', ignored", .{pair});
            continue;
        }
        var e: Entry = .{ .tag = "" };
        if (std.mem.startsWith(u8, what, "vb:")) {
            e.verbyte = std.fmt.parseInt(u8, what[3..], 0) catch {
                log.line("version", "REALMD_CLIENT_VERSIONS: bad version byte in '{s}', ignored", .{pair});
                continue;
            };
        } else if (parseWhat(what)) |v| {
            e.exe_version = v;
        } else {
            log.line("version", "REALMD_CLIENT_VERSIONS: bad version in '{s}', ignored", .{pair});
            continue;
        }
        @memcpy(tag_store[tag_used..][0..tag.len], tag);
        e.tag = tag_store[tag_used..][0..tag.len];
        tag_used += tag.len;
        configured[configured_n] = e;
        configured_n += 1;
    }
    if (configured_n != 0) log.line("version", "{d} client version mappings configured", .{configured_n});
}

fn parseWhat(what: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, what, '.') == null) return std.fmt.parseInt(u32, what, 0) catch null;
    var parts = std.mem.splitScalar(u8, what, '.');
    var f: [4]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |p| : (i += 1) {
        if (i >= 4) return null;
        f[i] = std.fmt.parseInt(u8, p, 10) catch return null;
    }
    if (i != 4) return null;
    return pack(f[0], f[1], f[2], f[3]);
}

/// The engine tag for a client, or null when nothing recognises it.
///
/// The dword is asked first because it names an exact patch; the version byte only names a family
/// and several patches share one, so it is the fallback rather than the answer.
/// The engine whose tag carries these two digits, or null.
///
/// A character's engine is chosen on the creation screen, after the logon that would otherwise
/// have decided it, so MCP_CHARCREATE carries it in the high byte of its status word — as the
/// era's own two digits, 6 or 9 or 14. Matching them against the tags this realm is CONFIGURED
/// with rather than against a table of our own means a realm can only ever stamp a character with
/// an engine it actually serves.
pub fn byEraCode(code: u8) ?[]const u8 {
    if (code == 0) return null;
    var buf: [2]u8 = .{ '0' + @as(u8, @intCast(code / 10)), '0' + @as(u8, @intCast(code % 10)) };
    for (configured[0..configured_n]) |e| {
        if (e.tag.len < 4) continue;
        if (e.tag[0] != '1' or e.tag[1] != '.') continue;
        if (std.mem.eql(u8, e.tag[2..4], &buf)) return e.tag;
    }
    return null;
}

pub fn resolve(exe_version: u32, verbyte: u8) ?[]const u8 {
    for (configured[0..configured_n]) |e| {
        if (e.exe_version != 0 and e.exe_version == exe_version) return e.tag;
    }
    for (builtin_map) |e| {
        if (e.exe_version == exe_version) return e.tag;
    }
    if (verbyte != 0) {
        for (configured[0..configured_n]) |e| {
            if (e.verbyte != 0 and e.verbyte == verbyte) return e.tag;
        }
    }
    return null;
}

// Unknown clients are logged once each rather than per connection: on a realm whose map is
// incomplete this fires on every single login, and a warning that repeats forever is a warning
// nobody reads.
var seen_unknown: [32]u32 = [_]u32{0} ** 32;
var seen_n: usize = 0;

pub fn noteUnknown(exe_version: u32, verbyte: u8) void {
    for (seen_unknown[0..seen_n]) |s| {
        if (s == exe_version) return;
    }
    if (seen_n < seen_unknown.len) {
        seen_unknown[seen_n] = exe_version;
        seen_n += 1;
    }
    var qb: [16]u8 = undefined;
    log.line("version", "client exeVersion={s} (0x{x:0>8}) verbyte={d} is not mapped to an engine; " ++
        "characters it makes carry no version. Map it with REALMD_CLIENT_VERSIONS={s}=<engine>", .{
        quad(exe_version, &qb), exe_version, verbyte, quad(exe_version, &qb),
    });
}

test "quad round-trips the packed dword" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1.14.3.71", quad(pack(1, 14, 3, 71), &buf));
}

test "the built-in map answers 1.14d and nothing else" {
    configured_n = 0;
    try std.testing.expectEqualStrings("1.14d", resolve(pack(1, 14, 3, 71), 0).?);
    try std.testing.expect(resolve(pack(1, 0, 13, 60), 0) == null);
}

test "configuration adds quads, dwords and version bytes, and wins over the built-in" {
    configure("1.0.13.60=1.13c, 0x01000001=test, vb:10=1.09d, 1.14.3.71=custom");
    defer configured_n = 0;
    try std.testing.expectEqualStrings("1.13c", resolve(pack(1, 0, 13, 60), 0).?);
    try std.testing.expectEqualStrings("test", resolve(0x01000001, 0).?);
    try std.testing.expectEqualStrings("1.09d", resolve(0xdeadbeef, 10).?);
    try std.testing.expectEqualStrings("custom", resolve(pack(1, 14, 3, 71), 0).?);
}

test "a version byte never overrides a dword the map knows" {
    configure("1.0.13.60=1.13c,vb:10=1.09d");
    defer configured_n = 0;
    try std.testing.expectEqualStrings("1.13c", resolve(pack(1, 0, 13, 60), 10).?);
}

test "junk entries are skipped without taking the good ones with them" {
    configure("nonsense,1.0.13.60=1.13c,=empty,vb:notanumber=x");
    defer configured_n = 0;
    try std.testing.expectEqualStrings("1.13c", resolve(pack(1, 0, 13, 60), 0).?);
    try std.testing.expectEqual(@as(usize, 1), configured_n);
}
