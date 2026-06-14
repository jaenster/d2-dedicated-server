//! Map reveal (client-side maphack) — fully reveals the current level's automap
//! and adds warp/preset markers. Ported from aether's features/map_reveal.zig
//! (jaenster). gameFrame walks the level/room tree (budgeted) and reveals; the
//! automap post-draw renders warp labels and the Arcane Sanctuary marker. Feature
//! is gated by its enable flag, so reveal_map is forced on here.
const std = @import("std");
const log = @import("../../log.zig");
const d2 = struct {
    const functions = @import("../../engine/d2/functions.zig");
    const globals = @import("../../engine/d2/globals.zig");
    const types = @import("../../engine/d2/types.zig");
    const automap = @import("../../engine/d2/automap.zig");
};

extern "kernel32" fn GetTickCount() callconv(.winapi) u32;

// d2gs has no settings system — the feature toggle gates the whole module.
const reveal_map = true;

const Room2 = d2.types.Room2;
const Level = d2.types.Level;
const AutomapLayer = d2.types.AutomapLayer;
const PresetUnit = d2.types.PresetUnit;

const LevelLabel = struct {
    x: f64,
    y: f64,
    layer_no: u32,
    level_no: u32,
};

const RevealState = struct {
    revealed: bool = false,
    next_room: ?*Room2 = null,
    layer: ?*AutomapLayer = null,
};

var current_level: u32 = 0;
var reveal_start: u32 = 0;
var in_game: bool = false;

var level_labels: [256]LevelLabel = undefined;
var label_count: usize = 0;
var reveal_data: [256]RevealState = [_]RevealState{.{}} ** 256;

// Arcane Sanctuary warp direction indicator
var arcane_warp: ?struct { x: f64, y: f64 } = null;

pub fn gameFrame() void {
    if (!reveal_map) return;
    if (!in_game) {
        label_count = 0;
        in_game = true;
        current_level = 0;
        reveal_start = 0;
        // game entered
    }

    const player = d2.globals.playerUnit().* orelse return;
    const path = player.dynamicPath() orelse return;
    const room1 = path.pRoom1 orelse return;
    const room2 = room1.pRoom2 orelse return;
    const level = room2.pLevel orelse return;

    const level_no = level.dwLevelNo;
    if (level_no != current_level) {
        current_level = level_no;
        reveal_start = GetTickCount();
        reveal_data = [_]RevealState{.{}} ** 256;
        label_count = 0;
        arcane_warp = null;
        // level changed
    }

    if (GetTickCount() -% reveal_start < 200) return;

    revealCurrentLevel(player);
}

pub fn oogFrame() void {
    current_level = 0;
    in_game = false;
}

pub fn gameAutomapPostDraw() void {
    const automap_layer = d2.globals.automapLayer().* orelse return;

    for (level_labels[0..label_count]) |label| {
        if (label.layer_no == automap_layer.nLayerNo) {
            drawWarpText(label.x, label.y, label.level_no);
        }
    }

    // Arcane Sanctuary — marker at the start of the Summoner's branch
    if (arcane_warp) |summoner| {
        if (current_level == 74) {
            d2.automap.drawAutomapX(summoner.x, summoner.y, 0x62, 5.0);
        }
    }
}

fn drawWarpText(x: f64, y: f64, level_no: u32) void {
    const level_txt = d2.functions.GetLevelText.call(level_no) orelse return;
    const name_ptr: [*:0]const u16 = @ptrCast(&level_txt.wName);

    var width: u32 = 0;
    var font_num: u32 = 6;
    _ = d2.functions.SetFont.call(.{6});
    _ = d2.functions.GetTextSize.call(.{ name_ptr, &width, &font_num });

    const pos = d2.automap.toAutomap(x, y);
    const offset_x = 8 - @as(c_int, @intCast(width / 2));
    d2.functions.DrawGameText.call(.{ name_ptr, pos.x + offset_x, pos.y - 16, 0, 0 });
}

fn isValidPtr(addr: usize) bool {
    return addr >= 0x10000 and addr < 0x7FFFFFFF;
}

fn revealCurrentLevel(player: *d2.types.UnitAny) void {
    const act = player.pAct orelse return;
    const misc = act.pMisc orelse return;
    const automap_layer = d2.globals.automapLayer().* orelse return;

    var budget: u32 = 20;

    var level = misc.pLevelFirst;
    while (level) |lvl| : (level = lvl.pNextLevel) {
        if (!isValidPtr(@intFromPtr(lvl))) {
            log.hex("BAD level ptr: ", @intFromPtr(lvl));
            return;
        }
        if (budget == 0) return;

        const lno = lvl.dwLevelNo;
        if (lno == 0 or lno >= 256) continue;
        if (lvl.pRoom2First == null) continue;

        const layer2 = d2.functions.GetLayer.call(.{lno}) orelse continue;
        if (layer2.nLayerNo != automap_layer.nLayerNo) continue;

        var state = &reveal_data[lno];
        if (state.revealed) continue;

        state.layer = automap_layer;

        // Resume from where we left off, or start from beginning
        var room2 = state.next_room orelse lvl.pRoom2First;
        while (room2) |r2| : (room2 = r2.pRoom2Next) {
            if (!isValidPtr(@intFromPtr(r2))) {
                log.hex("BAD room2 ptr: ", @intFromPtr(r2));
                return;
            }
            if (budget == 0) {
                state.next_room = room2;
                return;
            }
            if (r2.pLevel != null and isValidPtr(@intFromPtr(r2.pLevel))) {
                ensureAndReveal(r2, automap_layer);
                budget -= 1;
            }
        }

        // Finished this level
        state.revealed = true;
        state.next_room = null;
    }
}

var reveal_room_count: u32 = 0;

fn ensureAndReveal(room2: *Room2, layer: ?*AutomapLayer) void {
    const lyr = layer orelse return;
    reveal_room_count += 1;

    // Validate pLevel — force-loaded rooms can have garbage pointers
    const lvl_ptr = @intFromPtr(room2.pLevel);
    if (lvl_ptr != 0 and !isValidPtr(lvl_ptr)) {
        log.hex("BAD pLevel in room2: ", lvl_ptr);
        return;
    }

    const lvl_no = if (room2.pLevel) |l| l.dwLevelNo else 0;

    // Skip rooms with no valid level — RevealAutomapRoom crashes on these
    if (lvl_no == 0 or lvl_no >= 256) return;

    var added_room = false;
    if (room2.pRoom1 == null) {
        const lvl = room2.pLevel orelse return;
        const misc = lvl.pMisc orelse return;
        const act = misc.pAct orelse return;
        d2.functions.AddRoomData.call(act, @intCast(lvl.dwLevelNo), @intCast(room2.dwPosX), @intCast(room2.dwPosY), room2.pRoom1);
        added_room = true;
    }

    if (room2.pRoom1) |room1| {
        d2.functions.RevealAutomapRoom.call(room1, 1, lyr);
        drawPresets(room2, lyr);
    }

    if (added_room) {
        const lvl = room2.pLevel orelse return;
        const misc = lvl.pMisc orelse return;
        const act = misc.pAct orelse return;
        d2.functions.RemoveRoomData.call(act, @intCast(lvl.dwLevelNo), @intCast(room2.dwPosX), @intCast(room2.dwPosY), room2.pRoom1);
    }
}

fn drawPresets(room2: *Room2, layer: *AutomapLayer) void {
    var preset = room2.pPreset;
    while (preset) |unit| : (preset = unit.pPresetNext) {
        if (!isValidPtr(@intFromPtr(unit))) return;
        switch (unit.dwType) {
            1 => {
                switch (unit.dwTxtFileNo) {
                    250 => {
                        generateCell(room2, unit, 300, layer);
                        // Record Summoner position for Arcane direction indicator
                        if (room2.pLevel) |lvl| {
                            if (lvl.dwLevelNo == 74) {
                                arcane_warp = .{
                                    .x = @as(f64, @floatFromInt(unit.dwPosX)) + @as(f64, @floatFromInt(room2.dwPosX)) * 5.0,
                                    .y = @as(f64, @floatFromInt(unit.dwPosY)) + @as(f64, @floatFromInt(room2.dwPosY)) * 5.0,
                                };
                            }
                        }
                    },
                    256 => generateCell(room2, unit, 300, layer),
                    743, 744, 745 => generateCell(room2, unit, 300, layer),
                    else => {},
                }
            },
            2 => {
                switch (unit.dwTxtFileNo) {
                    580 => {
                        if (room2.pLevel) |lvl| {
                            if (lvl.dwLevelNo == 79) {
                                generateCell(room2, unit, 319, layer);
                                continue;
                            }
                        }
                        generateOwnCell(room2, unit, layer);
                    },
                    371 => generateCell(room2, unit, 318, layer),
                    152 => generateCell(room2, unit, 300, layer),
                    460 => generateCell(room2, unit, 1468, layer),
                    267 => {
                        if (room2.pLevel) |lvl| {
                            if (lvl.dwLevelNo != 75 and lvl.dwLevelNo != 103) continue;
                        }
                        generateOwnCell(room2, unit, layer);
                    },
                    268 => generateCell(room2, unit, 300, layer),
                    376 => {
                        if (room2.pLevel) |lvl| {
                            if (lvl.dwLevelNo == 107) continue;
                        }
                        generateOwnCell(room2, unit, layer);
                    },
                    // Promoted markers — bigger/brighter than nAutoMap default
                    109 => generateCell(room2, unit, 300, layer), // Stash
                    354 => generateCell(room2, unit, 300, layer), // Hellforge
                    356 => generateCell(room2, unit, 300, layer), // Khalim Orifice
                    357 => generateCell(room2, unit, 318, layer), // Horadric Cube Chest
                    392, 393, 394, 395, 396 => generateCell(room2, unit, 301, layer), // Chaos Sanctuary Seals
                    569 => generateCell(room2, unit, 300, layer), // Throne of Destruction Portal
                    // Waypoints — already rendered by RevealAutomapRoom
                    119, 145, 156, 157, 237, 238, 288, 323, 324, 398, 402, 429, 494, 496, 511, 539 => {},
                    else => {
                        if (unit.dwTxtFileNo <= 574) {
                            generateOwnCell(room2, unit, layer);
                        }
                    },
                }
            },
            5 => { // Tiles (warps)
                if (room2.pLevel) |lvl| {
                    if (lvl.pMisc) |misc| {
                        if (misc.dwStaffTombLevel != 0) {
                            var rt = room2.pRoomTiles;
                            while (rt) |tile| : (rt = tile.pNext) {
                                if (!isValidPtr(@intFromPtr(tile))) break;
                                if (tile.nNum) |num| {
                                    if (!isValidPtr(@intFromPtr(num))) continue;
                                    if (num.* == unit.dwTxtFileNo) {
                                        if (tile.pRoom2) |tile_room| {
                                            if (!isValidPtr(@intFromPtr(tile_room))) continue;
                                            if (tile_room.pLevel) |tile_lvl| {
                                                if (!isValidPtr(@intFromPtr(tile_lvl))) continue;
                                                if (tile_lvl.dwLevelNo == misc.dwStaffTombLevel) {
                                                    generateCell(room2, unit, 301, layer);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                const warpto = getFirstTileOtherRoom(room2, unit.dwTxtFileNo);
                if (warpto) |dest_room| {
                    if (!isValidPtr(@intFromPtr(dest_room))) continue;
                    if (dest_room.pLevel) |dest_lvl| {
                        if (!isValidPtr(@intFromPtr(dest_lvl))) continue;
                        // Skip if destination is same level (waypoints etc.)
                        if (room2.pLevel) |src_lvl| {
                            if (dest_lvl.dwLevelNo == src_lvl.dwLevelNo) continue;
                        }
                        if (label_count < level_labels.len) {
                            level_labels[label_count] = .{
                                .x = @as(f64, @floatFromInt(unit.dwPosX)) + @as(f64, @floatFromInt(room2.dwPosX)) * 5.0,
                                .y = @as(f64, @floatFromInt(unit.dwPosY)) + @as(f64, @floatFromInt(room2.dwPosY)) * 5.0,
                                .layer_no = if (d2.globals.automapLayer().*) |al| al.nLayerNo else 0,
                                .level_no = dest_lvl.dwLevelNo,
                            };
                            label_count += 1;
                        }
                    }
                }
            },
            else => {},
        }
    }
}

fn generateCell(room2: *const Room2, unit: *const PresetUnit, cell_no: i16, layer: *AutomapLayer) void {
    const cell = d2.functions.NewAutomapCell.call(.{}) orelse return;
    const px = @as(i32, @intCast(unit.dwPosX)) + @as(i32, @intCast(room2.dwPosX)) * 5;
    const py = @as(i32, @intCast(unit.dwPosY)) + @as(i32, @intCast(room2.dwPosY)) * 5;
    cell.nCellNo = cell_no;
    cell.xPixel = @intCast(@divTrunc((px - py) * 16, 10) + 1);
    cell.yPixel = @intCast(@divTrunc((py + px) * 8, 10) - 3);
    d2.functions.AddAutomapCell.call(.{ cell, &layer.pObjects });
}

const nTxtObjectsSize: *const u32 = @ptrFromInt(0x0096d474);

fn generateOwnCell(room2: *const Room2, unit: *const PresetUnit, layer: *AutomapLayer) void {
    // Bounds-check before calling GetObjectText — it calls Fog's unrecoverable error halt
    // on out-of-range input instead of returning null
    const id = unit.dwTxtFileNo;
    if (id >= nTxtObjectsSize.* or nTxtObjectsSize.* == 0) return;
    const obj = d2.functions.GetObjectText.call(id) orelse return;
    if (!isValidPtr(@intFromPtr(obj))) return;
    if (obj.nAutoMap > 0) {
        generateCell(room2, unit, @intCast(obj.nAutoMap), layer);
    }
}

fn getFirstTileOtherRoom(room2: *const Room2, num: u32) ?*Room2 {
    var rt = room2.pRoomTiles;
    while (rt) |tile| : (rt = tile.pNext) {
        if (!isValidPtr(@intFromPtr(tile))) break;
        if (tile.nNum) |n| {
            if (!isValidPtr(@intFromPtr(n))) continue;
            if (n.* == num) return tile.pRoom2;
        }
    }
    return null;
}
