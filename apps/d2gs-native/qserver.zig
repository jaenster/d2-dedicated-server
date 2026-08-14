//! The engine's own dedicated-server entry points, called directly.
//!
//! Same shape as `apps/d2gs/engine/server.zig` `bootstrapRealmServer()` on Windows: allocate the
//! QServer, publish the game-state struct, raise the running flag, then tick it forever. The Mac
//! build has no server application mode to boot into (bootstrap slot 2 is `{0, 0}`), so instead of
//! reconstructing the sequence blind, `NET_QServer_StartServer` 0x00073ac3 case 6/8 is read as the
//! image's own worked example of the call order — it is the Windows list minus the realm table,
//! with game type 1 and a local-client dial-out on the end. Both of those are wrong for a game
//! server, so they are the two things not replayed here.

const std = @import("std");
const macho = @import("macho");
const gslink = @import("gslink.zig");

var image: *const macho.load.Loaded = undefined;

/// Verified against the disassembly of `NET_QServer_StartServer` (case 6/8) and
/// `QSERVER_CooperativeThreadMain` 0x0006fd13. All of them are `__cdecl`: the Mac build passes
/// arguments in `[esp]`, `[esp+4]`, … rather than the Windows build's `__stdcall`.
const addr = struct {
    /// The client state machine's dispatch table. Entry 3 is the state it starts in.
    const pf_modes: u32 = 0x003cfc30;
    /// (eConnectionType, eGameType) -> pQServer 0x00552564. Forwards to the QServer constructor
    /// 0x002f3494 with the listener port immediate 0xfa0 = 4000 and the four packet callbacks.
    const qserver_create_and_init: u32 = 0x002ddfa7;
    /// The name is the engine's; the field it sets is the per-source-IP connection limit.
    const net_set_players_count: u32 = 0x002de00a;
    const net_hack_set_use_qserver_hack: u32 = 0x002de030;
    /// (pGameState, cookie) — fatals when either is zero, and stores the first to 0x005375a4.
    const qserver_set_global_instance: u32 = 0x001abe46;
    const qserver_initialize_server_state: u32 = 0x001abbf2;
    const qserver_tick_all_games: u32 = 0x001ae778;
    const net_d2gs_server_handle_any_incoming_packet: u32 = 0x001ade1c;
    const qserver_dispatch_and_cleanup: u32 = 0x001ae82b;
    const mac_sleep: u32 = 0x0002c035;

    /// The two globals `NET_QServer_StartServer` hands `QSERVER_SetGlobalInstance`, read out of the
    /// position-independent pointer slots 0x00396134 and 0x00396128 it loads them from.
    const gQServerGameState: u32 = 0x005c15f4;
    const qserver_state_cookie: u32 = 0x005c1670;
    /// One byte, not the Windows build's dword.
    const gbQServerRunning: u32 = 0x00441cf1;

    /// D2BattleNetEventCallbackTable* (win: BattleNetServerService 0x00883d50). Read at
    /// 0x001a78bc by the GAMELOGON handler; the Mac image has no writer for it at all, so it
    /// is permanently null and every join takes the no-realm branch.
    const battle_net_server_service: u32 = 0x005c8a50;
    /// uint32[0x401] token -> game-server id (win: DATA_LastGameServer). Indexed by the u16
    /// game token at 0x001abd1f; zero or -1 means "no such game".
    const token_table: u32 = 0x0053756c;
};

/// CONNECTIONTYPE_SERVER — the dedicated path, the same 0 the host branch passes.
const connectiontype_server: u32 = 0;
/// GAMETYPE_BNET — many games addressed by realm token. The Mac menu path can only ask for 1, one
/// game dialed by address, which is the wrong shape for a game server.
const gametype_bnet: u32 = 3;
/// Every client arrives through one gateway, so a per-source-IP limit would cap the whole realm.
const per_ip_unlimited: i32 = -1;

/// Take over the client state machine before its first state runs.
///
/// `fAPPMODE_client_ReturnAppMode` 0x0005dc61 initialises the memory managers, runs
/// `LoadDataForGame`, loads the string and txt tables, and only then enters the state machine at
/// state 3. Replacing that entry therefore inherits a fully loaded engine and skips everything a
/// server does not want: the single TCP/IP game, the local player, and the frame loop.
pub fn install(loaded: *const macho.load.Loaded) void {
    image = loaded;
    const slot: *u32 = @ptrFromInt(loaded.at(addr.pf_modes + 3 * 4));
    // The slot is a 32-bit function pointer because the image is i386. Truncating is only sound
    // where our own code is also below 4 GiB, which is why the host refuses to run the image
    // anywhere else — but the truncation still has to COMPILE on a 64-bit developer machine, since
    // that is where `--dry-run` and the tests live.
    slot.* = @truncate(@intFromPtr(&run));
}

fn run() callconv(.c) u32 {
    bootstrap();
    while (true) tick();
}

fn bootstrap() void {
    call(addr.qserver_create_and_init, fn (u32, u32) callconv(.c) void)(connectiontype_server, gametype_bnet);
    call(addr.net_set_players_count, fn (i32) callconv(.c) void)(per_ip_unlimited);
    call(addr.net_hack_set_use_qserver_hack, fn (u32) callconv(.c) void)(0);
    call(addr.qserver_set_global_instance, fn (usize, usize) callconv(.c) void)(
        image.at(addr.gQServerGameState),
        image.at(addr.qserver_state_cookie),
    );
    running().* = 1;
    call(addr.qserver_initialize_server_state, fn () callconv(.c) void)();
    note("d2gs-native: QSERVER running={d} on :4000\n", .{running().*});
    reportJoinPreconditions();
    // Only now: the link answers a create by calling into the engine, so it must not be reachable
    // before the server state it creates games in exists.
    gslink.start(image);
}

/// The two things the GAMELOGON handler consults before it will let anyone in, printed once so a
/// refusal can be read off the log instead of guessed at. With no realm callback table the engine
/// only serves game token 1, and only while that token holds a live game.
fn reportJoinPreconditions() void {
    const bnet: *const u32 = @ptrFromInt(image.at(addr.battle_net_server_service));
    const tokens: [*]const u32 = @ptrFromInt(image.at(addr.token_table));
    note("d2gs-native: BattleNetServerService={x} token[1]={x}\n", .{ bnet.*, tokens[1] });
}

/// One server heartbeat, as `QSERVER_CooperativeThreadMain` runs it: drain the sockets, advance
/// every live game, then flush what the games queued back out. Exactly one sleep per pass either
/// way — that is the engine's own pacing, and skipping it is what burns a core.
fn tick() void {
    // Not gated on a realm being attached: the empty-game reap is a byte patch on the engine and
    // applies to a game a client made for itself just as much as to one the realm asked for.
    gslink.holdGameForItsFirstPlayer();
    // Before the packet drain, so a game the realm asked for exists before the client that was
    // told about it can send its join.
    gslink.pump();
    call(addr.net_d2gs_server_handle_any_incoming_packet, fn () callconv(.c) void)();
    const sleep = call(addr.mac_sleep, fn (u32) callconv(.c) void);
    if (call(addr.qserver_tick_all_games, fn (u32) callconv(.c) u32)(1) != 0) {
        _ = call(addr.qserver_dispatch_and_cleanup, fn (usize, u32) callconv(.c) u32)(0, 0);
        sleep(30);
    } else {
        sleep(10);
    }
}

fn call(comptime static_addr: u32, comptime Fn: type) *const Fn {
    return @ptrFromInt(image.at(static_addr));
}

fn running() *u8 {
    return @ptrFromInt(image.at(addr.gbQServerRunning));
}

/// Unbuffered, for the same reason main.zig's is: this has to survive a fault.
fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}
