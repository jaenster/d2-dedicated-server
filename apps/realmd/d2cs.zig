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

extern "c" fn time(t: ?*c_long) c_long; // POSIX seconds-since-epoch, for the .d2s create time

// MCP message ids (subset; everything else is logged).
const mcp = @import("libd2").bnet.mcp;

const MCP_STARTUP = @intFromEnum(mcp.Op.startup);
const MCP_CHARCREATE = @intFromEnum(mcp.Op.charcreate);
const MCP_CREATEGAME = @intFromEnum(mcp.Op.creategame);
const MCP_JOINGAME = @intFromEnum(mcp.Op.joingame);
const MCP_GAMELIST = @intFromEnum(mcp.Op.gamelist);
const MCP_GAMEINFO = @intFromEnum(mcp.Op.gameinfo);
const MCP_CHARLOGON = @intFromEnum(mcp.Op.charlogon);
const MCP_CHARDELETE = @intFromEnum(mcp.Op.chardelete);
const MCP_LADDERDATA = @intFromEnum(mcp.Op.ladderdata);
const MCP_MOTD = @intFromEnum(mcp.Op.motd);
const MCP_CANCELCREATE = @intFromEnum(mcp.Op.cancelcreate);
const MCP_CHARRANK = @intFromEnum(mcp.Op.charrank);
const MCP_CHARUPGRADE = @intFromEnum(mcp.Op.charupgrade);
const MCP_CHARLIST2 = @intFromEnum(mcp.Op.charlist2);

// MCP result codes from OOG_PollJoinCreatePump @0x441770 (D2Client/OOGUtilities.cpp), with the
// string-table id each resolves to. A code not in this list falls to `default:`: no popup, no
// state change, player frozen on the join screen.
// CREATEGAME (0x03) replies:
const CREATE_OK: u32 = @intFromEnum(mcp.CreateResult.created);
const CREATE_INVALID_NAME: u32 = @intFromEnum(mcp.CreateResult.invalid_name); // str 0x1411 "Invalid Game Name"
const CREATE_NAME_TAKEN: u32 = @intFromEnum(mcp.CreateResult.already_exists); // str 0x1412 "Game Already Exists"
const CREATE_SERVER_DOWN: u32 = @intFromEnum(mcp.CreateResult.servers_down); // str 0x1413 "Server Down"
// There is NO "servers are full" code on the create path: JoinOrCreateGame @0x441500 bounds the
// switch at 0x20 and sends everything else to str 0x1415 "Error Creating Game" (0x2b "Game is
// Full" exists only on the JOIN path, and means that one game is full — not this). So a full
// fleet gets the default bucket on purpose: "Error Creating Game" is vague but TRUE, whereas
// "Server Down" would be a plain lie about servers that are up and busy.
const CREATE_ERROR_GENERIC: u32 = @intFromEnum(mcp.CreateResult.generic); // > 0x20 -> str 0x1415 "Error Creating Game"

// JOINGAME (0x04) replies. NOTE the first two — they are not in the order you would
// guess from the numbers, and realmd had them the wrong way round: 0x29 is the PASSWORD
// failure and 0x2a is the MISSING-GAME failure.
const JOIN_OK: u32 = @intFromEnum(mcp.JoinResult.ok);
const JOIN_BAD_PASSWORD: u32 = @intFromEnum(mcp.JoinResult.password_incorrect); // str 0x1428 "password don't match"
const JOIN_NO_SUCH_GAME: u32 = @intFromEnum(mcp.JoinResult.no_such_game); // str 0x1427 "Game does not exist."
const JOIN_FULL: u32 = @intFromEnum(mcp.JoinResult.game_full); // str 0x1429 "Game is Full."
const JOIN_HARDCORE_MIX: u32 = @intFromEnum(mcp.JoinResult.hardcore_mix); // str 0x1426 hc/normal mix
const JOIN_CLASSIC_INTO_EXPANSION: u32 = @intFromEnum(mcp.JoinResult.classic_into_expansion); // str 0x2775
const JOIN_EXPANSION_INTO_CLASSIC: u32 = @intFromEnum(mcp.JoinResult.expansion_into_classic); // str 0x2776
const JOIN_LADDER_MISMATCH: u32 = @intFromEnum(mcp.JoinResult.ladder_mismatch);
const JOIN_NEED_NIGHTMARE: u32 = @intFromEnum(mcp.JoinResult.need_nightmare); // str 0x14f4/0x5522 need Diablo/Baal kill
const JOIN_NEED_HELL: u32 = @intFromEnum(mcp.JoinResult.need_hell); // str 0x14f3/0x5521, str 0x2ab1/0x2ab2 by ladder flag

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
const max_players_per_game: u16 = 8;

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
    account: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    account_len: u8 = 0,
    char: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    char_len: u8 = 0,
    // Which engine the client on the other end runs. MCP is a different connection from the login
    // that learned it, so it comes back off the session at startup rather than off the wire.
    client_version: [state.max_version]u8 = [_]u8{0} ** state.max_version,
    client_version_len: u8 = 0,

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
            }
        }
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
        log.line(tag, "startup session={d} -> account={s} engine={s}", .{ sid, acct, v });
    } else {
        log.line(tag, "startup session={d} -> UNKNOWN (rejected)", .{sid});
    }

    var buf: [16]u8 = undefined;
    var w = startPacket(&buf, MCP_STARTUP);
    w.putU32(result);
    finish(c, &w);
}

fn onCharList(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const requested: u16 = @truncate(r.getU32());

    var names: [store.max_chars]store.Name = [_]store.Name{.{}} ** store.max_chars;
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
        // Pull class@0x28, level@0x2b and the status byte@0x24 from the .d2s for
        // the statstring the client's CharSel renders the list from.
        var save: [1024]u8 = undefined;
        const n = store.getCharD2s(c.accountName(), names[i].slice(), &save);
        const class: u8 = if (n > 0x2b) save[0x28] else 1;
        const level: u8 = if (n > 0x2b) save[0x2b] else 1;
        const status: u8 = if (n > 0x24) save[0x24] else 0x20; // default to expansion
        const progression: u8 = if (n > 0x25) save[0x25] else 0; // title (difficulty completed)
        // The .d2s header carries the menu-composite appearance the game wrote on save:
        // pAppearance1@0x88 = body-component graphic codes, pAppearance2@0x98 = color
        // transforms (16 each; the statstring uses the first 11). Empty => naked preview.
        const have_app = n > 0xA2;
        const app1: []const u8 = if (have_app) save[0x88..0x93] else &.{};
        const app2: []const u8 = if (have_app) save[0x98..0xA3] else &.{};

        w.putU32(0xFFFF_FFFF); // expiration — far future so it's NOT "expired"
        w.putStr(names[i].slice()); // character name
        const era = eraCode(store.charVersion(c.accountName(), names[i].slice()).slice());
        writeStatString(&w, class, level, status, progression, @intCast(total), app1, app2, era); // CharSel.cpp layout
        w.putU8(0); // statstring C-string terminator
    }
    finish(c, &w);
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
// [28..30] field9 (14-bit), [30] act (0xFF->0), [31..33] two fields (0xFF->0), [33..36] guild tag.
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
    w.putU8(0xFF); // act      (0xFF -> 0)
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
        var rbuf: [12]u8 = undefined;
        var rw = startPacket(&rbuf, MCP_CHARLOGON);
        rw.putU32(CHARLOGON_REFUSED);
        return finish(c, &rw);
    }

    c.setChar(name); // remember the active char so a later join can name it to the GS
    hook.charLogon(c.accountName(), name);
    log.line(tag, "char logon '{s}' (account={s}) -> ok", .{ name, c.accountName() });
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
    var probe: [d2s.new_save_size]u8 = undefined;
    if (store.getCharD2s(acct, name, &probe) > 0) {
        log.line(tag, "char create '{s}' (account={s}) -> name taken", .{ name, acct });
        w.putU32(0x14);
        return finish(c, &w);
    }
    var save: [d2s.new_save_size]u8 = undefined;
    const now: u32 = @truncate(@as(u64, @bitCast(@as(i64, time(null)))));
    // Honor the client's flags as-is (classic = no 0x20, expansion = 0x20, +hardcore/ladder).
    if (!d2s.newSave(&save, name, class, status_flags, now) or !store.saveCharD2s(acct, name, &save)) {
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
    if (char_version.len != 0) _ = store.setCharVersion(acct, name, char_version);
    log.line(tag, "char create '{s}' class={d} engine={s} (account={s}) -> created", .{ name, class, char_version, acct });
    w.putU32(0); // success
    finish(c, &w);
}

/// The logged-on character's status bits, read from its .d2s header at 0x24. This is what
/// decides which KIND of game the account may create or join. Defaults to expansion when
/// the save can't be read, matching the rest of the closed-realm assumptions here.
fn charStatus(c: *DConn) u8 {
    var save: [64]u8 = undefined;
    const n = store.getCharD2s(c.accountName(), c.charName(), &save);
    if (n <= 0x24) return STATUS_EXPANSION;
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

/// A game name the realm will accept. The client offers "Invalid Game Name" as a distinct
/// error, so an empty or oversized name should get it rather than being pushed to a GS
/// that will refuse it for reasons we'd then have to describe as "Server Down".
fn validGameName(name: []const u8) bool {
    return name.len > 0 and name.len <= 15;
}

fn onCreateGame(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    // MCP create-game flags DWORD: difficulty lives in bits 12-14 (Normal=0x0000,
    // Nightmare=0x1000, Hell=0x2000), the same GAMEFLAG_DIFFICULTY_BIT=12 the GS uses.
    const create_flags = r.getU32();
    const difficulty: u8 = @intCast(@min(@as(u32, 2), (create_flags >> 12) & 0x7));
    _ = r.getU8(); // unknown (1)
    _ = r.getU8(); // player difference
    _ = r.getU8(); // max players
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
        return fail(c, &w, CREATE_INVALID_NAME);
    }
    if (hook.gameCreate(c.accountName(), c.charName(), name, difficulty)) |result| {
        log.line(tag, "create game '{s}' -> refused by extension ({d})", .{ name, result });
        return fail(c, &w, result);
    }
    if (!fleet.ready()) {
        // "Server Down" is the honest one and, more to the point, the only one in the
        // client's switch that fits. The 0x06 that used to go out here isn't a case at
        // all, so the client fell to `default:` and left the player on a dead screen.
        log.line(tag, "create game '{s}' -> NO GS available", .{name});
        return fail(c, &w, CREATE_SERVER_DOWN);
    }
    // A name already in the realm registry is a DIFFERENT failure than "no GS took it":
    // the client shows "a game with that name already exists" and offers to join instead.
    // Asking the GS first would just get a refusal we'd report as the generic 0x1e.
    if (state.global.findGame(name) != null) {
        log.line(tag, "create game '{s}' -> name already exists", .{name});
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
    // Claim the name BEFORE dispatching. A game is only recorded once the server accepts the
    // create, and in that gap a second client asking for the same name is told it is free, loses
    // the race at the server, and is then left with nothing to join — the failure that fails
    // stress rounds. Claiming first moves the refusal to where the loser can still be told.
    if (!store.reserveGameName(name)) {
        log.line(tag, "create game '{s}' (account={s}) -> name already claimed", .{ name, c.accountName() });
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
            return fail(c, &w, CREATE_SERVER_DOWN);
        }
        log.line(tag, "create game '{s}' -> GS refused", .{name});
        return fail(c, &w, CREATE_SERVER_DOWN);
    }
    const rr = routed.?;
    // 1 player: the creator. That seed and the join-time bump keep the list responsive until the
    // GS's own UPDATEGAMEINFO overwrites them. Without the record the game exists on the GS but
    // nowhere the realm can find it, and the client's very next packet is a JOINGAME for this name
    // — "game does not exist" right after reporting success. Fail the create instead; the GS reaps
    // the orphaned empty game on its own idle timer.
    if (!state.global.registerGame(name, rr.gameid, rr.ip, rr.port, rr.gsid, 1, status, difficulty, pass, desc)) {
        store.releaseGameName(name);
        log.line(tag, "create game '{s}' -> GS made gameid={d} but the store would not record it", .{ name, rr.gameid });
        return fail(c, &w, CREATE_ERROR_GENERIC);
    }
    // The game record now owns the name and is what a duplicate create is refused against, so the
    // reservation has done its job. Holding it any longer would refuse a name for the rest of its
    // TTL after the game it guarded had already ended.
    store.releaseGameName(name);
    state.global.noteGameCreated(rr.gameid); // starts the clock the detail panel counts from
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
    finish(c, &w);
}

fn onJoinGame(c: *DConn, tag: []const u8, body: []const u8) void {
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
        return rejectJoin(c, &w, JOIN_NO_SUCH_GAME);
    }
    const g = game.?;
    // Reject a wrong password for a passworded game (open games have pw_len == 0).
    if (g.pw_len > 0 and !std.mem.eql(u8, g.pw(), join_pass)) {
        log.line(tag, "join game '{s}' (account={s}) -> WRONG PASSWORD", .{ name, c.accountName() });
        return rejectJoin(c, &w, JOIN_BAD_PASSWORD);
    }
    if (hook.gameJoin(c.accountName(), c.charName(), name)) |result| {
        log.line(tag, "join game '{s}' (account={s}) -> refused by extension ({d})", .{ name, c.accountName(), result });
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
        return rejectJoin(c, &w, why);
    }
    // Nightmare and Hell are earned. The client hides difficulties a character has not
    // unlocked, so anything asking for one here has either been modified or is stale —
    // either way it gets the specific message rather than a confusing generic failure.
    if (difficultyError(g.difficulty, charProgression(c), (joiner & STATUS_EXPANSION) != 0)) |why| {
        log.line(tag, "join game '{s}' (account={s}) -> difficulty {d} not unlocked (progression {d}) -> 0x{x}", .{ name, c.accountName(), g.difficulty, charProgression(c), why });
        return rejectJoin(c, &w, why);
    }
    // The engine's CreateClient hard-refuses a ninth client, so a join that would exceed
    // the cap is rejected while the client can still be told why. This is only trustworthy
    // because the count now comes back down when players leave.
    if (g.players >= max_players_per_game) {
        log.line(tag, "join game '{s}' (account={s}) -> FULL ({d} players)", .{ name, c.accountName(), g.players });
        return rejectJoin(c, &w, JOIN_FULL);
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
        return rejectJoin(c, &w, JOIN_FULL);
    }
    _ = store.addGameChar(g.gameid, c.accountName(), c.charName());
    // Stage the character into the shared store before the game server goes looking. The server
    // reads redis and nothing else, so a character that has only ever been in postgres would come
    // back missing — this read is what promotes it, and it is a no-op once it is there.
    warmChar(c.accountName(), c.charName());
    // Optimistic bump so the list reacts to this join right away; the GS corrects it (in
    // both directions) as soon as the player is actually in the game.
    _ = state.global.registerGame(name, g.gameid, g.gs_ip, g.gs_port, g.gsid, g.players + 1, g.status, g.difficulty, g.pw(), g.desc());
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
    log.line(tag, "game list (reqid={d}) -> {d} game(s)", .{ reqid, n });

    const acct = c.accountName();
    for (games[0..n]) |g| {
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
    }
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
    const ok = store.deleteCharD2s(c.accountName(), name);
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
    w.putU8(@intCast(max_players_per_game)); // +0xd max players
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

// MCP_LADDERDATA (0x11). Request: u8 mode, u16 reqid; reply ranks the realm's characters. Wire
// format from NET_MCP_CLIENT_Incoming0x11 @0x44afc0 + CHATDLG_HandleChatListClick @0x4403f0:
// after the id, [u8 flag][u16 total][u16 chunk][u16 offset][data]; `data` (one chunk) =
// [u32 rankBase=0][u32 count][u32 entrySize] then count entries of [u32 expLo][u32 expHi]
// [u32 charStats][entrySize-byte name]. charStats = class(&0xf) | died<<4 | expansion<<5 |
// hardcore<<6 | progression<<8 | level<<16. Empty realm -> the all-zero form; count/entrySize
// are capped (<=256 / <=16) by the client parser. Ordering is by experience, which is NOT in the
// header but in the packed attribute list (see d2s.attribute); the level byte alone ties.
const ladder_max = 200;
const ladder_entry_size: u32 = 16; // name field width

const LadderEntry = struct {
    name: [16]u8 = .{0} ** 16,
    stats: u32 = 0,
    experience: u32 = 0,
};

/// Highest experience first, falling back to level for characters whose save has no
/// attribute section yet — a character created but never played has no experience to
/// compare, and should not outrank one that has some.
fn ladderRankDesc(_: void, a: LadderEntry, b: LadderEntry) bool {
    if (a.experience != b.experience) return a.experience > b.experience;
    return (a.stats >> 16) > (b.stats >> 16);
}

fn collectLadder(out: *[ladder_max]LadderEntry) usize {
    var n: usize = 0;
    var accts: [256][32]u8 = undefined;
    const na = store.listAccounts(&accts);
    for (accts[0..na]) |acct_buf| {
        const acct = std.mem.sliceTo(&acct_buf, 0);
        if (acct.len == 0) continue;
        var names: [store.max_chars]store.Name = [_]store.Name{.{}} ** store.max_chars;
        const nc = store.listChars(acct, &names);
        for (names[0..nc]) |nm| {
            if (n >= ladder_max) return n;
            // Big enough to reach the attribute section of a played save; the header
            // alone would give the level but never the experience.
            var save: [8192]u8 = undefined;
            const sz = store.getCharD2s(acct, nm.slice(), &save);
            if (sz <= 0x2b) continue;
            const status = save[0x24];
            const progression: u32 = if (sz > 0x25) save[0x25] else 0;
            var stats: u32 = save[0x28] & 0xf; // class
            if (status & 0x08 != 0) stats |= 0x10; // died
            if (status & 0x20 != 0) stats |= 0x20; // expansion
            if (status & 0x04 != 0) stats |= 0x40; // hardcore
            stats |= (progression & 0x1f) << 8;
            stats |= @as(u32, save[0x2b]) << 16; // level
            const cn = nm.slice();
            out[n] = .{ .stats = stats, .experience = d2s.attribute(save[0..sz], d2s.stat_experience) orelse 0 };
            @memcpy(out[n].name[0..@min(cn.len, 16)], cn[0..@min(cn.len, 16)]);
            n += 1;
        }
    }
    return n;
}

fn onLadderData(c: *DConn, tag: []const u8, body: []const u8) void {
    const mode: u8 = if (body.len > 0) body[0] else 0;
    var entries: [ladder_max]LadderEntry = undefined;
    const n = collectLadder(&entries);
    std.sort.pdq(LadderEntry, entries[0..n], {}, ladderRankDesc);
    log.line(tag, "ladder data request mode=0x{x} -> {d} entries", .{ mode, n });

    var buf: [8192]u8 = undefined;
    var w = startPacket(&buf, MCP_LADDERDATA);
    if (n == 0) {
        w.zeros(14); // empty-ladder form (Incoming0x11 clear-and-done path)
        return finish(c, &w);
    }
    const total: u16 = @intCast(12 + n * (12 + ladder_entry_size));
    w.putU8(mode); // flag — echo the requested mode so the client renders this tab
    w.putU16(total); // whole-buffer size
    w.putU16(total); // this chunk's length (single chunk)
    w.putU16(0); // write offset
    w.putU32(0); // rankBase
    w.putU32(@intCast(n)); // count
    w.putU32(ladder_entry_size); // per-entry name width
    for (entries[0..n]) |e| {
        w.putU32(e.experience); // experience low
        w.putU32(0); // experience high — D2 experience is a u32, so this is always 0
        w.putU32(e.stats);
        w.putBytes(&e.name);
    }
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

// MCP_CHARRANK (0x16). Request: cstr charname, u32, u32. There is deliberately no reply:
// the client's incoming dispatch table (Src::McpConnect::INCOMING @0x70ed00, bounds-checked
// against 0x19) holds a null at index 0x16, so a 0x16 we sent back would be discarded before
// any handler saw it. Logging it is the whole of the correct behaviour.
fn onCharRank(c: *DConn, tag: []const u8, body: []const u8) void {
    _ = c;
    var r = proto.Reader.init(body);
    const name = r.getStr();
    log.line(tag, "char rank request '{s}' (client has no 0x16 handler; nothing to reply)", .{name});
}
