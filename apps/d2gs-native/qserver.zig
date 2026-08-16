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
const realm = @import("realm.zig");

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

    /// `QSERVER_ServerThread`'s two unguarded uses of a client socket — see `guardClosedSockets`.
    const closed_socket_clear_jnz: u32 = 0x002f5a76;
    const socket_index_site: u32 = 0x002f5c34;
    const socket_index_resume: u32 = 0x002f5c39;
    const server_thread_next_client: u32 = 0x002f5f13;
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
    guardClosedSockets(loaded);
}

/// Stop `sServerThread` indexing its `fd_set` with a socket that has since been closed.
///
/// The listener thread snapshots each client's socket into an `fd_set` (skipping -1), then reads
/// the socket twice more around `select`, both times without the check. A player leaving a game
/// closes that socket in between: `-1 >> 5` == 0x07ffffff, so `readfds[socket >> 5]` lands half a
/// gigabyte past the thread's stack frame — the crash a returning client hits (reporter names
/// 0x002f5c40, ECX = 0xffffffff):
///   0x002f5a78  AND byte ptr [EBP + 0x1ffffe67], 0x7f  — constant already folded by the compiler
///   0x002f5c40  MOV ESI, dword ptr [EBP + EBX*4 - 0x218]  — EBX = socket >> 5, freshly reloaded
///
/// Site 1 (inside `if (socket == -1)`) can only fault — its `JNZ` past the block becomes an
/// unconditional `JMP`. Site 2 is the live path: patched to the bounds test the engine never wrote,
/// jumping to the loop's next-client at 0x002f5f13 (`MOV EAX, 1` is exactly 5 bytes, EAX/flags dead).
fn guardClosedSockets(loaded: *const macho.load.Loaded) void {
    // The guard below is i386 instructions; there is no image running anywhere else to patch.
    if (comptime @import("builtin").cpu.arch != .x86) return;

    const jnz: [*]u8 = @ptrFromInt(loaded.at(addr.closed_socket_clear_jnz));
    jnz[0] = 0xeb;

    socket_index_resume = @truncate(loaded.at(addr.socket_index_resume));
    server_thread_next_client = @truncate(loaded.at(addr.server_thread_next_client));

    const site = loaded.at(addr.socket_index_site);
    const rel: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(&socketIndexGuard))) -% @as(u32, @truncate(site + 5)));
    const at: [*]u8 = @ptrFromInt(site);
    at[0] = 0xe9;
    std.mem.writeInt(i32, at[1..5], rel, .little);
}

/// Filled in by `guardClosedSockets`; the guard jumps back through them rather than through a
/// relative displacement it would have to compute against the slide.
export var socket_index_resume: u32 = 0;
export var server_thread_next_client: u32 = 0;

/// ECX is the socket the thread just reloaded. Past the end of an `fd_set` it belongs to nobody, so
/// this client is skipped — ESI restored first, exactly as the engine's own skip at 0x002f5c52 does.
fn socketIndexGuard() callconv(.naked) void {
    asm volatile (
        \\cmpl $0x400, %%ecx
        \\jae 1f
        \\movl $1, %%eax
        \\jmp *socket_index_resume
        \\1:
        \\movl %%edi, %%esi
        \\jmp *server_thread_next_client
    );
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
    realm.start(image);
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
    realm.holdGameForItsFirstPlayer();
    // Before the packet drain, so a game the realm asked for exists before the client that was
    // told about it can send its join.
    realm.pump();
    call(addr.net_d2gs_server_handle_any_incoming_packet, fn () callconv(.c) void)();
    const sleep = call(addr.mac_sleep, fn (u32) callconv(.c) void);
    // Not `QSERVER_TickAllGames`: it services the one game in `gpGameTable[1]` on a single global
    // budget, so calling it once per hosted game would advance the first and skip the rest.
    if (realm.tickGames()) sleep(30) else sleep(10);
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
