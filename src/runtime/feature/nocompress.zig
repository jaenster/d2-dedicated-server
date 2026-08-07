//! Serve the game stream UNCOMPRESSED and UNFRAMED, using the engine's own raw send mode.
//!
//! NET_D2GS_SERVER_SendPacketToClient @0x52b330 already has a verbatim path — the one the
//! 0xAF greeting itself rides:
//!
//!     if (nMode != 0 || pBytes[0] != 0xAF) {
//!         LogSentPacket(pBytes, nSize);
//!         if (nMode != 2) {                                  <- 0x52b3b5
//!             CompressPacket(pBuffer + 2, 1032, pBytes, nSize);
//!             SendPacketByClientId(... 1/2-byte length prefix ...);
//!             return;
//!         }
//!     }
//!     SendPacketByClientId(pQServer, nClientId, pBytes, nSize);   // raw, no prefix
//!
//! So mode 2 means "send exactly these bytes". Forcing the `nMode != 2` test to fall through
//! turns every server packet into a raw one: no Huffman, no length header. One 6-byte patch,
//! no detour, no codec of our own — we just take a road the engine already paves.
//!
//! This pairs with the 0xAF00 greeting. The client's receive thread has two disjoint paths
//! (ThreadClientToServer @0x52ab30, gated on the phase flag that
//! NET_D2GS_CLIENT_ParseRecvBufferIntoPacketQueues returns):
//!   * flag 0 (after 0xAF00) — recv straight into the packet buffer, then parse. NO length
//!     framing and NO DecompressPacket call anywhere on this path.
//!   * flag 1 (after 0xAF01) — the length-framed loop that decompresses every frame.
//! A STOCK client greeted with 0xAF00 therefore reads our raw stream natively. Nothing is
//! patched on the client, which is the point: the previous approach replaced BOTH codec
//! functions with an identity `rep movsb` that ignored the destination size, so a verbatim
//! world packet memcpy'd into a buffer sized for a decompressed one and corrupted the
//! client's heap during world-load.
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

/// The `CMP byte ptr [EBP+8], 2` / `JZ 0x52b45f` pair that decides compressed vs raw.
const MODE_GATE_JZ: usize = 0x0052b3b9;
/// Where that JZ lands: the raw SendPacketByClientId tail.
const RAW_SEND_PATH: usize = 0x0052b45f;

/// Rewrite `JZ RAW_SEND_PATH` (0f 84 rel32, 6 bytes) as a 5-byte `JMP RAW_SEND_PATH` plus one
/// NOP, so the compressed branch becomes unreachable for every mode, not just mode 2.
pub fn install() void {
    const ok = patch.MemoryPatch(MODE_GATE_JZ)
        .jump(RAW_SEND_PATH)
        .nops(1)
        .commit();
    if (ok) {
        log.print("nocompress: SendPacketToClient forced to raw mode (no huffman, no length prefix)");
    } else {
        log.print("nocompress: FAILED to patch the SendPacketToClient mode gate");
    }
}
