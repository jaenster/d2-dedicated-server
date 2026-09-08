//! Realm (D2CS / D2DBS) callback table for the GS.
//!
//! The engine null-guards every slot (NET_D2GS_SERVER_ProcessClientMessage_System @0x0052cc20,
//! NET_D2GS_SERVER_SrvJoinGame @0x0052fa50), so an all-null table is SAFE: realm mode on, no DB
//! yet, nothing crashes, games just can't be created/joined.
//!
//! ⚠ Slots are __fastcall (ECX/EDX + stack, callee-cleanup); Zig's x86 fastcall is buggy
//! (ziglang/zig#10363), so each is a `.naked` shim adapting fastcall→cdecl and `ret`ing the exact
//! stack-arg byte count — a wrong count corrupts the stack, confirm per call site. The layout and
//! the shim construction come from packages/d2engine; the counts below are 1.14d's (`cb.v114d`)
//! and are NOT the pre-1.14 ones.

const std = @import("std");
const server = @import("server.zig");
const cb = @import("d2engine").callbacks;
const hostapi = @import("d2engine").hostapi;
const gsredis = @import("gs_store");
const joinctx = @import("gs_seats");
const obs = @import("obs");
const log = @import("../log.zig");

extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *[2]u32) callconv(.winapi) void;

/// The table we register via SetupAsBnetServer.
pub var table: server.BnetServerService = .{};

// CLIENT_OnDatabaseCharacterReceived @0x5306e0 (__stdcall) — hands a character save to the engine.
// chunk==total==L stores it in one call (CLIENT_AccumulateSaveData marks it complete) and advances the
// joining client to state 2 via SendStateCommand(2); CsResult!=0 logs the load error and disconnects.
// It validates pContainer against pClient->pClientContainer, so we pass the value read off the client.
// The same function the pre-1.14 host reaches as D2Game @10007 ("D2GSSendDatabaseCharacter"),
// so its shape lives in d2engine and only its location is per-version. Here arg 7 is
// {FILETIME*, unk0x194} and arg 8 is the client container, which the engine checks against
// pClient->pClientContainer.
const OnDatabaseCharacterReceived: *const hostapi.SendDatabaseCharacterFn =
    @ptrFromInt(hostapi.sendDatabaseCharacter(.v114d).?.address);

// Arg 7 of CLIENT_OnDatabaseCharacterReceived is a POINTER TO the two dwords of a FILETIME, not
// a pointer to a pointer: @0x5307e8 the engine does `eax=[ebp+0x20]; [edi+0x190]=[eax];
// [edi+0x194]=[eax+4]`, so both dwords land verbatim in pClient->pFileTime. That timestamp is the
// left-hand side of the CompareFileTime in CalculateGetFlags @0x569d80: a ladder character joins
// only while its save reads NEWER than the realm's stored copy, which for a single-authority store
// is always true. Filled per delivery with "now".
var load_filetime: [2]u32 = .{ 0, 0 };

// Pending character delivery. fpGetDatabaseCharacter is meant to be async, but calling
// OnDatabaseCharacterReceived synchronously runs it before SrvJoinGame's ClientSetDwSaveTo1 and
// leaves the join half-set-up — so it queues here and pumpDelivery delivers after the join call
// stack unwinds. One slot PER JOIN IN FLIGHT: a shared slot let two joins overwrite each other,
// dropping the first client's delivery (engine refused it with 0xe, "no player unit").
const Pending = struct {
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    client_id: u32 = 0,
    container: ?*anyopaque = null,
    len: u32 = 0, // 0 = fetch failed (refuse the join)
    save: [16384]u8 = undefined,
};
// Eight: a full game's worth of players can arrive together, and a slot is held only
// for the fetch plus the tick that drains it.
var pending: [8]Pending = blk: {
    var e: [8]Pending = undefined;
    for (&e) |*slot| slot.* = .{};
    break :blk e;
};

/// Take an unused delivery slot, or null if every join in flight already holds one.
fn claimPending() ?*Pending {
    for (&pending) |*slot| {
        if (slot.busy.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) return slot;
    }
    return null;
}

// fpGetDatabaseCharacter (slot 0x08)
// Called when a client joins (NET_D2GS_SERVER_SrvJoinGame): the GS asks the realm
// for the character's save. __fastcall: ECX=&pClient->pRealm, EDX=szPlayerName,
// +nClientId, +pAccountName (ret 0x8). We fetch the .d2s from D2DBS and deliver it
// synchronously via CLIENT_OnDatabaseCharacterReceived, which advances the join.
fn getDatabaseCharImpl(ecx: usize, edx: usize, client_id: usize, account: usize) callconv(.c) usize {
    _ = .{ edx, account };
    // Start the GS-side join trace (Phase 3 will adopt realmd's trace id from the wire
    // instead). Every log line through the rest of this join carries this trace id.
    _ = obs.startTrace();
    // ECX = &pClient->pRealm (offset 0x68). The client the engine built: szCharName
    // @0x0D (ECX-0x5B), szAccName @0x1D (ECX-0x4B), pClientContainer @0x60 (ECX-8).
    const sz_char: [*:0]u8 = @ptrFromInt(ecx -% 0x5B);
    const sz_acct: [*:0]u8 = @ptrFromInt(ecx -% 0x4B);
    const char_name = std.mem.sliceTo(sz_char, 0);

    // The engine never fills the account on this path, so resolve it from the
    // join context the realm sent with JOINGAME (keyed by the joining char name),
    // and write it back into pClient->szAccName so the rest of the engine has it.
    var acct_buf: [joinctx.max_account]u8 = undefined;
    const acct_name = joinctx.accountForChar(char_name, &acct_buf) orelse
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

    const slot = claimPending() orelse {
        // Refusing is the honest outcome and the client is told; silently returning
        // would leave it sitting at a loading screen until it timed out.
        log.print("realm:   no free delivery slot — too many joins at once, refusing");
        return 0;
    };

    var save_len: usize = 0;
    {
        // Straight from the shared store. Nothing is dialled first: gating this on a connection
        // to the realm is what kept the retired path alive after the fetch itself had moved — the
        // fetch was never reached when the dial failed, and it read as a broken store.
        var sp = obs.enter("char_fetch");
        defer sp.exit();
        // Versioned: every save this session makes is fenced against the version these bytes came
        // at, so a save built from them can never land on top of somebody else's newer ones.
        const loaded = gsredis.getCharVersioned(acct_name, char_name, &slot.save);
        save_len = loaded.len;
        if (save_len > 0) joinctx.setVersion(char_name, loaded.ver);
    }

    // The character is now this server's to save. Hold its account/char mapping until the engine
    // reports it gone: every save for the rest of the session is keyed by that account, and an
    // entry recycled from under a seated player sends their saves to a key nothing reads.
    if (save_len > 0) joinctx.seat(char_name);

    // Queue the delivery for the tick loop; do NOT call OnDatabaseCharacterReceived
    // synchronously here (see Pending).
    GetSystemTimeAsFileTime(&load_filetime);
    slot.client_id = @intCast(client_id);
    slot.container = container;
    slot.len = if (save_len > 0 and save_len <= 0xFFFF) @intCast(save_len) else 0;
    slot.ready.store(true, .release);
    log.hex("realm:   save fetched, queued for delivery bytes=0x", save_len);
    return 0;
}

/// Deliver every queued character save to the engine, OUTSIDE the join call stack.
/// Call once per server tick. len==0 means the fetch failed → refuse that join.
/// Drains ALL ready slots: leaving one for the next tick is how a client ends up
/// waiting on a character that was fetched and then never handed over.
pub fn pumpDelivery() void {
    for (&pending) |*slot| {
        if (!slot.ready.swap(false, .acquire)) continue;
        defer slot.busy.store(false, .release);
        if (slot.len == 0) {
            log.print("realm:   char fetch FAILED — refusing join");
            _ = OnDatabaseCharacterReceived(slot.client_id, &slot.save, 0, 0, 1, 0, &load_filetime, @intFromPtr(slot.container));
            continue;
        }
        _ = OnDatabaseCharacterReceived(slot.client_id, &slot.save, slot.len, slot.len, 0, 0, &load_filetime, @intFromPtr(slot.container));
        log.print("realm:   char delivered (SendStateCommand 2)");
    }
}

pub const getDatabaseCharShim = cb.Shim(cb.v114d, .fpGetDatabaseCharacter, getDatabaseCharImpl).shim;

/// Read a NUL-terminated engine string without trusting it to be terminated. Anything the engine
/// hands us as `char*` is read this way: a missing terminator would otherwise walk off the end of
/// its buffer, and the strings here decide where a save is written.
fn boundedCStr(ptr: usize, max: usize) []const u8 {
    if (ptr == 0) return "";
    const p: [*]const u8 = @ptrFromInt(ptr);
    var i: usize = 0;
    while (i < max) : (i += 1) {
        if (p[i] == 0) return p[0..i];
    }
    return "";
}

// fpSaveDatabaseCharacter (slot 0x0C). Called by SaveAllPlayers @0x52ca10 -> SaveGameAllGameTypes
// @0x532400 -> SaveToFileBnet @0x531eb0 whenever the save CHANGED (~8192 frames / 5.5 min, or on
// leave/disconnect). __fastcall ECX+EDX+4 stack (6 args), ret 0x10 (confirmed by disasm + runtime
// arg dump). The call site is 0x53220d and sets up:
//
//   ECX = &nRealmId       a local COPY of the realm id on SaveToFileBnet's own frame. It is NOT
//                         &pClient->pRealm, so the ECX-0x4B / ECX-0x5B trick that reads the
//                         client's names in fpGetDatabaseCharacter does not work here.
//   EDX = char*           the character name
//   s1  = char*           THE ACCOUNT NAME — a local buffer SaveToFileBnet filled from
//                         GetAccountName @0x5392f0 (`SStrCopy(szText, pClient->szAccName, 0x32)`).
//   s2  = &{u16 size; .d2s}   size = .d2s_len + 2, the save itself at s2+2
//   s3  = total size
//   s4  = client container    pClient->pClientContainer (offset 0x60) by value — an opaque BNet
//                             handle, not a pointer into D2ClientStrc.
//
// Char name is taken from .d2s offset 0x14 (16 bytes) after validating the 0xaa55aa55 signature
// rather than from EDX, because the save is the thing being written and its own header is what
// names it. Outbound-only — safe to run synchronously on the tick thread.
fn saveDatabaseCharImpl(ecx: usize, edx: usize, s1: usize, s2: usize, s3: usize, s4: usize) callconv(.c) usize {
    _ = .{ ecx, edx, s3, s4 };
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

    // The save is keyed by ACCOUNT, and getting that wrong is invisible: a save written under the
    // wrong account is a perfectly good save at an address no login path reads, so the player is
    // rolled back to whatever their last correctly-keyed save was and nothing reports a failure.
    // This used to fall back to the CHARACTER's own name, writing `realmd:char:<Char>:<Char>`.
    //
    // Two sources, in this order:
    //
    //  1. s1, the engine's own account string for THIS CLIENT — a local buffer SaveToFileBnet
    //     fills from GetAccountName @0x5392f0, i.e. pClient->szAccName, which
    //     fpGetDatabaseCharacter wrote the realm's account into on the way in. Our own value
    //     handed back by the party that has held it all session.
    //  2. the seat table, for a save whose JOINGAME we have but whose client field is empty.
    //
    // Neither: DROP the save and say so. There is no third guess that is not a lie.
    //
    // The per-client field goes FIRST because it is the only one of the two that is unambiguous.
    // This realm does not make character names globally unique — the create-time check is scoped
    // to one account — so a lookup BY NAME can return the wrong player's account entirely, which
    // is not a rollback but a character swap. `gs_seats` refuses to seat two accounts' same-named
    // characters at once precisely so its answer stays usable as the fallback, but the engine's
    // own per-client field needs no such rule.
    //
    // `s1`'s identity is not taken on trust: it is the account argument in pvpgn's 1.09d game
    // server header, it is what 1.14d's SaveGameAllGameTypes passes (`SaveToFileBnet(pGame,
    // szAccountName, pUnit, szCharName, ...)`), and it is what the call site at 0x53220d loads.
    // The guard below is for the one failure that would be silent anyway: the NEIGHBOURING
    // argument is the character name, just as `keyable` as an account, and taking it would key
    // every save to `realmd:char:<Char>:<Char>` — the exact bug this path exists to stop.
    var acct_buf: [joinctx.max_account]u8 = undefined;
    const from_engine = boundedCStr(s1, joinctx.max_account + 1);
    const account = if (gsredis.keyable(from_engine) and !std.ascii.eqlIgnoreCase(from_engine, char_name))
        from_engine
    else joinctx.accountForChar(char_name, &acct_buf) orelse {
        log.print("realm: fpSaveDatabaseCharacter — NO ACCOUNT for this character, save DROPPED");
        log.cstr("realm:   char=", @intFromPtr(&d2s[0x14]));
        return 1;
    };

    log.print("realm: fpSaveDatabaseCharacter — persisting char");
    log.cstr("realm:   char=", @intFromPtr(&d2s[0x14]));
    log.hex("realm:   bytes=0x", d2s.len);

    // Straight to the store, with no realm to dial first — the save is durable the moment it
    // lands there, and the realm's flush worker moves it to the store of record behind us.
    // Fenced and durable. Fenced: the store accepts these bytes only if nothing has written this
    // character since we loaded it, which is what makes a rollback impossible rather than merely
    // unlikely. Durable: a store that could not be REACHED parks the save for the tick loop to
    // retry, rather than the bytes going back into the engine's buffer never to be offered again.
    switch (gsredis.putCharDurable(account, char_name, d2s, joinctx.version(char_name))) {
        .stored => |ver| {
            joinctx.setVersion(char_name, ver);
            log.print("realm:   char saved");
        },
        .stale => |cur| {
            // Somebody wrote this character after we loaded it — another server, an admin, an
            // import. Our bytes are the OLD ones. Refusing them is the correct outcome and the
            // whole point of the fence, so this is loud rather than quiet: it should not happen,
            // and if it does the character lock is not doing its job.
            log.print("realm:   char save REFUSED as stale — the store has a newer copy, not overwriting");
            log.hex("realm:   store version is 0x", @as(usize, @intCast(cur)));
            log.hex("realm:   ours was 0x", @as(usize, @intCast(joinctx.version(char_name))));
        },
        .unavailable => {
            log.print("realm:   char save deferred — the store did not answer, queued for retry");
            log.hex("realm:   saves waiting 0x", gsredis.pending());
        },
    }
    return 1;
}

pub const saveDatabaseCharShim = cb.Shim(cb.v114d, .fpSaveDatabaseCharacter, saveDatabaseCharImpl).shim;

// fpLeaveGame (slot 0x04). Called from CleanUpClient on leave/disconnect. The engine IsBadCodePtr-checks
// it (a null pointer reads as a bad code pointer and HALTS), so it MUST be a valid function. __fastcall
// ECX=&pClient->pRealm, EDX + 18 stack args (counted at the call site), return ignored — so a
// stack-balancing no-op (`ret 0x48`, 18*4 bytes of callee cleanup) is a safe stub.
const leaveGameStub = cb.BalancedStub(cb.v114d, .fpLeaveGame).shim;

// fpGetDatabaseFileTime (slot 0x54). CalculateGetFlags @0x569d80 calls this through the table WITHOUT an
// IsBadCodePtr guard (it only checks IsBattleNetServer), so null is a call-to-zero crash during the char
// load. __fastcall ECX = FILETIME* out (no stack args). It supplies the char's stored save timestamp for
// save-conflict/rollback checks; a zeroed filetime ("oldest") makes any loaded save count as current.
fn getFileTimeStub() callconv(.naked) void {
    asm volatile (
        \\movl $0, (%ecx)
        \\movl $0, 4(%ecx)
        \\ret
    );
}

// fpSetGameData (slot 0x34). Called once per game from SetGameDataHook @0x005379a0, during
// GAME_CreateBattleNetGame. Takes NO arguments (the call site pushes nothing and ECX is zero) and
// its return value is stored straight into pGame+0x20: `mov [esi+0x20], eax` @0x005379c4.
//
// That field is called pBnetGameData, which is a misnomer — nothing ever dereferences it. Its only
// readers are eight `RANDOM_RandomNumberSelector((D2SeedStrc*)&pGame->pBnetGameData, nRoll)` calls
// in the item drop path (Drop.cpp), which treat {+0x20, +0x24} as a 64-bit LCG state:
// `state = state.lo * 0x6ac690c5 + state.hi`, result = state mod range (RANDOM_RandomNumberSelector
// @0x0045c3e0). So this slot seeds the stream that decides what quality every item in the game
// rolls.
//
// Leaving it null does not crash, which is why it went unnoticed: +0x20 stays 0 and +0x24 is
// bGameIsSetup (1), so every game starts the same stream from {0, 1} and rolls the identical
// sequence of qualities as every other game. Seeding it per game is the whole fix.
//
// pvpgn's GS answers with the constant 0x87654321 (d2gs109 callback.c) — which has the same defect,
// just from a different starting point.
var drop_seed_state: u64 = 0;

/// SplitMix64 — one multiply-xor chain, no state beyond the counter, and well-distributed low bits
/// (which matter here: the engine takes `state mod range` with small ranges).
fn nextDropSeed() u32 {
    drop_seed_state +%= 0x9E3779B97F4A7C15;
    var z = drop_seed_state;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    const v: u32 = @truncate(z);
    return if (v == 0) 0x9E3779B9 else v; // never hand back the value that means "unseeded"
}

fn setGameDataImpl() callconv(.c) u32 {
    const seed = nextDropSeed();
    log.hex("realm: fpSetGameData — item-drop seed for this game 0x", seed);
    return seed;
}

/// Populate the realm callback table. Call before SetupAsBnetServer (i.e. before
/// bootstrapRealmServer). Wires the char loader + token validation + leave.
pub fn init() void {
    table.base.fpGetDatabaseCharacter = @ptrCast(&getDatabaseCharShim);
    table.base.fpSaveDatabaseCharacter = @ptrCast(&saveDatabaseCharShim);
    table.base.fpLeaveGame = @ptrCast(&leaveGameStub);
    table.base.fpSetGameData = @ptrCast(&setGameDataImpl);
    table.ext.fpGetDatabaseFileTime = @ptrCast(&getFileTimeStub); // 1.14d only, past the shared table
    enableTokenValidation(); // register fpFindPlayerToken (engine IsBadCodePtr-checks it)
    // Per PROCESS, not per game: games on one server must not repeat each other's drop stream, and
    // two servers started in the same tick must not share one either.
    var ft: [2]u32 = .{ 0, 0 };
    GetSystemTimeAsFileTime(&ft);
    drop_seed_state = (@as(u64, ft[1]) << 32) | @as(u64, ft[0]);
}

// Ladder joins used to be unblocked here by flipping the `JZ 0x569e17` at 0x00569dc3 so
// CalculateGetFlags skipped its whole IsBattleNetServer block. That is not needed any more and is
// deliberately gone: the block refused ladder characters only because we broke its two inputs —
// pClient->pFileTime was a truncated POINTER rather than a timestamp, and the game was created
// without flag bit 21, so a ladder character always met a non-ladder game. Both are supplied
// honestly now, which fixes the same refusal on every other engine too, where 0x00569dc3 is not
// that instruction and a byte patch could never have helped.

// fpFindPlayerToken (slot 0x18)
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

    // Join validation ported from D2Server.dll 1.00 PlayerToken_ValidateAndConsume: realmd authorized
    // this join via joinctx.remember; checked here (known + unconsumed + within the 120s TTL) and
    // consumed so it can't be replayed. s1 is the ENGINE GAMEID, not realmd's join token — d2ingress
    // rewrites the client's GAMELOGON token to the gameid before the GS sees it, hence validateGame.
    // OBSERVE-ONLY: legacy path accepted every join; flip `enforce_join` once live joins report VALID.
    const enforce_join = false;
    const gameid = @as(u32, @truncate(s1));
    const join_valid = joinctx.validateGame(gameid);
    log.print(if (join_valid) "realm:   join VALID (realm-issued, fresh)" else "realm:   join UNKNOWN/STALE/USED");
    if (enforce_join) {
        if (!join_valid) return 0; // reject: unknown, replayed, or expired authorization
        joinctx.consumeGame(gameid);
    }
    return 1; // accept — join proceeds to char load
}

pub const findPlayerTokenShim = cb.Shim(cb.v114d, .fpFindPlayerToken, findPlayerTokenImpl).shim;

/// Wire fpFindPlayerToken into the table (call before SetupAsBnetServer). Not
/// invoked yet — staged until the handler is implemented.
pub fn enableTokenValidation() void {
    table.base.fpFindPlayerToken = @ptrCast(&findPlayerTokenShim);
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
