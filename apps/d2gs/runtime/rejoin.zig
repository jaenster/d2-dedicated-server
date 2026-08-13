//! Let a character come straight back after the game it was in.
//!
//! NET_D2GS_SERVER_IsValidChecks @0x52c690 refuses a GAMELOGON whose character is still linked
//! in the engine's global by-name client table, and it refuses it with SILENCE: the reject path
//! is GuardStack(0), so nothing goes back on the wire and the client sits at the loading screen
//! until its own timeout. A character keeps that seat until the client holding it is cleaned
//! up, which lands a second or two after the socket died — so a player, or a bot, who leaves a
//! game and immediately makes the next one is refused roughly every other game, with no error
//! anywhere to explain it. Measured: 15/30 back-to-back joins on one character, and 10/10 once
//! the character alternates.
//!
//! The seat outlives the socket because the two halves of a client die on different clocks. The
//! QServer connection is gone the moment the socket closes, but the game-side D2ClientStrc is
//! still in its game and in both server hash tables (observed: connState=4 "in game", a live
//! pGame). The engine's own QSERVER_DisconnectClientByName cannot clear that state — it resolves
//! the game through the CONNECTION (GetClientServerTokenByClientId), which is exactly the half
//! that is already gone, so it finds no game and silently does nothing.
//!
//! So we resolve it the other way around, from the seat we can see: find the client in the
//! by-name table, take the game token off its own pGame, lock that game and hand both pointers
//! to SERVER_DisconnectClient. That is the same disconnect the engine's timeout path performs,
//! and it cleans up with bSavePlayer=1 — the character is saved on the way out, not rolled back.
//!
//! The realm's join record is the authorization. Only realmd writes joinctx, so a client cannot
//! name somebody else's character to have them thrown out of the game they are in.

const std = @import("std");
const patch = @import("patch.zig");
const joinctx = @import("../realmclient/joinctx.zig");
const log = @import("../log.zig");

extern "kernel32" fn EnterCriticalSection(cs: usize) callconv(.winapi) void;
extern "kernel32" fn LeaveCriticalSection(cs: usize) callconv(.winapi) void;

// In IsValidChecks: `LEA EDX,[EBP-0x14]; MOV ECX,ESI; CALL SERVER_IsPlayerCharacterInGame`.
const SEAT_CHECK_CALLSITE: usize = 0x0052c70c;
// __fastcall(ECX = szCharName, EDX = szExistingNameOut) -> nonzero when the name is FREE.
const IS_PLAYER_CHARACTER_IN_GAME: usize = 0x00538c60;

// The engine's server-wide client tables, both filled by CreateClient and emptied by
// CleanUpClient. We only read the by-name one, under the engine's own lock.
const BUCKET_BY_NAME: usize = 0x00883ea8; // D2ClientStrc*[256], keyed by SMem::HashForName
const BY_NAME_CS: usize = 0x008846c0; // gQServerClientByNameCs

// D2ClientStrc fields (struct is 1304 bytes).
const CL_CLIENT_NO: usize = 0x000; // int nClientNo
const CL_CHAR_NAME: usize = 0x00d; // char szCharName[16]
const CL_GAME: usize = 0x1a8; // D2GameStrc* pGame
const CL_NEXT_BY_NAME: usize = 0x4b0; // D2ClientStrc* pNextInListByName
const GAME_TOKEN: usize = 0x000; // D2GameStrc: uint nToken

// The reason byte rides along in the 0x5A leave-game event the disconnect broadcasts; 0 is what
// the engine's own timeout disconnect passes.
const DISCONNECT_REASON: u32 = 0;

// Engine calls on this path are __fastcall, and Zig's x86 fastcall is unreliable
// (ziglang/zig#10363 — same reason the realm callbacks use asm shims), so each one goes through
// a naked shim that moves the arguments into the registers the engine expects.

/// D2GameStrc* QSERVER_FindAndLockGame(uint nToken) — __fastcall(ECX), plain `ret`. Returns null
/// when no such game exists; on success the game is LOCKED and must be unlocked.
fn findAndLockGame(token: u32) usize {
    const S = struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\mov 4(%%esp), %%ecx
                \\mov %[f], %%eax
                \\jmp *%%eax
                :
                : [f] "i" (@as(usize, 0x0052e860)),
            );
        }
    };
    const f: *const fn (u32) callconv(.c) usize = @ptrCast(&S.shim);
    return f(token);
}

/// void Unlock(D2GameStrc*) — __fastcall(ECX), plain `ret`.
fn unlockGame(game: usize) void {
    const S = struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\mov 4(%%esp), %%ecx
                \\mov %[f], %%eax
                \\jmp *%%eax
                :
                : [f] "i" (@as(usize, 0x0052da90)),
            );
        }
    };
    const f: *const fn (usize) callconv(.c) void = @ptrCast(&S.shim);
    f(game);
}

/// D2ClientStrc* SERVER_GetClientFromGmeByClientId(D2GameStrc*, int) — __fastcall(ECX, EDX).
/// Re-resolving the client under the game lock beats reusing the pointer we read without it.
fn clientInGameById(game: usize, client_no: u32) usize {
    const S = struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\mov 4(%%esp), %%ecx
                \\mov 8(%%esp), %%edx
                \\mov %[f], %%eax
                \\jmp *%%eax
                :
                : [f] "i" (@as(usize, 0x00537810)),
            );
        }
    };
    const f: *const fn (usize, u32) callconv(.c) usize = @ptrCast(&S.shim);
    return f(game, client_no);
}

/// void SERVER_DisconnectClient(D2GameStrc*, D2ClientStrc*, uint nReason) — __fastcall(ECX, EDX)
/// plus one stack argument the callee pops itself (`ret 4`), so this one calls rather than jumps.
fn disconnectClient(game: usize, client: usize, reason: u32) void {
    const S = struct {
        fn shim() callconv(.naked) void {
            asm volatile (
                \\mov 4(%%esp), %%ecx
                \\mov 8(%%esp), %%edx
                \\push 12(%%esp)
                \\mov %[f], %%eax
                \\call *%%eax
                \\ret
                :
                : [f] "i" (@as(usize, 0x0052caf0)),
            );
        }
    };
    const f: *const fn (usize, usize, u32) callconv(.c) void = @ptrCast(&S.shim);
    f(game, client, reason);
}

/// uint QSERVER_GetClientGameToken(uint nClientId) — __stdcall, `ret 4`. Looks the client up in
/// the QServer's CONNECTION table and returns its server token, or zero when there is no
/// connection. That is the whole question this file turns on: a seat whose connection is gone is
/// a leftover, and a seat whose connection is still there is somebody playing.
fn connectionToken(client_no: u32) u32 {
    const f: *const fn (u32) callconv(std.builtin.CallingConvention{ .x86_stdcall = .{} }) u32 =
        @ptrFromInt(0x0052b610);
    return f(client_no);
}

const Seat = struct { client_no: u32, game: usize };

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Find the client currently holding `char_name`, reading the by-name table under the engine's
/// own lock. Every bucket is scanned rather than hashing the name ourselves: the table is 256
/// pointers with short chains, and it saves depending on Storm's hash matching the engine's.
/// The game lock is deliberately NOT taken here — the caller takes it after this returns, so the
/// two locks are never held at once.
fn findSeat(char_name: []const u8) ?Seat {
    var found: ?Seat = null;
    EnterCriticalSection(BY_NAME_CS);
    defer LeaveCriticalSection(BY_NAME_CS);
    var bucket: usize = 0;
    while (bucket < 256) : (bucket += 1) {
        var p: usize = @as(*const usize, @ptrFromInt(BUCKET_BY_NAME + bucket * 4)).*;
        // The chain is bounded in practice (8 clients to a game); the cap keeps a corrupt
        // list from spinning here forever rather than pretending it cannot happen.
        var hops: u32 = 0;
        while (p != 0 and hops < 64) : (hops += 1) {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(p + CL_CHAR_NAME)), 0);
            if (eqlIgnoreCase(name, char_name)) {
                found = .{
                    .client_no = @as(*const u32, @ptrFromInt(p + CL_CLIENT_NO)).*,
                    .game = @as(*const usize, @ptrFromInt(p + CL_GAME)).*,
                };
                return found;
            }
            p = @as(*const usize, @ptrFromInt(p + CL_NEXT_BY_NAME)).*;
        }
    }
    return found;
}

/// Release the seat `name_ptr` still holds, if the realm authorized this character to join.
/// Returns 1 when a client was actually disconnected, so the caller re-asks the engine.
fn releaseStaleSeat(name_ptr: usize) callconv(.c) u32 {
    const char_name = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(name_ptr)), 0);
    if (char_name.len == 0) return 0;
    // No realm-issued join for this name means this is not a rejoin we vouched for, and acting
    // on an unauthenticated packet would hand every client a way to evict anyone.
    if (!joinctx.hasFreshJoin(char_name)) {
        log.cstr("rejoin: seat still held, but the realm issued no join for ", name_ptr);
        return 0;
    }
    const seat = findSeat(char_name) orelse return 0;
    if (seat.game == 0) return 0;
    // Only a seat nobody is sitting in may be released. A character whose QServer connection is
    // still there is being PLAYED, and taking its seat would throw a live session out of its game
    // so a second login of the same character could take its place — which is not a rejoin, it is
    // one player evicting themselves. Refuse instead and let the first session keep playing.
    if (connectionToken(seat.client_no) != 0) {
        log.cstr("rejoin: refusing a second login — a live connection is playing ", name_ptr);
        return 0;
    }
    const token = @as(*const u32, @ptrFromInt(seat.game + GAME_TOKEN)).*;
    const game = findAndLockGame(token);
    if (game == 0) {
        log.hex("rejoin: the seat's game is already gone, token=0x", token);
        return 0;
    }
    defer unlockGame(game);
    const client = clientInGameById(game, seat.client_no);
    if (client == 0) {
        log.print("rejoin: the seat's client left its game on its own");
        return 0;
    }
    log.cstr("rejoin: releasing the seat still held by ", name_ptr);
    disconnectClient(game, client, DISCONNECT_REASON);
    return 1;
}

// Replaces the CALL in IsValidChecks: run the engine's own check, and only if it says the name
// is taken, release the stale seat and ask it again. ESI/EDI are callee-saved and the engine
// keeps live values in both across this call, hence the push/pop pair. Answering with the
// engine's second verdict, rather than a flat "free", keeps the decision the engine's.
fn seatIntercept() callconv(.naked) void {
    asm volatile (
        \\push %%esi
        \\push %%edi
        \\mov %%ecx, %%esi
        \\mov %%edx, %%edi
        \\mov %[orig], %%eax
        \\call *%%eax
        \\test %%eax, %%eax
        \\jnz 1f
        \\push %%esi
        \\call %[release:P]
        \\add $4, %%esp
        \\test %%eax, %%eax
        \\jz 1f
        \\mov %%esi, %%ecx
        \\mov %%edi, %%edx
        \\mov %[orig], %%eax
        \\call *%%eax
        \\1:
        \\pop %%edi
        \\pop %%esi
        \\ret
        :
        : [orig] "i" (IS_PLAYER_CHARACTER_IN_GAME),
          [release] "X" (&releaseStaleSeat),
    );
}

pub fn install() void {
    if (patch.MemoryPatch(SEAT_CHECK_CALLSITE).call(@intFromPtr(&seatIntercept)).commit()) {
        log.print("rejoin: stale-seat release installed (a character can re-enter immediately)");
    } else {
        log.print("rejoin: FAILED to hook the seat check — rejoins will be refused silently");
    }
}
