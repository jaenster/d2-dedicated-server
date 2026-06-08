//! Join diagnostics — log why the engine refuses a join.
//!
//! When CLIENT_LoadCharacterAndSendGameData fails, NET_D2GS_SERVER_SrvJoinAct
//! sends 0xB4 ConnectionRefused(nClientId, nReason) and cleans the client up. We
//! intercept that call site to log nReason (the load-error code) before letting
//! the original send proceed, so a refused join tells us exactly which check
//! tripped (0x13/0x14/0x15 hardcore, 0x17/0x18 expansion, else save-load error).

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

pub fn install() void {
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
