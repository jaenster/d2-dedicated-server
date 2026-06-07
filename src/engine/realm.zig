//! Realm (D2CS / D2DBS) callback table for the GS.
//!
//! The engine null-guards every slot before calling it (verified in
//! NET_D2GS_SERVER_ProcessClientMessage_System @0x0052cc20 and
//! NET_D2GS_SERVER_SrvJoinGame @0x004665... ), so an all-null table is a SAFE
//! "realm mode on, no DB yet" state: SetupAsBnetServer sets IsBattleNetServer=1,
//! games can't be created/joined until we implement the slots — but nothing
//! crashes. Fill slots in one at a time as each signature is confirmed.
//!
//! ⚠ Slots are __fastcall (ECX/EDX register args + stack, callee-cleanup) —
//! confirmed by disassembly. Zig's x86 fastcall is buggy (ziglang/zig#10363), so
//! implement each slot as a `callconv(.naked)` shim that adapts fastcall→cdecl
//! and `ret`s the exact stack-arg byte count (see [[zig-fastcall-callbacks]] /
//! REALM.md). Wrong arg count corrupts the stack — confirm each per call site.

const std = @import("std");
const server = @import("server.zig");
const fastcall = @import("../runtime/fastcall.zig");
const d2dbs = @import("../realm/d2dbs.zig");
const joinctx = @import("../realm/joinctx.zig");
const log = @import("../log.zig");

/// The table we register via SetupAsBnetServer.
pub var table: server.BnetServerService = .{};

// CLIENT_OnDatabaseCharacterReceived @0x5306e0 (__stdcall) — hands an accumulated
// character save to the engine. With chunk==total==L the save is stored in one
// call (CLIENT_AccumulateSaveData marks it complete) and the engine advances the
// joining client to state 2 via SendStateCommand(2). On CsResult!=0 it logs the
// load error and disconnects the client cleanly. It validates pContainer against
// pClient->pClientContainer, so we pass the value read straight off the client.
const OnDatabaseCharacterReceived: *const fn (
    n_client_id: u32,
    p_save: [*]const u8,
    n_chunk: u32, // this-call chunk size (low 16 bits used)
    n_total: u32, // total save size (low 16 bits used)
    cs_result: i32, // 0 = success, nonzero = load error (disconnect)
    dw_param: u32,
    pn_filetimes: *const [2]u32, // [0] = FILETIME*, [1] = unk0x194
    p_container: ?*anyopaque, // must equal pClient->pClientContainer
) callconv(.winapi) u32 = @ptrFromInt(0x005306e0);

// D2DBS endpoint (realmd's d2dbs listener) the GS fetches character saves from.
var dbs_host: [*:0]const u8 = "";
var dbs_port: u16 = 0;
var dbs_ready = false;

/// Point the realm char loader at a D2DBS server (host = dotted-quad IPv4).
pub fn setDatabaseSource(host: [*:0]const u8, port: u16) void {
    dbs_host = host;
    dbs_port = port;
    dbs_ready = port != 0;
    log.print("realm: d2dbs char source set");
}

var save_buf: [16384]u8 = undefined;
var load_filetime: [2]u32 = .{ 0, 0 }; // a zeroed FILETIME (load-time placeholder)
var load_filetimes: [2]u32 = undefined; // { &load_filetime, unk0x194 }

// ── fpGetDatabaseCharacter (slot 0x08) ───────────────────────────────────────
// Called when a client joins (NET_D2GS_SERVER_SrvJoinGame): the GS asks the realm
// for the character's save. __fastcall: ECX=&pClient->pRealm, EDX=szPlayerName,
// +nClientId, +pAccountName (ret 0x8). We fetch the .d2s from D2DBS and deliver it
// synchronously via CLIENT_OnDatabaseCharacterReceived, which advances the join.
fn getDatabaseCharImpl(ecx: usize, edx: usize, client_id: usize, account: usize) callconv(.c) usize {
    _ = .{ edx, account };
    // ECX = &pClient->pRealm (offset 0x68). The client the engine built: szCharName
    // @0x0D (ECX-0x5B), szAccName @0x1D (ECX-0x4B), pClientContainer @0x60 (ECX-8).
    const sz_char: [*:0]u8 = @ptrFromInt(ecx -% 0x5B);
    const sz_acct: [*:0]u8 = @ptrFromInt(ecx -% 0x4B);
    const char_name = std.mem.sliceTo(sz_char, 0);

    // The engine never fills the account on this path, so resolve it from the
    // join context realmd sent over the gs-link (keyed by the joining char name),
    // and write it back into pClient->szAccName so the rest of the engine has it.
    const acct_name = joinctx.accountForChar(char_name) orelse
        std.mem.sliceTo(sz_acct, 0); // fall back to whatever the engine had
    if (acct_name.len > 0 and acct_name.ptr != sz_acct) {
        const n = @min(acct_name.len, 63);
        @memcpy(sz_acct[0..n], acct_name[0..n]);
        sz_acct[n] = 0;
    }

    log.print("realm: fpGetDatabaseCharacter — fetching char");
    log.cstr("realm:   char=", ecx -% 0x5B);
    log.cstr("realm:   account=", ecx -% 0x4B);

    const container_slot: *const usize = @ptrFromInt(ecx -% 8);
    const container: ?*anyopaque = @ptrFromInt(container_slot.*);

    var save_len: usize = 0;
    if (dbs_ready and d2dbs.connectTo(dbs_host, dbs_port)) {
        save_len = d2dbs.fetchCharSave(acct_name, char_name, &save_buf);
        d2dbs.disconnect();
    }

    if (save_len == 0 or save_len > 0xFFFF) {
        log.print("realm:   char fetch FAILED — disconnecting client");
        // CsResult != 0 → engine logs the load error and disconnects cleanly
        // (avoids the half-built-client cleanup crash).
        _ = OnDatabaseCharacterReceived(@intCast(client_id), &save_buf, 0, 0, 1, 0, &load_filetimes, container);
        return 0;
    }

    load_filetimes = .{ @truncate(@intFromPtr(&load_filetime)), 0 };
    const len: u32 = @intCast(save_len);
    log.hex("realm:   delivering save bytes=0x", save_len);
    _ = OnDatabaseCharacterReceived(@intCast(client_id), &save_buf, len, len, 0, 0, &load_filetimes, container);
    log.print("realm:   char delivered (SendStateCommand 2)");
    return 0;
}

pub const getDatabaseCharShim = fastcall.Callback2(2, getDatabaseCharImpl).shim;

/// Populate the realm callback table. Call before SetupAsBnetServer (i.e. before
/// bootstrapRealmServer). Wires the char loader + token validation.
pub fn init() void {
    table.fpGetDatabaseCharacter = @ptrCast(&getDatabaseCharShim);
    enableTokenValidation(); // register fpFindPlayerToken (engine IsBadCodePtr-checks it)
}

// ── fpFindPlayerToken (slot 0x18) ────────────────────────────────────────────
// __fastcall: ECX + EDX + 7 stack args, callee-cleanup ret 0x1c, returns int
// (nonzero = token valid → join proceeds; 0 = reject). The shim adapts the
// engine's fastcall ABI to this plain cdecl handler. NOT registered yet — fill
// the out-param pointers + validate against D2CS first, then enableTokenValidation().
fn findPlayerTokenImpl(
    ecx: usize,
    edx: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
) callconv(.c) usize {
    _ = .{ ecx, edx };
    // s1 = game token (last pushed), s2..s7 = out-param pointers the engine reads
    // back. Log them so we can map each out-param, then accept the join.
    log.print("realm: fpFindPlayerToken — client joining");
    log.hex("realm:   token=0x", s1);
    log.hex("realm:   s2=0x", s2);
    log.hex("realm:   s3=0x", s3);
    log.hex("realm:   s4=0x", s4);
    log.hex("realm:   s5=0x", s5);
    log.hex("realm:   s6=0x", s6);
    log.hex("realm:   s7=0x", s7);
    return 1; // accept (token valid) — join proceeds to char load
}

pub const findPlayerTokenShim = fastcall.Callback2(7, findPlayerTokenImpl).shim;

/// Wire fpFindPlayerToken into the table (call before SetupAsBnetServer). Not
/// invoked yet — staged until the handler is implemented.
pub fn enableTokenValidation() void {
    table.fpFindPlayerToken = @ptrCast(&findPlayerTokenShim);
}

// Slots to implement, bridging to the user's D2CS/D2DBS (priority order):
//   fpFindPlayerToken      0x18  validate the join token D2CS issued
//   fpGetDatabaseCharacter 0x08  load char save  (→ D2DBS)
//   fpSaveDatabaseCharacter0x0C  persist char save
//   fpUnlock/Relock        0x20/0x38  char lock (anti-dupe)
//   fpEnter/Leave/CloseGame0x14/0x04/0x00  lifecycle → realm
//   fpUpdateCharacterLadder0x28 ; fpUpdateGameInformation 0x2C
//   fpServerLogMessage     0x10  logging
//   fpGetDatabaseFileTime  0x54  save-conflict timestamp
//
// Example (once a signature is confirmed — NOT yet wired):
//   fn serverLog(...) callconv(.{ .x86_stdcall = .{} }) void { ... }
//   pub fn init() void { table.fpServerLogMessage = @ptrCast(&serverLog); }
