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
//! The wire also opens with a 2-byte greeting `0xAF <flag>` (flag 0x01 = server Huffman-
//! compresses S->C, 0x00 = uncompressed) that the client's recv demux reads to pick its
//! decode path (ParseRecvBufferIntoPacketQueues @0x52a8d0). The greeting is the "client
//! accepted" QServer callback NET_D2GS_SERVER_Send_0xAF01 @0x52b720, which stores the flag
//! byte with `mov byte [ebp-5], 0x01` at 0x52b734; SendPacketToClient already ships an 0xAF
//! packet RAW (Server.cpp: `if (nMode!=0 || *pBytes!=0xAF)` gates the compress branch), so
//! the greeting itself is never Huffman-packed either way. To keep greeting + payload
//! CONSISTENT we also flip that flag immediate 0x01 -> 0x00 so the engine declares 0xAF00,
//! matching the identity codec (and the pure-Zig standalone GS, which speaks 0xAF00 + raw).
//!
//! ⚠ This is symmetric: it ONLY works when BOTH ends run this DLL (our GS + our injected
//! clients). A stock retail client would still Huffman-decode the verbatim bytes and get
//! garbage. So it's a closed-ecosystem / debugging switch (readable qqserver traces, no
//! codec-desync fragility), not something to enable against arbitrary players.
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

const COMPRESS_ADDR: usize = 0x0040b1b0;
const DECOMPRESS_ADDR: usize = 0x0040b260;
// The 0x01 immediate of `mov byte [ebp-5], 0x01` inside NET_D2GS_SERVER_Send_0xAF01 @0x52b720.
const GREETING_FLAG_ADDR: usize = 0x0052b734;

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
    // Flip the S->C greeting flag 0x01 -> 0x00 so the engine declares 0xAF00 (uncompressed),
    // consistent with the identity codec above. Both must agree or the client decodes garbage.
    const ok3 = patch.MemoryPatch(GREETING_FLAG_ADDR).byte(0x00).commit();
    if (ok1 and ok2 and ok3) {
        log.print("nocompress: D2GS codec->identity + greeting 0xAF01->0xAF00 (uncompressed wire)");
    } else {
        log.print("nocompress: FAILED to patch codec or greeting");
    }
}
