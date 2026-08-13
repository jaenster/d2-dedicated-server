//! Map units (client-side maphack) — draws monster / item / missile markers on
//! the automap. Ported from aether's features/map_units.zig (jaenster). Feature
//! is gated by its enable flag, so the per-category settings are forced on here.
const d2 = struct {
    const functions = @import("../../engine/d2/functions.zig");
    const globals = @import("../../engine/d2/globals.zig");
    const types = @import("../../engine/d2/types.zig");
    const automap = @import("../../engine/d2/automap.zig");
};

const UnitAny = d2.types.UnitAny;

// d2gs has no settings system — the feature toggle gates the whole module.
const show_monsters = true;
const show_items = true;
const show_missiles = true;

// Palette colors for item quality display
const item_rarity_color = [_]u32{ 255, 29, 30, 32, 151, 132, 111, 155, 111 };

pub fn gameAutomapPostDraw() void {
    // Don't draw if player isn't valid yet
    const player = d2.globals.playerUnit().* orelse return;
    _ = player.dynamicPath() orelse return;

    if (show_monsters) drawMonsters();
    if (show_items) drawItems();
    if (show_missiles) drawMissiles();
}

fn drawMonsters() void {
    const tables = d2.globals.serverSideUnits();
    for (tables.byType[1].table) |first| {
        var unit_opt: ?*UnitAny = first;
        while (unit_opt) |unit| {
            defer unit_opt = unit.pListNext;
            if (!isHostile(unit) or unitHP(unit) == 0 or !isAttackable(unit)) continue;

            const pos = d2.automap.unitPos(unit);
            const mdata = monsterData(unit) orelse continue;

            if (mdata.type_flags & 0x02 != 0) {
                // Unique/superunique
                d2.automap.drawAutomapX(pos.x, pos.y, 0x0C, 5.0);
            } else if (mdata.type_flags & 0x04 != 0) {
                // Champion
                d2.automap.drawAutomapX(pos.x, pos.y, 0x0C, 5.0);
            } else if (mdata.type_flags & 0x08 != 0) {
                // Minion
                d2.automap.drawAutomapX(pos.x, pos.y, 0x0B, 5.0);
            } else {
                d2.automap.drawAutomapX(pos.x, pos.y, 0x0A, 5.0);
            }
        }
    }
}

fn drawItems() void {
    const tables = d2.globals.serverSideUnits();
    for (tables.byType[4].table) |first| {
        var unit_opt: ?*UnitAny = first;
        while (unit_opt) |unit| {
            defer unit_opt = unit.pListNext;

            // Only show items on ground (mode 3 = dropped, mode 5 = dropping)
            if (unit.dwMode != 3 and unit.dwMode != 5) continue;

            const idata = itemData(unit) orelse continue;
            const pos = d2.automap.unitPos(unit);

            // Ethereal items
            if (idata.dwItemFlags & 0x4000000 != 0) {
                d2.automap.drawAutomapX(pos.x, pos.y, item_rarity_color[7], 3.0);
                continue;
            }

            // Quality items (magic+) or socketed superior+
            if (idata.dwQuality > 3 or
                (idata.dwItemFlags & 0x400800 != 0 and idata.dwQuality > 2 and
                    d2.functions.GetUnitStat.call(unit, 194, 0) >= 2))
            {
                const qi = if (idata.dwQuality < item_rarity_color.len) idata.dwQuality else 0;
                d2.automap.drawAutomapX(pos.x, pos.y, item_rarity_color[qi], 3.0);
                continue;
            }

            // Gems/runes/jewels
            const txt = d2.functions.GetItemText.call(unit.dwTxtFileNo) orelse continue;
            if ((txt.nType >= 96 and txt.nType <= 102) or txt.nType == 74) {
                d2.automap.drawAutomapX(pos.x, pos.y, 169, 3.0);
            }
        }
    }
}

fn drawMissiles() void {
    const tables = d2.globals.clientSideUnits();
    for (tables.byType[3].table) |first| {
        var unit_opt: ?*UnitAny = first;
        while (unit_opt) |unit| {
            defer unit_opt = unit.pListNext;
            const pos = d2.automap.unitPos(unit);
            d2.automap.drawAutomapDot(pos.x, pos.y, 0x99);
        }
    }
}

// Helpers — check unit flags via stat system
fn isHostile(unit: *const UnitAny) bool {
    return d2.functions.GetUnitStat.call(@constCast(unit), 172, 0) == 0;
}

fn isAttackable(unit: *const UnitAny) bool {
    return unit.dwFlags & 0x4 != 0;
}

fn unitHP(unit: *const UnitAny) u32 {
    return d2.functions.GetUnitStat.call(@constCast(unit), 6, 0) >> 8;
}

const MonsterData = d2.types.MonsterData;
const ItemData = d2.types.ItemData;

fn monsterData(unit: *const UnitAny) ?*MonsterData {
    const ptr = unit.pUnitData orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn itemData(unit: *const UnitAny) ?*ItemData {
    const ptr = unit.pUnitData orelse return null;
    return @ptrCast(@alignCast(ptr));
}
