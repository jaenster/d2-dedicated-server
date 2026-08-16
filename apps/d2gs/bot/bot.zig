//! Bot framework facade — the single import a script (or the launcher) needs.
//! Re-exports the unit/me/pather/town primitives, drives a bot as a frame-synced
//! fiber task (off the OOG/game loop, like oog.run), and keeps a named REGISTRY
//! so a bot can be selected by name from the command line (`--bot <name>`).
//!
//! A bot is just a `fn() void` that yields each frame via `waitFrames` — no
//! threads, no sleeps. This is the kolbot/d2bs composition layer that aether
//! deliberately leaves to user scripts.

const oog = @import("../test/oog.zig");
const log = @import("../log.zig");

pub const unit = @import("unit.zig");
pub const me = @import("me.zig");
pub const pather = @import("pather.zig");
pub const town = @import("town.zig");

pub const Unit = unit.Unit;
pub const Pos = unit.Pos;

/// Yield `n` game frames (re-export of the fiber primitive) — bots call this.
pub const waitFrames = oog.waitFrames;

/// Install `task` as a frame-driven fiber on the OOG/game loop.
pub fn run(task: *const fn () void) void {
    oog.run(task);
}

// named bot registry

const Entry = struct {
    name: []const u8,
    task: *const fn () void,
};

/// Name -> task table. Add a bot here to make it selectable via `--bot <name>`.
pub const registry = [_]Entry{
    .{ .name = "trade", .task = &tradeVendorBot },
};

/// Look up a bot by name and install it. Returns false if no such bot exists.
pub fn start(name: []const u8) bool {
    for (registry) |e| {
        if (eql(e.name, name)) {
            run(e.task);
            return true;
        }
    }
    log.print("bot: unknown bot name");
    return false;
}

/// Run a registered bot's task INLINE (inside an already-running fiber) rather
/// than installing a fresh loop — used when chaining a bot after the login flow.
pub fn runInline(name: []const u8) bool {
    for (registry) |e| {
        if (eql(e.name, name)) {
            e.task();
            return true;
        }
    }
    log.print("bot: unknown bot name");
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// sample bot: trade with the nearest vendor

/// Optional target vendor class id; 0 = nearest vendor of any kind. Set via
/// `setTradeClass` before running for a specific NPC (Akara=148, Charsi=154, Gheed=147).
var trade_class: u32 = 0;

/// Pick a specific vendor class for the trade bot (0 = nearest vendor).
pub fn setTradeClass(class_id: u32) void {
    trade_class = class_id;
}

/// Sample bot (replaces ingame.tradeFlow): wait until in game, find the target
/// vendor, walk to it, interact (0x2F), and open its trade window (0x38).
/// Verifies the NPC-vendor data path end-to-end — watch the GS log for
/// `npc_interact` -> `npc_menu` -> `npc_genitem`.
pub fn tradeVendorBot() void {
    while (!me.inGame()) waitFrames(1);
    log.print("bot/trade: in game — locating vendor");
    waitFrames(25); // let the act/town units stream in

    const npc = (if (trade_class != 0) town.getNPC(trade_class) else town.nearestVendor()) orelse {
        log.print("bot/trade: no vendor NPC found nearby");
        return;
    };
    log.hex("bot/trade: found vendor class=0x", npc.classId());
    town.dumpMenu(npc.classId());

    // Movement only takes effect under a viewport (see pather.zig). Headless, the
    // server auto-walks the player on interact, so this is best-effort.
    const reached = pather.moveToUnit(npc, 4);
    if (reached) log.print("bot/trade: reached vendor") else log.print("bot/trade: not in range (expected headless) — relying on server auto-walk");

    town.interact(npc);
    log.print("bot/trade: sent interact (0x2F)");
    waitFrames(12);

    _ = town.openTradeMenu(npc);
    log.print("bot/trade: opened vendor — store should roll now (npc_genitem)");
    waitFrames(20);
    log.print("bot/trade: done");
}
