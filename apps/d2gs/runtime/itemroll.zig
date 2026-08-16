//! Server item-generation driver — fans out the per-game `itemRoll` hook once an item is fully
//! built. Two doors materialise a server-side item: ITEM_CreateItemInstance @0x558d90 (GENERATED
//! — drop/chest/gamble/cube/vendor/shrine, twenty call sites) and ITEM_CreateFromSaveData
//! @0x558cb0 (RESTORED from the save blob, the join-and-idle path). Neither ENTRY can read
//! quality yet (ITEM_ApplyQualityAndAffixes can still downgrade it, restore still has it in the
//! bit buffer), so we wrap the LAST call each makes instead — both `call RefreshQuantity` with
//! ECX=pGame EDX=pItem, at 00558d5e and 00559120 — by which point quality/affixes/stats are
//! final. We patch the call SITES not the callee (RefreshQuantity has four other, non-creating
//! callers) which also keeps srvtrace's entry detour on 0x558d90 (`item_spawn`) intact. Verified
//! against 1.14d Game.exe (Ghidra c18aa0f2).
const patch = @import("patch.zig");
const log = @import("../log.zig");
const feature = @import("../engine/feature.zig");
const d2types = @import("../engine/d2types.zig");

/// D2Common::Items::Items::Drop::RefreshQuantity(pGame ECX, pItem EDX) — __fastcall, no
/// stack args (`push ebx/esi/edi` … plain `ret`), so re-invoking it needs no frame work.
const REFRESH_QUANTITY: usize = 0x0055_8580;

/// The `call RefreshQuantity` at the tail of each item constructor.
const call_sites = [_]usize{
    0x0055_8D5E, // ITEM_CreateFromSaveData  — restored (character inventory, ground pickups)
    0x0055_9120, // ITEM_CreateItemInstance  — generated (drops, vendors, cube, shrines)
};

/// Reached via a replaced `call`: ECX=pGame, EDX=pItem, [esp]=return address.
fn itemRollShim() callconv(.naked) void {
    asm volatile (
        \\push %%ecx                 // save pGame
        \\push %%edx                 // save pItem
        \\mov $0x00558580, %%eax     // RefreshQuantity — the call we replaced
        \\call *%%eax                // original; ECX/EDX still hold its args
        \\pop %%edx
        \\pop %%ecx
        \\push %%edx                 // handler arg2: pItem
        \\push %%ecx                 // handler arg1: pGame
        \\call %[handler:P]
        \\add $0x8, %%esp
        \\ret
        :
        : [handler] "X" (&itemRollHandler),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true });
}

fn itemRollHandler(pGame: *d2types.D2GameStrc, pItem: *anyopaque) callconv(.c) void {
    const pool = pGame.pMemoryPool orelse return; // no pool → can't build a game ctx
    const ctx = feature.gameCtx(pGame, pool);
    feature.fanItemRoll(&ctx, pItem);
}

/// True when `addr` really holds `call REFRESH_QUANTITY`. A patch that lands on anything
/// else would shred an instruction, so a site that does not match is skipped rather than
/// written — one missing door beats a corrupted engine.
fn isRefreshQuantityCall(addr: usize) bool {
    const p: [*]const u8 = @ptrFromInt(addr);
    if (p[0] != 0xE8) return false;
    const rel: i32 = @bitCast([4]u8{ p[1], p[2], p[3], p[4] });
    return @as(isize, @bitCast(addr)) + 5 + rel == @as(isize, @bitCast(REFRESH_QUANTITY));
}

pub fn install() void {
    var ok: usize = 0;
    for (call_sites) |site| {
        if (!isRefreshQuantityCall(site)) {
            log.hex("itemroll: not a RefreshQuantity call — skipping site 0x", site);
            continue;
        }
        if (patch.MemoryPatch(site).call(@intFromPtr(&itemRollShim)).commit()) {
            ok += 1;
        } else {
            log.hex("itemroll: FAILED to wrap site 0x", site);
        }
    }
    log.hex2("itemroll: item constructors wrapped (fans out itemRoll)", ok, call_sites.len);
}
