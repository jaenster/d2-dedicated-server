//! The realm's control link, from the Mac image's side.
//!
//! Same channel `apps/d2gs/realmclient/d2cs.zig` speaks on Windows and the same wire types, but a
//! different engine underneath: this build has no `GAME_CreateBattleNetGame` and no realm callback
//! table, so a game is made by calling `GAME_CreateGame` 0x001ac3f3 — the one the 0x67 packet uses
//! — with a null client. That is survivable: the only two things it does with the client are store
//! it in the new player record and hand it to a map that has a null-client singleton branch, which
//! is also where the new game's id ends up (0x00552568).
//!
//! One game at a time, always. The engine's token allocator clamps its counter to 1 and the table
//! it hands out of has one usable slot, so `maxgame` is 1 and a second create is refused rather
//! than allowed to produce a game no token can reach.

const std = @import("std");
const macho = @import("macho");
const p = @import("realm_proto").protocol;

// 0.16's std.posix has no socket layer, so the four calls this needs come straight from libc —
// the same shape `packages/realm-infra/net.zig` uses.
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn usleep(usec: c_uint) c_int;

var image: *const macho.load.Loaded = undefined;
var sock: c_int = -1;
var seqno: u32 = 0;
var started = false;

/// What the GS tells the realm to send clients to, and who it says it is.
var public_ip: [4]u8 = .{ 127, 0, 0, 1 };
var public_port: u16 = 4000;
var gsid: u32 = 0;

const addr = struct {
    /// (client, name, u8, u8, desc, u16, flags, u8, u8, u8, u8, u8, 0, 0) — __cdecl, void.
    const game_create: u32 = 0x001ac3f3;
    /// (u16 token) -> game id, or 0. The engine only ever issues token 1, so this doubles as
    /// "is a game live".
    const is_token_valid: u32 = 0x001abcff;
    /// Where 0x002de1f9 files a game id whose client is null — i.e. every game we make.
    const last_gameid: u32 = 0x00552568;
    /// GAMELOGON's `call SERVER_IsTokenValid`, and the instruction after it.
    const join_lookup_call: u32 = 0x001a7a36;
    const join_lookup_next: u32 = 0x001a7a3b;
};

/// The engine's token table has three entries and no bounds check, so a lookup past the end is a
/// wild read. Nothing above this may be handed to SERVER_IsTokenValid.
const engine_token_max: u32 = 2;

/// The engine's id for the live game, and the small id the realm knows it by. The two differ
/// because the engine counts games from a large seed while the realm's id has to survive being
/// truncated to the u16 the client carries in its GAMELOGON.
var live_gameid: u32 = 0;
var live_join_id: u16 = 0;
var next_join_id: u16 = 0;

/// Answers GAMELOGON's "what game is this". Replaces SERVER_IsTokenValid at its call site, and
/// falls back to it for the ids that function can safely be asked about — which keeps the engine's
/// own one-game-on-token-1 path working when no realm is attached.
fn resolveJoinId(id: u32) callconv(.c) u32 {
    if (id != 0 and id == live_join_id and live_gameid != 0) return live_gameid;
    if (id <= engine_token_max) return tokenValid(id);
    return 0;
}

/// Point GAMELOGON's lookup at `resolveJoinId`: same `call rel32`, new target. Runs before the
/// image is made read-only, and only where our own code is addressable in 32 bits — which is the
/// same condition the byte patches are already gated on.
pub fn installJoinHook(loaded: *const macho.load.Loaded) void {
    image = loaded;
    const site = loaded.at(addr.join_lookup_call);
    const rel: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(&resolveJoinId))) -%
        @as(u32, @truncate(loaded.at(addr.join_lookup_next))));
    const at: [*]u8 = @ptrFromInt(site);
    at[0] = 0xe8;
    std.mem.writeInt(i32, at[1..5], rel, .little);
}

/// The create is engine work, so it runs on the tick thread; this is the handoff.
var req_pending = std.atomic.Value(bool).init(false);
var req_done = std.atomic.Value(bool).init(false);
var req_name: [36]u8 = undefined;
var req_desc: [36]u8 = undefined;
var req_flags: u32 = 0;
var req_result: u32 = p.CREATE_FAILED;
var req_gameid: u32 = 0;

/// Two senders share the socket: the control thread answers requests, the tick thread reports a
/// game closing.
var send_lock = std.atomic.Value(bool).init(false);

pub fn start(loaded: *const macho.load.Loaded) void {
    image = loaded;
    const realm = env("D2GS_REALM") orelse {
        note("d2gs-native: gslink off (set D2GS_REALM=host:port to register with a realm)\n", .{});
        return;
    };
    const advertised = env("D2GS_GS_ADDR") orelse "127.0.0.1:4000";
    parseAddr(advertised, &public_ip, &public_port) catch {
        note("d2gs-native: D2GS_GS_ADDR=\"{s}\" is not host:port\n", .{advertised});
        return;
    };
    gsid = identity();
    started = true;
    _ = std.Thread.spawn(.{}, thread, .{realm}) catch |e| {
        note("d2gs-native: gslink thread: {s}\n", .{@errorName(e)});
        started = false;
    };
}

/// Called once per server tick. Runs whatever the control thread queued, and watches for the game
/// going away — the engine has no hook to tell us, but its token stops resolving.
pub fn pump() void {
    if (!started) return;
    if (req_pending.load(.acquire)) {
        runCreate();
        req_pending.store(false, .release);
        req_done.store(true, .release);
    }
    if (live_gameid != 0 and tokenValid(1) == 0) {
        sendCloseGame(live_join_id);
        note("d2gs-native: gslink CLOSEGAME gameid={d}\n", .{live_join_id});
        live_gameid = 0;
        live_join_id = 0;
    }
}

// ── engine ───────────────────────────────────────────────────────────────────

fn tokenValid(token: u32) u32 {
    const f: *const fn (u32) callconv(.c) u32 = @ptrFromInt(image.at(addr.is_token_valid));
    return f(token);
}

/// The 0x67 handler's call, with the packet's fields spelled out. Everything but the name, the
/// description and the flags is the constant that path passes for a plain expansion game.
fn runCreate() void {
    req_gameid = 0;
    if (tokenValid(1) != 0) {
        req_result = p.CREATE_SERVER_FULL;
        return;
    }
    const Create = fn (
        client: u32,
        name: [*:0]const u8,
        a2: u32,
        a3: u32,
        desc: [*:0]const u8,
        a5: u32,
        flags: u32,
        a7: u32,
        a8: u32,
        a9: u32,
        a10: u32,
        a11: u32,
        a12: u32,
        a13: u32,
    ) callconv(.c) void;
    const create: *const Create = @ptrFromInt(image.at(addr.game_create));
    create(0, @ptrCast(&req_name), 0, 1, @ptrCast(&req_desc), 0, req_flags, 0, 0, 0, 0, 0, 0, 0);

    const singleton: *const u32 = @ptrFromInt(image.at(addr.last_gameid));
    const id = singleton.*;
    // A game the engine did not file under token 1 is one no join can reach, so it is not a game
    // we can honestly report.
    if (id == 0 or tokenValid(1) != id) {
        req_result = p.CREATE_FAILED;
        return;
    }
    next_join_id = if (next_join_id == std.math.maxInt(u16)) 1 else next_join_id + 1;
    live_join_id = next_join_id;
    live_gameid = id;
    req_gameid = live_join_id;
    req_result = p.CREATE_OK;
}

// ── control connection ───────────────────────────────────────────────────────

fn thread(realm: []const u8) void {
    var ip: [4]u8 = undefined;
    var port: u16 = 6115;
    parseAddr(realm, &ip, &port) catch {
        note("d2gs-native: D2GS_REALM=\"{s}\" is not host:port\n", .{realm});
        return;
    };
    var complained = false;
    while (true) {
        if (connectOnce(ip, port)) {
            complained = false;
            serve();
            _ = close(sock);
            sock = -1;
            note("d2gs-native: gslink disconnected\n", .{});
        } else if (!complained) {
            complained = true;
            note("d2gs-native: gslink cannot reach {d}.{d}.{d}.{d}:{d} — retrying\n", .{ ip[0], ip[1], ip[2], ip[3], port });
        }
        // A realm that is not up yet is the normal case at boot; keep asking.
        _ = usleep(2_000_000);
    }
}

fn connectOnce(ip: [4]u8, port: u16) bool {
    const s = socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (s < 0) return false;
    const sa = std.posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
    if (connect(s, &sa, @sizeOf(std.posix.sockaddr.in)) != 0) {
        _ = close(s);
        return false;
    }
    sock = s;
    note("d2gs-native: gslink connected to {d}.{d}.{d}.{d}:{d} gsid=0x{x}\n", .{ ip[0], ip[1], ip[2], ip[3], port, gsid });
    return true;
}

fn serve() void {
    var body: [1024]u8 = undefined;
    while (true) {
        var head: [p.HEADER_LEN]u8 = undefined;
        if (!recvAll(&head)) return;
        const size = std.mem.readInt(u16, head[0..2], .little);
        const typ = std.mem.readInt(u16, head[2..4], .little);
        if (size < p.HEADER_LEN or size - p.HEADER_LEN > body.len) return;
        const n = size - p.HEADER_LEN;
        if (!recvAll(body[0..n])) return;
        onPacket(typ, body[0..n]);
    }
}

fn onPacket(typ: u16, body: []const u8) void {
    switch (typ) {
        @intFromEnum(p.Type.authreq) => sendRegistration(),
        @intFromEnum(p.Type.echo) => {
            var h: [p.HEADER_LEN]u8 = undefined;
            writeHeader(&h, p.HEADER_LEN, @intFromEnum(p.Type.echo));
            _ = sendAll(&h);
        },
        @intFromEnum(p.Type.creategame) => onCreateGame(body),
        @intFromEnum(p.Type.joingame) => {
            // The engine needs nothing primed: the join carries its own game id and the character
            // comes off the class byte in it. Acknowledging is all the realm is waiting for.
            const gid = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 0;
            var r = std.mem.zeroes(p.JoinGameReply);
            r.h = header(.joingame, @sizeOf(p.JoinGameReply));
            r.result = if (gid == live_join_id and gid != 0) 0 else 1;
            r.gameid = gid;
            _ = sendAll(std.mem.asBytes(&r));
        },
        else => {},
    }
}

/// AUTHREPLY + SETGSINFO + ADDRINFO in one burst — the realm only counts a GS as able to host
/// once the last of the three arrives.
fn sendRegistration() void {
    var auth = std.mem.zeroes(p.AuthReply);
    auth.h = header(.authreply, @sizeOf(p.AuthReply));
    auth.version = 1;
    _ = sendAll(std.mem.asBytes(&auth));

    var info = std.mem.zeroes(p.SetGsInfo);
    info.h = header(.setgsinfo, @sizeOf(p.SetGsInfo));
    info.maxgame = 1;
    _ = sendAll(std.mem.asBytes(&info));

    var ai = std.mem.zeroes(p.AddrInfo);
    ai.h = header(.addrinfo, @sizeOf(p.AddrInfo));
    ai.maxgame = 1;
    ai.gsid = gsid;
    ai.ip = public_ip;
    ai.port = public_port;
    _ = sendAll(std.mem.asBytes(&ai));
    note("d2gs-native: gslink registered {d}.{d}.{d}.{d}:{d} maxgame=1\n", .{
        public_ip[0], public_ip[1], public_ip[2], public_ip[3], public_port,
    });
}

fn onCreateGame(body: []const u8) void {
    var result: u32 = p.CREATE_FAILED;
    var gid: u32 = 0;
    if (body.len >= 4) {
        var off: usize = 4;
        copyz(&req_name, readCStr(body, &off));
        _ = readCStr(body, &off); // password: the realm already matched it
        copyz(&req_desc, readCStr(body, &off));
        req_flags = gameFlags(body[2], body[1] != 0, body[3] != 0);

        req_done.store(false, .release);
        req_pending.store(true, .release);
        var waited: u32 = 0;
        while (!req_done.load(.acquire) and waited < 5000) : (waited += 5) _ = usleep(5000);
        if (req_done.load(.acquire)) {
            result = req_result;
            gid = req_gameid;
        }
    }
    var r = std.mem.zeroes(p.CreateGameReply);
    r.h = header(.creategame, @sizeOf(p.CreateGameReply));
    r.result = result;
    r.gameid = gid;
    _ = sendAll(std.mem.asBytes(&r));
    note("d2gs-native: gslink CREATEGAME \"{s}\" -> result={d} gameid={d}\n", .{ cstr(&req_name), result, gid });
}

fn sendCloseGame(gid: u32) void {
    var c = std.mem.zeroes(p.CloseGame);
    c.h = header(.closegame, @sizeOf(p.CloseGame));
    c.gameid = gid;
    _ = sendAll(std.mem.asBytes(&c));
}

/// Bit 2 gates the per-frame client update and the engine asserts without it; bits 12-14 are the
/// difficulty. Same set `apps/d2gs/engine/server.zig` builds, and the same one the 0x67 probe used.
fn gameFlags(difficulty: u8, expansion: bool, hardcore: bool) u32 {
    var f: u32 = @as(u32, difficulty & 7) << 12;
    f |= 0x04;
    if (expansion) f |= 0x10_0000;
    if (hardcore) f |= 0x800;
    return f;
}

// ── plumbing ─────────────────────────────────────────────────────────────────

fn header(t: p.Type, size: u16) p.Header {
    seqno +%= 1;
    return .{ .size = size, .type = @intFromEnum(t), .seqno = seqno };
}

fn writeHeader(buf: []u8, size: u16, typ: u16) void {
    seqno +%= 1;
    std.mem.writeInt(u16, buf[0..2], size, .little);
    std.mem.writeInt(u16, buf[2..4], typ, .little);
    std.mem.writeInt(u32, buf[4..8], seqno, .little);
}

fn sendAll(bytes: []const u8) bool {
    while (send_lock.swap(true, .acquire)) _ = usleep(1000);
    defer send_lock.store(false, .release);
    if (sock < 0) return false;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(sock, bytes.ptr + off, bytes.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn recvAll(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(sock, buf.ptr + off, buf.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn readCStr(body: []const u8, off: *usize) []const u8 {
    const from = off.*;
    var i = from;
    while (i < body.len and body[i] != 0) : (i += 1) {}
    off.* = @min(i + 1, body.len);
    return body[from..i];
}

fn copyz(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    @memset(dst[n..], 0);
}

fn cstr(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

fn env(name: []const u8) ?[]const u8 {
    var nbuf: [64]u8 = undefined;
    const z = std.fmt.bufPrintZ(&nbuf, "{s}", .{name}) catch return null;
    const v = std.c.getenv(z.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn parseAddr(text: []const u8, ip: *[4]u8, port: *u16) !void {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.NoPort;
    port.* = try std.fmt.parseInt(u16, text[colon + 1 ..], 10);
    var it = std.mem.splitScalar(u8, text[0..colon], '.');
    for (ip) |*o| o.* = try std.fmt.parseInt(u8, it.next() orelse return error.NotDotted, 10);
    if (it.next() != null) return error.NotDotted;
}

/// A fleet needs one id per server, and the host name alone is not it: two servers on one machine
/// would collide. FNV-1a over name and port, as the Windows side derives it.
fn identity() u32 {
    if (env("D2GS_GSID")) |s| {
        if (std.fmt.parseInt(u32, s, 0)) |v| return v else |_| {}
    }
    var h: u32 = 2166136261;
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&name) catch name[0..0];
    for (host) |c| h = (h ^ c) *% 16777619;
    for (std.mem.asBytes(&public_port)) |c| h = (h ^ c) *% 16777619;
    return h;
}

fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

test "host:port parses into octets and a port" {
    var ip: [4]u8 = undefined;
    var port: u16 = 0;
    try parseAddr("10.1.2.3:6115", &ip, &port);
    try std.testing.expectEqual([4]u8{ 10, 1, 2, 3 }, ip);
    try std.testing.expectEqual(@as(u16, 6115), port);
    try std.testing.expectError(error.NoPort, parseAddr("10.1.2.3", &ip, &port));
    try std.testing.expectError(error.InvalidCharacter, parseAddr("realm.example:6115", &ip, &port));
    try std.testing.expectError(error.NotDotted, parseAddr("10.1.2.3.4:6115", &ip, &port));
}

test "game flags carry difficulty, the client-update gate and expansion" {
    try std.testing.expectEqual(@as(u32, 0x10_0004), gameFlags(0, true, false));
    try std.testing.expectEqual(@as(u32, 0x10_2804), gameFlags(2, true, true));
}
