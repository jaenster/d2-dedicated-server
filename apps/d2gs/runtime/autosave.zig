//! How often the engine saves a character mid-game.
//!
//! `UpdateClients` @0x52d440 calls `SaveAllPlayers` @0x52ca10 every 8192 game frames — about 5.5
//! minutes at 25 fps — and that is the only periodic path to the realm's save callback. The others
//! are edges: a clean leave (`NET_D2GS_SERVER_LeaveServer`) and a forced disconnect
//! (`CheckClientTimeouts`). So a server that dies, is rescheduled, or loses a client without a
//! clean leave gives the player back whatever they had up to 5.5 minutes ago, and a game shorter
//! than that never autosaves at all.
//!
//! The interval is a mask, not a counter: the compiler rendered `dwGameFrame % 8192 == 0` as
//! `AND EAX, 0x80001fff` @0x52d45c — the signed-modulo idiom, sign bit plus 8192-1 — followed by a
//! fixup for negative frames (`DEC; OR EAX, 0xffffe000; INC`) and a jump-if-zero. Shrinking the
//! interval is therefore two immediates and no new code, which is why it is done this way rather
//! than by calling `SaveAllPlayers` ourselves: the save then still happens at exactly the point in
//! the tick the engine expects, holding whatever it holds, with no argument or re-entrancy risk of
//! ours.
//!
//! Saving more often is close to free. `SaveToFileBnet` builds the save and compares it against
//! the copy the realm handed it at load; an unchanged character takes the
//! `fpRelockDatabaseCharacter` path and never reaches the store. So the cost of a short interval
//! is paid only by players who actually did something.
//!
//! The frame counter is per game (`pGame->dwGameFrame` @+0xa8), so games do not all save on the
//! same tick — the load is spread by construction.

const std = @import("std");
const patch = @import("patch.zig");
const log = @import("../log.zig");
/// The mask arithmetic and the shipped-constant proofs live in d2engine, where they are pure and
/// can be asserted on any host; this file is only the patching half.
const interval = @import("d2engine").saveinterval;

/// imm32 of `AND EAX, 0x80001fff` @0x52d45c (`25 ff 1f 00 80`) — the interval mask.
const MASK_IMM_ADDR: usize = 0x0052d45d;
/// imm32 of `OR EAX, 0xffffe000` @0x52d46a (`0d 00 e0 ff ff`) — the negative-frame fixup that has
/// to agree with the mask. `dwGameFrame` would have to run ~994 days at 25 fps to go negative, so
/// this path is unreachable in practice; it is patched anyway because a mask and a fixup that
/// disagree is a landmine left for whoever reads this next.
const FIXUP_IMM_ADDR: usize = 0x0052d46b;

/// The instructions as they ship. Checked before patching: an immediate written at an address
/// whose opcode moved is a silent corruption of whatever instruction is there now.
const MASK_INSN: [5]u8 = .{ 0x25, 0xff, 0x1f, 0x00, 0x80 };
const FIXUP_INSN: [5]u8 = .{ 0x0d, 0x00, 0xe0, 0xff, 0xff };

/// 512 frames — about 20 seconds at 25 fps. Chosen against what a rollback costs rather than what
/// a save costs: 20 seconds of lost play is an annoyance, 5.5 minutes is a boss run.
pub const default_frames: u32 = 512;

/// Set the periodic save interval to `frames`, which MUST be a power of two — the engine tests it
/// with a mask, so anything else would fire on a set of frames rather than an interval.
pub fn apply(frames: u32) void {
    if (!interval.isExpressible(frames)) {
        log.hex("autosave: REFUSED, interval is not a power of two: 0x", frames);
        return;
    }
    const mask = interval.mask(frames);
    const fixup = interval.fixup(frames);

    const mask_ok = patch.MemoryPatch(MASK_IMM_ADDR - 1)
        .expect(&MASK_INSN)
        .skip(1)
        .data(mask)
        .commit();
    if (!mask_ok) {
        log.print("autosave: FAILED to patch the save interval — leaving the engine's 8192 frames");
        return;
    }
    // Best-effort: the mask is the one that matters, and a failure here leaves an unreachable
    // path inconsistent rather than the save broken.
    _ = patch.MemoryPatch(FIXUP_IMM_ADDR - 1)
        .expect(&FIXUP_INSN)
        .skip(1)
        .data(fixup)
        .commit();

    log.hex("autosave: mid-game save interval set to frames 0x", frames);
    log.hex("autosave:   which is roughly seconds 0x", frames / interval.fps);
}

pub fn applyDefault() void {
    apply(default_frames);
}

/// `frames` from --autosave-frames / D2GS_AUTOSAVE_FRAMES, else the default.
///
/// Rounded DOWN to a power of two rather than refused, because the value is a duration to whoever
/// sets it and the power-of-two rule is an artefact of how the engine tests it. Clamped at both
/// ends: below 64 frames (~2.5s) the save stops being periodic and starts being per-action, and
/// above the engine's own 8192 there is no reason to be here at all.
pub fn applyConfigured(frames: u32) void {
    apply(interval.round(frames));
}
