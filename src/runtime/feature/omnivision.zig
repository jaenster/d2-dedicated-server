//! Omnivision (client-side maphack) — see monsters/players through walls and
//! light the whole map. Ported from Charon's Omnivision.cpp (jaenster). Two
//! patches; the dark-debug branch and the light-radius patch (which only matter
//! for DebugMode::DARK) are intentionally dropped — this is plain omnivision.
//!
//! 1. GetRoomColors @0x66bfd0 — the engine's per-room gamma/r/g/b lookup. We
//!    JMP the entry to a stub that forces all four output bytes to 0xFF (full
//!    bright), so no room is ever darkened by fog of war.
//! 2. PLAYER_CanSee call @0x4dc864 — replace the `call` with a hook that runs
//!    the original line-of-sight check and then forces the result to 1, so units
//!    behind walls are still considered visible.
//!
//! All addresses are 1.14d (base 0x00400000), sourced from Charon. Effect is only
//! visible on a rendered client — verify on the real client, not the headless GS.
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

const GETROOMCOLORS: usize = 0x0066bfd0; // void __fastcall GetRoomColors(Room1* ecx, BYTE* gamma edx, BYTE* r, *g, *b)
const CANSEE_CALLSITE: usize = 0x004dc864; // `call PLAYER_CanSee` to override
const CANSEE_ORIGINAL: usize = 0x004dc710;

/// Force the four room-colour output bytes to 0xFF (full brightness), then return
/// as the original would. __fastcall: ECX=pRoom (unused), EDX=gamma ptr, and
/// red/green/blue pointers on the stack (callee-clean 3 args → `ret 0xC`).
fn getRoomColorsOmni() callconv(.naked) void {
    asm volatile (
        \\movb $0xFF, (%edx)
        \\mov 0x4(%esp), %eax
        \\movb $0xFF, (%eax)
        \\mov 0x8(%esp), %eax
        \\movb $0xFF, (%eax)
        \\mov 0xc(%esp), %eax
        \\movb $0xFF, (%eax)
        \\ret $0xc
    );
}

/// Run the original line-of-sight check (preserving its side effects, ECX/EDX are
/// already set by the call site) then force the boolean result to 1 (visible).
fn playerCanSeeForceVisible() callconv(.naked) void {
    asm volatile (
        \\mov $0x004dc710, %eax
        \\call *%eax
        \\mov $1, %eax
        \\ret
    );
}

comptime {
    // CANSEE_ORIGINAL is encoded as an immediate in the stub above; keep the name
    // referenced so it stays meaningful / greppable.
    if (CANSEE_ORIGINAL != 0x004dc710) @compileError("CanSee original address drifted");
}

pub fn install() void {
    const ok1 = patch.MemoryPatch(GETROOMCOLORS).jump(@intFromPtr(&getRoomColorsOmni)).commit();
    const ok2 = patch.MemoryPatch(CANSEE_CALLSITE).call(@intFromPtr(&playerCanSeeForceVisible)).commit();
    if (ok1 and ok2) {
        log.print("omnivision: LoS + room brightness forced (see through walls)");
    } else {
        log.print("omnivision: FAILED to patch one or both sites");
    }
}
