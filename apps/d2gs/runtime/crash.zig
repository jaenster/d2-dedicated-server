//! Panic diagnostics for the injected DLL.
//!
//! A safety-check panic used to print one line and vanish: thread dies, process stays up,
//! health endpoint stays green, every join after that hangs silently — failure invisible
//! until "the server feels unstable" an hour later.
//!
//! So a panic here logs where it happened as addresses relative to this DLL's image base
//! (`tools/symbolize.sh` resolves those to file:line against zig-out/bin/d2gs.pdb), then
//! kills the process. A dead GS beats one that lies about being healthy.
const std = @import("std");
const win = std.os.windows;
const log = @import("../log.zig");

/// Where d2gs.dll landed, so logged addresses can be printed as image-relative and
/// symbolized against the PDB. Set from DllMain; 0 means "log raw addresses".
pub var image_base: usize = 0;

/// Exit code the process dies with after a panic. Distinctive on purpose: it is how
/// a supervisor tells "our own bug" apart from an engine access violation (0xc0000005).
pub const exit_code: u32 = 0xD2C5;

extern "kernel32" fn IsBadReadPtr(p: ?*const anyopaque, len: usize) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn TerminateProcess(h: ?*anyopaque, code: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

pub fn install(module_base: usize) void {
    image_base = module_base;
}

/// True if `len` bytes at `addr` can be read without raising. Walking a frame chain
/// means following pointers that a corrupted frame may have invented, and an unlucky
/// read would turn a diagnosable panic into an access violation with no message.
fn readable(addr: usize, len: usize) bool {
    if (addr == 0) return false;
    return IsBadReadPtr(@ptrFromInt(addr), len) == 0;
}

fn appendStr(buf: []u8, n_in: usize, s: []const u8) usize {
    var n = n_in;
    for (s) |c| {
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return n;
}

fn appendHex(buf: []u8, n_in: usize, value: usize) usize {
    var tmp: [16]u8 = undefined;
    const digits = "0123456789abcdef";
    var v = value;
    var i: usize = tmp.len;
    if (v == 0) {
        i -= 1;
        tmp[i] = '0';
    }
    while (v != 0) : (v >>= 4) {
        i -= 1;
        tmp[i] = digits[v & 0xf];
    }
    return appendStr(buf, n_in, tmp[i..]);
}

/// Print a code address the way the symbolizer wants it: `d2gs+0x<rva>` when it falls
/// inside our DLL, a bare address otherwise (the engine's own code, or a thunk).
fn appendCodeAddr(buf: []u8, n_in: usize, addr: usize) usize {
    var n = n_in;
    if (image_base != 0 and addr >= image_base and addr - image_base < 0x0400_0000) {
        n = appendStr(buf, n, " d2gs+0x");
        return appendHex(buf, n, addr - image_base);
    }
    n = appendStr(buf, n, " 0x");
    return appendHex(buf, n, addr);
}

/// Return addresses up the stack, read straight off the frame-pointer chain.
/// The DLL is built without omitting frame pointers on x86, so [ebp] is the caller's
/// frame and [ebp+4] its return address — which is all a symbolizer needs.
fn walkFrames(buf: []u8, n_in: usize, start_frame: usize) usize {
    var n = n_in;
    var frame = start_frame;
    var depth: usize = 0;
    while (depth < 24) : (depth += 1) {
        if (!readable(frame, @sizeOf(usize) * 2)) break;
        const next = @as(*const usize, @ptrFromInt(frame)).*;
        const ret = @as(*const usize, @ptrFromInt(frame + @sizeOf(usize))).*;
        if (ret == 0) break;
        n = appendCodeAddr(buf, n, ret);
        // The chain must climb; a frame that points at or below itself is garbage, and
        // following it loops forever inside a panic handler.
        if (next <= frame) break;
        frame = next;
    }
    return n;
}

/// Set once we are already dying, so a panic raised *by the panic handler* (a bad read
/// the guard missed, a logger that faults) exits instead of recursing.
var dying: bool = false;

fn hardExit() noreturn {
    _ = TerminateProcess(GetCurrentProcess(), exit_code);
    unreachable;
}

/// Root panic handler — wired up as `pub const panic = std.debug.FullPanic(crash.onPanic)`.
pub fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (@atomicRmw(bool, &dying, .Xchg, true, .seq_cst)) hardExit();

    var buf: [512]u8 = undefined;
    var n: usize = appendStr(&buf, 0, "PANIC: ");
    n = appendStr(&buf, n, msg);
    n = appendStr(&buf, n, " (tid=0x");
    n = appendHex(&buf, n, GetCurrentThreadId());
    n = appendStr(&buf, n, ", d2gs base=0x");
    n = appendHex(&buf, n, image_base);
    n = appendStr(&buf, n, ")");
    log.print(buf[0..n]);

    n = appendStr(&buf, 0, "PANIC at:");
    if (first_trace_addr) |addr| n = appendCodeAddr(&buf, n, addr);
    n = walkFrames(&buf, n, @frameAddress());
    log.print(buf[0..n]);

    log.print("PANIC: terminating — a game server with a dead thread reports healthy and serves nobody");
    hardExit();
}
