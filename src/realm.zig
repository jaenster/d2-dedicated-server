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

const server = @import("d2_server.zig");
const fastcall = @import("fastcall.zig");

/// The table we register via SetupAsBnetServer. All-null for now.
pub var table: server.BnetServerService = .{};

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
    _ = .{ ecx, edx, s1, s2, s3, s4, s5, s6, s7 };
    return 0; // reject until implemented (safe)
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
