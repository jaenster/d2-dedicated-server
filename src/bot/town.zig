//! Town interaction: finding NPCs and opening vendors. Town NPCs are monsters
//! (unit type 1) that carry an NPC-menu entry; a vendor is one whose menu offers
//! a Trade (0x0D44) or Trade/Repair (0x0D06) option.
//!
//! Interaction is PACKET-driven (raw 0x2F interact / 0x38 npc-menu), so it works
//! headless — no viewport. The server auto-walks the player to the NPC on
//! interact, so a town vendor opens without any pathing on our side.

const std = @import("std");
const fns = @import("../engine/d2/functions.zig");
const log = @import("../log.zig");
const unit = @import("unit.zig");

const Unit = unit.Unit;

// Town NPCs live in the monster hash table (unit type 1).
const UNIT_MONSTER: u32 = 1;

/// Well-known NPC trade menu string ids.
pub const MENU_TRADE: u16 = 0x0D44; // "Trade"
pub const MENU_TRADE_REPAIR: u16 = 0x0D06; // "Trade / Repair" (smiths)

// C->S packet ids (server handlers: npc_interact @0x54B930 takes 0x2F,
// npc_menu @0x54BCA0 takes 0x38).
const PKT_NPC_INTERACT: u8 = 0x2F; // [0x2F][u32 unk=0][u32 npcGUID]
const PKT_NPC_MENU: u8 = 0x38; // [0x38][u32 npcGUID][u32 menuId][u32 params=0]

fn writeU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

/// True if `u`'s class has a Trade / Trade-Repair option (i.e. it's a vendor).
fn classIsVendor(class_id: u32) bool {
    const n = fns.npcMenuOptionCount(class_id);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const sid = fns.npcMenuOptionId(class_id, i);
        if (sid == MENU_TRADE or sid == MENU_TRADE_REPAIR) return true;
    }
    return false;
}

fn isVendorUnit(u: Unit) bool {
    return classIsVendor(u.classId());
}

/// Nearest town NPC of a specific MonStats class id (e.g. Akara=148, Charsi=154).
pub fn getNPC(class_id: u32) ?Unit {
    return unit.nearestByClass(UNIT_MONSTER, class_id);
}

/// Nearest VENDOR — the closest NPC whose menu has a Trade or Trade/Repair option.
pub fn nearestVendor() ?Unit {
    return unit.nearest(UNIT_MONSTER, &isVendorUnit);
}

/// Right-click / talk to an NPC: the server auto-walks the player into range and
/// opens the conversation. Headless-safe (no viewport).
pub fn interact(npc: Unit) void {
    var buf = [_]u8{0} ** 9;
    buf[0] = PKT_NPC_INTERACT;
    writeU32(&buf, 1, 0); // unk
    writeU32(&buf, 5, npc.unitId());
    fns.sendPacket(&buf);
}

/// Send an NPC menu selection (the raw 0x38 packet) for a specific menu id.
fn sendNpcMenu(npc: Unit, menu_id: u16) void {
    var buf = [_]u8{0} ** 13;
    buf[0] = PKT_NPC_MENU;
    writeU32(&buf, 1, npc.unitId());
    writeU32(&buf, 5, menu_id);
    writeU32(&buf, 9, 0); // params
    fns.sendPacket(&buf);
}

/// Open an NPC's trade/vendor window. Scans the NPC's OWN menu for a Trade /
/// Trade-Repair option and sends that; if it has neither known id, falls back to
/// sending each of its menu options in turn (a vendor's store is one of them).
/// Returns true if a known trade option was found and sent. Each send is the raw
/// 0x38 packet so it works headless. Mirrors ingame.openVendor.
pub fn openTradeMenu(npc: Unit) bool {
    const class_id = npc.classId();
    const n = fns.npcMenuOptionCount(class_id);
    const known = [_]u16{ MENU_TRADE, MENU_TRADE_REPAIR };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const sid = fns.npcMenuOptionId(class_id, i);
        for (known) |k| if (sid == k) {
            log.hex("town: opening vendor via trade id=0x", sid);
            sendNpcMenu(npc, sid);
            return true;
        };
    }
    // No standard trade id — try every option (a vendor's store is one of them).
    log.print("town: no standard trade id — trying each menu option");
    i = 0;
    while (i < n) : (i += 1) {
        const sid = fns.npcMenuOptionId(class_id, i);
        if (sid == 0) continue;
        sendNpcMenu(npc, sid);
    }
    return false;
}

/// Log an NPC's available menu option ids — handy for discovering the right menu
/// id for a given NPC (option order/ids vary per NPC).
pub fn dumpMenu(class_id: u32) void {
    log.hex("town: NPC menu for class=0x", class_id);
    const n = fns.npcMenuOptionCount(class_id);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        log.hex("town:   optionStringId=0x", fns.npcMenuOptionId(class_id, i));
    }
}
