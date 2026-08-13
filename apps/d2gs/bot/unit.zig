//! A thin, ergonomic wrapper over the engine's `*UnitAny` plus the finders that
//! walk the server-side unit hash tables. This is the layer kolbot/d2bs scripts
//! lean on the most — "give me the nearest monster of class X", "iterate every
//! object" — without re-deriving struct offsets or hash-table layout each time.
//!
//! Unit types in the hash table: 0=player 1=monster (incl. town NPCs) 2=object
//! 3=missile 4=item 5=tile. Town NPCs are monsters (type 1) flagged interactable.

const std = @import("std");
const globals = @import("../engine/d2/globals.zig");
const types = @import("../engine/d2/types.zig");
const fns = @import("../engine/d2/functions.zig");

const UnitAny = types.UnitAny;

pub const Pos = struct { x: i32, y: i32 };

/// Predicate over a `Unit` — used by the `nearest` finder to filter candidates.
pub const Predicate = *const fn (Unit) bool;

/// Ergonomic handle over `*UnitAny`. Copyable; just wraps the pointer.
pub const Unit = struct {
    ptr: *UnitAny,

    pub fn from(p: *UnitAny) Unit {
        return .{ .ptr = p };
    }

    /// MonStats / ObjectsTxt / ItemsTxt class id (dwTxtFileNo).
    pub fn classId(self: Unit) u32 {
        return self.ptr.dwTxtFileNo;
    }

    /// The unit's network GUID (dwUnitId) — what packets reference.
    pub fn unitId(self: Unit) u32 {
        return self.ptr.dwUnitId;
    }

    /// 0=player 1=monster 2=object 3=missile 4=item 5=tile.
    pub fn unitType(self: Unit) u32 {
        return self.ptr.dwType;
    }

    /// Current animation/action mode (dwMode).
    pub fn mode(self: Unit) u32 {
        return self.ptr.dwMode;
    }

    /// World tile position (works for both dynamic and static units).
    pub fn pos(self: Unit) Pos {
        const p = self.ptr.getPos();
        return .{ .x = p.x, .y = p.y };
    }

    /// Display name (UTF-16, engine-owned), or null if the unit has none.
    pub fn name(self: Unit) ?[*:0]u16 {
        return fns.GetUnitName.call(.{self.ptr});
    }

    /// Squared tile distance to another unit (cheap; avoids the sqrt).
    pub fn distanceTo(self: Unit, other: Unit) i64 {
        const o = other.pos();
        return self.distanceToXY(o.x, o.y);
    }

    /// Squared tile distance to a world tile.
    pub fn distanceToXY(self: Unit, x: i32, y: i32) i64 {
        const p = self.pos();
        const dx: i64 = p.x - x;
        const dy: i64 = p.y - y;
        return dx * dx + dy * dy;
    }
};

// ── finders over the server-side unit hash tables ───────────────────────────

/// First unit of `unit_type` in the hash table, or null if the table is empty.
pub fn first(unit_type: u32) ?Unit {
    if (unit_type >= types.UNIT_TYPE_COUNT) return null;
    const tables = globals.serverSideUnits();
    for (tables.byType[unit_type].table) |head| {
        if (head) |u| return Unit.from(u);
    }
    return null;
}

/// The next unit after `unit` in the same hash table, walking the `pListNext`
/// chain and crossing into following buckets. Null when the table is exhausted.
/// Lets a caller iterate every unit of a type: `var it = first(t); while (it) |u| : (it = next(u)) {...}`.
pub fn next(unit: Unit) ?Unit {
    if (unit.ptr.pListNext) |n| return Unit.from(n);
    // End of this bucket's chain — scan forward to the next non-empty bucket.
    const unit_type = unit.ptr.dwType;
    if (unit_type >= types.UNIT_TYPE_COUNT) return null;
    const tables = globals.serverSideUnits();
    const bucket = bucketOf(tables.byType[unit_type].table, unit.ptr) orelse return null;
    var b = bucket + 1;
    while (b < types.UNIT_HASH_SIZE) : (b += 1) {
        if (tables.byType[unit_type].table[b]) |u| return Unit.from(u);
    }
    return null;
}

/// Which bucket head-chain contains `unit` (so `next` can cross buckets).
fn bucketOf(table: [types.UNIT_HASH_SIZE]?*UnitAny, unit: *UnitAny) ?usize {
    for (table, 0..) |head, i| {
        var it: ?*UnitAny = head;
        while (it) |u| : (it = u.pListNext) {
            if (u == unit) return i;
        }
    }
    return null;
}

/// Nearest unit of `unit_type` (to the local player) for which `pred` is true.
/// Units without a resolved path are skipped (they have no usable position).
pub fn nearest(unit_type: u32, pred: Predicate) ?Unit {
    const origin = playerPos() orelse return null;
    if (unit_type >= types.UNIT_TYPE_COUNT) return null;
    const tables = globals.serverSideUnits();
    var best: ?Unit = null;
    var best_d: i64 = std.math.maxInt(i64);
    for (tables.byType[unit_type].table) |head| {
        var it: ?*UnitAny = head;
        while (it) |raw| : (it = raw.pListNext) {
            if (raw.dynamicPath() == null and !raw.isStaticUnit()) continue;
            const u = Unit.from(raw);
            if (!pred(u)) continue;
            const d = u.distanceToXY(origin.x, origin.y);
            if (d < best_d) {
                best_d = d;
                best = u;
            }
        }
    }
    return best;
}

var wanted_class: u32 = 0;
fn isWantedClass(u: Unit) bool {
    return u.classId() == wanted_class;
}

/// Nearest unit of `unit_type` whose class id matches `class_id`.
pub fn nearestByClass(unit_type: u32, class_id: u32) ?Unit {
    wanted_class = class_id;
    return nearest(unit_type, &isWantedClass);
}

/// The local player's world tile position, or null if not in a game yet.
fn playerPos() ?Pos {
    const p = globals.playerUnit().* orelse return null;
    _ = p.dynamicPath() orelse return null;
    const pos = p.getPos();
    return .{ .x = pos.x, .y = pos.y };
}
