//! In-world collision-diff overlay (debug maphack). At every subtile where our
//! CLEAN-ROOM collision map (libd2) disagrees with the real engine's CollMap for
//! SEED 1, draws a colored dot on the automap AND a colored iso outline on the
//! ground near the player, plus a HUD line with this level's mismatch count and
//! the world-delta to the nearest cell (sparse cells are walkable-to that way).
//! At seed 1 the game's live collision equals the golden the diff was baked
//! against, so a lit cell is a real bug in our reconstruction.
//!
//! Data: colldiff.bin — u32 count, then sorted records {level:u16, x:u16, y:u16,
//! type:u8} (LE), generated offline from the ours-vs-golden diff (steady-state
//! all-rooms-active goldens). ONLY valid for seed 1.
const std = @import("std");
const d2 = struct {
    const functions = @import("../../engine/d2/functions.zig");
    const globals = @import("../../engine/d2/globals.zig");
    const types = @import("../../engine/d2/types.zig");
    const automap = @import("../../engine/d2/automap.zig");
};

const blob = @embedFile("colldiff.bin");

// COLOR SCHEME — palette indices (edit freely). Index = diff `type`:
//   0 red    we MISS a block the game has   (our map would walk you into a wall)
//   1 blue   we OVER-block an open cell      (our map blocks a walkable spot)
//   2 yellow LOS / missile-barrier bit differs
//   3 cyan   preset / sub-theme (0x10) bit differs
//   4 white  other
const COLOR = [5]u32{ 0x6A, 0x97, 0x0D, 0xCB, 0xFF };

/// World draw radius around the player, in subtiles.
const WORLD_RADIUS: i32 = 48;

fn le16(off: usize) u32 {
    return @as(u32, blob[off]) | (@as(u32, blob[off + 1]) << 8);
}

fn recordCount() usize {
    return le16(0) | (@as(u32, blob[2]) << 16) | (@as(u32, blob[3]) << 24);
}

fn currentLevelNo() ?u32 {
    const player = d2.globals.playerUnit().* orelse return null;
    const r1 = player.getRoom1() orelse return null;
    const r2 = r1.pRoom2 orelse return null;
    const lvl = r2.pLevel orelse return null;
    return lvl.dwLevelNo;
}

pub fn gameAutomapPostDraw() void {
    const lvl = currentLevelNo() orelse return;
    const count = recordCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = 4 + i * 7;
        if (le16(off) != lvl) continue;
        const x: f64 = @floatFromInt(le16(off + 2));
        const y: f64 = @floatFromInt(le16(off + 4));
        const t = blob[off + 6];
        const col = COLOR[if (t < COLOR.len) t else 4];
        d2.automap.drawAutomapDot(x, y, col);
    }
}

pub fn gamePostDraw() void {
    const player = d2.globals.playerUnit().* orelse return;
    const lvl = currentLevelNo() orelse return;
    const pp = player.getPos();

    const count = recordCount();
    var on_level: u32 = 0;
    var nearest_d: i64 = std.math.maxInt(i64);
    var nearest_dx: i32 = 0;
    var nearest_dy: i32 = 0;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = 4 + i * 7;
        if (le16(off) != lvl) continue;
        const cx: i32 = @intCast(le16(off + 2));
        const cy: i32 = @intCast(le16(off + 4));
        on_level += 1;

        const dx = cx - pp.x;
        const dy = cy - pp.y;
        const dd = @as(i64, dx) * dx + @as(i64, dy) * dy;
        if (dd < nearest_d) {
            nearest_d = dd;
            nearest_dx = dx;
            nearest_dy = dy;
        }
        if (dx <= -WORLD_RADIUS or dx >= WORLD_RADIUS or dy <= -WORLD_RADIUS or dy >= WORLD_RADIUS) continue;

        // Iso outline of the subtile: its 4 world corners projected to screen.
        const t = blob[off + 6];
        const col = COLOR[if (t < COLOR.len) t else 4];
        const fx: f64 = @floatFromInt(cx);
        const fy: f64 = @floatFromInt(cy);
        d2.automap.drawScreenDottedLine(fx, fy, fx + 1, fy, col);
        d2.automap.drawScreenDottedLine(fx + 1, fy, fx + 1, fy + 1, col);
        d2.automap.drawScreenDottedLine(fx + 1, fy + 1, fx, fy + 1, col);
        d2.automap.drawScreenDottedLine(fx, fy + 1, fx, fy, col);
    }

    // HUD: count + vector to the nearest mismatch (world dx,dy — walk that way).
    var buf: [96]u8 = undefined;
    const s = if (on_level == 0)
        std.fmt.bufPrint(&buf, "colldiff L{d}: clean", .{lvl}) catch return
    else
        std.fmt.bufPrint(&buf, "colldiff L{d}: {d} cells, nearest {d},{d}", .{ lvl, on_level, nearest_dx, nearest_dy }) catch return;
    var w: [96:0]u16 = undefined;
    for (s, 0..) |c, j| w[j] = c;
    w[s.len] = 0;
    _ = d2.functions.SetFont.call(.{4});
    d2.functions.DrawGameText.call(.{ @as([*:0]const u16, @ptrCast(&w)), 10, 100, 0, 0 });
}
