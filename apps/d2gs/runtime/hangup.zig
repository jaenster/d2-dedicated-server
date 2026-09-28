//! Let the server notice a client that hung up.
//!
//! The QServer's socket thread (Fog QServer98 `SocketThreadMain` @0x6c3470) selects every client
//! socket for reading AND for exceptions, and then skips any socket that came back in the
//! exception set:
//!
//!   006c3842  CALL __WSAFDIsSet(sock, exceptfds)
//!   006c3847  TEST EAX, EAX
//!   006c3849  JNZ  006c3af1          ; excepted: not read, not closed, try again next pass
//!   006c3857  CALL __WSAFDIsSet(sock, readfds)
//!
//! On Windows `exceptfds` means out-of-band data or a failed connect, neither of which an accepted
//! game connection ever has, so the skip never fires. Wine 11 on macOS also reports a socket whose
//! peer has sent FIN in `exceptfds` (Wine 8 on Linux does not; measured with the same probe under
//! both). Once that happens the socket is skipped on every pass: its end-of-stream is never read,
//! the connection is never closed, and select() returns at once on every call from then on, so the
//! socket thread spins. What a player sees: a client that dropped keeps its seat until the game's
//! own idle timeout (45 s in the world, 225 s while joining), and every attempt to rejoin in that
//! window is refused as "a live connection is playing" this character.
//!
//! The fix removes the skip. An excepted socket falls through to the readability test, and from
//! there to the engine's own recv: data is processed, end-of-stream or an error closes the
//! connection exactly as it does for any other socket. Nothing else reads the exception set.
//!
//! Installed before the QServer starts, so its thread never runs the bytes being replaced.

const patch = @import("patch.zig");
const log = @import("../log.zig");

const EXCEPT_SKIP: usize = 0x006c3849;
const JNZ_TO_SKIP = [_]u8{ 0x0f, 0x85, 0xa2, 0x02, 0x00, 0x00 };

pub fn install() void {
    if (patch.MemoryPatch(EXCEPT_SKIP).expect(&JNZ_TO_SKIP).nops(JNZ_TO_SKIP.len).commit()) {
        log.print("hangup: excepted client sockets are read, so a hang-up is seen");
    } else {
        log.print("hangup: FAILED to patch the exception skip — a hang-up may go unnoticed under wine");
    }
}
