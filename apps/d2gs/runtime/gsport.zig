//! Patch the engine's QServer LISTEN port so the d2ingress can own the client-facing :4000.
//!
//! QSERVER_CreateAndInit @0x0052b7a0 calls NET_QServer_Init(connType, 3, 4000, ...) — the
//! game port 4000 is pushed as `push 0xfa0` @0x0052b7be, so its imm32 lives at 0x0052b7bf
//! (bytes a0 0f 00 00). Rewriting that imm32 moves the GS's listener off 4000. Combined
//! with the GS self-reporting the same port via ADDRINFO, the realm records the route to
//! the moved port and the d2ingress (on :4000) splices client game traffic through to it.
const patch = @import("patch.zig");
const log = @import("../log.zig");

const PORT_IMM_ADDR: usize = 0x0052b7bf; // imm32 of `push 0xfa0` in QSERVER_CreateAndInit

/// Patch the QServer listen port. Must run BEFORE QSERVER_CreateAndInit (i.e. before
/// bootstrapRealmServer). A no-op value (4000) is harmless — it rewrites 0xfa0 with 0xfa0.
pub fn apply(port: u16) void {
    // Overwrite the 32-bit port immediate (little-endian) at the listen-setup site.
    if (patch.MemoryPatch(PORT_IMM_ADDR).data(@as(u32, port)).commit()) {
        log.hex("gsport: QServer listen port patched to 0x", port);
    } else {
        log.print("gsport: FAILED to patch QServer listen port");
    }
}
