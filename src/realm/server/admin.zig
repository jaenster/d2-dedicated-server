//! HTTP admin API, served on the same listener as the health probes (health.zig
//! routes /admin/* here). JSON, bearer-token gated. The token comes from
//! REALMD_ADMIN_TOKEN: when EMPTY the whole API is disabled (403) — off by
//! default so a misconfigured deploy never exposes it. JSON is hand-rolled
//! (tiny payloads, no std.json dependency).
//!
//!   GET  /admin/status       counts + which instance/backends
//!   GET  /admin/gameservers  the registered GS fleet
//!   GET  /admin/games        active games (in-memory path)
//!   GET  /admin/accounts     account names (filesystem)
//!   POST /admin/accounts     {"name","password"} -> create account
//!   POST /admin/games/close  {"name"} (or ?name=) -> expire a game
const std = @import("std");
const net = @import("realm_infra").net;
const gslink = @import("gslink.zig");
const state = @import("state.zig");
const store = @import("store.zig");
const xsha1 = @import("xsha1.zig");

// Set by main(), mirroring how health.require_gs is wired — admin reflects config
// without importing config.zig (keeps the listener config-free).
pub var token: []const u8 = "";
pub var instance: []const u8 = "realmd-0";
pub var durable: []const u8 = "fs";
pub var ephemeral: []const u8 = "fs";

const Status = struct { code: u16, text: []const u8 };
const ok: Status = .{ .code = 200, .text = "200 OK" };
const bad_request: Status = .{ .code = 400, .text = "400 Bad Request" };
const unauthorized: Status = .{ .code = 401, .text = "401 Unauthorized" };
const forbidden: Status = .{ .code = 403, .text = "403 Forbidden" };
const not_found: Status = .{ .code = 404, .text = "404 Not Found" };
const method_not_allowed: Status = .{ .code = 405, .text = "405 Method Not Allowed" };
const conflict: Status = .{ .code = 409, .text = "409 Conflict" };

fn respond(fd: net.Socket, st: Status, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ st.text, body.len }) catch return;
    _ = net.writeAll(fd, h);
    if (body.len > 0) _ = net.writeAll(fd, body);
}

/// Find the value of the case-insensitive "authorization:" header in the raw
/// request bytes; trims surrounding whitespace. Null if absent.
fn authHeader(req: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "authorization")) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// True if the request carries `Authorization: Bearer <token>` matching `token`.
fn authorized(req: []const u8) bool {
    const hv = authHeader(req) orelse return false;
    const prefix = "Bearer ";
    if (hv.len <= prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(hv[0..prefix.len], prefix)) return false;
    return std.mem.eql(u8, hv[prefix.len..], token);
}

/// The request body is whatever follows the blank line (\r\n\r\n).
fn bodyOf(req: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "";
    return req[sep + 4 ..];
}

/// Extract the string value of `"key": "value"` from a tiny flat JSON object.
/// No escape handling — inputs are simple test values. Null if the key is missing.
fn jsonStr(body: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [64]u8 = undefined;
    if (key.len + 2 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    const needle = kbuf[0 .. key.len + 2];
    const ki = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = ki + needle.len;
    // skip past ':' and the opening quote
    const colon = std.mem.indexOfScalarPos(u8, body, i, ':') orelse return null;
    i = colon + 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') i += 1;
    if (i >= body.len) return null;
    return body[start..i];
}

/// `?name=x` style query value, or null.
fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.splitScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn pathOnly(path: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..q];
}

/// Lowercase ASCII in place into `out` (for password hashing, matching the
/// client's lowercase-then-xsha1 convention).
fn lower(s: []const u8, out: []u8) []const u8 {
    const n = @min(s.len, out.len);
    for (s[0..n], 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out[0..n];
}

/// Entry point from health.zig for any /admin/* request. `req` is the full raw
/// request buffer (request line + headers + body); `method` and `path` are parsed.
pub fn handle(fd: net.Socket, method: []const u8, path: []const u8, req: []const u8) void {
    if (token.len == 0) return respond(fd, forbidden, "{\"error\":\"admin disabled\"}");
    if (!authorized(req)) return respond(fd, unauthorized, "{\"error\":\"unauthorized\"}");

    const p = pathOnly(path);
    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");

    if (std.mem.eql(u8, p, "/admin/status")) {
        if (!is_get) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return status(fd);
    } else if (std.mem.eql(u8, p, "/admin/gameservers")) {
        if (!is_get) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return gameservers(fd);
    } else if (std.mem.eql(u8, p, "/admin/games")) {
        if (!is_get) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return games(fd);
    } else if (std.mem.eql(u8, p, "/admin/games/close")) {
        if (!is_post) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return closeGame(fd, path, req);
    } else if (std.mem.eql(u8, p, "/admin/accounts")) {
        if (is_get) return accountsList(fd);
        if (is_post) return accountsCreate(fd, req);
        return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
    }
    return respond(fd, not_found, "{\"error\":\"not found\"}");
}

fn status(fd: net.Socket) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"sessions\":{d},\"games\":{d},\"gameservers\":{d},\"instance\":\"{s}\",\"durable\":\"{s}\",\"ephemeral\":\"{s}\"}}", .{
        state.global.sessionCount(),
        countGames(),
        gslink.registeredCount(),
        instance,
        durable,
        ephemeral,
    }) catch return respond(fd, ok, "{}");
    respond(fd, ok, body);
}

fn countGames() usize {
    var gbuf: [512]state.GameInfo = undefined;
    return state.snapshotGames(&gbuf);
}

fn gameservers(fd: net.Socket) void {
    var gs: [gslinkMax]gslink.GsInfo = undefined;
    const n = gslink.snapshot(&gs);
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    buf[w] = '[';
    w += 1;
    for (gs[0..n], 0..) |g, i| {
        const seg = std.fmt.bufPrint(buf[w..], "{s}{{\"gsid\":\"0x{x}\",\"addr\":\"{d}.{d}.{d}.{d}:{d}\",\"maxgame\":{d},\"live_games\":{d}}}", .{
            if (i == 0) "" else ",",
            g.gsid,
            g.ip[0], g.ip[1], g.ip[2], g.ip[3], g.port,
            g.maxgame,
            g.live,
        }) catch break;
        w += seg.len;
    }
    if (w < buf.len) {
        buf[w] = ']';
        w += 1;
    }
    respond(fd, ok, buf[0..w]);
}

const gslinkMax = 64;

fn games(fd: net.Socket) void {
    var gms: [512]state.GameInfo = undefined;
    const n = state.snapshotGames(&gms);
    var buf: [8192]u8 = undefined;
    var w: usize = 0;
    buf[w] = '[';
    w += 1;
    for (gms[0..n], 0..) |g, i| {
        const seg = std.fmt.bufPrint(buf[w..], "{s}{{\"name\":\"{s}\",\"gameid\":{d},\"gsid\":\"0x{x}\",\"ip\":\"{d}.{d}.{d}.{d}:{d}\"}}", .{
            if (i == 0) "" else ",",
            g.name_slice(),
            g.gameid,
            g.gsid,
            g.ip[0], g.ip[1], g.ip[2], g.ip[3], g.port,
        }) catch break;
        w += seg.len;
    }
    if (w < buf.len) {
        buf[w] = ']';
        w += 1;
    }
    respond(fd, ok, buf[0..w]);
}

fn accountsList(fd: net.Socket) void {
    var names: [256][32]u8 = undefined;
    const n = store.listAccounts(&names);
    var buf: [8192]u8 = undefined;
    var w: usize = 0;
    const head = "{\"accounts\":[";
    @memcpy(buf[0..head.len], head);
    w = head.len;
    for (names[0..n], 0..) |nm, i| {
        const name = std.mem.sliceTo(&nm, 0);
        const seg = std.fmt.bufPrint(buf[w..], "{s}\"{s}\"", .{ if (i == 0) "" else ",", name }) catch break;
        w += seg.len;
    }
    const tail = "]}";
    if (w + tail.len <= buf.len) {
        @memcpy(buf[w..][0..tail.len], tail);
        w += tail.len;
    }
    respond(fd, ok, buf[0..w]);
}

fn accountsCreate(fd: net.Socket, req: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    const password = jsonStr(body, "password") orelse return respond(fd, bad_request, "{\"error\":\"missing password\"}");
    if (name.len == 0) return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    var lb: [64]u8 = undefined;
    const pwhash = xsha1.xsha1(lower(password, &lb));
    if (store.createAccount(name, pwhash)) {
        respond(fd, ok, "{\"created\":true}");
    } else {
        respond(fd, conflict, "{\"error\":\"exists\"}");
    }
}

fn closeGame(fd: net.Socket, path: []const u8, req: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse queryParam(path, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    if (name.len == 0) return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    _ = state.global.closeGameByName(name);
    respond(fd, ok, "{\"closed\":true}");
}
