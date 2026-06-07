//! Battle.net / Diablo II realm protocol constants, as typed enums.
//!
//! Sourced from bnetdocs.org (clean-room: values only, no GPL code):
//!   - Chat flags ............... https://bnetdocs.org/document/15
//!   - D2GS accept sequence ..... https://bnetdocs.org/document/28
//!
//! Flag enums are `enum(u32)` of single-bit values; combine with
//! `@intFromEnum(a) | @intFromEnum(b)` and test with `has(bits, flag)`.

/// User flags in SID_CHATEVENT (per-user state in a channel).
pub const ChatUserFlag = enum(u32) {
    blizzard_rep = 0x0000_0001, // Blizzard Representative
    operator = 0x0000_0002, // Channel Operator
    speaker = 0x0000_0004, // Channel Speaker
    bnet_admin = 0x0000_0008, // Battle.net Administrator
    no_udp = 0x0000_0010, // No UDP Support
    squelched = 0x0000_0020, // Squelched
    special_guest = 0x0000_0040, // Special Guest
    reserved = 0x0000_0080,
    beep_enabled = 0x0000_0100,
    pgl_player = 0x0000_0200,
    pgl_official = 0x0000_0400,
    kbk_player = 0x0000_0800,
    wcg_official = 0x0000_1000, // WCG Official / Diablo II Referee
    kbk_singles = 0x0000_2000, // KBK Singles
    kbk_beginner = 0x0001_0000,
    white_kbk = 0x0002_0000, // White KBK (1 bar)
    gf_official = 0x0010_0000, // GF Official / Diablo II Referee
    gf_player = 0x0020_0000,
    pgl_player2 = 0x0200_0000,
    _,
};

/// Channel flags in SID_CHATEVENT (channel-level state).
pub const ChatChannelFlag = enum(u32) {
    public = 0x0000_0001, // Public Channel
    moderated = 0x0000_0002,
    restricted = 0x0000_0004,
    silent = 0x0000_0008,
    system = 0x0000_0010,
    product_specific = 0x0000_0020,
    globally_accessible = 0x0000_1000,
    redirected = 0x0000_4000,
    chat = 0x0000_8000,
    tech_support = 0x0001_0000,
    _,
};

/// Client ↔ D2GS message IDs used in the join/accept handshake (document 28).
/// Our headless game server (the real 1.14d engine) speaks these natively; they
/// are kept here for reference and for any realm-side tracing of the handoff.
///
/// Sequence after a successful MCP_JOINGAME:
///   1. D2GS  → client: NEGOTIATE_COMPRESSION (0xAF)
///   2. client → D2GS:  GAME_LOGON           (0x68)  — carries the join token
///   3. D2GS  → client: STARTGAME            (0x5C)  — framed `0x02 0x5C ...`
///   4. client → D2GS:  ENTER_GAME_ENVIRONMENT (0x6A) — single 0x6A byte
/// After step 4 the client is in-world; subsequent server messages are compressed.
pub const D2gsMsg = enum(u8) {
    negotiate_compression = 0xAF, // server → client
    game_logon = 0x68, // client → server
    startgame = 0x5C, // server → client (comp/start)
    enter_game_environment = 0x6A, // client → server
    _,
};

/// True if `bits` has `flag` set. `flag` is any of the flag enums above.
pub fn has(bits: u32, flag: anytype) bool {
    return (bits & @intFromEnum(flag)) != 0;
}
