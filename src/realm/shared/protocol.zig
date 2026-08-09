//! PvPGN D2CS <-> D2GS control protocol (pvpgn-server 1.99.x).
//!
//! The GS opens an outbound TCP connection to D2CS. All packets share an 8-byte
//! little-endian header `{ size:u16, type:u16, seqno:u32 }` where `size` is the
//! total packet length including the header. D2CS drives auth + game create/join;
//! the GS replies and pushes game-info/close updates.
//!
//! Source: pvpgn-server src/common/d2cs_d2gs_protocol.h.

const std = @import("std");

pub const Header = extern struct {
    size: u16, // total packet length incl. header
    type: u16,
    seqno: u32,
};

pub const HEADER_LEN = @sizeOf(Header); // 8

/// Packet types. Same numeric value is reused per direction (see comments).
pub const Type = enum(u16) {
    authreq = 0x10, // D2CS -> GS  (sessionnum, signlen, realmname, keychecksum)
    authreply = 0x11, // GS -> D2CS (version, checksum, randnum, signlen, sign[128])
    setgsinfo = 0x12, // GS -> D2CS (maxgame, gameflag)
    echo = 0x13, // D2CS -> GS echoreq / GS -> D2CS echoreply
    control = 0x14, // D2CS -> GS (cmd: 1=restart, 2=shutdown; value)
    setinitinfo = 0x15, // D2CS -> GS
    setconffile = 0x16, // D2CS -> GS
    creategame = 0x20, // D2CS -> GS req / GS -> D2CS reply
    joingame = 0x21, // D2CS -> GS req / GS -> D2CS reply
    updategameinfo = 0x22, // GS -> D2CS
    closegame = 0x23, // GS -> D2CS
    addrinfo = 0x24, // GS -> D2CS (self-reported public addr + id; our extension)
    _,
};

// ── D2CS -> GS ──────────────────────────────────────────────────────────────

/// AUTHREQ (0x10): header + sessionnum + signlen, then realmname (cstr) + key checksum.
pub const AuthReqFixed = extern struct {
    h: Header,
    sessionnum: u32,
    signlen: u32,
    // followed by: realmname (null-terminated), then signlen bytes of key checksum
};

/// CONTROL (0x14).
pub const Control = extern struct {
    h: Header,
    cmd: u32, // 1 = restart, 2 = shutdown
    value: u32,
};

/// CREATEGAMEREQ (0x20): flags for the game D2CS wants spun up.
pub const CreateGameReq = extern struct {
    h: Header,
    ladder: u8,
    expansion: u8,
    difficulty: u8,
    hardcore: u8,
    // followed by: gamename (cstr), password (cstr), gamedesc (cstr) [pvpgn variant]
};

/// JOINGAMEREQ (0x21): a client wants into a game; `token` is what the engine's
/// fpFindPlayerToken validates.
pub const JoinGameReq = extern struct {
    h: Header,
    gameid: u32,
    token: u32,
};

// ── GS -> D2CS ──────────────────────────────────────────────────────────────

/// AUTHREPLY (0x11). `sign` is the realm-key signature; pvpgn can be configured
/// to skip verification — we send zeros and rely on that (see PVPGN notes).
pub const AuthReply = extern struct {
    h: Header,
    version: u32,
    checksum: u32,
    randnum: u32,
    signlen: u32,
    sign: [128]u8,
};

/// SETGSINFO (0x12): advertise capacity to D2CS.
pub const SetGsInfo = extern struct {
    h: Header,
    maxgame: u32,
    gameflag: u32,
};

/// ADDRINFO (0x24, our extension): the GS self-reports the public address clients
/// must dial for game traffic (`ip`:`port`), plus a stable `gsid` so D2CS can key a
/// fleet of game servers. Needed because behind a k8s Service the GS's control-conn
/// peer IP is SNAT'd and useless as the client-facing address. Field order is chosen
/// so there is no internal padding (offsets: maxgame@8 gsid@12 ip@16 port@20).
pub const AddrInfo = extern struct {
    h: Header,
    maxgame: u32,
    gsid: u32,
    ip: [4]u8, // network-order IPv4 octets
    port: u16, // host-order port the client dials (the GS game port, e.g. 4000)
};

/// CREATEGAMEREPLY (0x20). result: 0=ok, 1=fail.
pub const CreateGameReply = extern struct {
    h: Header,
    result: u32,
    gameid: u32,
};

/// JOINGAMEREPLY (0x21). result: 0=ok, 1=fail, 2=full.
pub const JoinGameReply = extern struct {
    h: Header,
    result: u32,
    gameid: u32,
};

/// CLOSEGAME (0x23). GS -> D2CS when a game is destroyed. The handler reads the
/// gameid at body offset 4 (the reserved word mirrors CreateGameReply's result
/// slot), then removeGameById drops it from the join list + redis indexes.
pub const CloseGame = extern struct {
    h: Header,
    reserved: u32 = 0,
    gameid: u32,
};

/// UPDATEGAMEINFO (0x22). GS -> D2CS whenever a game's population changes, so the join
/// screen's PLAYERS column tracks reality instead of the count realmd guessed at create
/// time. `players` is the GS's own client count *after* the change — a level, not a delta,
/// so a dropped message self-corrects on the next one and nothing can drift.
///
/// `flag` says which edge caused it (0=periodic update, 1=enter, 2=leave). The character
/// it happened to follows the struct as a C-string, with the level and class the join
/// screen's detail panel lists them by — realmd has no other way to learn who is in a
/// game, since it only ever sees the request to join, never the arrival.
pub const UpdateGameInfo = extern struct {
    h: Header,
    flag: u32,
    gameid: u32,
    players: u32,
    charlevel: u32,
    charclass: u32,
    // followed by: cstr charname
};

/// UPDATEGAMEINFO flag values.
pub const GAMEINFO_UPDATE: u32 = 0;
pub const GAMEINFO_ENTER: u32 = 1;
pub const GAMEINFO_LEAVE: u32 = 2;

/// Read the i-th null-terminated string from a packet body, starting at `off`.
/// Returns the slice (without the null) and advances `off` past the terminator.
pub fn readCStr(body: []const u8, off: *usize) []const u8 {
    const start = off.*;
    var i = start;
    while (i < body.len and body[i] != 0) : (i += 1) {}
    off.* = if (i < body.len) i + 1 else i;
    return body[start..i];
}

/// Build a header in-place for a packet of total length `size` and given type.
pub fn header(t: Type, size: u16, seqno: u32) Header {
    return .{ .size = size, .type = @intFromEnum(t), .seqno = seqno };
}
