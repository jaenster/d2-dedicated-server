//! Server item-generation driver — fans out the per-game `itemRoll` hook once an item
//! is fully built.
//!
//! The engine materialises a server-side item through exactly two doors, and a counter
//! that watches only one of them reads zero for an ordinary session:
//!   ITEM_CreateItemInstance @0x558d90 — a GENERATED item: monster drop, chest, gamble,
//!     cube output, vendor stock, shrine gem. Twenty call sites funnel into it.
//!   ITEM_CreateFromSaveData  @0x558cb0 — a RESTORED item: everything a character walks
//!     in wearing, rebuilt from the save blob the realm handed us. This is the one that
//!     actually fires on a join-and-idle workload, and missing it is why a first cut of
//!     this counter stayed at zero through three full games.
//!
//! Neither one's ENTRY is the right place to read quality. The generation context carries
//! only the quality that was ASKED for, and ITEM_ApplyQualityAndAffixes (reached from
//! ITEM_InitItemBaseStats, inside the call) still downgrades it whenever the roll finds no
//! valid affix set — counting at entry over-reports rares and uniques. The restore path
//! does not know the quality at entry at all; it is still in the bit buffer.
//!
//! So we wrap the LAST call each of them makes instead. Both tails are the same shape:
//!   00558d5e  call RefreshQuantity   ; ECX=pGame EDX=pItem, then `mov eax,esi` = return
//!   00559120  call RefreshQuantity   ; ECX=pGame EDX=pItem, then `mov eax,edi` = return
//! Every successful creation reaches its site (the failure paths bail earlier and free the
//! unit), and by then the item's quality, affixes and stats are final. RefreshQuantity is
//! called from four other places, none of which create anything, which is why we wrap the
//! two call SITES rather than the callee. Verified against 1.14d Game.exe (Ghidra c18aa0f2).
//!
//! Wrapping a call rather than detouring an entry also keeps this off srvtrace's toes: it
//! owns the first six bytes of 0x558d90 for its `item_spawn` event.
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
