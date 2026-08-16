//! Join diagnostics — log why the engine refuses a join.
//!
//! When CLIENT_LoadCharacterAndSendGameData fails, NET_D2GS_SERVER_SrvJoinAct sends 0xB4
//! ConnectionRefused(nClientId, nReason). That call site is intercepted to log nReason before the
//! original send: 0x13/0x14/0x15 hardcore, 0x17/0x18 expansion, else save-load error.

const patch = @import("patch.zig");
const log = @import("../log.zig");

// In SrvJoinAct: `MOV EDX,nReason; MOV ECX,nClientId; CALL Send_0xB4` (5-byte E8).
const B4_CALLSITE: usize = 0x005301f1;
const SEND_0XB4: usize = 0x0053b260; // NET_D2GS_SERVER_Send_0xB4_ConnectionRefused

// ProcessClientMessage_GameSetup: `CALL SrvJoinAct` for the 0x6b JOINGAME message.
const JOINACT_CALLSITE: usize = 0x0053f2dc;
const SRVJOINACT: usize = 0x00530190; // NET_D2GS_SERVER_SrvJoinAct (fastcall ECX=nClientId)

fn logReason(reason: usize) callconv(.c) void {
    log.hex("realm: JOIN REFUSED — nReason=0x", reason);
}

fn logJoinAct(client_id: usize) callconv(.c) void {
    log.hex("realm: SrvJoinAct ENTER — clientId=0x", client_id);
}

fn joinActIntercept() callconv(.naked) void {
    asm volatile (
        \\push %%ecx
        \\push %%ecx
        \\call %[f:P]
        \\add $4, %%esp
        \\pop %%ecx
        \\mov %[t], %%eax
        \\jmp *%%eax
        :
        : [f] "X" (&logJoinAct),
          [t] "i" (SRVJOINACT),
    );
}

// Replaces the original CALL: save fastcall regs, log EDX (nReason), restore,
// then tail-jump to the real Send_0xB4 so it still rets to the call site.
fn b4Intercept() callconv(.naked) void {
    asm volatile (
        \\push %%ecx
        \\push %%edx
        \\push %%edx
        \\call %[f:P]
        \\add $4, %%esp
        \\pop %%edx
        \\pop %%ecx
        \\mov %[send], %%eax
        \\jmp *%%eax
        :
        : [f] "X" (&logReason),
          [send] "i" (SEND_0XB4),
    );
}

// Which gate of IsValidChecks refused a GAMELOGON. The 0xB4 hook above only sees refusals that
// reach SrvJoinAct; NET_D2GS_SERVER_IsValidChecks @0x52c690's eight checks all branch to one
// shared reject label with no reply, so "refused" is otherwise the only fact available.
// Intercept the four that are calls (others are inline compares, constant per client); report
// only on failure, so an accepted join costs one jump.
const NAME_LEN_CALLSITE: usize = 0x0052c6d5; // ECX=szCharName, EDX=16 -> length is within bounds
const STRING_LENGTH_CHECK: usize = 0x0053efc0;
const NAME_BY_ID_CALLSITE: usize = 0x0052c6fe; // ECX=nClientId -> the connection has a name
const GET_PLAYER_NAME_BY_CLIENT_ID: usize = 0x00538b70;
const TOKEN_VALID_CALLSITE: usize = 0x0052c717; // ECX=nGameToken -> this server has that game
const SERVER_IS_TOKEN_VALID: usize = 0x0052c060;
const NAME_CHARS_CALLSITE: usize = 0x0052c72d; // EDX=szCharName, EDI=16 -> no forbidden characters
const CHECK_FORBIDDEN_CHARS: usize = 0x0052c5b0;

fn refusedName(name_ptr: usize) callconv(.c) void {
    log.cstr("realm: JOIN REFUSED by IsValidChecks — name length: ", name_ptr);
}

fn refusedNoNameForClient(client_id: usize) callconv(.c) void {
    log.hex("realm: JOIN REFUSED by IsValidChecks — no name for clientId=0x", client_id);
}

fn refusedToken(token: usize) callconv(.c) void {
    log.hex("realm: JOIN REFUSED by IsValidChecks — this server has no game token=0x", token);
}

fn refusedChars(name_ptr: usize) callconv(.c) void {
    log.cstr("realm: JOIN REFUSED by IsValidChecks — forbidden characters in ", name_ptr);
}

/// Build an intercept for one gate: call the engine's check unchanged, and on a zero result hand
/// `reg` to `report` before returning that same zero. EAX is the check's own return, so it is
/// saved across the report; ECX and EDX are dead at all four call sites and EBX/ESI/EDI/EBP are
/// preserved by the reporting function's own calling convention.
fn gate(comptime orig: usize, comptime report: anytype, comptime reg: []const u8) fn () callconv(.naked) void {
    return struct {
        fn shim() callconv(.naked) void {
            asm volatile ("mov %[o], %%eax\n call *%%eax\n test %%eax, %%eax\n jnz 1f\n push %%eax\n push " ++ reg ++ "\n call %[r:P]\n add $4, %%esp\n pop %%eax\n 1:\n ret"
                :
                : [o] "i" (orig),
                  [r] "X" (report),
            );
        }
    }.shim;
}

const nameLenGate = gate(STRING_LENGTH_CHECK, &refusedName, "%%esi");
const nameByIdGate = gate(GET_PLAYER_NAME_BY_CLIENT_ID, &refusedNoNameForClient, "%%edi");
const tokenGate = gate(SERVER_IS_TOKEN_VALID, &refusedToken, "%%ebx");
const nameCharsGate = gate(CHECK_FORBIDDEN_CHARS, &refusedChars, "%%esi");

fn hookGates() void {
    var ok = true;
    inline for (.{
        .{ NAME_LEN_CALLSITE, &nameLenGate },
        .{ NAME_BY_ID_CALLSITE, &nameByIdGate },
        .{ TOKEN_VALID_CALLSITE, &tokenGate },
        .{ NAME_CHARS_CALLSITE, &nameCharsGate },
    }) |g| {
        if (!patch.MemoryPatch(g[0]).call(@intFromPtr(g[1])).commit()) ok = false;
    }
    log.print(if (ok)
        "joindiag: IsValidChecks gates hooked (a silent refusal now names its check)"
    else
        "joindiag: FAILED to hook the IsValidChecks gates — refusals stay silent");
}

pub fn install() void {
    hookGates();
    if (patch.MemoryPatch(B4_CALLSITE).call(@intFromPtr(&b4Intercept)).commit()) {
        log.print("joindiag: ConnectionRefused hook installed (logs nReason)");
    } else {
        log.print("joindiag: FAILED to hook ConnectionRefused");
    }
    if (patch.MemoryPatch(JOINACT_CALLSITE).call(@intFromPtr(&joinActIntercept)).commit()) {
        log.print("joindiag: SrvJoinAct hook installed (logs entry)");
    } else {
        log.print("joindiag: FAILED to hook SrvJoinAct");
    }
}
