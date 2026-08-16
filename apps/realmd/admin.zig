//! HTTP admin API, served on the same listener as the health probes (health.zig
//! routes /admin/* here). JSON, bearer-token gated. The token comes from
//! REALMD_ADMIN_TOKEN: when EMPTY the whole API is disabled (403) — off by
//! default so a misconfigured deploy never exposes it. JSON is hand-rolled
//! (tiny payloads, no std.json dependency).
//!
//!   GET  /admin/status       counts + which instance/backends
//!   GET  /admin/gameservers  the registered GS fleet
//!   GET  /admin/games        active games (in-memory, or shared store when shared)
//!   GET  /admin/accounts     account names (filesystem)
//!   POST /admin/accounts     {"name","password"} -> create account
//!   POST /admin/games/close  {"name"} (or ?name=) -> expire a game
//!   POST /admin/chars/copy   {"src_account","src_char","dst_char"[,"dst_account"]} -> clone char
const std = @import("std");
const net = @import("realm_infra").net;
const fleet = @import("fleet.zig");
const state = @import("state.zig");
const store = @import("store.zig");
const xsha1 = @import("libd2").bnet.xsha1;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

// Set by main(), mirroring how health.require_gs is wired — admin reflects config
// without importing config.zig (keeps the listener config-free).
pub var token: []const u8 = "";
pub var instance: []const u8 = "realmd-0";
pub var durable: []const u8 = "fs";
pub var ephemeral: []const u8 = "fs";
/// Comma-separated realm-account names allowed into the web UI (REALMD_ADMINS).
pub var admins: []const u8 = "";
/// Request header trusted as an authenticated username for SSO (forward-auth proxy).
/// Empty = SSO off. The value must still be in `admins`.
pub var trusted_header: []const u8 = "";

/// How long a web-UI session cookie is valid (seconds).
const session_ttl_s: i64 = 12 * 60 * 60;

// HMAC key signing session cookies. Set by initSigning(): the configured secret
// (stable across restarts/instances) or a per-process random key.
var key_buf: [64]u8 = undefined;
var sign_key: []const u8 = "";

/// Fill `out` with cryptographic randomness from /dev/urandom; on failure fall back
/// to a time-seeded PRNG (the fallback key is per-process anyway).
fn fillRandom(out: []u8) void {
    const fd = open("/dev/urandom", 0, @as(c_int, 0)); // O_RDONLY
    if (fd >= 0) {
        defer _ = close(fd);
        var off: usize = 0;
        while (off < out.len) {
            const r = read(fd, out.ptr + off, out.len - off);
            if (r <= 0) break;
            off += @intCast(r);
        }
        if (off == out.len) return;
    }
    var s: u64 = @bitCast(@as(i64, time(null)));
    for (out) |*b| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        b.* = @truncate(s >> 33);
    }
}

/// Wire the cookie-signing key. Call once from main(). Empty secret → random key.
pub fn initSigning(secret: []const u8) void {
    if (secret.len > 0) {
        const n = @min(secret.len, key_buf.len);
        @memcpy(key_buf[0..n], secret[0..n]);
        sign_key = key_buf[0..n];
    } else {
        fillRandom(key_buf[0..32]);
        sign_key = key_buf[0..32];
    }
}

/// Set by main() at startup (and on runtime promote) when ≥1 account carries the DB
/// admin flag — so account login stays available across restarts without env config.
pub var any_db_admin: bool = false;

/// The admin API is enabled if any auth path can grant access: bearer token (scripts /
/// break-glass), env allowlist, SSO (trusted header), or a stored DB admin account.
fn enabled() bool {
    return token.len > 0 or admins.len > 0 or trusted_header.len > 0 or any_db_admin;
}

/// Whether `name` may admin: the DB admin flag is the source of truth; the
/// REALMD_ADMINS env list is an OR'd-in static override (lockout escape hatch, and
/// the way an SSO user with no realm account is allowed in).
fn isAdmin(name: []const u8) bool {
    if (name.len == 0) return false;
    if (store.accountIsAdmin(name)) return true;
    return envAdmin(name);
}

/// Case-insensitive membership of `name` in the comma-separated `admins` env allowlist.
fn envAdmin(name: []const u8) bool {
    if (admins.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, admins, ',');
    while (it.next()) |a| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, a, " "), name)) return true;
    }
    return false;
}

fn ctEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var d: u8 = 0;
    for (a, b) |x, y| d |= x ^ y;
    return d == 0;
}

/// Mint a signed session cookie value for `name`: b64(name|exp).b64(hmac). Stateless
/// (no server-side session table) so it works unchanged across instances given a
/// shared REALMD_ADMIN_SECRET.
fn mintSession(name: []const u8, out: []u8) ?[]const u8 {
    var pbuf: [128]u8 = undefined;
    const payload = std.fmt.bufPrint(&pbuf, "{s}|{d}", .{ name, time(null) + session_ttl_s }) catch return null;
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, payload, sign_key);
    var w: usize = 0;
    const e1 = b64.Encoder.encode(out[w..], payload);
    w += e1.len;
    if (w >= out.len) return null;
    out[w] = '.';
    w += 1;
    const e2 = b64.Encoder.encode(out[w..], &mac);
    w += e2.len;
    return out[0..w];
}

/// Verify a session cookie; on success copy the account name into `name_out` and
/// return it. Rejects bad signatures and expired cookies.
fn verifySession(tok: []const u8, name_out: []u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, tok, '.') orelse return null;
    const p_b64 = tok[0..dot];
    const s_b64 = tok[dot + 1 ..];
    var pbuf: [128]u8 = undefined;
    const plen = b64.Decoder.calcSizeForSlice(p_b64) catch return null;
    if (plen == 0 or plen > pbuf.len) return null;
    b64.Decoder.decode(pbuf[0..plen], p_b64) catch return null;
    const payload = pbuf[0..plen];
    var sbuf: [32]u8 = undefined;
    const slen = b64.Decoder.calcSizeForSlice(s_b64) catch return null;
    if (slen != 32) return null;
    b64.Decoder.decode(sbuf[0..32], s_b64) catch return null;
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, payload, sign_key);
    if (!ctEq(&mac, &sbuf)) return null;
    const bar = std.mem.lastIndexOfScalar(u8, payload, '|') orelse return null;
    const exp = std.fmt.parseInt(i64, payload[bar + 1 ..], 10) catch return null;
    if (time(null) >= exp) return null;
    const nm = payload[0..bar];
    const n = @min(nm.len, name_out.len);
    @memcpy(name_out[0..n], nm[0..n]);
    return name_out[0..n];
}

const Status = struct { code: u16, text: []const u8 };
const ok: Status = .{ .code = 200, .text = "200 OK" };
const bad_request: Status = .{ .code = 400, .text = "400 Bad Request" };
const unauthorized: Status = .{ .code = 401, .text = "401 Unauthorized" };
const forbidden: Status = .{ .code = 403, .text = "403 Forbidden" };
const not_found: Status = .{ .code = 404, .text = "404 Not Found" };
const method_not_allowed: Status = .{ .code = 405, .text = "405 Method Not Allowed" };
const conflict: Status = .{ .code = 409, .text = "409 Conflict" };

fn respond(fd: net.Socket, st: Status, body: []const u8) void {
    respondCookie(fd, st, body, "");
}

/// Like respond(), but also emits a Set-Cookie header when `set_cookie` is non-empty.
fn respondCookie(fd: net.Socket, st: Status, body: []const u8, set_cookie: []const u8) void {
    var hdr: [512]u8 = undefined;
    const h = if (set_cookie.len > 0)
        std.fmt.bufPrint(&hdr, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nSet-Cookie: {s}\r\nConnection: close\r\n\r\n", .{ st.text, body.len, set_cookie }) catch return
    else
        std.fmt.bufPrint(&hdr, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ st.text, body.len }) catch return;
    _ = net.writeAll(fd, h);
    if (body.len > 0) _ = net.writeAll(fd, body);
}

/// Value of the case-insensitive `hname` header in the raw request bytes; trims
/// surrounding whitespace. Null if absent.
fn headerValue(req: []const u8, hname: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], hname)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Value of cookie `name` from the request's `Cookie:` header, or null.
fn cookieValue(req: []const u8, name: []const u8) ?[]const u8 {
    const cookies = headerValue(req, "cookie") orelse return null;
    var it = std.mem.splitScalar(u8, cookies, ';');
    while (it.next()) |pair| {
        const p = std.mem.trim(u8, pair, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
    }
    return null;
}

/// True if the request carries `Authorization: Bearer <token>` matching `token`.
fn bearerMatches(req: []const u8) bool {
    if (token.len == 0) return false;
    const hv = headerValue(req, "authorization") orelse return false;
    const prefix = "Bearer ";
    if (hv.len <= prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(hv[0..prefix.len], prefix)) return false;
    return ctEq(hv[prefix.len..], token);
}

const Auth = struct { name: []const u8, via: []const u8 };

/// Resolve the caller's identity, or null if unauthenticated. Precedence: SSO
/// (trusted header) → session cookie → bearer token. `name_out` backs the returned
/// name slice (so the result stays valid after return). SSO/session identities must
/// be in the `admins` allowlist; the bearer token is the unnamed break-glass path.
fn identify(req: []const u8, name_out: []u8) ?Auth {
    if (trusted_header.len > 0) {
        if (headerValue(req, trusted_header)) |u| {
            if (isAdmin(u)) {
                const n = @min(u.len, name_out.len);
                @memcpy(name_out[0..n], u[0..n]);
                return .{ .name = name_out[0..n], .via = "sso" };
            }
        }
    }
    if (cookieValue(req, "realmd_admin")) |tok| {
        if (verifySession(tok, name_out)) |nm| {
            if (isAdmin(nm)) return .{ .name = nm, .via = "session" };
        }
    }
    if (bearerMatches(req)) return .{ .name = "token", .via = "token" };
    return null;
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

/// Entry point from health.zig for any /admin/* request. `req` is the full raw
/// request buffer (request line + headers + body); `method` and `path` are parsed.
pub fn handle(fd: net.Socket, method: []const u8, path: []const u8, req: []const u8) void {
    if (!enabled()) return respond(fd, forbidden, "{\"error\":\"admin disabled\"}");

    const p = pathOnly(path);
    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");

    // Pre-auth endpoints: login establishes a session; logout clears it.
    if (std.mem.eql(u8, p, "/admin/login")) {
        if (!is_post) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return login(fd, req);
    }
    if (std.mem.eql(u8, p, "/admin/logout")) {
        // Idempotent: always clear the cookie.
        return respondCookie(fd, ok, "{\"ok\":true}", "realmd_admin=; HttpOnly; Path=/; SameSite=Strict; Max-Age=0");
    }

    var name_buf: [33]u8 = undefined;
    const auth = identify(req, &name_buf);

    // /admin/me reports the current identity (the UI uses it to skip the login form,
    // e.g. when SSO already authenticated upstream). 401 when not logged in.
    if (std.mem.eql(u8, p, "/admin/me")) {
        const a = auth orelse return respond(fd, unauthorized, "{\"error\":\"unauthorized\"}");
        var b: [128]u8 = undefined;
        return respond(fd, ok, std.fmt.bufPrint(&b, "{{\"name\":\"{s}\",\"via\":\"{s}\"}}", .{ a.name, a.via }) catch "{}");
    }

    if (auth == null) return respond(fd, unauthorized, "{\"error\":\"unauthorized\"}");

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
    } else if (std.mem.eql(u8, p, "/admin/accounts/delete")) {
        if (!is_post) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return accountsDelete(fd, req, auth.?.name);
    } else if (std.mem.eql(u8, p, "/admin/accounts/admin")) {
        if (!is_post) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return setAdminEndpoint(fd, req, auth.?.name);
    } else if (std.mem.eql(u8, p, "/admin/chars/delete")) {
        if (!is_post) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return charsDelete(fd, req);
    } else if (std.mem.eql(u8, p, "/admin/chars/copy")) {
        if (!is_post) return respond(fd, method_not_allowed, "{\"error\":\"method not allowed\"}");
        return charsCopy(fd, req);
    }
    return respond(fd, not_found, "{\"error\":\"not found\"}");
}

const server_error: Status = .{ .code = 500, .text = "500 Internal Server Error" };

// POST /admin/login {"name","password"} — authenticate a realm account that is in the
// `admins` allowlist, by its stored password hash (xsha1 of the lowercased password,
// matching account creation). On success sets an HMAC-signed session cookie.
fn login(fd: net.Socket, req: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    const password = jsonStr(body, "password") orelse return respond(fd, bad_request, "{\"error\":\"missing password\"}");
    const invalid = "{\"error\":\"invalid credentials\"}";
    if (!isAdmin(name)) return respond(fd, unauthorized, invalid);
    var stored: [20]u8 = undefined;
    const has = store.accountPwHash(name, &stored) orelse return respond(fd, unauthorized, invalid);
    if (!has) return respond(fd, unauthorized, invalid); // password-less account can't admin-login
    const got = xsha1.passwordHash(password);
    if (!ctEq(&got, &stored)) return respond(fd, unauthorized, invalid);

    var tokbuf: [256]u8 = undefined;
    const sess = mintSession(name, &tokbuf) orelse return respond(fd, server_error, "{\"error\":\"sign failed\"}");
    var cbuf: [384]u8 = undefined;
    const cookie = std.fmt.bufPrint(&cbuf, "realmd_admin={s}; HttpOnly; Path=/; SameSite=Strict; Max-Age={d}", .{ sess, session_ttl_s }) catch return respond(fd, server_error, "{\"error\":\"cookie\"}");
    var nb: [128]u8 = undefined;
    respondCookie(fd, ok, std.fmt.bufPrint(&nb, "{{\"name\":\"{s}\",\"via\":\"session\"}}", .{name}) catch "{}", cookie);
}

fn status(fd: net.Socket) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"sessions\":{d},\"games\":{d},\"gameservers\":{d},\"instance\":\"{s}\",\"durable\":\"{s}\",\"ephemeral\":\"{s}\"}}", .{
        state.global.sessionCount(),
        countGames(),
        fleet.registeredCount(),
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
    var gs: [fleetMax]fleet.GsInfo = undefined;
    const n = fleet.snapshot(&gs);
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

const fleetMax = 64;

/// JSON booleans: the format string needs a string, not a Zig bool.
fn boolJson(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn games(fd: net.Socket) void {
    var gms: [512]state.GameInfo = undefined;
    const n = state.snapshotGames(&gms);
    var buf: [8192]u8 = undefined;
    var w: usize = 0;
    buf[w] = '[';
    w += 1;
    for (gms[0..n], 0..) |g, i| {
        // Everything an operator would want to know about a live game and, until now, had
        // no way to see: how full it is, what the creator called it, and which kind of
        // game it is — the same status bits a joining character has to match.
        const seg = std.fmt.bufPrint(
            buf[w..],
            "{s}{{\"name\":\"{s}\",\"gameid\":{d},\"gsid\":\"0x{x}\",\"ip\":\"{d}.{d}.{d}.{d}:{d}\"," ++
                "\"players\":{d},\"description\":\"{s}\",\"expansion\":{s},\"hardcore\":{s},\"ladder\":{s}}}",
            .{
                if (i == 0) "" else ",",
                g.name_slice(),
                g.gameid,
                g.gsid,
                g.ip[0],   g.ip[1], g.ip[2], g.ip[3], g.port,
                g.players, g.desc(),
                boolJson(g.status & 0x20 != 0),
                boolJson(g.status & 0x04 != 0),
                boolJson(g.status & 0x40 != 0),
            },
        ) catch break;
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
        const seg = std.fmt.bufPrint(buf[w..], "{s}{{\"name\":\"{s}\",\"admin\":{}}}", .{ if (i == 0) "" else ",", name, store.accountIsAdmin(name) }) catch break;
        w += seg.len;
    }
    const tail = "]}";
    if (w + tail.len <= buf.len) {
        @memcpy(buf[w..][0..tail.len], tail);
        w += tail.len;
    }
    respond(fd, ok, buf[0..w]);
}

// POST /admin/chars/copy {"src_account","src_char","dst_char"[,"dst_account"]} — clone a
// character to a new name. dst_account defaults to src_account (clone within the account).
// The .d2s name + checksum are rewritten so the client accepts the copy.
fn charsCopy(fd: net.Socket, req: []const u8) void {
    const body = bodyOf(req);
    const src_account = jsonStr(body, "src_account") orelse return respond(fd, bad_request, "{\"error\":\"missing src_account\"}");
    const src_char = jsonStr(body, "src_char") orelse return respond(fd, bad_request, "{\"error\":\"missing src_char\"}");
    const dst_char = jsonStr(body, "dst_char") orelse return respond(fd, bad_request, "{\"error\":\"missing dst_char\"}");
    const dst_account = jsonStr(body, "dst_account") orelse src_account;
    if (store.copyChar(src_account, src_char, dst_account, dst_char)) {
        respond(fd, ok, "{\"copied\":true}");
    } else {
        respond(fd, conflict, "{\"error\":\"copy failed (missing source, invalid name, or destination exists)\"}");
    }
}

// POST /admin/chars/delete {"account","char"} — remove one character. The companion to
// chars/copy: an operator who can clone a character should be able to undo it. Idempotent, so
// a repeat is not an error.
fn charsDelete(fd: net.Socket, req: []const u8) void {
    const body = bodyOf(req);
    const account = jsonStr(body, "account") orelse return respond(fd, bad_request, "{\"error\":\"missing account\"}");
    const char = jsonStr(body, "char") orelse return respond(fd, bad_request, "{\"error\":\"missing char\"}");
    if (!store.deleteCharD2s(account, char)) return respond(fd, conflict, "{\"error\":\"delete failed\"}");
    respond(fd, ok, "{\"deleted\":true}");
}

/// True if the flat JSON body has `"key": true`. Crude (no nesting), matches jsonStr.
fn jsonBool(body: []const u8, key: []const u8) bool {
    var kbuf: [64]u8 = undefined;
    if (key.len + 2 > kbuf.len) return false;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    const needle = kbuf[0 .. key.len + 2];
    const ki = std.mem.indexOf(u8, body, needle) orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, body, ki + needle.len, ':') orelse return false;
    var i = colon + 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    return std.mem.startsWith(u8, body[i..], "true");
}

fn accountsCreate(fd: net.Socket, req: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    const password = jsonStr(body, "password") orelse return respond(fd, bad_request, "{\"error\":\"missing password\"}");
    if (name.len == 0) return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    const pwhash = xsha1.passwordHash(password);
    if (!store.createAccount(name, pwhash)) return respond(fd, conflict, "{\"error\":\"exists\"}");
    if (jsonBool(body, "admin")) _ = store.setAdmin(name, true);
    respond(fd, ok, "{\"created\":true}");
}

// POST /admin/accounts/delete {"name"} — remove an account and everything under it.
// `caller` is the logged-in identity: you cannot delete the account you are using, which is the
// same lockout guard the demote path has and for the same reason.
fn accountsDelete(fd: net.Socket, req: []const u8, caller: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    if (name.len == 0) return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    if (std.ascii.eqlIgnoreCase(name, caller))
        return respond(fd, conflict, "{\"error\":\"refusing to delete yourself\"}");
    if (!store.accountExists(name)) return respond(fd, not_found, "{\"error\":\"no such account\"}");
    if (!store.deleteAccount(name)) return respond(fd, conflict, "{\"error\":\"delete failed\"}");
    respond(fd, ok, "{\"deleted\":true}");
}

// POST /admin/accounts/admin {"name","admin":bool} — promote/demote an account's web-UI
// admin flag. `caller` is the logged-in identity: you cannot demote yourself (lockout
// guard; an env-allowlisted admin can always undo via REALMD_ADMINS).
fn setAdminEndpoint(fd: net.Socket, req: []const u8, caller: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    const want = jsonBool(body, "admin");
    if (!want and std.ascii.eqlIgnoreCase(name, caller))
        return respond(fd, conflict, "{\"error\":\"refusing to demote yourself\"}");
    if (!store.accountExists(name)) return respond(fd, not_found, "{\"error\":\"no such account\"}");
    _ = store.setAdmin(name, want);
    if (want) any_db_admin = true; // keep the API enabled across restarts
    var b: [64]u8 = undefined;
    respond(fd, ok, std.fmt.bufPrint(&b, "{{\"name\":\"{s}\",\"admin\":{}}}", .{ name, want }) catch "{}");
}

fn closeGame(fd: net.Socket, path: []const u8, req: []const u8) void {
    const body = bodyOf(req);
    const name = jsonStr(body, "name") orelse queryParam(path, "name") orelse return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    if (name.len == 0) return respond(fd, bad_request, "{\"error\":\"missing name\"}");
    _ = state.global.closeGameByName(name);
    respond(fd, ok, "{\"closed\":true}");
}
