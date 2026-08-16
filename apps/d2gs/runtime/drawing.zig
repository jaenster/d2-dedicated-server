//! Client draw driver — client-side analog of runtime/gameloop.zig. Hooks the engine's render path
//! so features can draw. Ported from Charon's Drawing.cpp. Minimal so far: only the AUTOMAP draw
//! site — DRAW_UI calls `DrawAutomap` at 0x456fa5 (`call 0x45ad60`, verified in recon 9df5e900),
//! replaced with our hook fanning gameAutomapPreDraw -> real DrawAutomap -> gameAutomapPostDraw
//! (where maphack draws reveal cells/unit dots/labels). More of Charon's draw hooks added as needed.
//! Client-only: these render functions never run in the headless GS, so the patch is idle there.
const patch = @import("patch.zig");
const log = @import("../log.zig");
const feature = @import("../engine/feature.zig");
const d2fn = @import("../engine/d2/functions.zig");

const AUTOMAP_DRAW_CALLSITE: usize = 0x00456fa5; // `call DrawAutomap` inside DRAW_UI
const GAME_POST_DRAW_CALLSITE: usize = 0x0044cb14; // CALL after the viewport render — replaceable, no original to chain

/// Replaces the engine's `call DrawAutomap`. cdecl/void is call-compatible with the
/// original fastcall-0-arg site (both clobber only eax/ecx/edx, no args, no result).
fn automapDrawHook() callconv(.c) void {
    feature.fanGameAutomapPreDraw();
    d2fn.DrawAutomap.call(.{}); // the original render we replaced
    feature.fanGameAutomapPostDraw();
}

/// Replaces the post-viewport CALL (the same site aether/d2probe hook for their
/// gamePostDraw). Font is saved/restored around the fan so features can SetFont.
fn gamePostDrawHook() callconv(.c) void {
    const old = d2fn.SetFont.call(.{1});
    feature.fanGamePostDraw();
    _ = d2fn.SetFont.call(.{old});
}

pub fn install() void {
    if (patch.MemoryPatch(AUTOMAP_DRAW_CALLSITE).call(@intFromPtr(&automapDrawHook)).commit()) {
        log.print("drawing: automap draw hook installed (gameAutomapPre/PostDraw)");
    } else {
        log.print("drawing: FAILED to hook automap draw");
    }
    if (patch.MemoryPatch(GAME_POST_DRAW_CALLSITE).call(@intFromPtr(&gamePostDrawHook)).commit()) {
        log.print("drawing: game post-draw hook installed (gamePostDraw)");
    } else {
        log.print("drawing: FAILED to hook game post-draw");
    }
}
