//! ExperienceMod (server) — scale awarded experience and drive the feature
//! framework's expAward hook. Ported from Charon's ExperienceMod.cpp (exp half;
//! the players-count override is a separate follow-up).
//!
//! SERVER_CalculateExperienceForUnit calls CALC_Experience @0x57e3f0 at 0x57e4fa
//! (`call`, verified recon 9df5e900). CALC_Experience is callee-clean (`ret 8`,
//! custom-reg args: pUnit=ECX, nParam2=EAX, pGame/nParam on the stack). We replace
//! that call with a shim that re-invokes the original with the same frame, then
//! scales the result and threads it through feature.fanExpAward.
//!
//! The whole wrap lives on the stack (no globals): save pUnit, re-push the two
//! stack args for the original call, restore, then call our cdecl scaler and
//! `ret 8` ourselves (matching CALC's callee-clean contract).
const std = @import("std");
const patch = @import("../patch.zig");
const log = @import("../../log.zig");
const feature = @import("../../engine/feature.zig");
const d2types = @import("../../engine/d2types.zig");

const CALL_SITE: usize = 0x0057e4fa; // `call CALC_Experience` to wrap

extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;

/// Multiplier applied to every exp award. Read from D2GS_EXP_MULT at install
/// (default 1 = no change; the feature still drives fanExpAward).
pub var multiplier: u32 = 1;

/// Scale + fan-out, run on the real exp value. cdecl.
fn expScale(exp: u32, pUnit: *d2types.D2UnitStrc, pGame: *d2types.D2GameStrc) callconv(.c) u32 {
    var out = exp *% multiplier;
    if (pGame.pMemoryPool) |pool| {
        const ctx = feature.gameCtx(pGame, pool);
        out = feature.fanExpAward(&ctx, @ptrCast(pUnit), out);
    }
    return out;
}

/// Reached via the replaced `call` (ECX=pUnit, EAX=nParam2, [esp]=ret,
/// [esp+4]=pGame, [esp+8]=nParam). See the stack trace in the module doc.
fn expShim() callconv(.naked) void {
    asm volatile (
        \\push %%ecx                 // save pUnit
        \\pushl 0xc(%%esp)           // re-push nParam for the original call
        \\pushl 0xc(%%esp)           // re-push pGame
        \\mov $0x0057e3f0, %%edx     // CALC_Experience
        \\call *%%edx                // original; ret 8 cleans the two args, EAX=exp
        \\pop %%ecx                  // restore pUnit; stack back to entry frame
        \\pushl 0x4(%%esp)           // expScale arg3: pGame
        \\push %%ecx                 // arg2: pUnit
        \\push %%eax                 // arg1: exp
        \\call %[scale:P]            // EAX = scaled/fanned exp
        \\add $0xc, %%esp
        \\ret $0x8                   // callee-clean, like the original
        :
        : [scale] "X" (&expScale),
        : .{ .ecx = true, .edx = true, .memory = true });
}

fn readMultiplier() void {
    var buf: [16]u8 = undefined;
    const n = GetEnvironmentVariableA("D2GS_EXP_MULT", &buf, buf.len);
    if (n == 0 or n >= buf.len) return;
    multiplier = std.fmt.parseInt(u32, buf[0..n], 10) catch 1;
}

pub fn install() void {
    readMultiplier();
    if (patch.MemoryPatch(CALL_SITE).call(@intFromPtr(&expShim)).commit()) {
        log.hex("expmod: CALC_Experience wrapped, multiplier=0x", multiplier);
    } else {
        log.print("expmod: FAILED to wrap CALC_Experience");
    }
}
