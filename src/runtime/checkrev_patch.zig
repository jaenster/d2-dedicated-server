//! Client-side CheckRevision bypass (launcher model — D2Launcher does similar).
//!
//! Now that the BNFTP download works, the client successfully downloads our MPQ
//! and calls BNDOWNLOAD_PerformCheckRevision @0x0051e6d0 to process it. Instead of
//! fighting the weak-sig + Authenticode gates to make our own DLL load, we just
//! overwrite the function entry with a stub that writes dummy version/checksum
//! and returns success — realmd accepts any SID_AUTH_CHECK. (This is safe ONLY
//! because the download already completed; the earlier failure was the download
//! asserting first, not this patch.) See [[d2-checkrevision]].
//!
//! __fastcall(uint32_t* version [ECX], uint32_t* checksum [EDX],
//!            uint8_t* exeInfoOut [stack]) -> int. ret 4 (callee cleans the one
//! stack arg).
const patch = @import("patch.zig");
const log = @import("../log.zig");

const PERFORM_CHECKREVISION: usize = 0x0051e6d0;

// The launcher (Game/Launcher.cpp) gates on `if (BNDOWNLOAD_GetProgress() != 0x66)
// { ApplyPrepatch(); TerminateProcess() }`. 0x66 (102) means "no patch needed".
// With our dummy checkrevision the progress state never lands on 0x66, so the
// launcher thinks a patch is pending, terminates Game.exe and spawns BNUpdate.exe.
// Force the getter to 0x66 so the launcher concludes "current, no patch" and
// proceeds into the game — and never starts the patch download that divides by
// zero on a size-0 reply. __stdcall(void) -> mov eax,0x66 ; ret.
const GET_PROGRESS: usize = 0x0051ea70;
const ret_0x66 = [_]u8{ 0xB8, 0x66, 0x00, 0x00, 0x00, 0xC3 };

// test ecx,ecx / jz +6 / mov [ecx],0x01000001
// test edx,edx / jz +6 / mov [edx],0xDEADBEEF
// mov eax,[esp+4] / test eax,eax / jz +3 / mov byte [eax],0
// mov eax,1 / ret 4
const stub = [_]u8{
    0x85, 0xC9, // test ecx,ecx
    0x74, 0x06, // jz +6
    0xC7, 0x01, 0x01, 0x00, 0x00, 0x01, // mov dword [ecx],0x01000001
    0x85, 0xD2, // test edx,edx
    0x74, 0x06, // jz +6
    0xC7, 0x02, 0xEF, 0xBE, 0xAD, 0xDE, // mov dword [edx],0xDEADBEEF
    0x8B, 0x44, 0x24, 0x04, // mov eax,[esp+4]  (exeInfoOut)
    0x85, 0xC0, // test eax,eax
    0x74, 0x03, // jz +3
    0xC6, 0x00, 0x00, // mov byte [eax],0  (empty exe-info string)
    0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax,1
    0xC2, 0x04, 0x00, // ret 4
};

pub fn apply() void {
    if (patch.writeBytes(PERFORM_CHECKREVISION, &stub)) {
        log.print("checkrev: PerformCheckRevision bypassed (dummy version/checksum)");
    } else {
        log.print("checkrev: FAILED to patch PerformCheckRevision");
    }
    if (patch.writeBytes(GET_PROGRESS, &ret_0x66)) {
        log.print("checkrev: GetProgress forced to 0x66 (no patch -> launcher proceeds)");
    } else {
        log.print("checkrev: FAILED to patch GetProgress");
    }
}
