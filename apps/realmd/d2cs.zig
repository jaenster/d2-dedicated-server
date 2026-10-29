//! D2CS — realm/character server, client-facing, muxed onto the BNCS port. After bnetd's realm
//! handoff the client connects here, proves itself with the session bnetd minted (MCP_STARTUP),
//! lists/selects a character, and creates/joins games.
//!
//! Framing: `<len:u16 LE> <id:u8>`, len includes the 3-byte header. The first byte on the socket
//! is a protocol selector (0x01), consumed once.
const std = @import("std");
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const proto = @import("proto.zig");
const state = @import("state.zig");
const store = @import("store.zig");
const version = @import("version.zig");
const d2s = @import("d2s.zig");
const fleet = @import("fleet.zig");
const guilds = @import("guilds.zig");
const hook = @import("hook.zig");
const metrics = @import("metrics.zig");
const ladder_list = @import("ladder.zig");

extern "c" fn time(t: ?*c_long) c_long; // POSIX seconds-since-epoch, for the .d2s create time

// MCP message ids (subset; everything else is logged).
const mcp = @import("libd2").bnet.mcp;

const MCP_STARTUP = @backingInt(mcp.Op.startup);
const MCP_CHARCREATE = @backingInt(mcp.Op.charcreate);
const MCP_CREATEGAME = @backingInt(mcp.Op.creategame);
const MCP_JOINGAME = @backingInt(mcp.Op.joingame);
const MCP_GAMELIST = @backingInt(mcp.Op.gamelist);
const MCP_GAMEINFO = @backingInt(mcp.Op.gameinfo);
const MCP_CHARLOGON = @backingInt(mcp.Op.charlogon);
const MCP_CHARDELETE = @backingInt(mcp.Op.chardelete);
const MCP_LADDERDATA = @backingInt(mcp.Op.ladderdata);
const MCP_MOTD = @backingInt(mcp.Op.motd);
const MCP_CANCELCREATE = @backingInt(mcp.Op.cancelcreate);
const MCP_CHARRANK = @backingInt(mcp.Op.charrank);
const MCP_CHARUPGRADE = @backingInt(mcp.Op.charupgrade);
const MCP_CHARLIST2 = @backingInt(mcp.Op.charlist2);

// MCP result codes from OOG_PollJoinCreatePump @0x441770 (D2Client/OOGUtilities.cpp), with the
// string-table id each resolves to. A code not in this list falls to `default:`: no popup, no
// state change, player frozen on the join screen.
// CREATEGAME (0x03) replies:
const CREATE_OK: u32 = @backingInt(mcp.CreateResult.created);
const CREATE_INVALID_NAME: u32 = @backingInt(mcp.CreateResult.invalid_name); // str 0x1411 "Invalid Game Name"
const CREATE_NAME_TAKEN: u32 = @backingInt(mcp.CreateResult.already_exists); // str 0x1412 "Game Already Exists"
const CREATE_SERVER_DOWN: u32 = @backingInt(mcp.CreateResult.servers_down); // str 0x1413 "Server Down"
// There is NO "servers are full" code on the create path: JoinOrCreateGame @0x441500 bounds the
// switch at 0x20 and sends everything else to str 0x1415 "Error Creating Game" (0x2b "Game is
// Full" exists only on the JOIN path, and means that one game is full — not this). So a full
// fleet gets the default bucket on purpose: "Error Creating Game" is vague but TRUE, whereas
// "Server Down" would be a plain lie about servers that are up and busy.
const CREATE_ERROR_GENERIC: u32 = @backingInt(mcp.CreateResult.generic); // > 0x20 -> str 0x1415 "Error Creating Game"

// JOINGAME (0x04) replies. NOTE the first two — they are not in the order you would
// guess from the numbers, and realmd had them the wrong way round: 0x29 is the PASSWORD
// failure and 0x2a is the MISSING-GAME failure.
const JOIN_OK: u32 = @backingInt(mcp.JoinResult.ok);
const JOIN_BAD_PASSWORD: u32 = @backingInt(mcp.JoinResult.password_incorrect); // str 0x1428 "password don't match"
const JOIN_NO_SUCH_GAME: u32 = @backingInt(mcp.JoinResult.no_such_game); // str 0x1427 "Game does not exist."
const JOIN_FULL: u32 = @backingInt(mcp.JoinResult.game_full); // str 0x1429 "Game is Full."
const JOIN_HARDCORE_MIX: u32 = @backingInt(mcp.JoinResult.hardcore_mix); // str 0x1426 hc/normal mix
const JOIN_CLASSIC_INTO_EXPANSION: u32 = @backingInt(mcp.JoinResult.classic_into_expansion); // str 0x2775
const JOIN_EXPANSION_INTO_CLASSIC: u32 = @backingInt(mcp.JoinResult.expansion_into_classic); // str 0x2776
const JOIN_LADDER_MISMATCH: u32 = @backingInt(mcp.JoinResult.ladder_mismatch);
const JOIN_NEED_NIGHTMARE: u32 = @backingInt(mcp.JoinResult.need_nightmare); // str 0x14f4/0x5522 need Diablo/Baal kill
const JOIN_NEED_HELL: u32 = @backingInt(mcp.JoinResult.need_hell); // str 0x14f3/0x5521, str 0x2ab1/0x2ab2 by ladder flag

/// Character status bits as they sit in the .d2s header at 0x24 — the same bits the
/// CharSel statstring and MCP_CHARCREATE speak in. A game stores the creator's, so a
/// joiner can be checked against it.
const STATUS_HARDCORE: u8 = 0x04;
const STATUS_EXPANSION: u8 = 0x20;
const STATUS_LADDER: u8 = 0x40;
const STATUS_JOIN_MASK: u8 = STATUS_HARDCORE | STATUS_EXPANSION | STATUS_LADDER;

/// How far a character has to have got to be let into a harder game — the client's OWN
/// thresholds. CharSel @0x4349b0 offers a difficulty at `progression > 3` (classic) / `> 4`
/// (expansion); UIMENU_SelectDifficultySinglePlayerOrTcpip @0x439780 reveals Hell at `> 7` / `> 9`.
/// Progression is the .d2s byte at 0x25, the same value the CharSel statstring carries in bits
/// 8..12 of the character flags. Expansion needs one more step per gate: its acts are counted too.
const progression_nightmare_classic: u8 = 4;
const progression_nightmare_expansion: u8 = 5;
const progression_hell_classic: u8 = 8;
const progression_hell_expansion: u8 = 10;

/// The reason `progression` cannot enter a game of `difficulty`, or null if it can.
/// Normal is always open — everyone starts there.
fn difficultyError(difficulty: u8, progression: u8, expansion: bool) ?u32 {
    return switch (difficulty) {
        0 => null,
        1 => if (progression < (if (expansion) progression_nightmare_expansion else progression_nightmare_classic))
            JOIN_NEED_NIGHTMARE
        else
            null,
        else => if (progression < (if (expansion) progression_hell_expansion else progression_hell_classic))
            JOIN_NEED_HELL
        else
            null,
    };
}

/// A D2 game holds eight players; past that the engine's CreateClient refuses outright
/// (`pGame->nClientsCount < 8`, D2Game/Game/Clients.cpp CreateClient @0x539a30). Turning
/// a join away here means a clear "Game is Full." instead of a silent failure at the GS.
const realm_proto = @import("realm_proto");
const max_players_per_game: u16 = realm_proto.max_players_per_game;

/// How many seats a game offers: what its creator chose, 1..8, and never more than the engine's
/// own ceiling.
fn seatLimit(max: u8) u32 {
    return @min(max, max_players_per_game);
}

test "a game offers the seats its creator chose, never past eight" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 8), max_players_per_game);
    try t.expectEqual(@as(u32, 1), seatLimit(1));
    try t.expectEqual(@as(u32, 4), seatLimit(4));
    try t.expectEqual(@as(u32, 8), seatLimit(8));
    try t.expectEqual(@as(u32, 8), seatLimit(200));
}

/// How long a join waits for a create that is still in flight for the same name, and how often it
/// looks. Bounded: a client that waits is better than one told the game does not exist, but not at
/// the cost of pinning a connection thread on a create that never lands.
const create_settle_ms: u32 = 750;
/// How long a join waits for a character's previous seat to be freed. Longer than the create
/// settle: the engine needs a moment per departing client to notice the socket is gone, and that
/// is measured in hundreds of milliseconds rather than tens.
const seat_release_ms: u32 = 1500;
const create_poll_ms: u32 = 25;

extern "c" fn usleep(usec: c_uint) c_int;

fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

// The game-traffic ingress clients are told to dial, set from main() and required there.
// JOINGAME never advertises a game server's own address: the token handed to the client is
// realm-global, and only an ingress (d2ingress, or the embedded edge) can translate it to the
// engine's gameid. `route_ttl_s` is how long the recorded route stays valid.
pub var game_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var route_ttl_s: u32 = 60;

/// Largest character this will stage. A real 1.14d save is a few KB; a read that exactly filled a
/// smaller buffer could not be told from a truncated one, and the store refuses to cache those.
const max_stage_d2s = 32 * 1024;

/// Pull a character into the shared store so the game server can find it there.
///
/// The read itself is the mechanism: the store populates its cache on a miss, and does so only
/// when nothing is cached, so this can never put an older copy over a newer save.
fn warmChar(account: []const u8, charname: []const u8) void {
    var buf: [max_stage_d2s]u8 = undefined;
    const n = store.getCharD2s(account, charname, &buf);
    if (n == 0) log.line("d2cs", "warm '{s}/{s}' -> no such character", .{ account, charname });
}

/// Mint the next game token. realmd OWNS the token it hands the client — two clients behind one
/// public IP get distinct ones, which is what makes the gateway's translation NAT-proof. The
/// counter lives in the store so it is realm-global rather than per-process; see
/// `store.mintToken`.
fn mintToken() u16 {
    return store.mintToken();
}

pub const DConn = struct {
    fd: net.Socket,
    // Outbound packets accumulate here and leave in one write: the game list sends one packet
    // PER GAME plus a terminator, so browsing a busy realm cost a syscall per listed game.
    // Flushed before we block on read, and by a `defer` so no exit path can strand them.
    out: [16384]u8 = undefined,
    out_len: usize = 0,
    session: u64 = 0,
    account: [state.max_name + 1]u8 = @splat(0),
    account_len: u8 = 0,
    char: [state.max_name + 1]u8 = @splat(0),
    char_len: u8 = 0,
    // Which engine the client on the other end runs. MCP is a different connection from the login
    // that learned it, so it comes back off the session at startup rather than off the wire.
    client_version: [state.max_version]u8 = @splat(0),
    client_version_len: u8 = 0,
    /// Set by a successful MCP_STARTUP and by nothing else; every other command needs it. `drop`
    /// closes the connection once the current packet is answered.
    authed: bool = false,
    drop: bool = false,

    /// Empty when the realm could not name the client's engine, which reads as no constraint.
    pub fn clientVersion(c: *const DConn) []const u8 {
        return c.client_version[0..c.client_version_len];
    }

    fn setAccount(c: *DConn, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, state.max_name));
        @memcpy(c.account[0..n], name[0..n]);
        c.account_len = n;
    }
    fn accountName(c: *DConn) []const u8 {
        return c.account[0..c.account_len];
    }
    fn setChar(c: *DConn, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, state.max_name));
        @memcpy(c.char[0..n], name[0..n]);
        c.char_len = n;
    }
    fn charName(c: *DConn) []const u8 {
        return c.char[0..c.char_len];
    }
};

fn startPacket(buf: []u8, id: u8) proto.Writer {
    var w = proto.Writer.init(buf);
    w.putU16(0); // length placeholder ([0..2]), back-patched in finish()
    w.putU8(id);
    return w;
}
/// Push `bytes` into the connection's outbound buffer, flushing first if they will not fit.
/// A packet larger than the whole buffer goes straight out on its own.
fn queue(c: *DConn, bytes: []const u8) void {
    if (bytes.len > c.out.len) {
        flushOut(c);
        _ = net.writeAll(c.fd, bytes);
        return;
    }
    if (c.out_len + bytes.len > c.out.len) flushOut(c);
    @memcpy(c.out[c.out_len..][0..bytes.len], bytes);
    c.out_len += bytes.len;
}

/// Write everything queued. Cheap to call when nothing is pending.
fn flushOut(c: *DConn) void {
    if (c.out_len == 0) return;
    const n = c.out_len;
    c.out_len = 0; // cleared first: a failed write must not leave bytes to be re-sent
    _ = net.writeAll(c.fd, c.out[0..n]);
}

fn finish(c: *DConn, w: *proto.Writer) void {
    w.patchU16(0, @intCast(w.pos));
    queue(c, w.slice());
}

/// Standalone listener entry (the dedicated d2cs port): the leading 0x01 protocol
/// selector is still on the wire and is consumed here.
pub fn handle(fd: net.Socket, tag: []const u8) void {
    serve(fd, tag, &.{}, false);
}

/// Entry from the bnetd selector-mux (bncs.zig) when an MCP connection rides the
/// shared :6112 port: the 0x01 selector is already consumed and `initial` holds the
/// bytes read after it. Lets MCP share the BNCS/BNFTP port, like real Battle.net.
pub fn handleFrom(fd: net.Socket, tag: []const u8, initial: []const u8) void {
    serve(fd, tag, initial, true);
}

fn serve(fd: net.Socket, tag: []const u8, initial: []const u8, proto_consumed: bool) void {
    var c = DConn{ .fd = fd };
    defer flushOut(&c); // no exit path may strand queued packets
    log.line(tag, "client connected", .{});
    metrics.connectionOpened(.mcp);
    defer {
        metrics.sessionChanged(.mcp, c.authed, false);
        metrics.connectionClosed(.mcp);
    }

    var acc: [16384]u8 = undefined;
    var len: usize = @min(initial.len, acc.len);
    @memcpy(acc[0..len], initial[0..len]);
    var got_proto = proto_consumed;

    while (true) {
        // Process buffered bytes BEFORE blocking on another read — a seeded
        // MCP_STARTUP must be dispatched (and replied to) or the client hangs.
        var off: usize = 0;
        if (!got_proto and len >= 1) {
            if (acc[0] != 0x01) {
                log.line(tag, "unexpected protocol byte 0x{x:0>2}", .{acc[0]});
                return;
            }
            got_proto = true;
            off = 1;
        }
        if (got_proto) {
            while (len - off >= 3) {
                const plen = std.mem.readInt(u16, acc[off..][0..2], .little);
                if (plen < 3) {
                    log.line(tag, "bad packet length {d}", .{plen});
                    return;
                }
                if (len - off < plen) break; // wait for the rest
                dispatch(&c, tag, acc[off + 2], acc[off + 3 .. off + plen]);
                off += plen;
                if (c.drop) break;
            }
        }
        if (c.drop) break;
        if (off > 0) {
            std.mem.copyForwards(u8, acc[0 .. len - off], acc[off..len]);
            len -= off;
        }
        if (len == acc.len) {
            log.line(tag, "oversized packet, dropping connection", .{});
            return;
        }
        // Everything answered so far goes out before we wait for the next request.
        flushOut(&c);
        const n = net.readSome(fd, acc[len..]);
        if (n == 0) break;
        len += n;
    }
    log.line(tag, "client disconnected ({s})", .{c.accountName()});
}

// REALMD_TRACE=1 -> hexdump every inbound MCP packet (the full client MCP sequence)
// while still serving normally. Set from main alongside bncs.trace_packets.
pub var trace_packets: bool = false;

fn dispatch(c: *DConn, tag: []const u8, id: u8, body: []const u8) void {
    if (!c.authed and id != MCP_STARTUP) {
        log.line(tag, "MCP 0x{x:0>2} before a startup; dropping the connection", .{id});
        c.drop = true;
        return;
    }
    if (!hook.mcpPacket(c, id, body)) return; // an extension took it
    if (trace_packets) {
        log.line(tag, "rx MCP 0x{x:0>2} ({d} bytes)", .{ id, body.len });
        if (body.len > 0) log.hexdump(tag, body);
    }
    switch (id) {
        MCP_STARTUP => onStartup(c, tag, body),
        MCP_CHARLIST2 => onCharList(c, tag, body),
        MCP_CHARLOGON => onCharLogon(c, tag, body),
        MCP_CHARCREATE => onCharCreate(c, tag, body),
        MCP_CREATEGAME => onCreateGame(c, tag, body),
        MCP_JOINGAME => onJoinGame(c, tag, body),
        MCP_GAMELIST => onGameList(c, tag, body),
        MCP_GAMEINFO => onGameInfo(c, tag, body),
        MCP_CHARDELETE => onCharDelete(c, tag, body),
        MCP_CHARUPGRADE => onCharUpgrade(c, tag, body),
        MCP_MOTD => onMotd(c, tag, body),
        MCP_LADDERDATA => onLadderData(c, tag, body),
        MCP_CANCELCREATE => onCancelCreate(c, tag, body),
        MCP_CHARRANK => onCharRank(c, tag, body),
        // The dispatch above is the COMPLETE 1.14d client surface: senders 0x01-0x07, 0x0a,
        // 0x11-0x13, 0x16, 0x18, 0x19, all handled. The build also has senders for 0x08, 0x09,
        // 0x0b, 0x0c, 0x0d, 0x0f, 0x10 — DEAD, zero xrefs in Game.exe, so deliberately not
        // implemented. One showing up here means the assumption changed; look at the hexdump.
        else => {
            log.line(tag, "unhandled MCP 0x{x:0>2} ({d} bytes)", .{ id, body.len });
            if (body.len > 0) log.hexdump(tag, body);
        },
    }
}

fn onStartup(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU32(); // cookie
    _ = r.getU32(); // status
    const lo = r.getU32(); // chunk1[0] = session id low
    const hi = r.getU32(); // chunk1[1] = session id high
    const sid = @as(u64, lo) | (@as(u64, hi) << 32);

    var namebuf: [state.max_name + 1]u8 = undefined;
    var result: u32 = 0x0a; // "unable to identify" until proven
    if (state.global.accountForSession(sid, &namebuf)) |acct| {
        c.session = sid;
        c.setAccount(acct);
        var vb: [state.max_version]u8 = undefined;
        const v = state.global.versionForSession(sid, &vb);
        c.client_version_len = @intCast(v.len);
        @memcpy(c.client_version[0..v.len], v);
        result = 0x00;
        metrics.logon(.mcp_session_ok);
        log.line(tag, "startup session={d} -> account={s} engine={s}", .{ sid, acct, v });
    } else {
        metrics.logon(.mcp_session_unknown_session);
        log.line(tag, "startup session={d} -> UNKNOWN (rejected)", .{sid});
    }

    const was = c.authed;
    c.authed = result == 0x00;
    metrics.sessionChanged(.mcp, was, c.authed);
    if (!c.authed) c.drop = true;
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, MCP_STARTUP);
    w.putU32(result);
    finish(c, &w);
}

fn onCharList(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const requested: u16 = @truncate(r.getU32());

    var names: [store.max_chars]store.Name = @splat(.{});
    const total = store.listChars(c.accountName(), &names);
    const ret: u16 = @intCast(@min(total, requested));
    log.line(tag, "charlist requested={d} (account={s}) -> total={d} returned={d}", .{ requested, c.accountName(), total, ret });

    var buf: [4096]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARLIST2);
    w.putU16(requested); // number requested
    w.putU32(@intCast(total)); // total characters on the account
    w.putU16(ret); // number returned in this packet
    var i: usize = 0;
    while (i < ret) : (i += 1) {
        w.putU32(0xFFFF_FFFF); // expiration — far future so it's NOT "expired"
        w.putStr(names[i].slice()); // character name
        writeCharStat(&w, c.accountName(), names[i].slice(), @intCast(total)); // CharSel.cpp layout
        w.putU8(0); // statstring C-string terminator
    }
    finish(c, &w);
}

/// A character's statstring, from the head of its .d2s: class@0x28, level@0x2b, status@0x24,
/// progression@0x25 (the title, difficulty completed), and the menu-composite appearance the game
/// wrote on save (pAppearance1@0x88 body-component graphic codes, pAppearance2@0x98 colour
/// transforms, 16 each; the statstring uses the first 11). No appearance is a naked preview.
fn writeCharStat(w: *proto.Writer, account: []const u8, charname: []const u8, realm_count: u32) void {
    var save: [1024]u8 = undefined;
    const n = store.getCharD2s(account, charname, &save);
    writeCharStatFrom(w, account, charname, realm_count, save[0..n]);
}

fn writeCharStatFrom(w: *proto.Writer, account: []const u8, charname: []const u8, realm_count: u32, save: []const u8) void {
    const n = save.len;
    const class: u8 = if (n > 0x2b) save[0x28] else 1;
    const level: u8 = if (n > 0x2b) save[0x2b] else 1;
    const status: u8 = if (n > 0x24) save[0x24] else 0x20; // default to expansion
    const progression: u8 = if (n > 0x25) save[0x25] else 0;
    const have_app = n > 0xA2;
    const app1: []const u8 = if (have_app) save[0x88..0x93] else &.{};
    const app2: []const u8 = if (have_app) save[0x98..0xA3] else &.{};
    const era = eraCode(store.charVersion(account, charname).slice());
    writeStatString(w, class, level, status, progression, realm_count, app1, app2, era);
}

/// The statstring the lobby's user list draws a character from, as Battle.net sent it for a
/// Diablo II user: the product tag, `realm,charname,` and then the same blob the character list
/// carries (class, level, gear, flags). The client takes the portrait, class, level and realm out of
/// it and draws an "unknown" user when the tag is missing. Null when the account has no such
/// character.
pub fn chatStat(out: []u8, tag: []const u8, realm: []const u8, account: []const u8, charname: []const u8) ?[]const u8 {
    var save: [1024]u8 = undefined;
    const n = store.getCharD2s(account, charname, &save);
    if (n == 0) return null;
    var w = proto.Writer.init(out);
    w.putBytes(tag);
    w.putBytes(realm);
    w.putU8(',');
    w.putBytes(charname);
    w.putU8(',');
    writeCharStatFrom(&w, account, charname, 1, save[0..n]);
    return w.slice();
}

/// The two characters that stand for an engine in a character's guild tag.
///
/// The tag is the only field of the statstring the game hands straight back to the player, so it
/// is where a realm serving several engines can say which one a character is — and every client
/// shows it, not only one that was built knowing about it. It renders as " {14}" after the name.
///
/// TWO characters and never three. `D2CharSelStrc.szGuildTag` is `char[3]` filled by a strncpy of
/// three, so a three-character tag arrives with no terminator and the client's `" {%s}"` runs on
/// into the difficulty byte at 0x32D. Two leaves the statstring's own terminator to land in the
/// third.
///
/// Two is enough because that is exactly where the tags differ: "1.06b", "1.09d", "1.14d" all
/// carry their era in the two characters after the dot. Anything shaped differently gets no tag
/// rather than a wrong one.
fn eraCode(tag: []const u8) []const u8 {
    if (tag.len < 4) return "";
    if (tag[0] != '1' or tag[1] != '.') return "";
    const code = tag[2..4];
    for (code) |ch| {
        if (ch < '0' or ch > '9') return "";
    }
    return code;
}

// 14-bit-encoded int: 7 bits/byte, high bit always set so the value never
// produces a 0x00 byte (the statstring is sent as a C-string).
fn enc14(w: *proto.Writer, v: u32) void {
    w.putU8(@intCast((v & 0x7F) | 0x80));
    w.putU8(@intCast(((v >> 7) & 0x7F) | 0x80));
}

// Character statstring — per-char blob in the MCP_CHARLIST2 (0x19) reply char-select renders
// from. RE'd from CHARSEL_ParseRealmCharList @0x43aab0 -> SAVEFILE_ParseSaveData @0x438ad0.
// Offsets: [0..2] realm char count (14-bit), [2..13] equip slot1 (11, GRAPHIC codes),
// [13] class+1 (parser subtracts CLASS_SORCERESS=1), [14..25] equip slot2 (11, color TRANSFORMS),
// [25] level, [26..28] flags (14-bit; bit2=0x04 expansion, bit3=0x08 ladder/hardcore mix),
// [28..30] field9 (14-bit), [30] ladder season (0xFF->0, non-zero = ladder), [31..33] two fields (0xFF->0), [33..36] guild tag.
// Every byte must stay non-zero (C-string); 14-bit ints set the high bit, "none" is 0xFF not 0x00.
// Rendering: AllocCharSelectComponent @0x5066c0. Weapons are slot1[5]/[6]; unarmed (both 0xFF)
// renders a valid naked character — real gear needs parsing .d2s items, not done yet.
// putEquipSlot: 11-byte equip slot from .d2s appearance block; map 0x00/missing to 0xFF.
fn putEquipSlot(w: *proto.Writer, app: []const u8) void {
    var k: usize = 0;
    while (k < 11) : (k += 1) {
        const b: u8 = if (k < app.len and app[k] != 0) app[k] else 0xFF;
        w.putU8(b);
    }
}

fn writeStatString(w: *proto.Writer, class: u8, level: u8, status: u8, progression: u8, realm_count: u32, app1: []const u8, app2: []const u8, era: []const u8) void {
    enc14(w, realm_count); // realm char count (CharSel: nRealmCharCount)
    putEquipSlot(w, app1); // equip slot 1: body-component graphic codes (.d2s pAppearance1)
    w.putU8(class + 1); // class (CharSel subtracts CLASS_SORCERESS=1)
    putEquipSlot(w, app2); // equip slot 2: component color transforms (.d2s pAppearance2)
    w.putU8(if (level == 0) 1 else level); // level (avoid 0)
    // The char-select reads nCharacterFlags here: the LOW byte mirrors the .d2s status
    // byte (CharSel tests hardcore & 4, died & 8, expansion & 0x20, ladder & 0x40), and
    // the HIGH byte (>> 8 & 0x1f) is the title progression (difficulty completed) that
    // picks the char's title — without it every char shows the "EXPANSION CHARACTER"
    // no-title fallback. Both come straight from the .d2s (status@0x24, progression@0x25).
    const flags: u32 = (@as(u32, progression & 0x1f) << 8) | (status & 0x6C);
    enc14(w, flags);
    enc14(w, 0); // field9
    // The byte some references call bAct is the ladder season: CHARSEL_ParseRealmCharList reads
    // it with 0xFF -> 0, and char select draws "Ladder" (str 0x2aaf) and sets the launcher's
    // isLadder from it being non-zero; the 0x40 status bit is not looked at for either. The chat
    // user list reads the same byte the same way and compares it with isLadder. 1 for a ladder
    // character (the realm has one season), 0xFF (none) otherwise.
    w.putU8(if (status & 0x40 != 0) 1 else 0xFF);
    w.putU8(0xFF); // field_0x32f
    w.putU8(0xFF); // field_0x330
    // The guild tag, which on this realm is the character's engine. Two characters, so the
    // caller's trailing NUL lands in the third and terminates it; a realm with nothing to say
    // writes none and the NUL lands on the first, which is the empty tag the game expects.
    // Emitting 0xFF bytes here instead made it append " {ÿÿÿ}" to the character's name.
    for (era) |ch| w.putU8(ch);
}

// MCP_CHARLOGON (0x07) replies. The client stores the result dword as the D2GS join result and
// SelectedCharBnetSingleTcpIp @0x434a00 reads it back: 0x46 puts up string 0x140d and returns to
// character select, 0x7b puts up 0x2b89 (formatted with the character name) and tears the MCP
// connection down with FreeMCP, and anything else proceeds into the game. So there are exactly two
// ways to refuse, and 0x46 is the one that does not cost the player their MCP connection.
const CHARLOGON_OK: u32 = 0;
const CHARLOGON_REFUSED: u32 = 0x46;

fn onCharLogon(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const name = r.getStr();
    const acct = c.accountName();

    // A character belongs to the engine it was made on, and handing it to a client of another one
    // does not fail cleanly: the save format and the wire framing both moved between eras, so the
    // client either refuses the load or takes a character it will write back wrong. Refusing here
    // costs a popup; not refusing costs the character.
    //
    // Both sides being known and different is the only refusal. Everything created before the
    // realm recorded versions has none, and a client the realm could not name has none either —
    // neither is a disagreement, and treating it as one would lock players out of their own
    // characters the day this shipped.
    const char_version = store.charVersion(acct, name);
    const client_version = c.clientVersion();
    const compatible = hook.charCompatible(acct, name, char_version.slice(), client_version) orelse
        char_version.compatible(client_version);
    if (!compatible) {
        log.line(tag, "char logon '{s}' (account={s}) -> REFUSED: character is {s}, client is {s}", .{
            name, acct, char_version.slice(), client_version,
        });
        metrics.charLogon(.incompatible);
        var rbuf: [12]u8 = undefined;
        var rw = startPacket(&rbuf, MCP_CHARLOGON);
        rw.putU32(CHARLOGON_REFUSED);
        return finish(c, &rw);
    }

    c.setChar(name); // remember the active char so a later join can name it to the GS
    hook.charLogon(c.accountName(), name);
    log.line(tag, "char logon '{s}' (account={s}) -> ok", .{ name, c.accountName() });
    metrics.charLogon(.ok);
    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARLOGON);
    w.putU32(CHARLOGON_OK);
    finish(c, &w);
}

// MCP_CHARCREATE (0x02) body: u32 class + cstr name (NET_MCP_CLIENT_Send_0x02_CharCreate
// writes only the class dword; status isn't on the wire). We generate a fresh level-1 .d2s
// (the engine fills starting stats/items on first play) and persist it via the store, so the
// new char shows in CHARLIST2 and is playable. Result: 0 ok, 0x14 name taken, 0x15 invalid.
fn onCharCreate(c: *DConn, tag: []const u8, body: []const u8) void {
    // MCP_CHARCREATE (0x02) body = [u32 class][u16 status][cstr name] (verified from a live
    // capture: 01000000 6000 "DiagSorc\0"). status low byte carries the .d2s flags the client's
    // checkboxes set: expansion 0x20, hardcore 0x04, ladder 0x40.
    var r = proto.Reader.init(body);
    const class: u8 = @intCast(r.getU32() & 0xff);
    const status_word = r.getU16();
    const status_flags: u8 = @intCast(status_word & 0x6C); // hardcore|died|expansion|ladder
    // The HIGH byte is not the game's. A stock client sends zero and the character takes the
    // engine of the client that made it; a launcher that lets the player pick one sends its two
    // digits, because that choice is made on the creation screen and not at logon.
    const asked_era: u8 = @intCast(status_word >> 8);
    const name = r.getStr();
    const acct = c.accountName();

    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARCREATE);

    const expansion = (status_flags & 0x20) != 0;
    // Druid (5) and Assassin (6) only exist in the expansion — they cannot be classic chars.
    const expansion_only_class = (class == 5 or class == 6);
    if (name.len == 0 or name.len > d2s.name_max or class > 6 or (expansion_only_class and !expansion)) {
        log.line(tag, "char create '{s}' class={d} exp={} -> invalid", .{ name, class, expansion });
        w.putU32(0x15);
        return finish(c, &w);
    }
    if (hook.charCreate(acct, name, class)) |result| {
        log.line(tag, "char create '{s}' (account={s}) -> refused by extension ({d})", .{ name, acct, result });
        w.putU32(result);
        return finish(c, &w);
    }
    // The character list answers with at most max_chars, so a character past that would exist and never
    // show; the client stops offering Create New Character at the same count.
    var held: [store.max_chars]store.Name = undefined;
    if (store.listChars(acct, &held) >= store.max_chars) {
        log.line(tag, "char create '{s}' (account={s}) -> account is full ({d} characters)", .{ name, acct, store.max_chars });
        w.putU32(0x15);
        return finish(c, &w);
    }
    var probe: [d2s.new_save_size]u8 = undefined;
    if (store.getCharD2s(acct, name, &probe) > 0) {
        log.line(tag, "char create '{s}' (account={s}) -> name taken", .{ name, acct });
        w.putU32(0x14);
        return finish(c, &w);
    }
    // Claimed across the whole realm, not just this account, and claimed ATOMICALLY — which also
    // settles the race the probe above cannot: two creates of the same name, on two instances, can
    // both pass a check-then-act and the second silently replaces the first.
    //
    // Realm-wide because a character name is an identity everywhere downstream of here: the game
    // servers' seat tables, the save-retry queue, a departing player's seat release, and the Mac
    // engine's own `<charname>.d2s` all key on it. Two characters sharing a name is one player's
    // save landing under the other's account.
    if (!store.claimCharName(acct, name)) {
        log.line(tag, "char create '{s}' (account={s}) -> name taken realm-wide", .{ name, acct });
        w.putU32(0x14);
        return finish(c, &w);
    }
    var save: [d2s.new_save_size]u8 = undefined;
    const now: u32 = @truncate(@as(u64, @bitCast(@as(i64, time(null)))));
    // Honor the client's flags as-is (classic = no 0x20, expansion = 0x20, +hardcore/ladder).
    if (!d2s.newSave(&save, name, class, status_flags, now) or !store.saveCharD2s(acct, name, &save)) {
        // The claim outlives the failure otherwise, and the name is then held by a character that
        // does not exist — unusable by anyone, including the player who just tried.
        store.releaseCharName(acct, name);
        log.line(tag, "char create '{s}' (account={s}) -> store FAILED", .{ name, acct });
        w.putU32(0x06);
        return finish(c, &w);
    }
    // Which engine this character belongs to, decided once and never again. An extension may say
    // otherwise; the realm's own answer is the engine of the client that made it, which is empty
    // on a realm that has not mapped its clients and means the character is unconstrained.
    // Order: what the request asked for, then what an extension says, then what the client is.
    // The request wins because it is the only one of the three that knows what the player picked.
    const asked = version.byEraCode(asked_era);
    const char_version = asked orelse hook.charVersion(acct, name, c.clientVersion()) orelse c.clientVersion();
    store.markCreated(acct, name);
    if (char_version.len != 0) _ = store.setCharVersion(acct, name, char_version);
    log.line(tag, "char create '{s}' class={d} engine={s} (account={s}) -> created", .{ name, class, char_version, acct });
    // A successful create IS the character select: the client goes from the creation screen
    // straight to the lobby and never sends MCP_CHARLOGON for the new character. Without this the
    // connection has no active character, so the first game it creates or joins names an empty
    // one to the game server; only a reconnect, which does select it, got it right.
    c.setChar(name);
    hook.charCreated(acct, name, class, status_flags);
    hook.charLogon(acct, name);
    w.putU32(0); // success
    finish(c, &w);
}

/// The logged-on character's status bits, read from its .d2s header at 0x24. This is what
/// decides which KIND of game the account may create or join. Defaults to expansion when
/// the save can't be read, matching the rest of the closed-realm assumptions here.
fn charStatus(c: *DConn) u8 {
    var save: [64]u8 = undefined;
    const n = store.getCharD2s(c.accountName(), c.charName(), &save);
    if (n <= 0x24) {
        // Say so. This decides whether the game is classic/hardcore/ladder, and guessing wrong
        // makes the engine refuse the creator's own join for a reason the player never sees.
        log.line("d2cs", "char status unreadable for '{s}' ({d} bytes) -> assuming expansion softcore non-ladder", .{ c.charName(), n });
        return STATUS_EXPANSION;
    }
    return save[0x24] & STATUS_JOIN_MASK;
}

/// The logged-on character's progression (.d2s 0x25) — how far through the game it has got.
/// Zero when the save can't be read, which gates it to Normal; that is the safe direction.
fn charProgression(c: *DConn) u8 {
    var save: [64]u8 = undefined;
    const n = store.getCharD2s(c.accountName(), c.charName(), &save);
    if (n <= 0x25) return 0;
    return save[0x25] & 0x1f;
}

/// Reply to a failed JOINGAME. All five fields still have to be on the wire: the client's
/// Incoming0x04 @0x44ac20 reads them unconditionally, and only consults `result` once it
/// has seen the IP is zero — a short packet is not a rejection, it's a desync.
fn rejectJoin(c: *DConn, w: *proto.Writer, result: u32) void {
    w.putU16(0); // token
    w.putU16(0); // unknown
    w.putU32(0); // d2gs IP — zero is what sends the client down the error branch
    w.putU32(0); // game hash
    w.putU32(result);
    finish(c, w);
}

/// Whether `joiner` may enter a game created by a character with `game` status, and which
/// of the client's messages says why not. Each mismatch has its own string, so answering
/// with a generic failure would be throwing away an explanation the client already has.
fn joinStatusError(game: u8, joiner: u8) ?u32 {
    if ((game & STATUS_EXPANSION) != (joiner & STATUS_EXPANSION)) {
        return if ((joiner & STATUS_EXPANSION) == 0) JOIN_CLASSIC_INTO_EXPANSION else JOIN_EXPANSION_INTO_CLASSIC;
    }
    if ((game & STATUS_HARDCORE) != (joiner & STATUS_HARDCORE)) return JOIN_HARDCORE_MIX;
    if ((game & STATUS_LADDER) != (joiner & STATUS_LADDER)) return JOIN_LADDER_MISMATCH;
    return null;
}

/// Whether the logged-on character could join `g` — the join's own status and difficulty checks, so
/// the list shows exactly the games a join would not turn away for being the wrong kind. Battle.net
/// listed only those: a classic character never saw expansion games, nor a softcore one hardcore.
fn gameOpenTo(status: u8, difficulty: u8, joiner: u8, progression: u8) bool {
    if (joinStatusError(status, joiner) != null) return false;
    return difficultyError(difficulty, progression, (joiner & STATUS_EXPANSION) != 0) == null;
}

/// A game name the realm will accept. The client offers "Invalid Game Name" as a distinct
/// error, so an empty or oversized name should get it rather than being pushed to a GS
/// that will refuse it for reasons we'd then have to describe as "Server Down".
fn validGameName(name: []const u8) bool {
    return name.len > 0 and name.len <= 15;
}

fn onCreateGame(c: *DConn, tag: []const u8, body: []const u8) void {
    // Every return below names its outcome; the time is what the player waited for the answer.
    const t0 = metrics.nowUs();
    var outcome: metrics.Create = .gs_refused;
    defer metrics.gameCreate(outcome, t0);
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    // MCP create-game flags DWORD: difficulty lives in bits 12-14 (Normal=0x0000,
    // Nightmare=0x1000, Hell=0x2000), the same GAMEFLAG_DIFFICULTY_BIT=12 the GS uses.
    const create_flags = r.getU32();
    const difficulty: u8 = @intCast(@min(@as(u32, 2), (create_flags >> 12) & 0x7));
    _ = r.getU8(); // unknown (1)
    _ = r.getU8(); // player difference
    const max_players = realm_proto.gameMaxPlayers(r.getU8()); // max players
    const name = r.getStr();
    const pass = r.getStr();
    const desc = r.getStr();

    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, MCP_CREATEGAME);
    w.putU16(reqid);

    const fail = struct {
        fn f(cc: *DConn, ww: *proto.Writer, result: u32) void {
            ww.putU16(0); // token
            ww.putU16(0); // unknown
            ww.putU32(result);
            finish(cc, ww);
        }
    }.f;

    if (!validGameName(name)) {
        log.line(tag, "create game '{s}' -> invalid name", .{name});
        outcome = .invalid_name;
        return fail(c, &w, CREATE_INVALID_NAME);
    }
    if (hook.gameCreate(c.accountName(), c.charName(), name, difficulty)) |result| {
        log.line(tag, "create game '{s}' -> refused by extension ({d})", .{ name, result });
        outcome = .refused;
        return fail(c, &w, result);
    }
    if (!fleet.ready()) {
        // "Server Down" is the honest one and, more to the point, the only one in the
        // client's switch that fits. The 0x06 that used to go out here isn't a case at
        // all, so the client fell to `default:` and left the player on a dead screen.
        log.line(tag, "create game '{s}' -> NO GS available", .{name});
        outcome = .no_gs;
        return fail(c, &w, CREATE_SERVER_DOWN);
    }
    // A name already in the realm registry is a DIFFERENT failure than "no GS took it":
    // the client shows "a game with that name already exists" and offers to join instead.
    // Asking the GS first would just get a refusal we'd report as the generic 0x1e.
    if (state.global.findGame(name) != null) {
        log.line(tag, "create game '{s}' -> name already exists", .{name});
        outcome = .name_taken;
        return fail(c, &w, CREATE_NAME_TAKEN);
    }
    // The game inherits the CREATOR's character flags — a hardcore ladder character makes
    // a hardcore ladder game. They used to be hardcoded to expansion/softcore/non-ladder,
    // which made every game look joinable to everyone and pushed the mismatch down to the
    // GS, where it surfaces as a disconnect rather than a sentence.
    const status = charStatus(c);
    const expansion = (status & STATUS_EXPANSION) != 0;
    const hardcore = (status & STATUS_HARDCORE) != 0;
    const ladder: u8 = if ((status & STATUS_LADDER) != 0) 1 else 0;
    // NOT gated here, deliberately. CREATEGAME's three codes (invalid name, name taken, server
    // down) cannot say "you have not unlocked that difficulty". The client sends JOINGAME right
    // after a successful create, and that path has the same check plus a code that says the true
    // thing (0x73 / 0x74) — so an ineligible character is still turned away, one packet later.
    log.line(tag, "create game '{s}' desc='{s}' diff={d} status=0x{x:0>2} (flags=0x{x})", .{ name, desc, difficulty, status, create_flags });
    // The creator is about to be sent straight into this game, and a character is in one game at a
    // time: if another still holds it (after the moment the engine needs to free a seat the player
    // just left), refuse here rather than leave an empty game behind a join that will be turned away.
    {
        var hb: [64]u8 = undefined;
        var waited: u32 = 0;
        while (store.charLockOwner(c.accountName(), c.charName(), &hb) != null and waited < seat_release_ms) : (waited += create_poll_ms) sleepMs(create_poll_ms);
        if (store.charLockOwner(c.accountName(), c.charName(), &hb)) |holder| {
            log.line(tag, "create game '{s}' (account={s}) -> character '{s}' is held by {s}", .{ name, c.accountName(), c.charName(), holder });
            return fail(c, &w, CREATE_ERROR_GENERIC);
        }
    }
    // Claim the name BEFORE dispatching. A game is only recorded once the server accepts the
    // create, and in that gap a second client asking for the same name is told it is free, loses
    // the race at the server, and is then left with nothing to join — the failure that fails
    // stress rounds. Claiming first moves the refusal to where the loser can still be told.
    if (!store.reserveGameName(name)) {
        log.line(tag, "create game '{s}' (account={s}) -> name already claimed", .{ name, c.accountName() });
        outcome = .name_taken;
        return fail(c, &w, CREATE_NAME_TAKEN);
    }
    const char_version = store.charVersion(c.accountName(), c.charName());
    const routed = fleet.createGameRouted(.{
        .name = name,
        .pass = pass,
        .desc = desc,
        .ladder = ladder,
        .expansion = expansion,
        .difficulty = difficulty,
        .hardcore = hardcore,
        .account = c.accountName(),
        .charname = c.charName(),
        // Where this game has to be hosted. Taken from the CHARACTER, not from the connection: the
        // two agree by the time a game is being created (charLogon refuses a pairing that does
        // not), and the character is the one that outlives the session.
        .version = char_version.slice(),
    });
    // A create that did not produce a game must not keep the name.
    if (routed == null) store.releaseGameName(name);
    if (routed == null) {
        // The findGame() check above is not a guarantee: two clients can both pass it
        // before either has registered anything, and only the GS that would host the
        // game knows the name is spoken for. When it says so, say so — the player gets
        // "that name already exists" and the offer to join, instead of being told the
        // realm is down while it plainly is not.
        if (fleet.last_create_failure == .name_taken) {
            log.line(tag, "create game '{s}' -> name already exists (GS refused; lost the race)", .{name});
            outcome = .name_taken;
            return fail(c, &w, CREATE_NAME_TAKEN);
        }
        // Nothing to do with the name. Say WHICH of the two it was in the LOG: a fleet with no
        // room left is an operational signal (add GS capacity), a refusal is a fault. The client
        // gets the same code either way — "server down" is the only one of its three that fits
        // "no server took your game", and a fleet that is merely busy is not an error to report
        // as one. The distinction that matters to a player is none; the one that matters to
        // whoever runs the realm is in the line above.
        if (fleet.last_create_failure == .all_full) {
            log.line(tag, "create game '{s}' -> every GS is at its game limit (fleet is full)", .{name});
            outcome = .fleet_full;
            return fail(c, &w, CREATE_SERVER_DOWN);
        }
        // No server at all is a different operational signal from one that said no.
        outcome = if (fleet.last_create_failure == .no_gs) .no_gs else .gs_refused;
        log.line(tag, "create game '{s}' -> GS refused", .{name});
        return fail(c, &w, CREATE_SERVER_DOWN);
    }
    const rr = routed.?;
    // 1 player: the creator. That seed and the join-time bump keep the list responsive until the
    // GS's own UPDATEGAMEINFO overwrites them. Without the record the game exists on the GS but
    // nowhere the realm can find it, and the client's very next packet is a JOINGAME for this name
    // — "game does not exist" right after reporting success. Fail the create instead; the GS reaps
    // the orphaned empty game on its own idle timer.
    if (!state.global.registerGame(name, rr.gameid, rr.ip, rr.port, rr.gsid, 1, status, difficulty, pass, desc, max_players)) {
        store.releaseGameName(name);
        log.line(tag, "create game '{s}' -> GS made gameid={d} but the store would not record it: {s}", .{ name, rr.gameid, store.registerGameError() });
        outcome = .store_error;
        return fail(c, &w, CREATE_ERROR_GENERIC);
    }
    // The game record now owns the name and is what a duplicate create is refused against, so the
    // reservation has done its job. Holding it any longer would refuse a name for the rest of its
    // TTL after the game it guarded had already ended.
    store.releaseGameName(name);
    state.global.noteGameCreated(rr.gameid); // starts the clock the detail panel counts from
    hook.gameStarted(.{
        .account = c.accountName(),
        .charname = c.charName(),
        .gamename = name,
        .gameid = rr.gameid,
        .gsid = rr.gsid,
        .difficulty = difficulty,
        .hardcore = hardcore,
        .expansion = expansion,
        .ladder = ladder != 0,
    });
    // The creator immediately joins the game they just made, but the GAMELOGON only
    // carries the char name — the account reaches the GS solely via the join-context
    // notify. JOIN seeds it; CREATE must too, or the GS resolves an empty account and
    // the character fetch (fpGetDatabaseCharacter) fails for the game's own creator.
    var gtagbuf1: [8]u8 = undefined;
    const gtag1 = guilds.tagOf(c.accountName(), &gtagbuf1); // cut Guild Halls: tell the GS the creator's guild
    if (rr.gsid != 0) _ = fleet.notifyJoin(rr.gsid, rr.gameid, rr.gameid, c.charName(), c.accountName(), gtag1);
    // Mint a realm-global token and record {token -> GS addr + real gameid} so the
    // d2ingress can translate the client's token to the engine's gameid and splice.
    // The character is NOT claimed here. The client sends JOINGAME for the game it just made, and
    // that is where the seat is actually taken — claiming it twice for one seat is what forced the
    // claim to be re-takeable, and a re-takeable claim cannot tell a second client apart from the
    // first one arriving again.
    const token = mintToken();
    _ = store.recordTokenRoute(token, rr.ip, rr.port, rr.gameid, route_ttl_s);
    log.line(tag, "create game '{s}' (account={s}) -> gameid={d} token=0x{x} gs=0x{x}@{d}.{d}.{d}.{d}:{d}", .{ name, c.accountName(), rr.gameid, token, rr.gsid, rr.ip[0], rr.ip[1], rr.ip[2], rr.ip[3], rr.port });
    w.putU16(token); // game token (client presents this to the d2ingress)
    w.putU16(0); // unknown
    w.putU32(0); // result: success
    outcome = .ok;
    finish(c, &w);
}

/// The client sends `-1` for a game created with the password field left empty, and the realm keeps
/// that as it came; a join arriving by a link or the launcher carries an empty password instead. Both
/// spellings mean an open game, and an open game lets anyone in whatever the joiner typed.
fn joinPasswordOk(stored: []const u8, supplied: []const u8) bool {
    if (stored.len == 0 or std.mem.eql(u8, stored, "-1")) return true;
    return std.mem.eql(u8, stored, supplied);
}

/// A game with a password is private: the list leaves it out, as Battle.net does, and only a join
/// that names it and gives the password gets in.
fn isPrivate(password: []const u8) bool {
    return !joinPasswordOk(password, "\x00");
}

test "only a game with a real password is private" {
    try std.testing.expect(!isPrivate(""));
    try std.testing.expect(!isPrivate("-1"));
    try std.testing.expect(isPrivate("Pw1"));
}

test "a game created with an empty password is open to a join with an empty or any password" {
    try std.testing.expect(joinPasswordOk("-1", ""));
    try std.testing.expect(joinPasswordOk("-1", "-1"));
    try std.testing.expect(joinPasswordOk("", "-1"));
    try std.testing.expect(joinPasswordOk("", ""));
    try std.testing.expect(joinPasswordOk("-1", "stale"));
}

test "a passworded game needs exactly its password" {
    try std.testing.expect(joinPasswordOk("Pw1", "Pw1"));
    try std.testing.expect(!joinPasswordOk("Pw1", ""));
    try std.testing.expect(!joinPasswordOk("Pw1", "-1"));
    try std.testing.expect(!joinPasswordOk("Pw1", "pw1"));
}

fn onJoinGame(c: *DConn, tag: []const u8, body: []const u8) void {
    const t0 = metrics.nowUs();
    var outcome: metrics.Join = .not_found;
    defer metrics.gameJoin(outcome, t0);
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    const name = r.getStr();
    const join_pass = r.getStr();

    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, MCP_JOINGAME);
    w.putU16(reqid);

    // A create for this name may still be in flight — the client that lost the name race asks to
    // join a moment later, and the game is not recorded until its server has accepted it. Saying
    // "does not exist" there is a lie the client acts on. Wait briefly for the name's owner to
    // finish, but only while a reservation says somebody is actually making it.
    var game = state.global.findGame(name);
    if (game == null and store.gameNameReserved(name)) {
        var waited: u32 = 0;
        while (waited < create_settle_ms) : (waited += create_poll_ms) {
            sleepMs(create_poll_ms);
            game = state.global.findGame(name);
            if (game != null) break;
            if (!store.gameNameReserved(name)) break; // the create finished or gave up
        }
        if (game != null) log.line(tag, "join game '{s}' -> waited {d}ms for its create", .{ name, waited });
    }
    if (game == null) {
        log.line(tag, "join game '{s}' -> not found", .{name});
        outcome = .not_found;
        return rejectJoin(c, &w, JOIN_NO_SUCH_GAME);
    }
    const g = game.?;
    // Reject a wrong password for a passworded game (open games have pw_len == 0).
    if (!joinPasswordOk(g.pw(), join_pass)) {
        log.line(tag, "join game '{s}' (account={s}) -> WRONG PASSWORD (game has {d} chars, join sent {d})", .{ name, c.accountName(), g.pw_len, join_pass.len });
        outcome = .bad_password;
        return rejectJoin(c, &w, JOIN_BAD_PASSWORD);
    }
    if (hook.gameJoin(c.accountName(), c.charName(), name)) |result| {
        log.line(tag, "join game '{s}' (account={s}) -> refused by extension ({d})", .{ name, c.accountName(), result });
        outcome = .refused;
        return rejectJoin(c, &w, result);
    }
    // Guild Hall game type (cut feature): a game named exactly after a guild IS that
    // guild's private hall. Only members on the approved list may enter — the wiki's
    // "the Battle.net server will check if your character is on the approved list".
    // Non-members are told the game does not exist, so the hall stays hidden.
    if (guilds.load(name)) |gh| {
        var ghc = gh;
        if (ghc.findMember(c.accountName()) == null) {
            log.line(tag, "join guild hall '{s}' (account={s}) -> NOT A MEMBER, hidden", .{ name, c.accountName() });
            outcome = .not_member;
            return rejectJoin(c, &w, JOIN_NO_SUCH_GAME);
        }
        log.line(tag, "join guild hall '{s}' as member {s}", .{ name, c.accountName() });
    }
    // A character that doesn't belong in this game is turned away HERE, with the specific
    // reason, rather than at the GS — which has no way to say anything back to a client
    // still sitting on the join screen.
    const joiner = charStatus(c);
    if (joinStatusError(g.status, joiner)) |why| {
        log.line(tag, "join game '{s}' (account={s}) -> status mismatch game=0x{x:0>2} char=0x{x:0>2} -> 0x{x}", .{ name, c.accountName(), g.status, joiner, why });
        outcome = .status_mismatch;
        return rejectJoin(c, &w, why);
    }
    // Nightmare and Hell are earned. The client hides difficulties a character has not
    // unlocked, so anything asking for one here has either been modified or is stale —
    // either way it gets the specific message rather than a confusing generic failure.
    if (difficultyError(g.difficulty, charProgression(c), (joiner & STATUS_EXPANSION) != 0)) |why| {
        log.line(tag, "join game '{s}' (account={s}) -> difficulty {d} not unlocked (progression {d}) -> 0x{x}", .{ name, c.accountName(), g.difficulty, charProgression(c), why });
        outcome = .difficulty_locked;
        return rejectJoin(c, &w, why);
    }
    // A character is in one game at a time. Checked HERE, upfront, because the game server's own
    // refusal answers nothing: the realm issues the join, the engine declines it silently, and the
    // player sits at a loading screen until the client times out. Taking the lock IS the check —
    // SET NX cannot report free and then be taken by someone else. Re-taking a character this same
    // game already holds succeeds, so a client re-entering its own game is not shut out.
    var job: [32]u8 = undefined;
    const jowner = store.gameOwnerId(&job, g.gameid);
    // A seat is released when the player leaves, and the engine takes a moment to notice a socket
    // has gone — so the character a client is bringing to its NEXT game can still be held by the
    // one it just left. Wait for that to clear before refusing. A genuine second login waits the
    // same moment and is then turned away, which costs it nothing it can perceive.
    var claimed = store.lockChar(c.accountName(), c.charName(), jowner);
    // The same player asking again for this very game, whose earlier attempt never got in: that
    // attempt's seat is theirs to take back, and it is already in the count.
    const retaken = !claimed and store.retakePendingChar(g.gameid, c.accountName(), c.charName());
    if (retaken) {
        claimed = true;
        log.line(tag, "join game '{s}' (account={s}) -> took over the unconfirmed seat of '{s}'", .{ name, c.accountName(), c.charName() });
    }
    if (!claimed) {
        var waited: u32 = 0;
        while (waited < seat_release_ms) : (waited += create_poll_ms) {
            sleepMs(create_poll_ms);
            claimed = store.lockChar(c.accountName(), c.charName(), jowner);
            if (claimed) break;
        }
        if (claimed and waited > 0)
            log.line(tag, "join game '{s}' -> waited {d}ms for '{s}' to leave its last game", .{ name, waited, c.charName() });
    }
    if (!claimed) {
        var whob: [64]u8 = undefined;
        const holder = store.charLockOwner(c.accountName(), c.charName(), &whob) orelse "another game";
        // There is NO result code for "that character is already in a game" — the client's switch
        // (OOG_PollJoinCreatePump @0x441770) has none, and an unlisted code falls to `default:`:
        // no popup at all, the silent freeze this check exists to remove. "Game is Full." is the
        // least-bad listed code: untrue here, but it refuses visibly. Replace it if a truer one
        // is found.
        log.line(tag, "join game '{s}' (account={s}) -> character '{s}' is held by {s}", .{ name, c.accountName(), c.charName(), holder });
        outcome = .char_busy;
        return rejectJoin(c, &w, JOIN_FULL);
    }
    // The seat limit is enforced here, atomically, against every seat the game holds. The player
    // count on the game record is no use for this: it carries the creator twice until the game
    // server corrects it, and it is a snapshot two joins can both read before either takes the last
    // seat. The engine's CreateClient refuses a client past the cap outright, so a join that would
    // exceed it is turned away here, while the client can still be told why.
    if (store.addGameChar(g.gameid, c.accountName(), c.charName(), seatLimit(g.max_players)) == .full) {
        _ = store.unlockChar(c.accountName(), c.charName(), jowner);
        log.line(tag, "join game '{s}' (account={s}) -> FULL (every seat taken or pending)", .{ name, c.accountName() });
        outcome = .full;
        return rejectJoin(c, &w, JOIN_FULL);
    }
    // Stage the character into the shared store before the game server goes looking. The server
    // reads redis and nothing else, so a character that has only ever been in postgres would come
    // back missing — this read is what promotes it, and it is a no-op once it is there.
    warmChar(c.accountName(), c.charName());
    // Optimistic bump so the list reacts to this join right away; the GS corrects it (in
    // both directions) as soon as the player is actually in the game.
    if (!retaken) _ = state.global.registerGame(name, g.gameid, g.gs_ip, g.gs_port, g.gsid, g.players + 1, g.status, g.difficulty, g.pw(), g.desc(), g.max_players);
    // The client connects to the GS directly using the IP in the game record, so
    // any realmd instance can serve a join. Best-effort notify the GS that owns this
    // game (by its fleet id) so it can prefetch the joining account's character.
    var gtagbuf2: [8]u8 = undefined;
    const gtag2 = guilds.tagOf(c.accountName(), &gtagbuf2); // cut Guild Halls: tell the GS the joiner's guild
    if (g.gsid != 0) _ = fleet.notifyJoin(g.gsid, g.gameid, g.gameid, c.charName(), c.accountName(), gtag2);
    // Mint a realm-global token for this joining client and record {token -> the real
    // GS + engine gameid}. The d2ingress reads the token from the client's first packet
    // and translates it — NAT-proof, since the token is unique even when two clients
    // share one public IP. (Source-IP recordRoute is no longer used by the gateway.)
    const token = mintToken();
    _ = store.recordTokenRoute(token, g.gs_ip, g.gs_port, g.gameid, route_ttl_s);
    const advertised_ip = game_ip;
    log.line(tag, "join game '{s}' (account={s}) gameid={d} token=0x{x} gs={d}.{d}.{d}.{d} -> client dials {d}.{d}.{d}.{d}", .{ name, c.accountName(), g.gameid, token, g.gs_ip[0], g.gs_ip[1], g.gs_ip[2], g.gs_ip[3], advertised_ip[0], advertised_ip[1], advertised_ip[2], advertised_ip[3] });
    w.putU16(token); // game token
    w.putU16(0); // unknown
    w.putBytes(&advertised_ip); // d2gs / d2ingress IP (in_addr, network order)
    w.putU32(0); // game hash
    w.putU32(JOIN_OK); // result: success
    outcome = .ok;
    finish(c, &w);
}

// MCP_GAMELIST (0x05). Request: u16 reqid, u32 difficulty filter, cstr search
// (NET_MCP_CLIENT_Send_0x05_GameList @0x44a590). ONE GAME PER 0x05 PACKET, not concatenated:
// each packet -> NET_MCP_CLIENT_Incoming0x05 @0x44b2d0 -> g_CharSelectBuffer, polled by
// JoinOrCreateGame -> OOGMENU_AddGameToCache per game. Final packet token == -2 (0xFFFFFFFE)
// -> result 0x33 end-of-list -> OOGMENU_RefreshGameListDisplay().
// Per-game payload (offsets from pBytes[0]): +1 u16 reqid (must echo), +3 u32 gameid (low u16
// = dedup key), +7 u8 player count (PLAYERS column), +8 u32 token (not -1/-2), +0xc cstr name
// then cstr description.
fn onGameList(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    var games: [64]state.GameInfo = undefined;
    const n = state.snapshotGames(&games);

    const acct = c.accountName();
    // Nothing to compare against until a character is on: the list is then unfiltered.
    const have_char = c.charName().len > 0;
    const joiner: u8 = if (have_char) charStatus(c) else 0;
    const progression: u8 = if (have_char) charProgression(c) else 0;
    var shown: usize = 0;
    for (games[0..n]) |g| {
        if (have_char and !gameOpenTo(g.status, g.difficulty, joiner, progression)) continue;
        if (isPrivate(g.pw())) continue;
        // An extension decides what this player is shown — a private league's games, a staging
        // game, a lobby scoped to a channel. Hiding is cosmetic: a player who knows the name can
        // still attempt the join, and gameJoin is where that is actually refused.
        if (hook.gameVisible(acct, g.name_slice(), g.gameid)) |visible| {
            if (!visible) continue;
        }
        var buf: [128]u8 = undefined; // 12B header + name + description, both bounded
        var w = startPacket(&buf, MCP_GAMELIST);
        w.putU16(reqid); // +1 echo request id
        w.putU32(g.gameid); // +3 gameid (low u16 = dedup key)
        w.putU8(@intCast(@min(g.players, 255))); // +7 player count (PLAYERS column)
        w.putU32(g.gameid); // +8 token (non -1/-2 -> treated as a real game entry)
        w.putStr(g.name_slice()); // +0xc game name (shown in the list)
        w.putStr(g.desc()); // description the creator typed
        finish(c, &w);
        shown += 1;
    }
    log.line(tag, "game list (reqid={d}) char=0x{x:0>2} -> {d} of {d} game(s) open to it", .{ reqid, joiner, shown, n });
    // End-of-list marker: token == -2 -> SetD2GSJoinResult(0x33) -> RefreshGameListDisplay().
    var tbuf: [16]u8 = undefined;
    var tw = startPacket(&tbuf, MCP_GAMELIST);
    tw.putU16(reqid);
    tw.putU32(0); // +3 unused
    tw.putU8(0); // +7 unused
    tw.putU32(0xFFFF_FFFE); // +8 token = -2 (end of list)
    finish(c, &tw);
}

// Message-of-the-day shown in the chat window after entering the realm. Settable so
// a deployment can override it; defaults to a neutral welcome.
pub var motd: []const u8 = "Welcome to the realm.";

// MCP_CHARDELETE (0x0a). Request: u16 reqid, cstr charname. Removes the .d2s from the
// durable store (fs/redis/pg — works in shared/multi-instance mode). Reply: u16 reqid
// echo + u32 result (0 = deleted). Client: NET_MCP_CLIENT_Incoming0x0A checks the reqid
// then SetD2GSJoinResult(result) + marks the delete handled, refreshing CharSel.
fn onCharDelete(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    const name = r.getStr();
    // Refused while the character is in a game. The game server holds it in memory and saves it
    // back on its own timer, so deleting it here does not end the session — it just loses the
    // race: the next save recreates the character, and if the player has meanwhile made a NEW one
    // with the same name, that stale save lands on top of it. A delete that cannot be made to
    // stick is better refused than half-done.
    if (store.charInUse(c.accountName(), name)) {
        log.line(tag, "char delete '{s}' (account={s}) -> REFUSED, still in a game", .{ name, c.accountName() });
        var busy: [16]u8 = undefined;
        var bw = startPacket(&busy, MCP_CHARDELETE);
        bw.putU16(reqid);
        bw.putU32(1);
        return finish(c, &bw);
    }
    const ok = store.deleteCharD2s(c.accountName(), name);
    // The name goes back to the realm with the character.
    if (ok) store.releaseCharName(c.accountName(), name);
    if (ok) hook.charDeleted(c.accountName(), name);
    log.line(tag, "char delete '{s}' (account={s}) -> {s}", .{ name, c.accountName(), if (ok) "deleted" else "FAILED" });
    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARDELETE);
    w.putU16(reqid);
    w.putU32(if (ok) 0 else 1); // 0 = success
    finish(c, &w);
}

// MCP_GAMEINFO (0x06). Request: u16 reqid, cstr gamename. Fills the join screen's detail panel.
// RE'd from NET_MCP_CLIENT_Incoming0x06 @0x44aca0 + OOGMENU_DisplayGameDetails @0x443ba0.
// Offsets from id byte: +0x00 u8 id(0x06), +0x01 u16 reqid (must echo), +0x03 i32 token
// (-1=no info, -2=end-of-list), +0x07 u32 uptime secs, +0x0b u8 ref char level, +0x0c u8 level
// diff (0=no restriction), +0x0d u8 max players (shown 1..7), +0x0e u8 player count (bounds
// both loops below), +0x0f u8[16] per-player class, +0x1f u8[16] per-player level, +0x2f cstr
// description then `player count` cstrs of player names. Count at +0x0e is load-bearing: 0 stops
// after description, else exactly that many name strings must follow or client reads OOB.
fn onGameInfo(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    const name = r.getStr();

    var buf: [512]u8 = undefined;
    var w = startPacket(&buf, MCP_GAMEINFO);
    w.putU16(reqid); // +1 reqid echo

    const game = state.global.findGame(name) orelse {
        log.line(tag, "game info '{s}' -> not found", .{name});
        w.putU32(0xFFFF_FFFF); // +3 token = -1 -> "no info", client returns before parsing
        w.zeros(8); // +7 uptime, +0xb..0xe levels/limits — unread on this path
        finish(c, &w);
        return;
    };
    const g = game;
    // A game the list would not have shown is not described either.
    if (c.charName().len > 0 and !gameOpenTo(g.status, g.difficulty, charStatus(c), charProgression(c))) {
        log.line(tag, "game info '{s}' -> not open to this character", .{name});
        w.putU32(0xFFFF_FFFF);
        w.zeros(8);
        finish(c, &w);
        return;
    }

    var members: [state.max_members]state.Member = undefined;
    const n = state.global.gameMembers(g.gameid, &members);
    const created = state.global.gameCreated(g.gameid);
    const uptime: u32 = if (created > 0) @intCast(@max(0, time(null) - created)) else 0;

    w.putU32(g.gameid); // +3 token: a real entry (not -1/-2)
    w.putU32(uptime); // +7 how long it has been up
    // No level restrictions are enforced on this realm, so the reference level is the
    // highest character present and the difference is 0 — which the client renders as a
    // single level rather than a range. Inventing a range would gate joins we do allow.
    var top_level: u8 = 0;
    for (members[0..n]) |m| top_level = @max(top_level, m.level);
    w.putU8(top_level); // +0xb reference level
    w.putU8(0); // +0xc level difference: unrestricted
    w.putU8(g.max_players); // +0xd max players: the creator's choice
    w.putU8(@intCast(n)); // +0xe player count — must match the strings below

    var i: usize = 0;
    while (i < 16) : (i += 1) w.putU8(if (i < n) members[i].class else 0); // +0x0f classes
    i = 0;
    while (i < 16) : (i += 1) w.putU8(if (i < n) members[i].level else 0); // +0x1f levels

    w.putStr(g.desc()); // +0x2f description
    for (members[0..n]) |m| w.putStr(m.name_slice()); // then exactly `n` names

    log.line(tag, "game info '{s}' -> {d} player(s), up {d}s", .{ name, n, uptime });
    finish(c, &w);
}

// MCP_MOTD (0x12). Request: empty. Reply: 1 pad byte then a C-string the client shows in
// chat (Incoming0x12 reads the message at pBytes+2).
fn onMotd(c: *DConn, tag: []const u8, body: []const u8) void {
    _ = body;
    log.line(tag, "motd -> '{s}'", .{motd});
    var buf: [256]u8 = undefined;
    var w = startPacket(&buf, MCP_MOTD);
    w.putU8(0); // body[0] pad; message begins at body[1] (client reads pBytes+2)
    w.putStr(motd);
    finish(c, &w);
}

// MCP_LADDERDATA (0x11). Request: u8 mode, u16 start (the first row the client wants, a multiple
// of sixteen: the ladder screen asks again each time it is scrolled past one). Reply, after the
// id (NET_MCP_CLIENT_Incoming0x11 @0x44afc0): [u8 mode][u16 total][u16 chunk][u16 offset] then
// `chunk` bytes of the block at `offset`; the client stitches the pieces until it has `total`,
// then parses the block (ladder.writeBlock) and draws the rows from rank `rankBase`. A block is
// several packets because one realm packet over 1024 bytes is dropped by the client unread
// (ladder.chunk_max). What is on the list is ladder.zig's.
//
// An empty list gets no reply: the all-zero form is the answer to a character search that found
// nobody, and the client says "Player '' is not on the ladder" for it.
fn onLadderData(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const mode_byte = r.getU8();
    const start: usize = r.getU16();
    const mode = ladder_list.decodeMode(mode_byte) orelse {
        log.line(tag, "ladder data request with unknown mode 0x{x}, ignored", .{mode_byte});
        return;
    };
    var list: [ladder_list.overall_rows]ladder_list.Entry = undefined;
    const n = ladder_list.view(mode, &list);
    const rows = ladder_list.page(list[0..n], start);
    log.line(tag, "ladder data request mode=0x{x} start={d} -> {d} of {d}", .{ mode_byte, start, rows.len, n });
    if (rows.len == 0) return;
    sendLadder(c, mode_byte, @intCast(start), rows);
}

/// Send `rows` (ranks from `rank_base`) as one block in as many 0x11 packets as it takes.
fn sendLadder(c: *DConn, mode_byte: u8, rank_base: u32, rows: []const ladder_list.Entry) void {
    var frames: [ladder_list.block_bytes_max + 16 * 16]u8 = undefined;
    const bytes = ladderPackets(&frames, mode_byte, rank_base, rows);
    queue(c, bytes);
    flushOut(c);
}

/// The 0x11 packets for one block, back to back in `buf`, each a whole MCP packet of at most
/// 2 + 1 + 7 + ladder.chunk_max bytes.
fn ladderPackets(buf: []u8, mode_byte: u8, rank_base: u32, rows: []const ladder_list.Entry) []const u8 {
    var block_buf: [ladder_list.block_bytes_max]u8 = undefined;
    const block = ladder_list.writeBlock(&block_buf, rank_base, rows);
    var at: usize = 0;
    var off: usize = 0;
    while (off < block.len) {
        const len = @min(ladder_list.chunk_max, block.len - off);
        var w = startPacket(buf[at..], MCP_LADDERDATA);
        w.putU8(mode_byte);
        w.putU16(@intCast(block.len)); // the whole block
        w.putU16(@intCast(len)); // this piece
        w.putU16(@intCast(off)); // where it goes
        w.putBytes(block[off..][0..len]);
        w.patchU16(0, @intCast(w.pos));
        at += w.pos;
        off += len;
    }
    return buf[0..at];
}

/// The empty 0x11: "Player '<name>' is not on the ladder." on the client's screen.
fn sendNotOnLadder(c: *DConn) void {
    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, MCP_LADDERDATA);
    w.zeros(14);
    finish(c, &w);
}

// MCP_CHARUPGRADE (0x18). Request: cstr charname. This is the CharSel screen's
// "convert to Lord of Destruction" (MAINMENU_UpgradeCharacterToExpansion @0x4349b0), and
// the client's only test of the reply is result == 0 (Incoming0x18 @0x44ae40 stores the
// u32 at +1). It used to be acked without touching anything, which meant the character
// came back classic the next time it logged on and the screen kept offering the upgrade.
fn onCharUpgrade(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const name = r.getStr();
    const outcome = store.upgradeCharToExpansion(c.accountName(), name);
    log.line(tag, "char upgrade '{s}' (account={s}) -> {s}", .{ name, c.accountName(), @tagName(outcome) });

    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARUPGRADE);
    // A character that was already expansion is not a failure — the conversion it asked
    // for is a fact either way, and reporting non-zero would put an error on screen for a
    // character that is exactly as the player wanted it.
    w.putU32(switch (outcome) {
        .upgraded, .already_expansion => 0,
        .no_such_char, .failed => 1,
    });
    finish(c, &w);
}

// MCP_CANCELCREATE (0x13). Request: empty. Fire-and-forget — the client gave up on a
// pending create. CreateGame is synchronous here so there's nothing to unwind; just note
// it. No reply (the client has no Incoming0x13).
fn onCancelCreate(c: *DConn, tag: []const u8, body: []const u8) void {
    _ = c;
    _ = body;
    log.line(tag, "cancel game create (no-op)", .{});
}

// MCP_CHARRANK (0x16): the ladder screen's search for one character. Request
// (NET_MCP_CLIENT_Send_0x16_CharRank @0x44aae0): [u32 hardcore][u32 expansion][cstr name]. The
// client has no 0x16 handler (Src::McpConnect::INCOMING @0x70ed00 holds a null there); the answer
// is a 0x11 for the overall list of that group (CHATDLG_RequestLadderRank @0x43ec60 has just set
// the screen to it), starting at the page the character is on. The client scrolls there and
// draws the searched name's row in white. Nobody by that name gets the empty 0x11.
fn onCharRank(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const hardcore = r.getU32() != 0;
    const expansion = r.getU32() != 0;
    const name = r.getStr();
    const mode: ladder_list.Mode = .{ .hardcore = hardcore, .expansion = expansion };
    var list: [ladder_list.overall_rows]ladder_list.Entry = undefined;
    const n = ladder_list.view(mode, &list);
    const rank = ladder_list.rankOf(list[0..n], name) orelse {
        log.line(tag, "char rank '{s}' (mode 0x{x}): not on the ladder", .{ name, mode.byte() });
        return sendNotOnLadder(c);
    };
    const start = ladder_list.pageStart(rank);
    log.line(tag, "char rank '{s}' (mode 0x{x}): rank {d}", .{ name, mode.byte(), rank + 1 });
    sendLadder(c, mode.byte(), @intCast(start), ladder_list.page(list[0..n], start));
}

/// What the client does with the 0x11 packets, after NET_MCP_CLIENT_Incoming0x11: each packet
/// must fit its 1024-byte read, the pieces are stitched at their offsets, and the block that comes
/// out names its first rank, count and name width.
fn parseLikeClient(packets: []const u8, block_out: []u8) !struct { mode: u8, block: []const u8 } {
    var at: usize = 0;
    var total: usize = 0;
    var mode: u8 = 0;
    var got: usize = 0;
    while (at < packets.len) {
        const len = std.mem.readInt(u16, packets[at..][0..2], .little);
        if (len - 2 > 1024) return error.DroppedByClient;
        const p = packets[at + 2 .. at + len];
        if (p[0] != MCP_LADDERDATA) return error.WrongId;
        mode = p[1];
        total = std.mem.readInt(u16, p[2..4], .little);
        const chunk = std.mem.readInt(u16, p[4..6], .little);
        const off = std.mem.readInt(u16, p[6..8], .little);
        if (off + chunk > total or chunk != p.len - 8) return error.BadChunk;
        @memcpy(block_out[off..][0..chunk], p[8..][0..chunk]);
        got += chunk;
        at += len;
    }
    if (got != total) return error.Incomplete;
    return .{ .mode = mode, .block = block_out[0..total] };
}

test "a ladder page goes out in packets the client can read, and comes back whole" {
    var rows: [ladder_list.block_max]ladder_list.Entry = undefined;
    for (&rows, 0..) |*e, i| {
        e.* = .{ .experience = @intCast(100_000 - i), .level = 90, .class = @intCast(i % 7), .status = 0x60 };
        _ = std.fmt.bufPrint(&e.name, "Char{d}", .{i}) catch unreachable;
    }
    var buf: [ladder_list.block_bytes_max + 16 * 16]u8 = undefined;
    const packets = ladderPackets(&buf, 0x1b, 32, &rows);
    var block: [ladder_list.block_bytes_max]u8 = undefined;
    const got = try parseLikeClient(packets, &block);
    try std.testing.expectEqual(@as(u8, 0x1b), got.mode);
    try std.testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, got.block[0..4], .little)); // rank base
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, got.block[4..8], .little)); // count
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, got.block[8..12], .little)); // name width
    try std.testing.expectEqual(12 + 256 * ladder_list.wire_entry, @as(u32, @intCast(got.block.len)));
    // The last row survived the stitching.
    const last = got.block[12 + 255 * ladder_list.wire_entry ..];
    try std.testing.expectEqual(@as(u32, 100_000 - 255), std.mem.readInt(u32, last[0..4], .little));
    try std.testing.expectEqualStrings("Char255", std.mem.sliceTo(last[12..28], 0));
    // The old single-packet reply of 176 rows was 4940 bytes; the client drops anything over 1024.
    try std.testing.expect(packets.len > 1024);
}

test "a short ladder fits one packet" {
    const rows = [_]ladder_list.Entry{.{ .experience = 5, .level = 2, .status = 0x60 }};
    var buf: [256]u8 = undefined;
    const packets = ladderPackets(&buf, 0x09, 0, &rows);
    try std.testing.expectEqual(@as(usize, 2 + 1 + 7 + 12 + 28), packets.len);
}

test "a chat statstring is the character list's blob behind the product tag, with no NUL in it" {
    var b: [128]u8 = undefined;
    var w = proto.Writer.init(&b);
    w.putBytes("PX2D");
    w.putBytes("TypeGuru");
    w.putU8(',');
    w.putBytes("Sorc");
    w.putU8(',');
    const at = w.pos;
    writeStatString(&w, 1, 42, 0x20, 3, 1, &.{}, &.{}, "14");
    const s = w.slice();
    // what the client's parser reads after the second comma: class at 13, level at 25, the flags at 26
    const blob = s[at..];
    try std.testing.expectEqual(@as(u8, 2), blob[13]); // class + 1
    try std.testing.expectEqual(@as(u8, 42), blob[25]);
    try std.testing.expect(std.mem.indexOfScalar(u8, s, 0) == null);
}

/// The user-list fields the 1.14d client reads out of a chat statstring (ComCallback @0x446d90):
/// the same offsets as the character list, after the product tag and "realm,charname,".
const ChatUser = struct {
    class: u8,
    level: u8,
    hardcore: bool,
    expansion: bool,
    ladder: bool,
    progression: u8,

    /// How many titles the character has earned, by the client's own thresholds (ComCallback
    /// @0x447d00): 0 = none. Classic steps at 4/8/12, expansion at 5/10/15.
    fn titleLevel(u: ChatUser) u8 {
        const p = u.progression;
        if (u.expansion) return if (p < 5) 0 else if (p < 10) 1 else if (p < 15) 2 else 3;
        return if (p < 4) 0 else if (p < 8) 1 else if (p < 12) 2 else 3;
    }
};

fn parseChatStat(s: []const u8) !ChatUser {
    if (!std.mem.eql(u8, s[0..4], "PX2D")) return error.NoTag;
    var i: usize = 4;
    var commas: u8 = 0;
    while (commas < 2) : (i += 1) {
        if (s[i] == ',') commas += 1;
    }
    const blob = s[i..];
    var flags: u32 = 0;
    flags = (blob[26] & 0x7f) | (@as(u32, blob[27] & 0x7f) << 7);
    return .{
        .class = blob[13] - 1,
        .level = blob[25],
        .hardcore = flags & 0x04 != 0,
        .expansion = flags & 0x20 != 0,
        .ladder = flags & 0x40 != 0,
        .progression = @intCast((flags >> 8) & 0x1f),
    };
}

fn statFor(out: []u8, class: u8, level: u8, status: u8, progression: u8) []const u8 {
    var w = proto.Writer.init(out);
    w.putBytes("PX2D");
    w.putBytes("realm");
    w.putU8(',');
    w.putBytes("Char");
    w.putU8(',');
    writeStatString(&w, class, level, status, progression, 1, &.{}, &.{}, "14");
    return w.slice();
}

test "a chat statstring carries the character's class, level, mode and title progression" {
    var b: [128]u8 = undefined;
    const Case = struct { class: u8, level: u8, status: u8, prog: u8, hc: bool, xp: bool, ladder: bool, title: u8 };
    const cases = [_]Case{
        // a level-99 expansion sorceress who has finished Hell: the title of the owner's character
        .{ .class = 1, .level = 99, .status = 0x28, .prog = 15, .hc = false, .xp = true, .ladder = false, .title = 3 },
        // a fresh classic softcore amazon
        .{ .class = 0, .level = 1, .status = 0x00, .prog = 0, .hc = false, .xp = false, .ladder = false, .title = 0 },
        // expansion hardcore ladder, Nightmare done
        .{ .class = 4, .level = 75, .status = 0x64, .prog = 5, .hc = true, .xp = true, .ladder = true, .title = 1 },
        // classic softcore, Nightmare and Hell opened but not finished
        .{ .class = 3, .level = 60, .status = 0x00, .prog = 8, .hc = false, .xp = false, .ladder = false, .title = 2 },
        // classic finished, expansion needs 15 for the same title
        .{ .class = 5, .level = 90, .status = 0x00, .prog = 12, .hc = false, .xp = false, .ladder = false, .title = 3 },
        .{ .class = 5, .level = 90, .status = 0x20, .prog = 12, .hc = false, .xp = true, .ladder = false, .title = 2 },
        .{ .class = 6, .level = 30, .status = 0x24, .prog = 4, .hc = true, .xp = true, .ladder = false, .title = 0 },
    };
    for (cases) |c| {
        const s = statFor(&b, c.class, c.level, c.status, c.prog);
        try std.testing.expect(std.mem.indexOfScalar(u8, s, 0) == null);
        const u = try parseChatStat(s);
        try std.testing.expectEqual(c.class, u.class);
        try std.testing.expectEqual(c.level, u.level);
        try std.testing.expectEqual(c.hc, u.hardcore);
        try std.testing.expectEqual(c.xp, u.expansion);
        try std.testing.expectEqual(c.ladder, u.ladder);
        try std.testing.expectEqual(c.prog, u.progression);
        try std.testing.expectEqual(c.title, u.titleLevel());
    }
}

test "the statstring's ladder byte is 1 for a ladder character and 0xFF otherwise" {
    var b: [128]u8 = undefined;
    const Case = struct { status: u8, season: u8 };
    const cases = [_]Case{
        .{ .status = 0x60, .season = 1 }, // expansion ladder
        .{ .status = 0x64, .season = 1 }, // expansion hardcore ladder
        .{ .status = 0x40, .season = 1 }, // classic ladder
        .{ .status = 0x20, .season = 0xFF }, // expansion non-ladder
        .{ .status = 0x24, .season = 0xFF }, // expansion hardcore non-ladder
        .{ .status = 0x00, .season = 0xFF }, // classic non-ladder
    };
    for (cases) |c| {
        var w = proto.Writer.init(&b);
        writeStatString(&w, 1, 50, c.status, 0, 1, &.{}, &.{}, "14");
        const blob = w.slice();
        try std.testing.expectEqual(c.season, blob[30]);
        // the bytes around it keep their meaning: flags carry the same ladder bit, the two
        // fields after it stay "none", and the guild tag follows
        const flags = (blob[26] & 0x7f) | (@as(u32, blob[27] & 0x7f) << 7);
        try std.testing.expectEqual(c.status & 0x40 != 0, flags & 0x40 != 0);
        try std.testing.expectEqual(@as(u8, 0xFF), blob[31]);
        try std.testing.expectEqual(@as(u8, 0xFF), blob[32]);
        try std.testing.expectEqualStrings("14", blob[33..35]);
        try std.testing.expect(std.mem.indexOfScalar(u8, blob, 0) == null);
    }
}

test "a save's header is read into the statstring, gear or none" {
    var save: [0xB0]u8 = @splat(0);
    save[0x24] = 0x28; // expansion, died bit
    save[0x25] = 15;
    save[0x28] = 1; // sorceress
    save[0x2b] = 99;
    var b: [128]u8 = undefined;
    var w = proto.Writer.init(&b);
    w.putBytes("PX2Drealm,Char,");
    const at = w.pos;
    // no store behind it: the era tag comes from writeCharStatFrom's store lookup, so build the
    // same fields from the header the way it does
    writeStatString(&w, save[0x28], save[0x2b], save[0x24], save[0x25], 1, &.{}, &.{}, "");
    const blob = w.slice()[at..];
    // no gear: all 0xFF in both slots, which the client draws as a naked character
    for (blob[2..13]) |x| try std.testing.expectEqual(@as(u8, 0xFF), x);
    for (blob[14..25]) |x| try std.testing.expectEqual(@as(u8, 0xFF), x);
    const u = try parseChatStat(w.slice());
    try std.testing.expectEqual(@as(u8, 1), u.class);
    try std.testing.expectEqual(@as(u8, 99), u.level);
    try std.testing.expectEqual(@as(u8, 15), u.progression);
    try std.testing.expect(u.expansion and !u.hardcore);
}
