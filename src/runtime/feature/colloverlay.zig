//! In-world collision-diff overlay (debug maphack). Draws a colored dot on the
//! automap at every subtile where our CLEAN-ROOM collision map (libd2) disagrees
//! with the real engine's CollMap, for SEED 1. At seed 1 the game's live collision
//! equals the golden the diff was baked against, so a lit cell is a real bug in our
//! reconstruction — walk to it and look at what's actually there.
//!
//! Data: colldiff.bin — sorted records {level:u16, x:u16, y:u16, type:u8} (LE),
//! generated offline from the ours-vs-golden collision diff. ONLY valid for seed 1.
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
//   2 yellow missile-barrier bit differs
//   3 cyan   preset / sub-theme (0x10) bit differs
//   4 white  other
const COLOR = [5]u32{ 0x6A, 0x97, 0x0D, 0xCB, 0xFF };

fn le16(off: usize) u32 {
    return @as(u32, blob[off]) | (@as(u32, blob[off + 1]) << 8);
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

    // Records are 7 bytes each after a u32 count header; sorted by level.
    const count = le16(0) | (@as(u32, blob[2]) << 16) | (@as(u32, blob[3]) << 24);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = 4 + i * 7;
        const rl = le16(off);
        if (rl != lvl) continue;
        const x: f64 = @floatFromInt(le16(off + 2));
        const y: f64 = @floatFromInt(le16(off + 4));
        const t = blob[off + 6];
        const col = COLOR[if (t < COLOR.len) t else 4];
        d2.automap.drawAutomapDot(x, y, col);
    }
}
