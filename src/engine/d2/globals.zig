const types = @import("types.zig");
const UnitAny = types.UnitAny;
const UnitHashTableCollection = types.UnitHashTableCollection;
const D2CharSelStrc = types.D2CharSelStrc;
const AutomapLayer = types.AutomapLayer;

const DWORD = u32;

fn globalRef(comptime T: type, comptime addr: usize) *T {
    return @ptrFromInt(addr);
}

fn globalPtr(comptime T: type, comptime addr: usize) **T {
    return @ptrFromInt(addr);
}

// Unit hash tables
pub fn clientSideUnits() *UnitHashTableCollection {
    return globalRef(UnitHashTableCollection, 0x7A5270);
}

pub fn serverSideUnits() *UnitHashTableCollection {
    return globalRef(UnitHashTableCollection, 0x7A5E70);
}

// Player
pub fn playerUnit() *?*UnitAny {
    return @ptrFromInt(0x7A6A70);
}

pub fn noPickUp() *DWORD {
    return globalRef(DWORD, 0x7A6A90);
}

// Game info
pub fn gameInfo() *?*anyopaque {
    return @ptrFromInt(0x7A0438);
}

pub fn currentGameType() *c_int {
    return globalRef(c_int, 0x7A0610);
}

// Window handles
pub fn hInst() *?*anyopaque {
    return @ptrFromInt(0x7C8CA8);
}

pub fn hWnd() *?*anyopaque {
    return @ptrFromInt(0x7C8CBC);
}

// Char select / launcher
pub fn charSelStrcFirst() *?*D2CharSelStrc {
    return @ptrFromInt(0x779DC0);
}

pub fn gnSelectedCharGameState() *c_int {
    return globalRef(c_int, 0x7795E8);
}

pub fn oogCurrentCharSelectionMode() *c_int {
    return globalRef(c_int, 0x7795EC);
}

pub fn iniDataLauncher() *?*anyopaque {
    return @ptrFromInt(0x7795D4);
}

// Automap
pub fn automapLayer() *?*types.AutomapLayer {
    return @ptrFromInt(0x7A5164);
}

pub fn automapOffset() *types.POINT {
    return @ptrFromInt(0x7A5198);
}

// Screen
pub fn screenWidth() *c_int {
    return @ptrFromInt(0x71146C);
}

pub fn screenHeight() *c_int {
    return @ptrFromInt(0x711470);
}

pub fn divisor() *c_int {
    return @ptrFromInt(0x711254);
}

// ============================================================================
// sgtDataTable txt pointers (base address: 0x0096bc30)
// For tables without a dedicated GetLine function, we read the pointer directly.
// ============================================================================

/// Generic txt table accessor: reads pointer at addr, indexes by id * record_size
fn txtGetLine(comptime ptr_addr: usize, comptime record_size: usize, id: i32) ?[*]u8 {
    const base_ptr: *?[*]u8 = @ptrFromInt(ptr_addr);
    const base = base_ptr.* orelse return null;
    if (id < 0) return null;
    return base + @as(usize, @intCast(id)) * record_size;
}

// Missiles (420 bytes) — sgtDataTable + 0x764
pub fn txtMissilesGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c794, 420, id);
}

// UniqueItems (332 bytes) — pTxtUniqueItems at 0x0096c854
pub fn txtUniqueItemsGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c854, 332, id);
}

// SetItems (440 bytes) — pTxtSetItems at 0x0096c848
pub fn txtSetItemsGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c848, 440, id);
}

// ItemTypes (228 bytes) — pTxtItemTypes at 0x0096c828 (NOT the Link at 0x0096c824)
pub fn txtItemTypesGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c828, 228, id);
}

// Properties (46 bytes) — pTxtProperties at 0x0096bcd4
pub fn txtPropertiesGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096bcd4, 46, id);
}

// Overlay (132 bytes) — pTxtOverlay at 0x0096c7ec
pub fn txtOverlayGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c7ec, 132, id);
}

// MonLvl — pTxtMonLvl at 0x0096c7a0
pub fn txtMonLvlGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c7a0, 4, id); // small records
}

// Experience (32 bytes per level) — pTxtExperience at 0x0096c8a8
// Indexed by level (0-99), each row has 7 class exp values + ExpRatio
pub fn txtExperienceGetLine(id: i32) ?[*]u8 {
    return txtGetLine(0x0096c8a8, 32, id);
}
