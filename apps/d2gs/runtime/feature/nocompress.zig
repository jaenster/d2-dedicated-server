//! Serve the game stream UNCOMPRESSED and UNFRAMED, via the engine's own raw send mode.
//!
//! NET_D2GS_SERVER_SendPacketToClient @0x52b330 already has a verbatim path: `nMode == 2` skips
//! CompressPacket + the length prefix (JZ @0x52b3b5) and sends the bytes as-is. Forcing that test
//! to always fall through turns every server packet raw — one 6-byte patch, no codec of our own.
//!
//! Pairs with the 0xAF00 greeting: the client's ThreadClientToServer @0x52ab30 has two disjoint
//! recv paths gated on the phase flag from NET_D2GS_CLIENT_ParseRecvBufferIntoPacketQueues — flag 0
//! (after 0xAF00) parses straight from the recv buffer, no framing, no DecompressPacket; flag 1
//! (0xAF01) is the length-framed, decompressing loop. So a STOCK client greeted 0xAF00 reads our
//! raw stream natively, unpatched. The earlier approach instead identity-patched both codec
//! functions with `rep movsb`, ignoring destination size — a verbatim world packet memcpy'd into a
//! decompressed-size buffer and corrupted the client's heap during world-load.
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
