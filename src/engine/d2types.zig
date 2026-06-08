//! D2 1.14d engine struct definitions, mirrored from our Ghidra reconstruction
//! (session 9df5e900 = typeguru `Diablo2Lod/windows/1.14d/Game.exe`). Only the
//! subset we touch is defined here — grow it as features need more. Field offsets
//! and sizes are verified against the recon (comptime-asserted), NOT Charon's
//! older D2Structs.h (which is stale — e.g. its preset-unit layout is wrong).

const std = @import("std");

/// Unit kind (recon: eD2UnitType). pUnitList/preset/eUnitType use it.
pub const UnitType = enum(u32) {
    player = 0,
    monster = 1,
    object = 2,
    missile = 3,
    item = 4,
    warp = 5,
    _,
};

/// D2's FOG memory-pool manager. Opaque — we only pass the pointer to the engine's
/// pool functions (see engine/fog.zig). Each game owns one (D2GameStrc.pMemoryPool).
pub const D2PoolManagerStrc = opaque {};

// Still opaque — features only pass these pointers to engine functions for now.
// Promote to field-level structs (with recon offsets) when a feature reads them.
pub const D2RoomStrc = opaque {}; // "Room1" — in-game active room (recon 128B)
pub const D2RoomExStrc = opaque {}; // "Room2" — DRLG room (recon 236B)
pub const D2LevelStrc = opaque {}; // recon D2DrlgLevelStrc
pub const D2ActStrc = opaque {}; // recon D2DrlgActStrc
pub const D2AutomapLayer2Strc = opaque {}; // automap layer-2 (GetLayer result)

// ── D2GameStrc — a QServer game instance (recon: 7672 bytes, 72 fields) ───────
// Partial: head through the fields we read, then a tail pad to full size.
pub const D2GameStrc = extern struct {
    nToken: u32, // 0x00 hash key / game token from QServer
    pHashLink1: u32, // 0x04
    nHashLinkOffset1: u32, // 0x08
    pHashLink2: u32, // 0x0C
    nHashLinkOffset2: u32, // 0x10
    field_0x14: u32, // 0x14
    lpCriticalSection: u32, // 0x18 LPCRITICAL_SECTION
    pMemoryPool: ?*D2PoolManagerStrc, // 0x1C ← the game's FOG pool
    pBnetGameData: u32, // 0x20
    bGameIsSetup: i32, // 0x24 1 once initialized
    nServerToken: u16, // 0x28
    szGameName: [16]u8, // 0x2A
    szGamePassword: [16]u8, // 0x3A
    szGameDescription: [32]u8, // 0x4A
    nGameType: u8, // 0x6A eD2HostGameType
    nTemplate: u8, // 0x6B
    nReserved: u8, // 0x6C
    nDifficulty: u8, // 0x6D 0=Normal 1=Nightmare 2=Hell
    nLadder: u8, // 0x6E
    _pad_0x6F: u8, // 0x6F
    bExpansion: i32, // 0x70 0=Classic 1=Expansion
    eGameType: u32, // 0x74 eD2GSGameType
    _tail: [7552]u8, // 0x78.. rest of the 7672-byte struct

    pub inline fn pool(self: *D2GameStrc) ?*D2PoolManagerStrc {
        return self.pMemoryPool;
    }
    pub inline fn isExpansion(self: *const D2GameStrc) bool {
        return self.bExpansion != 0;
    }
    pub inline fn difficulty(self: *const D2GameStrc) u8 {
        return self.nDifficulty;
    }
    pub inline fn name(self: *const D2GameStrc) [:0]const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.szGameName)), 0);
    }

    comptime {
        std.debug.assert(@offsetOf(D2GameStrc, "pMemoryPool") == 0x1C);
        std.debug.assert(@offsetOf(D2GameStrc, "nDifficulty") == 0x6D);
        std.debug.assert(@offsetOf(D2GameStrc, "bExpansion") == 0x70);
        std.debug.assert(@sizeOf(D2GameStrc) == 7672);
    }
};

// ── D2UnitStrc — any unit (recon: 244 bytes, 52 fields) ───────────────────────
// Partial: the fields features read, gaps padded to keep offsets exact.
pub const D2UnitStrc = extern struct {
    eUnitType: UnitType, // 0x00
    nClassId: i32, // 0x04 txt-file index (PlrClass/MonStats/Objects/Items/...)
    pMemory: ?*D2PoolManagerStrc, // 0x08
    nUnitGUID: i32, // 0x0C
    eAnimMode: u32, // 0x10 dwMode
    pUnitData: u32, // 0x14 D2UnitDataUnion*
    nAct: u8, // 0x18
    _pad_0x19: [3]u8, // 0x19
    pDrlgAct: u32, // 0x1C
    sSeed: [2]u32, // 0x20 D2SeedStrc (lo,hi) — [2]u32 not u64 to keep align 4 (size 244)
    nInitSeed: i32, // 0x28
    pPath: u32, // 0x2C D2PathUnion* — world position lives here
    _pad_0x30: [0xE4 - 0x30]u8, // 0x30 .. 0xE4
    pListNext: ?*D2UnitStrc, // 0xE4 hash-table next (server/client unit list)
    pRoomNext: ?*D2UnitStrc, // 0xE8 room unit-list next
    _pad_0xEC: [244 - 0xEC]u8, // 0xEC .. 244

    pub inline fn unitType(self: *const D2UnitStrc) UnitType {
        return self.eUnitType;
    }
    /// txt-file index (a.k.a. dwTxtFileNo) — class id for this unit's kind.
    pub inline fn txtFileNo(self: *const D2UnitStrc) u32 {
        return @bitCast(self.nClassId);
    }
    pub inline fn mode(self: *const D2UnitStrc) u32 {
        return self.eAnimMode;
    }
    pub inline fn is(self: *const D2UnitStrc, t: UnitType) bool {
        return self.eUnitType == t;
    }

    comptime {
        std.debug.assert(@offsetOf(D2UnitStrc, "pPath") == 44);
        std.debug.assert(@offsetOf(D2UnitStrc, "pListNext") == 228);
        std.debug.assert(@offsetOf(D2UnitStrc, "pRoomNext") == 232);
        std.debug.assert(@sizeOf(D2UnitStrc) == 244);
    }
};

// ── D2PresetUnitStrc — a DRLG preset placement (recon: 32 bytes) ──────────────
pub const D2PresetUnitStrc = extern struct {
    nMode: i32, // 0x00 1=monster, 3=item (item code encoded)
    nClassId: i32, // 0x04 MonStats/Object id
    nPosX: i32, // 0x08 world X (sub-tile)
    pPresetUnitNext: ?*D2PresetUnitStrc, // 0x0C
    pPath: u32, // 0x10 preset path data
    eType: UnitType, // 0x14
    nPosY: i32, // 0x18 world Y (sub-tile)
    nFlags: i32, // 0x1C bit0 = auto-generated

    pub inline fn next(self: *const D2PresetUnitStrc) ?*D2PresetUnitStrc {
        return self.pPresetUnitNext;
    }
    pub inline fn unitType(self: *const D2PresetUnitStrc) UnitType {
        return self.eType;
    }
    /// World position of the preset within its room (sub-tile units).
    pub inline fn pos(self: *const D2PresetUnitStrc) struct { x: i32, y: i32 } {
        return .{ .x = self.nPosX, .y = self.nPosY };
    }

    comptime {
        std.debug.assert(@offsetOf(D2PresetUnitStrc, "nPosX") == 8);
        std.debug.assert(@offsetOf(D2PresetUnitStrc, "nPosY") == 24);
        std.debug.assert(@sizeOf(D2PresetUnitStrc) == 32);
    }
};

// ── automap (recon /Diablo2/AUTOMAP) ─────────────────────────────────────────
pub const D2AutomapCellStrc = extern struct {
    fSaved: u8, // 0x00 1=loaded from save, 0=revealed at runtime
    _pad_0x01: [3]u8, // 0x01
    nCellNo: i16, // 0x04
    xPixel: i16, // 0x06
    yPixel: i16, // 0x08
    wWeight: i16, // 0x0A
    pLess: ?*D2AutomapCellStrc, // 0x0C
    pMore: ?*D2AutomapCellStrc, // 0x10

    comptime {
        std.debug.assert(@offsetOf(D2AutomapCellStrc, "nCellNo") == 4);
        std.debug.assert(@sizeOf(D2AutomapCellStrc) == 20);
    }
};

pub const D2AutomapLayerStrc = extern struct {
    nLayer: i32, // 0x00
    fSaved: u32, // 0x04
    pFloors: ?*D2AutomapCellStrc, // 0x08
    pWalls: ?*D2AutomapCellStrc, // 0x0C
    pObjects: ?*D2AutomapCellStrc, // 0x10
    pExtras: ?*D2AutomapCellStrc, // 0x14
    pNext: ?*D2AutomapLayerStrc, // 0x18

    /// `&pObjects` — the list AddAutomapCell appends marker cells to.
    pub inline fn objects(self: *D2AutomapLayerStrc) *?*D2AutomapCellStrc {
        return &self.pObjects;
    }

    comptime {
        std.debug.assert(@offsetOf(D2AutomapLayerStrc, "pObjects") == 0x10);
        std.debug.assert(@sizeOf(D2AutomapLayerStrc) == 28);
    }
};
