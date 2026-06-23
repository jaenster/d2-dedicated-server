//! Bindings into 1.14d Game.exe's built-in dedicated-server engine.
//!
//! All addresses are absolute in the Game.exe 1.14d image (image base 0x00400000,
//! no ASLR). We still rebase off the actual module base defensively in case the
//! loader ever relocates the image.
//!
//! Source of truth: a decompiled/reconstructed map of retail 1.14d Game.exe
//! (D2Game/Game/Server.cpp, Fog/QServer/*, D2Client/ClientModeInGame.cpp).
//! Every address tagged `// VERIFIED` was cross-checked against the
//! reconstruction or disassembly of the retail binary — see VERIFY.md.

const std = @import("std");
const feature = @import("feature.zig");

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;

/// 1.14d preferred image base. Reconstruction uses absolute addresses against this.
const IMAGE_BASE: usize = 0x0040_0000;

/// Resolve an absolute 1.14d address against the real loaded base.
fn at(comptime abs_addr: usize) usize {
    const base = @intFromPtr(GetModuleHandleA(null));
    return base + (abs_addr - IMAGE_BASE);
}

/// All engine functions here are __stdcall (callconv `.x86_stdcall` in the recon).
const StdcallConv = std.builtin.CallingConvention{ .x86_stdcall = .{} };

fn stdcall(comptime abs_addr: usize, comptime Fn: type) *const Fn {
    return @ptrFromInt(at(abs_addr));
}

// ── enums (src/d2_enums.h) ──────────────────────────────────────────────────
pub const ConnectionType = enum(u32) {
    server = 0, // CONNECTIONTYPE_SERVER       — dedicated D2GS path
    singleplayer = 1,
    singleplayer_uncapped = 2,
};

pub const GameType = enum(u32) {
    singleplayer = 0,
    singleplayer_uncapped = 1,
    bnet_beta = 2,
    bnet = 3, // GAMETYPE_BNET — realm / multi-game, token-driven
    bnet_internal = 4,
};

// ── verified function bindings ──────────────────────────────────────────────
// D2Game/Game/Server.cpp

/// Allocate + wire the QServer (port 0xfa0 = 4000) with the D2Game packet
/// dispatch callbacks. Stores the instance in the global `pQServer`.
///   void QSERVER_CreateAndInit(eD2GSConnectionType, eD2GSGameType)
pub fn QSERVER_CreateAndInit(conn: ConnectionType, game: GameType) void {
    stdcall(0x0052b7a0, fn (u32, u32) callconv(StdcallConv) void)(@intFromEnum(conn), @intFromEnum(game)); // VERIFIED
}

/// Max players the QServer accepts.  void NET_SetPlayersCount(int)
pub fn NET_SetPlayersCount(n: u32) void {
    stdcall(0x0052b250, fn (u32) callconv(StdcallConv) void)(n); // VERIFIED
}

/// Toggle the QServer anti-hack throttle.  void NET_HACK_SetUseQServerHack(int)
pub fn NET_HACK_SetUseQServerHack(on: u32) void {
    stdcall(0x0052b280, fn (u32) callconv(StdcallConv) void)(on); // VERIFIED
}

/// Tick every live game once. `bLimitFrameSkip` matches the engine call (=1).
/// Returns engine-defined status. This is the server heartbeat.
///   int QSERVER_TickAllGames(int bLimitFrameSkip)
pub fn QSERVER_TickAllGames(limit_frame_skip: u32) u32 {
    return stdcall(0x0052fc20, fn (u32) callconv(StdcallConv) u32)(limit_frame_skip); // VERIFIED
}

/// Drain inbound packets queued by the QServer worker threads into game logic.
///   void NET_D2GS_SERVER_HandleAnyIncomingPacket(void)
pub fn NET_D2GS_SERVER_HandleAnyIncomingPacket() void {
    stdcall(0x0052cfe0, fn () callconv(StdcallConv) void)(); // VERIFIED
}

/// Dispatch queued outbound packets to clients (the per-frame flush) + cleanup.
/// The real cooperative server loop calls this after QSERVER_TickAllGames; without
/// it, packets queued via SendPacket_Helper (game flags, the state command, game
/// data, pongs) never reach the socket and a joining client times out.
///   int QSERVER_DispatchAndCleanup(uint* pnParam, int nParam)  — call (0,0)
pub fn QSERVER_DispatchAndCleanup(pn: usize, n: u32) void {
    _ = stdcall(0x0052fd90, fn (usize, u32) callconv(StdcallConv) u32)(pn, n); // VERIFIED 0052fd90
}

/// Create a battle.net (realm) game in the engine. Requires gpQServerGameState
/// (set by the bootstrap). `flags` (eD2ArenaFlags) encodes difficulty in bits
/// 12-14, expansion via ARENAFLAG_Expansion, gametype in bit 21. `p_game_id` is
/// an OUT pointer that receives the server token (the gameid) — must NOT be null.
/// Returns 1 on success (and *p_game_id set), 0 on failure.
///   BOOL GAME_CreateBattleNetGame(name, pass, desc, flags, template, reserved, ladder, WORD* pGameId)
pub fn GAME_CreateBattleNetGame(
    name: ?[*:0]const u8,
    pass: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    flags: u32,
    template_: u32,
    reserved: u32,
    ladder: u32,
    p_game_id: *u16,
) u32 {
    const f = stdcall(0x00530930, fn (u32, u32, u32, u32, u32, u32, u32, *u16) callconv(StdcallConv) u32); // VERIFIED
    return f(
        @intFromPtr(name orelse null),
        @intFromPtr(pass orelse null),
        @intFromPtr(desc orelse null),
        flags,
        template_,
        reserved,
        ladder,
        p_game_id,
    );
}

// eD2ArenaFlags bits used by GAME_CreateBattleNetGame (VERIFIED from the
// eD2ArenaFlags enum). GAME_CreateBattleNetGame sets pGame->bExpansion =
// (flags & ARENAFLAG_Expansion) != 0; a char with the expansion status bit can
// only join an expansion game (else error 0x18), so this bit MUST be right.
/// Bit 2 gates UpdateClients (ARENA_GetClientUpdateFlag = (eArenaFlags>>2)&1);
/// must be set or ticking the game asserts.
pub const ARENAFLAG_ClientUpdate: u32 = 0x04;
pub const ARENAFLAG_Hardcore: u32 = 0x800; // 2048
pub const ARENAFLAG_Expansion: u32 = 0x10_0000; // 1048576
// Bit 21 -> pGame->eGameType (GAME_CreateBattleNetGame: eGameType = (flags>>0x15)&1).
// Setting it marks the game NOT single-player, which would make the 0x01 GameFlags packet
// tell the client to render online NPC positions (e.g. Deckard Cain by the Act 5 waypoint).
// BUT it also routes CLIENT_LoadCharacterAndSendGameData down a different validation branch
// that refuses the join with nReason 0x19 (verified live: flag on -> every join refused;
// flag off -> joins succeed). So leave it CLEAR until that char-load path is understood —
// a working join beats Cain's cosmetic position.
pub const ARENAFLAG_Multiplayer: u32 = 0x20_0000; // 2097152 (bit 21) — intentionally NOT set
pub fn gameFlags(difficulty: u3, expansion: bool, hardcore: bool) u32 {
    var f: u32 = @as(u32, difficulty) << 12; // difficulty in bits 12-14
    f |= ARENAFLAG_ClientUpdate;
    if (expansion) f |= ARENAFLAG_Expansion;
    if (hardcore) f |= ARENAFLAG_Hardcore;
    return f;
}

// ── realm communication (D2CS / D2DBS bridge) ───────────────────────────────
// The GS calls back into this table to talk to the realm/database — same model
// as the 1.13 D2GS↔D2CS↔D2DBS. We implement the slots we need and register the
// table with SetupAsBnetServer; until then BattleNetServerService is null and
// the realm system-message path no-ops. Layout: D2Client/D2BattleNetEventCallbackTable.h
pub const BnetServerService = extern struct {
    fpCloseGame: ?*const anyopaque = null, // 0x00
    fpLeaveGame: ?*const anyopaque = null, // 0x04
    fpGetDatabaseCharacter: ?*const anyopaque = null, // 0x08 (client*, charName, clientId, accountName)
    fpSaveDatabaseCharacter: ?*const anyopaque = null, // 0x0C
    fpServerLogMessage: ?*const anyopaque = null, // 0x10
    fpEnterGame: ?*const anyopaque = null, // 0x14
    fpFindPlayerToken: ?*const anyopaque = null, // 0x18 — validate the token D2CS issued
    fpSaveDatabaseGuild: ?*const anyopaque = null, // 0x1C
    fpUnlockDatabaseCharacter: ?*const anyopaque = null, // 0x20
    fpReserved1: ?*const anyopaque = null, // 0x24
    fpUpdateCharacterLadder: ?*const anyopaque = null, // 0x28
    fpUpdateGameInformation: ?*const anyopaque = null, // 0x2C
    fpReserved2_systemMsg: ?*const anyopaque = null, // 0x30
    fpSetGameData: ?*const anyopaque = null, // 0x34
    fpRelockDatabaseCharacter: ?*const anyopaque = null, // 0x38
    fpLoadComplete: ?*const anyopaque = null, // 0x3C
    fpReserved3: ?*const anyopaque = null, // 0x40
    fpReserved4: ?*const anyopaque = null, // 0x44
    fpReserved5: ?*const anyopaque = null, // 0x48
    fpReserved6: ?*const anyopaque = null, // 0x4C
    fpReserved7: ?*const anyopaque = null, // 0x50
    fpGetDatabaseFileTime: ?*const anyopaque = null, // 0x54 — char timestamp for save-conflict resolution
    fpReserved8: ?*const anyopaque = null, // 0x58
    fpReserved9: ?*const anyopaque = null, // 0x5C
    fpReserved10: ?*const anyopaque = null, // 0x60
};

/// Register the realm callback table → sets BattleNetServerService + IsBattleNetServer=1.
/// Pass null to clear. void SetupAsBnetServer(D2BattleNetEventCallbackTable*)
pub fn SetupAsBnetServer(table: ?*const BnetServerService) void {
    stdcall(0x0052c0e0, fn (usize) callconv(StdcallConv) void)(@intFromPtr(table)); // VERIFIED 1.14d win:0052c0e0
}

/// Set the global QServer game-state pointer. HALTS if state is null; pass a
/// nonzero cookie to skip the second (also-halting) path. Needed for realm mode.
///   void QSERVER_SetGlobalInstance(D2QServerGameStateStrc*, int cookie)
pub fn QSERVER_SetGlobalInstance(state: *anyopaque, cookie: u32) void {
    stdcall(0x0052c0a0, fn (usize, u32) callconv(StdcallConv) void)(@intFromPtr(state), cookie); // VERIFIED 0052c0a0
}

/// Allocate the next free game token (1..0x400). uint32 QSERVER_GenerateToken()
pub fn QSERVER_GenerateToken() u32 {
    return stdcall(0x0052c170, fn () callconv(StdcallConv) u32)(); // VERIFIED 0052c170
}

/// Bind a token to a game-server id in the token table.
///   void QSERVER_PutNewGameOnTokenList(uint32 gameServerId, uint16 token)
pub fn QSERVER_PutNewGameOnTokenList(game_server_id: u32, token: u16) void {
    stdcall(0x0052c110, fn (u32, u16) callconv(StdcallConv) void)(game_server_id, token); // VERIFIED 0052c110
}

/// Initialize the gQServerGameState struct (its game hashtable + crit-sections
/// at +0x50). Operates on the static global directly. void QSERVER_InitializeServerState()
pub fn QSERVER_InitializeServerState() void {
    stdcall(0x00530690, fn () callconv(StdcallConv) void)(); // VERIFIED 0053 0690
}

/// Load + compile all D2Common data tables (txt/bin) — items, monsters, missiles,
/// skills, levels, etc. Game creation (RollSeed/Alloc*Control) needs these. The
/// client app-mode entry normally calls this; for a server-only boot we call it
/// ourselves. pMemory=0 is what retail passes (memory manager uses its pool id).
/// Depends on the memory managers + string tables already being initialized.
///   void TXT_InitTxtFiles(D2PoolManagerStrc*, int nZero2, int bGametypeIsOBNetHost)
pub fn TXT_InitTxtFiles(p_mem: usize, n_zero2: u32, b_obnet_host: u32) void {
    stdcall(0x00619300, fn (usize, u32, u32) callconv(StdcallConv) void)(p_mem, n_zero2, b_obnet_host); // VERIFIED 0061 9300
}

// ── engine globals (static, retail addresses; base 0x400000, no ASLR) ────────
// From zig-output/data/data_symbols.json.
pub const globals = struct {
    /// D2QServerGameStateStrc (104 bytes) — the server game-state struct.
    pub const gQServerGameState: usize = 0x007a_0690;
    /// u32 — server-running flag.
    pub const gbQServerRunning: usize = 0x007a_0458;
    /// D2QServerGameStateStrc* — set by SetGlobalInstance to &gQServerGameState.
    pub const gpQServerGameState: usize = 0x0088_3d38;
    /// D2BattleNetEventCallbackTable* — set by SetupAsBnetServer (realm table).
    pub const BattleNetServerService: usize = 0x0088_3d50;
};

// NOTE: realm callbacks are __fastcall (ECX/EDX register args + stack, callee
// cleanup), NOT stdcall — confirmed by disassembly. e.g. fpFindPlayerToken
// (slot 0x18) = ECX, EDX, + 7 stack args (9 total), `ret 0x1c`, returns int
// (nonzero = token valid). Implement BnetServerService slots with fastcall shims
// (Zig x86 fastcall is unreliable — use the naked-asm shims in fastcall.zig).

fn gptr(comptime abs_addr: usize, comptime T: type) *T {
    return @ptrFromInt(at(abs_addr));
}

/// Full dedicated-realm bootstrap. Mirrors NET_QServer_StartServer @0x0044bc30's
/// OBNET/LAN-host tail, minus the host-as-player-1 NET_D2GS_ConnectToServer, plus
/// SetupAsBnetServer to enable realm mode. `realm` may be null to run open (no
/// D2CS) — then BattleNetServerService stays null and the realm path no-ops.
pub fn bootstrapRealmServer(realm: ?*const BnetServerService) void {
    if (realm) |t| SetupAsBnetServer(t);
    QSERVER_CreateAndInit(.server, .bnet); // allocs pQServer, opens :4000 listener
    NET_SetPlayersCount(8);
    NET_HACK_SetUseQServerHack(0);
    QSERVER_SetGlobalInstance(@ptrFromInt(at(globals.gQServerGameState)), 1); // cookie≠0 → no halt
    gptr(globals.gbQServerRunning, u32).* = 1;
    // Game-data tables (levels/monstats/skills/NPC item tables/…) must be loaded
    // BEFORE QSERVER_InitializeServerState — it builds the NPC hireling tables from
    // this txt data, and game creation's AllocNpcControl/AllocMonsterRegion read it.
    // Depends on the memory managers brought up by QSERVER_CreateAndInit above.
    TXT_InitTxtFiles(0, 0, 1);
    QSERVER_InitializeServerState();
}

/// One tick of the server: drain inbound packets, advance all games, then flush
/// queued outbound packets to clients. Mirrors QSERVER_CooperativeThreadMain.
pub fn tick() void {
    NET_D2GS_SERVER_HandleAnyIncomingPacket();
    if (QSERVER_TickAllGames(1) != 0) {
        QSERVER_DispatchAndCleanup(0, 0);
    }
    // Fan out to feature serverTick() hooks. Per-game hooks (gameServerLoop,
    // gameCreate/Destroy with a GameCtx carrying the game's FOG-pool allocator)
    // are dispatched once the per-game pool pointer is wired from D2GameStrc.
    feature.fanServerTick();
}
