//! Fog ordinals some engine imports and we have no implementation for.
//!
//! They are exported anyway, as stubs that report themselves and stop. That is deliberate, and it
//! is the whole reason this file exists separately from `fog.zig`:
//!
//! **Not exporting them is worse.** Wine ABORTS the process on a call to an ordinal a DLL does not
//! export, and the abort names nothing — the server goes silent at 0% CPU with an empty log, and
//! the next person spends a day on it. Fog `@10265` cost exactly that.
//!
//! **Exporting them as no-ops would be worse still.** The engine would carry on with a call that
//! silently did nothing, which is the failure mode that takes weeks instead of a day.
//!
//! So the stub reports which ordinal was called and where from, and exits. It does **not return**,
//! and that is a correctness requirement rather than laziness: each of these has its own callee-pop
//! count, and returning with the wrong one corrupts the engine's stack rather than failing. Not
//! returning is correct for every arity, so the list needs no per-ordinal research to be safe.
//!
//! The list is checked both ways by `ordinals.zig`: an ordinal an engine imports must be either
//! implemented or listed here, and an entry here that nothing imports any more must be deleted.
//! Removing a row is what "we implemented it" looks like.

/// Sorted, and kept that way so a diff reads as one line rather than a reshuffle.
pub const ordinals = [_]u32{
    // D2CMP's sprite decompression: DC6/DCC drawing. A headless server loads the module because
    // the engine links it and never asks it for a pixel — so these have never fired, and if one
    // ever does, that is worth being told about rather than aborting namelessly.
    10022,
    10091,
    10092,
    10093,
    10094,
    10095,
    10097,
    // A four-argument forwarder (ECX, EDX + two stack) straight to Storm.dll ordinal #271. We ship
    // the real Storm, so closing this is a shim rather than an implementation. Imported by 1.13c's
    // D2Common and D2Lang; 1.13c serves a world today, so nothing on the join path calls it yet.
    10106,
    // `Fog\Src\BitManip\StringPack.c` — the string-packing family, alongside BITMANIP in the same
    // Fog module. Imported by D2Common on 1.06b and 1.07 only.
    10134,
    10135,
    10136,
    // 1.06b's D2Game, and nothing else. Not reached yet, because 1.06b does not serve a world.
    10144,
    10202,
};

pub fn contains(ordinal: u32) bool {
    for (ordinals) |o| {
        if (o == ordinal) return true;
    }
    return false;
}
