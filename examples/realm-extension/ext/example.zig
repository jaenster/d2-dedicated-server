//! Every hook the realm offers, in one extension, doing the smallest real thing each one is for.
//!
//! Two jobs. It is the worked example a realm is started from — copy it, delete the hooks you do
//! not want, and what is left still compiles. And it is upstream's drift guard: this file is built
//! by `zig build realm-example`, which `zig build test` depends on, so a hook whose signature
//! changes stops the build here instead of silently never being called in somebody's realm.
//!
//! Declare only what you need. A hook you do not declare costs nothing — the realm's `inline for`
//! skips it at compile time — and a hook you MISSPELL is simply never called, which is the one
//! failure this arrangement cannot catch for you.
const std = @import("std");
const realmd = @import("realmd");

/// Named for the startup log line, and the namespace this extension's storage and configuration
/// live under: `store.ext("example")`, `REALMD_EXT_EXAMPLE_*`.
pub const name = "example";

/// Durable + cached storage that is ours alone. Nothing the realm stores can collide with it, and
/// no upstream schema change can break it.
const db = realmd.store.ext(name);

/// Read once at startup rather than per call — `cfg.ext` reads the environment every time.
var greeting: []const u8 = "Welcome.";

// startup

/// The store is up, nothing is listening yet. Returning an error aborts startup, which is the
/// right answer for configuration this extension cannot run without.
pub fn startup(cfg: anytype) !void {
    greeting = cfg.ext(name).getOr("greeting", "Welcome.");
    const season = cfg.ext(name).int(u32, "season", 1);

    // Durable state, in our own keyspace. Absent on a realm's very first boot.
    var buf: [32]u8 = undefined;
    const n = db.get("season", &buf);
    if (n == 0) {
        var sb: [16]u8 = undefined;
        _ = db.put("season", std.fmt.bufPrint(&sb, "{d}", .{season}) catch return error.SeasonUnwritable);
    }
    // Our listener's port comes from the environment, so a realm can move it and a second instance
    // can be given a different one. Unset (0) means this extension binds nothing.
    const api_port = cfg.ext(name).int(u16, "api_port", 0);
    if (api_port != 0) {
        api[0] = .{ .name = "example-api", .port = api_port, .handler = serveApi };
        api_n = 1;
    }
    realmd.log.line(name, "season {d}, greeting '{s}', api port {d}", .{ season, greeting, api_port });
}

// who gets in

/// OVERRIDE the password check. Null means "not mine" — the realm's own check runs — so this only
/// claims the accounts it actually knows about. A real one would ask an account database, a
/// launcher token or an SSO provider here.
///
/// This one implements a ban list out of our own keyspace, and leaves every other login alone.
pub fn authenticate(req: realmd.hook.AuthRequest) ?realmd.hook.Auth {
    var buf: [8]u8 = undefined;
    var key: [128]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "banned:{s}", .{req.account}) catch return null;
    if (db.get(k, &buf) == 0) return null; // not banned: not our business
    realmd.log.line(name, "refused banned account {s}", .{req.account});
    return .reject_no_account;
}

/// VETO an account before it exists. Reserved names, an invite-only realm, an external registry
/// that has to be the one issuing accounts.
pub fn accountCreate(account: []const u8) bool {
    return !std.ascii.startsWithIgnoreCase(account, "gm_");
}

/// OBSERVE a finished logon. The answer is already decided; this is for counting and telemetry.
pub fn accountLogin(account: []const u8, ok: bool) void {
    // A shared counter, so the number is the whole realm's rather than one replica's.
    _ = db.incr(if (ok) "logins:ok" else "logins:failed", 1, 0);
    _ = account;
}

// characters

/// VETO a character. Return an MCP result code to refuse, null to allow.
pub fn charCreate(account: []const u8, charname: []const u8, class: u8) ?u32 {
    _ = account;
    _ = class;
    // 0x15 is what the client renders as "name already exists"; a realm enforcing its own naming
    // rules picks whichever of the MCP codes says the closest true thing.
    return if (charname.len < 3) 0x15 else null;
}

pub fn charLogon(account: []const u8, charname: []const u8) void {
    realmd.log.line(name, "{s}/{s} entered", .{ account, charname });
}

/// The .d2s as the game server left it. Read it — a ladder counts levels here — but do not keep
/// the slice; it is not yours after this returns.
pub fn charSave(account: []const u8, charname: []const u8, bytes: []const u8) void {
    var key: [128]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "lastsave:{s}:{s}", .{ account, charname }) catch return;
    var sz: [16]u8 = undefined;
    _ = db.put(k, std.fmt.bufPrint(&sz, "{d}", .{bytes.len}) catch return);
}

// games

/// VETO a game create. Return an MCP result code to refuse, null to allow.
pub fn gameCreate(account: []const u8, charname: []const u8, gamename: []const u8, difficulty: u8) ?u32 {
    _ = account;
    _ = charname;
    _ = difficulty;
    _ = gamename;
    return null;
}

/// VETO a join, on the same terms.
pub fn gameJoin(account: []const u8, charname: []const u8, gamename: []const u8) ?u32 {
    _ = account;
    _ = charname;
    _ = gamename;
    return null;
}

/// OVERRIDE what the join list shows this player. False hides a game, true forces it visible,
/// null leaves the answer to the realm. Hiding is cosmetic — `gameJoin` is where a join is
/// actually refused.
pub fn gameVisible(account: []const u8, gamename: []const u8, gameid: u32) ?bool {
    _ = account;
    _ = gameid;
    // A convention this realm invents: games whose name starts with '.' are unlisted.
    return if (std.mem.startsWith(u8, gamename, ".")) false else null;
}

/// OVERRIDE where a game is hosted. Return a gsid to place it there, null to let the realm place
/// it as it would. The choice is reserved atomically and can still lose the race; if it does, the
/// realm falls back to its own pick rather than failing the create.
///
/// This is the hook that turns one fleet into several — hardcore on its own servers, a region kept
/// local, or a game routed to a server that runs the engine version it needs.
pub fn pickGs(req: realmd.hook.GsPick) ?u32 {
    if (!req.hardcore) return null;
    // Hardcore goes to the emptiest server, so a death is never a server's fault.
    var best: ?realmd.hook.GsInfo = null;
    for (req.servers) |s| {
        if (s.maxgame != 0 and s.live >= s.maxgame) continue;
        if (best == null or s.live < best.?.live) best = s;
    }
    return if (best) |b| b.gsid else null;
}

// chat

/// ADD a `/command`. Runs after the realm's own, so it cannot shadow one by accident. Return true
/// once you have answered it and it goes no further.
pub fn chatCommand(c: *realmd.bncs.Conn, tag: []const u8, text: []const u8) bool {
    _ = tag;
    if (!std.ascii.eqlIgnoreCase(text, "/season")) return false;
    var buf: [32]u8 = undefined;
    const n = db.get("season", &buf);
    var line: [64]u8 = undefined;
    c.tell(std.fmt.bufPrint(&line, "Season {s}. {s}", .{ buf[0..n], greeting }) catch "Season unknown.");
    return true;
}

/// VETO a line of channel talk — mutes, flood control, word filters. False drops it, and the
/// sender is not told unless you tell them.
pub fn chatSay(c: *realmd.bncs.Conn, account: []const u8, channel: []const u8, text: []const u8) bool {
    _ = account;
    _ = channel;
    if (text.len <= 200) return true;
    c.warn("That line is too long for this realm.");
    return false;
}

// raw protocol

/// Every BNCS packet, before the realm's own dispatch. False consumes it — the escape hatch for
/// protocol work upstream does not model. True (the common case) passes it through untouched.
pub fn bncsPacket(c: *realmd.bncs.Conn, id: u8, body: []const u8) bool {
    _ = c;
    _ = id;
    _ = body;
    return true;
}

/// Every MCP packet, on the same terms.
pub fn mcpPacket(c: *realmd.d2cs.DConn, id: u8, body: []const u8) bool {
    _ = c;
    _ = id;
    _ = body;
    return true;
}

// listeners of our own

/// ADD ports the realm binds at startup, alongside its own. This is how a realm grows a login
/// path the D2 client never had — a launcher endpoint, a REST hook a website calls — without that
/// traffic having to arrive as BNCS packets.
///
/// Read from configuration in `startup`, not hardcoded, and empty when unset. A fixed port would
/// make the SECOND instance of this realm fail to bind and die — a bind that fails is fatal, as
/// the realm's own listeners are, because a realm that comes up healthy with half of itself
/// missing is worse than one that refuses to start.
var api: [1]realmd.hook.Listener = undefined;
var api_n: usize = 0;

pub fn listeners() []const realmd.hook.Listener {
    return api[0..api_n];
}

/// A `net.Handler`, the same shape the realm's own listeners use: one connection, and it is yours
/// until you close it. Runs on its own thread, so blocking here blocks nothing else.
fn serveApi(fd: realmd.net.Socket, tag: []const u8) void {
    defer realmd.net.closeSocket(fd);
    var buf: [512]u8 = undefined;
    const n = realmd.net.readSome(fd, &buf);
    if (n == 0) return;
    realmd.log.line(tag, "api request ({d} bytes)", .{n});
    var seasonb: [32]u8 = undefined;
    const sn = db.get("season", &seasonb);
    var body: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&body, "{{\"season\":\"{s}\"}}", .{seasonb[0..sn]}) catch return;
    var head: [160]u8 = undefined;
    const resp = std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload }) catch return;
    _ = realmd.net.writeAll(fd, resp);
}
