//! Guild panel (client) — the cut "Steeg Stone" Guild Hall interface, ported from
//! D2Client GuildStone.cpp (GuildStone_PanelHandler). It loads the beta-era guild
//! art (steegstonebckg.dc6, transplanted into the client MPQ) and blits it, then
//! draws the guild's name/tag, Steeg Stone treasury, hall level and member list —
//! the same surface the original 3316-byte panel handler rendered.
//!
//! The guild DATA (treasury/members/level) is the authoritative realmd state; the
//! client learns it from the `/guild info` reply (parsed into `state` below). Until
//! a query is wired, the panel renders with whatever `state` holds (zeros = an empty
//! hall), which still proves the art + render path end-to-end.
//!
//! Gated by --guild-panel. Drawn in the automap pass for now (open the map to see
//! it); a dedicated toggle + UI draw hook is the follow-up. Positions/palette are
//! first-pass and meant to be tuned against the real panel art on a live client.
const std = @import("std");
const log = @import("../../log.zig");
const fns = @import("../../engine/d2/functions.zig");

const PANEL_DC6: [*:0]const u8 = "data\\global\\ui\\panel\\steegstonebckg.dc6";

/// Client-side mirror of the guild the local player belongs to (fed by /guild info).
pub const State = struct {
    name: [24:0]u8 = std.mem.zeroes([24:0]u8),
    tag: [3:0]u8 = std.mem.zeroes([3:0]u8),
    hall_level: u8 = 0,
    treasury: u64 = 0,
    member_count: u16 = 0,
    in_guild: bool = false,
};
pub var state: State = .{};

var panel: ?*anyopaque = null;
var tried = false;

fn ensureLoaded() void {
    if (tried) return;
    tried = true;
    panel = fns.ImageLoadDC6Ex.call(.{ PANEL_DC6, 0 });
    log.print(if (panel != null)
        "guild_panel: steegstonebckg.dc6 loaded"
    else
        "guild_panel: steegstonebckg.dc6 MISSING — transplant the beta DC6 into the client MPQ");
}

// Draw an ASCII line as D2 unicode text (font 6, default color). Positions are
// first-pass — tune against the real panel art on a live client.
fn drawText(comptime fmt: []const u8, args: anytype, x: c_int, y: c_int) void {
    var ab: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&ab, fmt, args) catch return;
    var ub: [128:0]u16 = undefined;
    var i: usize = 0;
    while (i < s.len and i < 127) : (i += 1) ub[i] = s[i];
    ub[i] = 0;
    _ = fns.SetFont.call(.{6});
    fns.DrawGameText.call(.{ @as([*:0]const u16, &ub), x, y, 0, 0 });
}

/// Render the Steeg Stone panel. Called from the automap post-draw pass.
pub fn gameAutomapPostDraw() void {
    ensureLoaded();
    const ctx = panel orelse return;

    const mode = fns.GetScreenMode.call();
    var w: c_int = 800;
    var h: c_int = 600;
    fns.GetScreenModeSize.call(@intCast(mode), &w, &h);

    // D2 DC6 origin is bottom-left; place the panel roughly centered.
    const x = @divTrunc(w, 2) - 130;
    const y = @divTrunc(h, 2) + 130;
    fns.DrawImage.call(ctx, x, y, 0, 0, null);

    // Guild data over the panel (from realmd's /guild info → `state`).
    const tx = x + 24;
    var ty = y - 232;
    if (state.in_guild) {
        drawText("{s} [{s}]", .{ std.mem.sliceTo(&state.name, 0), std.mem.sliceTo(&state.tag, 0) }, tx, ty);
        ty += 22;
        drawText("Steeg Stone: {d} gold", .{state.treasury}, tx, ty);
        ty += 22;
        drawText("Guild Hall level {d}", .{state.hall_level}, tx, ty);
        ty += 22;
        drawText("{d} members", .{state.member_count}, tx, ty);
    } else {
        drawText("No guild yet", .{}, tx, ty);
        ty += 22;
        drawText("/guild create <TAG> <name>", .{}, tx, ty);
    }
}

pub fn install() void {
    log.print("guild_panel: install (Steeg Stone guild-hall panel; open the automap to view)");
}
