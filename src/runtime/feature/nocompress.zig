//! Disable the D2GS game-protocol compression by replacing both codec functions with
//! an identity copy. The server→client game stream is Huffman bit-packed end-to-end:
//!   NET_D2GS_SERVER_CompressPacket   @0x40b1b0 (GS packs outgoing packets)
//!   NET_D2GS_CLIENT_DecompressPacket @0x40b260 (client unpacks incoming packets)
//! Both share the signature `(dst, dstSize, src, srcSize) -> bytesWritten`, __fastcall
//! (ECX=dst, EDX=dstSize, [esp+4]=src, [esp+8]=srcSize, callee-cleans `ret 8`). The
//! caller (NET_D2GS_SERVER_SendPacketToClient @0x52b330) keeps its 1/2-byte length header
//! around whatever the codec returns, so an identity codec keeps the framing intact and
//! only drops the bit-packing — the payloads go out verbatim.
//!
//! ⚠ This is symmetric: it ONLY works when BOTH ends run this DLL (our GS + our injected
//! clients). A stock retail client would still Huffman-decode the verbatim bytes and get
//! garbage. So it's a closed-ecosystem / debugging switch (readable qqserver traces, no
//! codec-desync fragility), not something to enable against arbitrary players.
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

const COMPRESS_ADDR: usize = 0x0040b1b0;
const DECOMPRESS_ADDR: usize = 0x0040b260;

// Identity __fastcall codec: memcpy(dst=ECX, src=[esp+0xc after 2 pushes], srcSize), return
// srcSize in EAX, `ret 8`. Equivalent to `{ @memcpy(dst, src[0..n]); return n; }`.
fn identityCodec() callconv(.naked) void {
    asm volatile (
        \\push %esi
        \\push %edi
        \\cld
        \\mov %ecx, %edi
        \\mov 0xc(%esp), %esi
        \\mov 0x10(%esp), %ecx
        \\mov %ecx, %eax
        \\rep movsb
        \\pop %edi
        \\pop %esi
        \\ret $8
    );
}

/// Patch both codecs to the identity stub. Call once at process attach (GS or client).
pub fn install() void {
    const ok1 = patch.MemoryPatch(COMPRESS_ADDR).jump(@intFromPtr(&identityCodec)).commit();
    const ok2 = patch.MemoryPatch(DECOMPRESS_ADDR).jump(@intFromPtr(&identityCodec)).commit();
    if (ok1 and ok2) {
        log.print("nocompress: D2GS compress + decompress patched to identity (uncompressed wire)");
    } else {
        log.print("nocompress: FAILED to patch one or both codecs");
    }
}
