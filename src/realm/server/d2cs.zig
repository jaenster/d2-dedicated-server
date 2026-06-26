//! D2CS — the realm/character server (port 6113), client-facing side. After
//! bnetd's realm handoff the client connects here, proves who it is with the
//! session bnetd minted (MCP_STARTUP), lists/selects a character, and
//! creates/joins games.
//!
//! Framing: `<len:u16 LE> <id:u8>` where len includes the 3-byte header. The
//! first byte on the socket is a protocol selector (0x01), consumed once.
//!
//! The STARTUP handler resolving a session another listener (bnetd) created is
//! the proof that the front is stateless over shared state — i.e. that a second
//! realmd instance could resolve it too once the session table is a shared Store.
const std = @import("std");
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const proto = @import("proto.zig");
const state = @import("state.zig");
const store = @import("store.zig");
const d2s = @import("d2s.zig");
const gslink = @import("gslink.zig");
const guilds = @import("guilds.zig");

extern "c" fn time(t: ?*c_long) c_long; // POSIX seconds-since-epoch, for the .d2s create time

// MCP message ids (subset; everything else is logged).
const MCP_STARTUP = 0x01;
const MCP_CHARCREATE = 0x02;
const MCP_CREATEGAME = 0x03;
const MCP_JOINGAME = 0x04;
const MCP_GAMELIST = 0x05;
const MCP_GAMEINFO = 0x06;
const MCP_CHARLOGON = 0x07;
const MCP_CHARDELETE = 0x0a;
const MCP_LADDERDATA = 0x11;
const MCP_MOTD = 0x12;
const MCP_CANCELCREATE = 0x13;
const MCP_CHARRANK = 0x16;
const MCP_CHARUPGRADE = 0x18;
const MCP_CHARLIST2 = 0x19;

// Set from main() (mirrors gslink.gs_ip_override). When `game_ip` is set, JOINGAME
// advertises the qqserver's public IP to the client instead of the GS's own IP; the
// real GS address is recorded as a route for the qqserver to splice to. `route_ttl_s`
// is how long that route stays valid.
pub var game_ip: ?[4]u8 = null;
pub var route_ttl_s: u32 = 60;

// Realm-global game-token counter. realmd OWNS the u16 token it hands the client, so a
// process-global atomic makes it unique per CREATE/JOIN within this instance — two
// clients behind one public IP get distinct tokens, which is what makes the qqserver's
// token translation NAT-proof. NOTE: for multi-instance uniqueness this wants a redis
// INCR / instance-id namespacing (same as session ids); the atomic is fine for now.
var token_ctr = std.atomic.Value(u16).init(1);

/// Mint the next realm-global game token (wraps at u16; fine for the test/MVP).
fn mintToken() u16 {
    return token_ctr.fetchAdd(1, .monotonic);
}

const DConn = struct {
    fd: net.Socket,
    session: u64 = 0,
    account: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    account_len: u8 = 0,
    char: [state.max_name + 1]u8 = [_]u8{0} ** (state.max_name + 1),
    char_len: u8 = 0,

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
fn finish(c: *DConn, w: *proto.Writer) void {
    w.patchU16(0, @intCast(w.pos));
    _ = net.writeAll(c.fd, w.slice());
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
        result = 0x00;
        log.line(tag, "startup session={d} -> account={s}", .{ sid, acct });
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
        writeStatString(&w, class, level, status, progression, @intCast(total), app1, app2); // CharSel.cpp layout
        w.putU8(0); // statstring C-string terminator
    }
    finish(c, &w);
}

// 14-bit-encoded int: 7 bits/byte, high bit always set so the value never
// produces a 0x00 byte (the statstring is sent as a C-string).
fn enc14(w: *proto.Writer, v: u32) void {
    w.putU8(@intCast((v & 0x7F) | 0x80));
    w.putU8(@intCast(((v >> 7) & 0x7F) | 0x80));
}

// Character statstring — the per-char blob in the MCP_CHARLIST2 (0x19) reply that the
// client's char-select screen renders each character from. Layout fully reverse-engineered
// from the 1.14d client (Game.exe), parser CHARSEL_ParseRealmCharList @0x43aab0 →
// SAVEFILE_ParseSaveData @0x438ad0. Offsets from the statstring start:
//   [0..2]   realm char count   (14-bit encoded — SAVEFILE_ReadEncodedInt14Bit)
//   [2..13]  equip slot 1 (11)  → body-component GRAPHIC codes (see below)
//   [13]     class + 1          (parser subtracts CLASS_SORCERESS=1)
//   [14..25] equip slot 2 (11)  → component color TRANSFORMS (tints)
//   [25]     level
//   [26..28] character flags    (14-bit; bit2=0x04 expansion, bit3=0x08 ladder/hardcore mix)
//   [28..30] field9             (14-bit)
//   [30]     act (0xFF->0), [31..33] two fields (0xFF->0), [33..36] guild tag (3 bytes)
// Every byte must stay NON-ZERO (the statstring is sent as a C-string; a 0 truncates it) —
// that's why 14-bit ints set the high bit and "none" is 0xFF, not 0x00.
//
// Rendering: the client builds the 3D char preview via AllocCharSelectComponent @0x5066c0
// (class, expansion-mode, slot1 [graphic codes], slot2 [transforms]). The 16-entry equip
// loop treats a code of 0 / 0xFF / >= max as an EMPTY body slot. Weapons live at slot1[5]
// (right) and slot1[6] (left); D2COMP_ResolveWeaponClass @0x504af0 returns 1 (unarmed) when
// both are 0xFF, so an all-0xFF statstring renders a VALID NAKED character of the right
// class/level — it is not broken, just bare. To show real equipped gear, parse the .d2s
// item list (JM section) into gaCompCharacterCompositeItems indices and fill slot1/slot2
// (a future "char portrait" feature; the GS has the items in memory on save and could
// supply the portrait, like real pvpgn d2cs does).
// Emit the 11-byte equip slot from a .d2s appearance block. The statstring is a
// C-string, so a 0x00 byte would truncate it — map 0x00 (and any missing byte, e.g. a
// naked char with an empty slice) to 0xFF = "no component in this slot".
fn putEquipSlot(w: *proto.Writer, app: []const u8) void {
    var k: usize = 0;
    while (k < 11) : (k += 1) {
        const b: u8 = if (k < app.len and app[k] != 0) app[k] else 0xFF;
        w.putU8(b);
    }
}

fn writeStatString(w: *proto.Writer, class: u8, level: u8, status: u8, progression: u8, realm_count: u32, app1: []const u8, app2: []const u8) void {
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
    // No guild tag: the statstring's trailing NUL (added by the caller) lands on the
    // guild-tag slot, so CharSel's strncpy reads an empty tag. Emitting 0xFF bytes here
    // instead made it append " {ÿÿÿ}" garbage to the char name (looked like "no name").
}

fn onCharLogon(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const name = r.getStr();
    c.setChar(name); // remember the active char so a later join can name it to the GS
    log.line(tag, "char logon '{s}' (account={s}) -> ok", .{ name, c.accountName() });
    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARLOGON);
    w.putU32(0); // success
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
    const status_flags: u8 = @intCast(r.getU16() & 0x6C); // hardcore|died|expansion|ladder
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
    log.line(tag, "char create '{s}' class={d} (account={s}) -> created", .{ name, class, acct });
    w.putU32(0); // success
    finish(c, &w);
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

    if (!gslink.ready()) {
        log.line(tag, "create game '{s}' -> NO GS available", .{name});
        w.putU16(0); // token
        w.putU16(0); // unknown
        w.putU32(0x06); // result: server down / unavailable
        finish(c, &w);
        return;
    }
    // Expansion (LOD), softcore, non-ladder; difficulty from the client's request.
    // The registry picks the least-loaded GS with capacity and gives us its address.
    log.line(tag, "create game '{s}' diff={d} (flags=0x{x})", .{ name, difficulty, create_flags });
    const routed = gslink.createGameRouted(name, pass, desc, 0, true, difficulty, false);
    if (routed == null) {
        log.line(tag, "create game '{s}' -> GS refused / all full", .{name});
        w.putU16(0);
        w.putU16(0);
        w.putU32(0x1e); // result: a game with that name failed
        finish(c, &w);
        return;
    }
    const rr = routed.?;
    _ = state.global.registerGame(name, rr.gameid, rr.ip, rr.port, rr.gsid, 1, pass); // 1 player: the creator
    // The creator immediately joins the game they just made, but the GAMELOGON only
    // carries the char name — the account reaches the GS solely via the join-context
    // notify. JOIN seeds it; CREATE must too, or the GS resolves an empty account and
    // the character fetch (fpGetDatabaseCharacter) fails for the game's own creator.
    var gtagbuf1: [8]u8 = undefined;
    const gtag1 = guilds.tagOf(c.accountName(), &gtagbuf1); // cut Guild Halls: tell the GS the creator's guild
    if (rr.gsid != 0) _ = gslink.notifyJoin(rr.gsid, rr.gameid, rr.gameid, c.charName(), c.accountName(), gtag1);
    // Mint a realm-global token and record {token -> GS addr + real gameid} so the
    // qqserver can translate the client's token to the engine's gameid and splice.
    const token = mintToken();
    _ = store.recordTokenRoute(token, rr.ip, rr.port, rr.gameid, route_ttl_s);
    log.line(tag, "create game '{s}' (account={s}) -> gameid={d} token=0x{x} gs=0x{x}@{d}.{d}.{d}.{d}:{d}", .{ name, c.accountName(), rr.gameid, token, rr.gsid, rr.ip[0], rr.ip[1], rr.ip[2], rr.ip[3], rr.port });
    w.putU16(token); // game token (client presents this to the qqserver)
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

    const game = state.global.findGame(name);
    if (game == null) {
        log.line(tag, "join game '{s}' -> not found", .{name});
        w.putU16(0); // token
        w.putU16(0); // unknown
        w.putU32(0); // d2gs IP
        w.putU32(0); // game hash
        w.putU32(0x29); // result: game does not exist
        finish(c, &w);
        return;
    }
    const g = game.?;
    // Reject a wrong password for a passworded game (open games have pw_len == 0).
    // 0x2a = "incorrect password" (verify the exact client string in a live test).
    if (g.pw_len > 0 and !std.mem.eql(u8, g.pw(), join_pass)) {
        log.line(tag, "join game '{s}' (account={s}) -> WRONG PASSWORD", .{ name, c.accountName() });
        w.putU16(0); // token
        w.putU16(0); // unknown
        w.putU32(0); // d2gs IP
        w.putU32(0); // game hash
        w.putU32(0x2a); // result: incorrect password
        finish(c, &w);
        return;
    }
    // Guild Hall game type (cut feature): a game named exactly after a guild IS that
    // guild's private hall. Only members on the approved list may enter — the wiki's
    // "the Battle.net server will check if your character is on the approved list".
    // Non-members get 0x29 (game does not exist) so the hall stays hidden from outsiders.
    if (guilds.load(name)) |gh| {
        var ghc = gh;
        if (ghc.findMember(c.accountName()) == null) {
            log.line(tag, "join guild hall '{s}' (account={s}) -> NOT A MEMBER, hidden", .{ name, c.accountName() });
            w.putU16(0); // token
            w.putU16(0); // unknown
            w.putU32(0); // d2gs IP
            w.putU32(0); // game hash
            w.putU32(0x29); // result: game does not exist
            finish(c, &w);
            return;
        }
        log.line(tag, "join guild hall '{s}' as member {s}", .{ name, c.accountName() });
    }
    // Best-effort bump of the join-screen player count (the GS owns the authoritative
    // count; leaves aren't tracked here yet, so this can run high until the game closes).
    _ = state.global.registerGame(name, g.gameid, g.gs_ip, g.gs_port, g.gsid, g.players + 1, g.pw());
    // The client connects to the GS directly using the IP in the game record, so
    // any realmd instance can serve a join. Best-effort notify the GS that owns this
    // game (by its fleet id) so it can prefetch the joining account's character.
    var gtagbuf2: [8]u8 = undefined;
    const gtag2 = guilds.tagOf(c.accountName(), &gtagbuf2); // cut Guild Halls: tell the GS the joiner's guild
    if (g.gsid != 0) _ = gslink.notifyJoin(g.gsid, g.gameid, g.gameid, c.charName(), c.accountName(), gtag2);
    // Mint a realm-global token for this joining client and record {token -> the real
    // GS + engine gameid}. The qqserver reads the token from the client's first packet
    // and translates it — NAT-proof, since the token is unique even when two clients
    // share one public IP. (Source-IP recordRoute is no longer used by the gateway.)
    const token = mintToken();
    _ = store.recordTokenRoute(token, g.gs_ip, g.gs_port, g.gameid, route_ttl_s);
    // Advertise the qqserver's public IP when configured, else the GS IP (back-compat).
    const advertised_ip = game_ip orelse g.gs_ip;
    log.line(tag, "join game '{s}' (account={s}) gameid={d} token=0x{x} gs={d}.{d}.{d}.{d} -> client dials {d}.{d}.{d}.{d}", .{ name, c.accountName(), g.gameid, token, g.gs_ip[0], g.gs_ip[1], g.gs_ip[2], g.gs_ip[3], advertised_ip[0], advertised_ip[1], advertised_ip[2], advertised_ip[3] });
    w.putU16(token); // game token
    w.putU16(0); // unknown
    w.putBytes(&advertised_ip); // d2gs / qqserver IP (in_addr, network order)
    w.putU32(0); // game hash
    w.putU32(0); // result: success
    finish(c, &w);
}

// MCP_GAMELIST (0x05). Request body: u16 reqid, u32 difficulty filter, cstr search
// (NET_MCP_CLIENT_Send_0x05_GameList @0x44a590).
//
// The realm game list is delivered ONE GAME PER 0x05 PACKET, not one concatenated reply.
// Client side: each packet -> NET_MCP_CLIENT_Incoming0x05 @0x44b2d0 stores it in the
// g_CharSelectBuffer struct; JoinOrCreateGame polls it and calls OOGMENU_AddGameToCache
// once per game. A final packet whose token field == -2 (0xFFFFFFFE) maps to result 0x33
// = end-of-list, which triggers OOGMENU_RefreshGameListDisplay() to redraw the list.
//
// Per-game 0x05 payload (offsets are from the type byte the client sees as pBytes[0]):
//   +1   u16 reqid   (must equal the request's seq or the client drops it)
//   +3   u32 gameid  (low u16 is the AddGameToCache dedup key)
//   +7   u8  player count (the join screen's PLAYERS column; cache+0x14, read as u16)
//   +8   u32 token   (must NOT be -1/-2 for a real game)
//   +0xc cstr name, then cstr description
fn onGameList(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    var games: [64]state.GameInfo = undefined;
    const n = state.snapshotGames(&games);
    log.line(tag, "game list (reqid={d}) -> {d} game(s)", .{ reqid, n });

    for (games[0..n]) |g| {
        var buf: [64]u8 = undefined;
        var w = startPacket(&buf, MCP_GAMELIST);
        w.putU16(reqid); // +1 echo request id
        w.putU32(g.gameid); // +3 gameid (low u16 = dedup key)
        w.putU8(@intCast(@min(g.players, 255))); // +7 player count (PLAYERS column)
        w.putU32(g.gameid); // +8 token (non -1/-2 -> treated as a real game entry)
        w.putStr(g.name_slice()); // +0xc game name (shown in the list)
        w.putStr(""); // description
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

// MCP_GAMEINFO (0x06). Request: u16 reqid, cstr gamename. Populates the join-screen
// detail panel. We mirror the verified 0x05 per-game layout but set the token to -1 so
// the client cleanly shows "no detail" (Incoming0x06 maps -1 -> result 0x32 and returns
// before parsing the server-name/player-list area). Join still works without it; the
// full player-list layout is a live-client follow-up.
fn onGameInfo(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const reqid = r.getU16();
    const name = r.getStr();
    const exists = state.global.findGame(name) != null;
    log.line(tag, "game info '{s}' -> {s}", .{ name, if (exists) "exists (no detail)" else "not found" });
    var buf: [32]u8 = undefined;
    var w = startPacket(&buf, MCP_GAMEINFO);
    w.putU16(reqid); // +1 reqid echo
    w.putU32(0); // +3 unused
    w.putU8(0); // +7 status
    w.putU32(0xFFFF_FFFF); // +8 token = -1 -> "no info" (early return, no name parse)
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

// MCP_LADDERDATA (0x11). Request: u8 mode, u16 reqid. Reply with the realm's characters
// ranked by level. Wire format reversed from NET_MCP_CLIENT_Incoming0x11 @0x44afc0 +
// CHATDLG_HandleChatListClick @0x4403f0: after the id, [u8 flag][u16 total][u16 chunk]
// [u16 offset][data]; `data` (sent as one chunk) = [u32 rankBase=0][u32 count][u32 entrySize]
// then count entries of [u32 expLo][u32 expHi][u32 charStats][entrySize-byte name]. charStats
// = class(&0xf) | died<<4 | expansion<<5 | hardcore<<6 | progression<<8 | level<<16. Empty
// realm -> the all-zero "empty ladder" form. count/entrySize are capped (<=256 / <=16) by the
// client parser. Experience lives in the .d2s stat section (not the header) so we rank by level.
const ladder_max = 200;
const ladder_entry_size: u32 = 16; // name field width

const LadderEntry = struct { name: [16]u8 = .{0} ** 16, stats: u32 = 0 };

fn ladderLevelDesc(_: void, a: LadderEntry, b: LadderEntry) bool {
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
            var save: [256]u8 = undefined;
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
            out[n] = .{ .stats = stats };
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
    std.sort.pdq(LadderEntry, entries[0..n], {}, ladderLevelDesc);
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
        w.putU32(0); // experience low (not in the .d2s header)
        w.putU32(0); // experience high
        w.putU32(e.stats);
        w.putBytes(&e.name);
    }
    finish(c, &w);
}

// MCP_CHARUPGRADE (0x18). Request: cstr charname (classic -> expansion conversion).
// We run an expansion-only realm, so we accept it (Incoming0x18 reads result@u32 and
// marks success). Mutating the .d2s expansion flag needs a checksum rewrite + a live
// client to verify, so that part is deliberately deferred — the ack keeps the UI happy.
fn onCharUpgrade(c: *DConn, tag: []const u8, body: []const u8) void {
    var r = proto.Reader.init(body);
    const name = r.getStr();
    log.line(tag, "char upgrade '{s}' (account={s}) -> ack (save unchanged)", .{ name, c.accountName() });
    var buf: [12]u8 = undefined;
    var w = startPacket(&buf, MCP_CHARUPGRADE);
    w.putU32(0); // result: success
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

// MCP_CHARRANK (0x16). Request: cstr charname, u32, u32. Cosmetic ranking lookup; the
// client has no Incoming0x16, so there's no reply to send. Acknowledge in the log.
fn onCharRank(c: *DConn, tag: []const u8, body: []const u8) void {
    _ = c;
    _ = body;
    log.line(tag, "char rank request (no ladder; no-op)", .{});
}
