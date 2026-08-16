//! Enable ladder-only content regardless of a game's ladder flag. Ported from Charon's
//! TxtOverride.cpp. CompileTxt @0x6122f0 (a.k.a. CreateTxtTableArray, __stdcall(pMemory,
//! szTableName, pBinFieldInput, int* nTxtTableSize, nLineLength) -> table*) is JMP'd to a stdcall
//! intercept: run the original through a relocated-prologue stub, then clear the ladder gate on the
//! rows it built (offsets verified against the 1.14d structs, Ghidra session 62fbfe69):
//!   runes        D2RuneTableStrc   (288B)  server @129  -> 0   (runeword usable off-ladder)
//!   cubemain     D2CubeMainTxt     (328B)  nLadder @1   -> 0   (recipe usable off-ladder)
//!   uniqueitems  D2UniqueItemsTxt  (332B)  flags @44 bit3(0x08) cleared (unique usable off-ladder)
const std = @import("std");
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

const COMPILETXT: usize = 0x006122f0;
const COMPILETXT_REJOIN: usize = 0x006122f9; // entry + 9 (after the relocated prologue)

const StdcallConv = std.builtin.CallingConvention{ .x86_stdcall = .{} };
const CompileTxtFn = fn (
    pMemory: ?*anyopaque,
    szTableName: [*:0]const u8,
    pBinFieldInput: ?*anyopaque,
    nTxtTableSize: ?*i32, // engine passes null for some tables (CompileTxt guards it)
    nLineLength: i32,
) callconv(StdcallConv) ?*anyopaque;

/// Re-emit CompileTxt's 9-byte prologue (push ebp; mov ebp,esp; sub esp,0x11c) then
/// continue the original at +9. Callable as the original CompileTxt (__stdcall, ret 0x14).
fn compileTxtRelocated() callconv(.naked) void {
    asm volatile (
        \\push %ebp
        \\mov %esp, %ebp
        \\sub $0x11c, %esp
        \\push $0x006122f9
        \\ret
    );
}

fn compileTxtIntercept(
    pMemory: ?*anyopaque,
    szTableName: [*:0]const u8,
    pBinFieldInput: ?*anyopaque,
    nTxtTableSize: ?*i32,
    nLineLength: i32,
) callconv(StdcallConv) ?*anyopaque {
    const original: *const CompileTxtFn = @ptrCast(&compileTxtRelocated);
    const table = original(pMemory, szTableName, pBinFieldInput, nTxtTableSize, nLineLength);
    // Only the three ladder tables matter; bail on null table / row-count (the engine
    // passes a null nTxtTableSize for tables whose row count it doesn't need).
    const base: [*]u8 = @ptrCast(table orelse return table);
    const pcount = nTxtTableSize orelse return table;
    const rows: usize = @intCast(@max(@as(i32, 0), pcount.*));
    const name = std.mem.span(szTableName);

    if (std.mem.eql(u8, name, "runes")) {
        var i: usize = 0;
        while (i < rows) : (i += 1) base[i * 288 + 129] = 0; // server -> 0
        log.hex("ladderitems: ladder runewords enabled, rows=0x", @intCast(rows));
    } else if (std.mem.eql(u8, name, "cubemain")) {
        var i: usize = 0;
        while (i < rows) : (i += 1) base[i * 328 + 1] = 0; // nLadder -> 0
        log.hex("ladderitems: ladder cube recipes enabled, rows=0x", @intCast(rows));
    } else if (std.mem.eql(u8, name, "uniqueitems")) {
        var i: usize = 0;
        while (i < rows) : (i += 1) {
            const flags: *align(1) u32 = @ptrCast(&base[i * 332 + 44]);
            flags.* &= ~@as(u32, 0x08); // clear ladder bit (bit3)
        }
        log.hex("ladderitems: ladder unique items enabled, rows=0x", @intCast(rows));
    }
    return table;
}

pub fn install() void {
    comptime {
        if (COMPILETXT_REJOIN != COMPILETXT + 9) @compileError("rejoin must be entry+9 (prologue length)");
    }
    // 9-byte prologue -> 5-byte JMP + 4 NOP.
    if (patch.MemoryPatch(COMPILETXT).jump(@intFromPtr(&compileTxtIntercept)).nops(4).commit()) {
        log.print("ladderitems: CompileTxt hooked (ladder runewords/recipes/uniques enabled)");
    } else {
        log.print("ladderitems: FAILED to hook CompileTxt");
    }
}
