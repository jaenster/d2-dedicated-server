const std = @import("std");
const DWORD = u32;
const WORD = u16;
const BYTE = u8;
const BOOL = i32;

pub const UnitType = enum(DWORD) {
    player = 0,
    monster = 1,
    object = 2,
    missile = 3,
    item = 4,
    roomtile = 5,
};

pub const ItemQuality = enum(DWORD) {
    low = 1,
    normal = 2,
    superior = 3,
    magic = 4,
    set = 5,
    rare = 6,
    unique = 7,
    crafted = 8,
};

pub const GameType = enum(c_int) {
    singleplayer = 0,
    singleplayer_uncapped = 1,
    bnet_beta = 2,
    bnet = 3,
    _,
    // lan_host = 8,
    // lan_join = 9,
};

pub const PlayerStatus = packed struct(i16) {
    _pad0: u2 = 0,
    hardcore: bool = false,
    _pad1: u2 = 0,
    expansion: bool = false,
    _pad2: u10 = 0,
};

// UnitAny — 0xF4 bytes (244)
pub const UnitAny = extern struct {
    dwType: DWORD, // 0x00
    dwTxtFileNo: DWORD, // 0x04
    _08: DWORD, // 0x08
    dwUnitId: DWORD, // 0x0C
    dwMode: DWORD, // 0x10
    pUnitData: ?*anyopaque, // 0x14 — PlayerData/ItemData/MonsterData/ObjectData
    dwAct: DWORD, // 0x18
    pAct: ?*Act, // 0x1C
    dwLoSeed: DWORD, // 0x20
    dwHiSeed: DWORD, // 0x24
    dwInitSeed: DWORD, // 0x28
    pPath: ?*anyopaque, // 0x2C — DynamicPath or StaticPath depending on dwType
    pAnimSeq: ?*anyopaque, // 0x30
    dwSeqFrameCount: DWORD, // 0x34
    dwSeqFrame: DWORD, // 0x38
    dwAnimSpeed: DWORD, // 0x3C
    dwSeqMode: DWORD, // 0x40
    dwGfxFrame: DWORD, // 0x44
    dwFrameRemain: DWORD, // 0x48
    wFrameRate: WORD, // 0x4C
    wActionFrame: WORD, // 0x4E
    pGfxUnk: ?*anyopaque, // 0x50
    pGfxInfo: ?*anyopaque, // 0x54
    pGfxInfoCopy: ?*anyopaque, // 0x58
    pStats: ?*StatList, // 0x5C
    pInventory: ?*Inventory, // 0x60
    ptLight: ?*anyopaque, // 0x64
    dwStartLightRadius: DWORD, // 0x68
    nPl2ShiftIdx: WORD, // 0x6C
    nUpdateType: WORD, // 0x6E
    pUpdateUnit: ?*UnitAny, // 0x70
    pQuestRecord: ?*anyopaque, // 0x74
    bSparklyChest: DWORD, // 0x78
    pTimerArgs: ?*anyopaque, // 0x7C
    dwSoundSync: DWORD, // 0x80
    _84: [2]DWORD, // 0x84
    wX: WORD, // 0x8C
    wY: WORD, // 0x8E
    _90: DWORD, // 0x90
    dwOwnerType: DWORD, // 0x94
    dwOwnerId: DWORD, // 0x98
    _9C: [2]DWORD, // 0x9C
    pOMsg: ?*anyopaque, // 0xA4
    pInfo: ?*Info, // 0xA8
    pCombat: ?*anyopaque, // 0xAC
    dwLastHitClass: DWORD, // 0xB0
    _B4: DWORD, // 0xB4
    dwDropItemCode: DWORD, // 0xB8
    _BC: DWORD, // 0xBC
    _C0: DWORD, // 0xC0
    dwFlags: DWORD, // 0xC4
    dwFlags2: DWORD, // 0xC8
    _CC: [5]DWORD, // 0xCC
    pChangedNext: ?*UnitAny, // 0xE0
    pListNext: ?*UnitAny, // 0xE4
    pRoomNext: ?*UnitAny, // 0xE8
    pMsgFirst: ?*anyopaque, // 0xEC
    pMsgLast: ?*anyopaque, // 0xF0

    /// Objects (2), items (4), and tiles (5) use StaticPath, everything else uses DynamicPath
    pub fn isStaticUnit(self: *const UnitAny) bool {
        return self.dwType == 2 or self.dwType == 4 or self.dwType == 5;
    }

    pub fn dynamicPath(self: *const UnitAny) ?*DynamicPath {
        return @ptrCast(@alignCast(self.pPath));
    }

    pub fn staticPath(self: *const UnitAny) ?*StaticPath {
        return @ptrCast(@alignCast(self.pPath));
    }

    pub fn getPos(self: *const UnitAny) struct { x: i32, y: i32 } {
        if (self.isStaticUnit()) {
            const sp = self.staticPath() orelse return .{ .x = 0, .y = 0 };
            return .{ .x = @bitCast(sp.xPos), .y = @bitCast(sp.yPos) };
        }
        const dp = self.dynamicPath() orelse return .{ .x = 0, .y = 0 };
        return .{ .x = @as(i32, dp.xPos), .y = @as(i32, dp.yPos) };
    }

    pub fn getRoom1(self: *const UnitAny) ?*Room1 {
        if (self.isStaticUnit()) {
            const sp = self.staticPath() orelse return null;
            return sp.pRoom1;
        }
        const dp = self.dynamicPath() orelse return null;
        return dp.pRoom1;
    }

    comptime {
        std.debug.assert(@sizeOf(UnitAny) == 0xF4);
    }
};

// DynamicPath — used by players, monsters, missiles (moving units)
pub const DynamicPath = extern struct {
    xOffset: WORD, // 0x00
    xPos: WORD, // 0x02
    yOffset: WORD, // 0x04
    yPos: WORD, // 0x06
    _08: [2]DWORD, // 0x08
    xTarget: WORD, // 0x10
    yTarget: WORD, // 0x12
    _14: [2]DWORD, // 0x14
    pRoom1: ?*Room1, // 0x1C
    pRoomUnk: ?*Room1, // 0x20
    _24: [3]DWORD, // 0x24
    pUnit: ?*UnitAny, // 0x30
    dwFlags: DWORD, // 0x34
    _38: DWORD, // 0x38
    dwPathType: DWORD, // 0x3C
    dwPrevPathType: DWORD, // 0x40
    dwUnitSize: DWORD, // 0x44
    _48: [4]DWORD, // 0x48
    pTargetUnit: ?*UnitAny, // 0x58
    dwTargetType: DWORD, // 0x5C
    dwTargetId: DWORD, // 0x60
    bDirection: BYTE, // 0x64
};

// StaticPath — used by objects, items on ground (stationary units)
pub const StaticPath = extern struct {
    pRoom1: ?*Room1, // 0x00
    nScreenX: i32, // 0x04
    nScreenY: i32, // 0x08
    xPos: DWORD, // 0x0C — world tile X
    yPos: DWORD, // 0x10 — world tile Y
    _14: DWORD, // 0x14
    _18: DWORD, // 0x18
    nDirection: BYTE, // 0x1C
};

// Legacy alias — DynamicPath is what most code expects for pPath
pub const Path = DynamicPath;

// D2UnderMouseStrc — passed to PLAYER_InteractWithObject/Unit (0x20 bytes)
pub const D2UnderMouseStrc = extern struct {
    flags: DWORD, // 0x00
    pPlayer: ?*UnitAny, // 0x04
    pTarget: ?*UnitAny, // 0x08
    nX: DWORD, // 0x0C
    nY: DWORD, // 0x10
    nMoveActionType: i32, // 0x14 — 1=left skill walk
    nAttackActionType: i32, // 0x18 — 2=left skill interact
    pSkill: ?*anyopaque, // 0x1C

    comptime {
        std.debug.assert(@sizeOf(D2UnderMouseStrc) == 0x20);
    }
};

pub const StatList = extern struct {
    _00: DWORD, // 0x00
    pUnit: ?*UnitAny, // 0x04
    dwUnitType: DWORD, // 0x08
    dwUnitId: DWORD, // 0x0C
    dwFlags: DWORD, // 0x10
    _14: [4]DWORD, // 0x14
    stat_vec: StatVector, // 0x24
    pPrevLink: ?*StatList, // 0x2C
    _30: DWORD, // 0x30
    pPrev: ?*StatList, // 0x34
    _38: DWORD, // 0x38
    pNext: ?*StatList, // 0x3C
    pSetList: ?*StatList, // 0x40
    _44: DWORD, // 0x44
    set_stat_vec: StatVector, // 0x48
    _50: [2]DWORD, // 0x50
    state_bits: [6]DWORD, // 0x58
};

pub const Stat = extern struct {
    wSubIndex: WORD, // 0x00
    wStatIndex: WORD, // 0x02
    dwStatValue: DWORD, // 0x04
};

pub const StatVector = extern struct {
    pStats: ?*Stat,
    wCount: WORD,
    wSize: WORD,
};

pub const Inventory = extern struct {
    dwSignature: DWORD, // 0x00
    bGame1C: ?*anyopaque, // 0x04
    pOwner: ?*UnitAny, // 0x08
    pFirstItem: ?*UnitAny, // 0x0C
    pLastItem: ?*UnitAny, // 0x10
    _14: [2]DWORD, // 0x14
    dwLeftItemUid: DWORD, // 0x1C
    pCursorItem: ?*UnitAny, // 0x20
    dwOwnerId: DWORD, // 0x24
    dwItemCount: DWORD, // 0x28
};

pub const Info = extern struct {
    pGame1C: ?*anyopaque, // 0x00
    pFirstSkill: ?*Skill, // 0x04
    pLeftSkill: ?*Skill, // 0x08
    pRightSkill: ?*Skill, // 0x0C
};

pub const SkillInfo = extern struct {
    wSkillId: WORD, // 0x00
};

pub const Skill = extern struct {
    pSkillInfo: ?*SkillInfo, // 0x00
    pNextSkill: ?*Skill, // 0x04
    _08: [8]DWORD, // 0x08
    dwSkillLevel: DWORD, // 0x28
    _2C: [2]DWORD, // 0x2C
    item_id: DWORD, // 0x34 — 0xFFFFFFFF if not a charge
    charges_left: DWORD, // 0x38
    is_charge: DWORD, // 0x3C — 1 for charge, else 0
};

pub const PlayerData = extern struct {
    szName: [0x10]u8, // 0x00
    pNormalQuest: ?*anyopaque, // 0x10
    pNightmareQuest: ?*anyopaque, // 0x14
    pHellQuest: ?*anyopaque, // 0x18
    pNormalWaypoint: ?*anyopaque, // 0x1C
    pNightmareWaypoint: ?*anyopaque, // 0x20
    pHellWaypoint: ?*anyopaque, // 0x24
};

pub const ItemData = extern struct {
    dwQuality: DWORD, // 0x00 — eD2ItemQuality
    dwSeed: [2]DWORD, // 0x04 — D2SeedStrc
    nPlayerGUID: DWORD, // 0x0C
    nModSeed: DWORD, // 0x10
    eItemCmd: DWORD, // 0x14 — eD2ItemCmd
    dwItemFlags: DWORD, // 0x18 — eD2ItemFlag (runeword=0x4000000, identified=0x10, etc.)
    _1C: [2]DWORD, // 0x1C
    dwActionStamp: DWORD, // 0x24
    dwFileIndex: DWORD, // 0x28
    dwItemLevel: DWORD, // 0x2C
    wItemFormat: WORD, // 0x30
    wRarePrefix: WORD, // 0x32
    wRareSuffix: WORD, // 0x34
    wAutoPrefix: WORD, // 0x36
    wMagicPrefix: [3]WORD, // 0x38
    wMagicSuffix: [3]WORD, // 0x3E
    body_location: BYTE, // 0x44 — eD2BodyLoc
    item_location: BYTE, // 0x45 — eInventoryPage
    _46: WORD, // 0x46
    bEarLevel: BYTE, // 0x48
    bVariant: BYTE, // 0x49
    szPlayerName: [16]u8, // 0x4A
    wRuneWordIndex: WORD, // 0x5A — runeword ID (0=none)
    pOwnerInventory: ?*Inventory, // 0x5C
    pPrevItem: ?*UnitAny, // 0x60
    pNextItem: ?*UnitAny, // 0x64
    game_location: BYTE, // 0x68 — eD2InventoryGrid
    node_page: BYTE, // 0x69 — eD2InventoryGridType
    _6A: WORD, // 0x6A
    pPrevItemInPage: ?*UnitAny, // 0x6C
    pNextItemInPage: ?*UnitAny, // 0x70
};

pub const MonsterData = extern struct {
    _00: [22]BYTE, // 0x00
    type_flags: WORD, // 0x16 — eMonsterType flags (0x02=SUPERUNIQUE,0x04=CHAMPION,0x08=UNIQUE,0x10=MINION)
    _18: DWORD, // 0x18
    enchants: [9]BYTE, // 0x1C
    _25: BYTE, // 0x25 padding
    wUniqueNo: WORD, // 0x26
    _28: DWORD, // 0x28
    wName: [28]WORD, // 0x2C
};

pub const Room1 = extern struct {
    pRoomsNear: ?[*]?*Room1, // 0x00
    _04: [3]DWORD, // 0x04
    pRoom2: ?*Room2, // 0x10
    _14: [3]DWORD, // 0x14
    pColl: ?*CollMap, // 0x20
    dwRoomsNear: DWORD, // 0x24
    _28: [9]DWORD, // 0x28
    dwXStart: DWORD, // 0x4C
    dwYStart: DWORD, // 0x50
    dwXSize: DWORD, // 0x54
    dwYSize: DWORD, // 0x58
    _5C: [6]DWORD, // 0x5C
    pUnitFirst: ?*UnitAny, // 0x74
    _78: DWORD, // 0x78
    pRoomNext: ?*Room1, // 0x7C
};

pub const Room2 = extern struct {
    _00: [2]DWORD, // 0x00
    pRoom2Near: ?*?*Room2, // 0x08
    _0C: [5]DWORD, // 0x0C
    pType2Info: ?*anyopaque, // 0x20
    pRoom2Next: ?*Room2, // 0x24
    dwRoomFlags: DWORD, // 0x28
    dwRoomsNear: DWORD, // 0x2C
    pRoom1: ?*Room1, // 0x30
    dwPosX: DWORD, // 0x34
    dwPosY: DWORD, // 0x38
    dwSizeX: DWORD, // 0x3C
    dwSizeY: DWORD, // 0x40
    _44: DWORD, // 0x44
    dwPresetType: DWORD, // 0x48
    pRoomTiles: ?*RoomTile, // 0x4C
    _50: [2]DWORD, // 0x50
    pLevel: ?*Level, // 0x58
    pPreset: ?*PresetUnit, // 0x5C
};

pub const Level = extern struct {
    _00: [4]DWORD, // 0x00
    pRoom2First: ?*Room2, // 0x10
    _14: [2]DWORD, // 0x14
    dwPosX: DWORD, // 0x1C
    dwPosY: DWORD, // 0x20
    dwSizeX: DWORD, // 0x24
    dwSizeY: DWORD, // 0x28
    _2C: [96]DWORD, // 0x2C
    pNextLevel: ?*Level, // 0x1AC
    _1B0: DWORD, // 0x1B0
    pMisc: ?*ActMisc, // 0x1B4
    _1B8: [6]DWORD, // 0x1B8 (was _1BC at 0x1BC in C++, but 0x1B8 here for correct offset after pMisc)
    dwLevelNo: DWORD, // 0x1D0
    _1D4: [3]DWORD, // 0x1D4
    room_center_x: [9]DWORD, // 0x1E0
    room_center_y: [9]DWORD, // 0x204
    dwRoomEntries: DWORD, // 0x228
};

pub const ActMisc = extern struct {
    _00: [37]DWORD, // 0x00
    dwStaffTombLevel: DWORD, // 0x94
    _98: [245]DWORD, // 0x98
    pAct: ?*Act, // 0x46C
    _470: [3]DWORD, // 0x470
    pLevelFirst: ?*Level, // 0x47C
};

pub const Act = extern struct {
    _00: [3]DWORD, // 0x00
    dwMapSeed: DWORD, // 0x0C
    pRoom1: ?*Room1, // 0x10
    dwAct: DWORD, // 0x14
    _18: [12]DWORD, // 0x18
    pMisc: ?*ActMisc, // 0x48
};

pub const CollMap = extern struct {
    dwPosGameX: DWORD, // 0x00
    dwPosGameY: DWORD, // 0x04
    dwSizeGameX: DWORD, // 0x08
    dwSizeGameY: DWORD, // 0x0C
    dwPosRoomX: DWORD, // 0x10
    dwPosRoomY: DWORD, // 0x14
    dwSizeRoomX: DWORD, // 0x18
    dwSizeRoomY: DWORD, // 0x1C
    pMapStart: ?[*]WORD, // 0x20
};

pub const PresetUnit = extern struct {
    _00: DWORD, // 0x00
    dwTxtFileNo: DWORD, // 0x04
    dwPosX: DWORD, // 0x08
    pPresetNext: ?*PresetUnit, // 0x0C
    _10: DWORD, // 0x10
    dwType: DWORD, // 0x14
    dwPosY: DWORD, // 0x18
};

pub const LevelTxt = extern struct {
    dwLevelNo: DWORD, // 0x00
    _04: [60]DWORD, // 0x04
    _F4: BYTE, // 0xF4
    szName: [40]u8, // 0xF5
    szEntranceText: [40]u8, // 0x11D
    szLevelDesc: [41]u8, // 0x145
    wName: [40]WORD, // 0x16E

    comptime {
        std.debug.assert(@offsetOf(LevelTxt, "wName") == 0x16E);
    }
};

pub const ObjectTxt = extern struct {
    szName: [0x40]u8, // 0x00
    wszName: [0x40]WORD, // 0x40
    _C0: [0xFC]BYTE, // 0xC0 .. 0x1BB
    nAutoMap: DWORD, // 0x1BC — automap cell number

    comptime {
        std.debug.assert(@offsetOf(ObjectTxt, "nAutoMap") == 0x1BC);
    }
};

pub const ItemTxt = extern struct {
    szFlippyFile: [32]u8, // 0x00
    szInvFile: [32]u8, // 0x20
    szUniqueInvFile: [32]u8, // 0x40
    szSetInvFile: [32]u8, // 0x60
    szCode: [4]u8, // 0x80
    _84: [0x88]BYTE, // 0x84
    nType: DWORD, // 0x10C

    comptime {
        std.debug.assert(@offsetOf(ItemTxt, "nType") == 0x10C);
    }
};

pub const D2CharSelStrc = extern struct {
    szCharname: [256]u8, // 0x000
    _100: [0x220]BYTE, // 0x100
    ePlayerClassID: BYTE, // 0x320
    _321: BYTE, // 0x321
    nLevel: WORD, // 0x322
    nCharacterFlags: WORD, // 0x324
    _326: [0x26]BYTE, // 0x326
    pNext: ?*D2CharSelStrc, // 0x34C
};

pub const UNIT_TYPE_COUNT = 6;
pub const UNIT_HASH_SIZE = 128;

// Unit hash table: 128 bucket heads, units chained via pListNext
pub const UnitHashTable = extern struct {
    table: [UNIT_HASH_SIZE]?*UnitAny,
};

// 6 hash tables indexed by unit type: [0]=player [1]=monster [2]=object [3]=missile [4]=item [5]=tile
pub const UnitHashTableCollection = extern struct {
    byType: [UNIT_TYPE_COUNT]UnitHashTable,

    pub fn get(self: *UnitHashTableCollection, unit_type: u32) ?*UnitHashTable {
        if (unit_type >= UNIT_TYPE_COUNT) return null;
        return &self.byType[unit_type];
    }
};

pub const D2PoolManagerStrc = opaque {};

pub const POINT = extern struct {
    x: i32,
    y: i32,
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

// Automap types
pub const AutomapCell = extern struct {
    fSaved: DWORD, // 0x00
    nCellNo: i16, // 0x04
    xPixel: WORD, // 0x06
    yPixel: WORD, // 0x08
    wWeight: WORD, // 0x0A
    pLess: ?*AutomapCell, // 0x0C
    pMore: ?*AutomapCell, // 0x10
};

pub const AutomapLayer = extern struct {
    nLayerNo: DWORD, // 0x00
    fSaved: DWORD, // 0x04
    pFloors: ?*AutomapCell, // 0x08
    pWalls: ?*AutomapCell, // 0x0C
    pObjects: ?*AutomapCell, // 0x10
    pExtras: ?*AutomapCell, // 0x14
    pNextLayer: ?*AutomapLayer, // 0x18
};

pub const AutomapLayer2 = extern struct {
    _00: [2]DWORD, // 0x00
    nLayerNo: DWORD, // 0x08
};

pub const RoomTile = extern struct {
    pRoom2: ?*Room2, // 0x00
    pNext: ?*RoomTile, // 0x04
    _08: [2]DWORD, // 0x08
    nNum: ?*DWORD, // 0x10
};
