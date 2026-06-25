//! Realm (D2CS / D2DBS) callback table for the GS.
//!
//! The engine null-guards every slot before calling it (verified in
//! NET_D2GS_SERVER_ProcessClientMessage_System @0x0052cc20 and
//! NET_D2GS_SERVER_SrvJoinGame @0x0052fa50 ), so an all-null table is a SAFE
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
const d2dbs = @import("../realm/client/d2dbs.zig");
const joinctx = @import("../realm/client/joinctx.zig");
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

// Pending character delivery. fpGetDatabaseCharacter is meant to be async (the
// real d2dbs reply arrives as a SEPARATE event); delivering synchronously from
// inside the callback runs OnDatabaseCharacterReceived before SrvJoinGame's
// ClientSetDwSaveTo1 and leaves the join half-set-up. So the callback fetches the
// save and queues it here, and the tick loop (pumpDelivery) delivers it once the
// engine's join call stack has fully unwound.
const Pending = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    client_id: u32 = 0,
    container: ?*anyopaque = null,
    len: u32 = 0, // 0 = fetch failed (refuse the join)
};
var pending: Pending = .{};

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

    // Queue the delivery for the tick loop; do NOT call OnDatabaseCharacterReceived
    // synchronously here (see Pending).
    load_filetimes = .{ @truncate(@intFromPtr(&load_filetime)), 0 };
    pending.client_id = @intCast(client_id);
    pending.container = container;
    pending.len = if (save_len > 0 and save_len <= 0xFFFF) @intCast(save_len) else 0;
    pending.ready.store(true, .release);
    log.hex("realm:   save fetched, queued for delivery bytes=0x", save_len);
    return 0;
}

/// Deliver a queued character save to the engine, OUTSIDE the join call stack.
/// Call once per server tick. len==0 means the fetch failed → refuse the join.
pub fn pumpDelivery() void {
    if (!pending.ready.swap(false, .acquire)) return;
    if (pending.len == 0) {
        log.print("realm:   char fetch FAILED — refusing join");
        _ = OnDatabaseCharacterReceived(pending.client_id, &save_buf, 0, 0, 1, 0, &load_filetimes, pending.container);
        return;
    }
    _ = OnDatabaseCharacterReceived(pending.client_id, &save_buf, pending.len, pending.len, 0, 0, &load_filetimes, pending.container);
    log.print("realm:   char delivered (SendStateCommand 2)");
}

pub const getDatabaseCharShim = fastcall.Callback2(2, getDatabaseCharImpl).shim;

// ── fpSaveDatabaseCharacter (slot 0x0C) ──────────────────────────────────────
// The engine persists a player via SaveAllPlayers @0x52ca10 → SaveGameAllGameTypes
// @0x532400 → SaveToFileBnet @0x531eb0, which calls this callback whenever the save
// CHANGED (every ~8192 frames / 5.5 min, and on leave/disconnect). __fastcall, same
// family as fpGetDatabaseCharacter: ECX = account-name string, EDX = &{ u16 size; .d2s
// bytes } (size = .d2s_len + 2; the .d2s starts at EDX+2), + 2 stack (total size, the
// client container), ret 0x8. The char name lives INSIDE the .d2s (offset 0x14, 16 bytes);
// we extract it, validate the 0xaa55aa55 signature, and push the bytes to D2DBS (which
// realmd persists to <data>/chars/<account>/<char>.d2s). Outbound-only — safe to run
// synchronously on the tick thread (unlike the load, which re-enters the engine).
// __fastcall ECX+EDX+4 stack (6 args), ret 0x10 — confirmed by disassembly + a runtime
// arg dump. ECX=&realmId, EDX/s1=name strings, s2=&{ u16 size; .d2s }, s3=total size,
// s4=client container. The save buffer is s2 (size = .d2s_len+2, .d2s starts at s2+2);
// the char name is read from the .d2s (offset 0x14) and the account is resolved from the
// join context — the same source the load used, so the save lands on the load's path.
fn saveDatabaseCharImpl(ecx: usize, edx: usize, s1: usize, s2: usize, s3: usize, s4: usize) callconv(.c) usize {
    _ = .{ ecx, edx, s1, s3, s4 };
    const buf: [*]const u8 = @ptrFromInt(s2);
    const total: usize = std.mem.readInt(u16, buf[0..2], .little);
    if (total < 2 + 0x24) {
        log.hex("realm: fpSaveDatabaseCharacter — save too small size=0x", total);
        return 0;
    }
    const d2s = buf[2..total]; // the raw .d2s (length = total - 2)
    const sig = std.mem.readInt(u32, d2s[0..4], .little);
    if (sig != 0xaa55aa55) {
        log.hex("realm: fpSaveDatabaseCharacter — bad .d2s signature 0x", sig);
        return 0;
    }
    const char_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d2s[0x14])), 0);
    const account = joinctx.accountForChar(char_name) orelse char_name;

    log.print("realm: fpSaveDatabaseCharacter — persisting char");
    log.cstr("realm:   char=", @intFromPtr(&d2s[0x14]));
    log.hex("realm:   bytes=0x", d2s.len);

    if (!dbs_ready) {
        log.print("realm:   no d2dbs source — save dropped");
        return 1;
    }
    if (d2dbs.connectTo(dbs_host, dbs_port)) {
        const ok = d2dbs.saveCharSave(account, char_name, d2s);
        d2dbs.disconnect();
        log.print(if (ok) "realm:   char saved to d2dbs" else "realm:   d2dbs save FAILED");
    } else {
        log.print("realm:   d2dbs connect failed — save dropped");
    }
    return 1;
}

pub const saveDatabaseCharShim = fastcall.Callback2(4, saveDatabaseCharImpl).shim;

// ── fpLeaveGame (slot 0x04) ──────────────────────────────────────────────────
// Called from CleanUpClient when a client leaves/disconnects. The engine
// IsBadCodePtr-checks it (a null pointer reads as a bad code pointer and HALTS),
// so it MUST be a valid function even if we do nothing with the leave yet. It is
// __fastcall with ECX=&pClient->pRealm, EDX + 18 stack args (counted at the call
// site) and its return is ignored — so a stack-balancing no-op (`ret 0x48`,
// 18*4 bytes of callee cleanup) is a safe stub.
fn leaveGameStub() callconv(.naked) void {
    asm volatile ("ret $0x48");
}

// ── fpGetDatabaseFileTime (slot 0x54) ────────────────────────────────────────
// CalculateGetFlags @0x569d80 calls this through the table WITHOUT an
// IsBadCodePtr guard (it only checks IsBattleNetServer), so a null pointer is a
// straight call-to-zero crash during the char load. __fastcall ECX = FILETIME*
// out (no stack args). It supplies the char's stored save timestamp for
// save-conflict/rollback checks; a zeroed filetime ("oldest") makes any loaded
// save count as current, which is what we want for a fresh realm load.
fn getFileTimeStub() callconv(.naked) void {
    asm volatile (
        \\movl $0, (%ecx)
        \\movl $0, 4(%ecx)
        \\ret
    );
}

/// Populate the realm callback table. Call before SetupAsBnetServer (i.e. before
/// bootstrapRealmServer). Wires the char loader + token validation + leave.
pub fn init() void {
    table.fpGetDatabaseCharacter = @ptrCast(&getDatabaseCharShim);
    table.fpSaveDatabaseCharacter = @ptrCast(&saveDatabaseCharShim);
    table.fpLeaveGame = @ptrCast(&leaveGameStub);
    table.fpGetDatabaseFileTime = @ptrCast(&getFileTimeStub);
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

    // Token validation ported from D2Server.dll 1.00 PlayerToken_ValidateAndConsume:
    // the realm (realmd/d2cs) issued this join token via joinctx.remember; the GS
    // validates it here — known + unconsumed + within the 120s TTL — and consumes it
    // once so it can't be replayed. Default is OBSERVE-ONLY: the legacy path accepted
    // every join, and s1==issued-token isn't yet confirmed in a live join, so we only
    // log the verdict. Flip `enforce_token` true once a live join shows "token VALID"
    // to close the accept-all gap (then unknown/stale/replayed tokens are rejected).
    const enforce_token = false;
    const token = @as(u32, @truncate(s1));
    const token_valid = joinctx.validate(token);
    log.print(if (token_valid) "realm:   token VALID (known, fresh)" else "realm:   token UNKNOWN/STALE/USED");
    if (enforce_token) {
        if (!token_valid) return 0; // reject: unknown, replayed, or expired token
        joinctx.consume(token);
    }
    return 1; // accept — join proceeds to char load
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
