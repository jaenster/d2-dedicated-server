//! Detour trampoline: copy the first N bytes of a hooked function into an
//! executable buffer (fixing up any relative E8/E9 within them), then append a
//! JMP back to `target+N`. Lets a detour call through to the original code after
//! we've overwritten its prologue with a 5-byte JMP to our handler.
//!
//! Built on patch.calcRelAddr; ported from aether's hook/trampoline.zig.
const std = @import("std");
const win = std.os.windows;
const patch = @import("patch.zig");

const DWORD = u32;
const BYTE = u8;

const MEM_COMMIT: DWORD = 0x1000;
const MEM_RESERVE: DWORD = 0x2000;
const MEM_RELEASE: DWORD = 0x8000;
const PAGE_EXECUTE_READWRITE: DWORD = 0x40;

extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, alloc_type: DWORD, protect: DWORD) callconv(.winapi) ?[*]BYTE;
extern "kernel32" fn VirtualFree(addr: *anyopaque, size: usize, free_type: DWORD) callconv(.winapi) win.BOOL;

pub const Trampoline = struct {
    buffer: [*]BYTE,
    buffer_size: usize,

    pub fn destroy(self: *Trampoline) void {
        _ = VirtualFree(@ptrCast(self.buffer), 0, MEM_RELEASE);
        self.buffer = undefined;
    }
};

fn writeI32(buf: [*]BYTE, off: usize, v: i32) void {
    const b: [4]u8 = @bitCast(v);
    buf[off] = b[0];
    buf[off + 1] = b[1];
    buf[off + 2] = b[2];
    buf[off + 3] = b[3];
}

fn inList(offsets: []const usize, off: usize) bool {
    for (offsets) |o| if (o == off) return true;
    return false;
}

/// Build a trampoline for a detour hook: copy `hook_size` bytes from `target_addr` into an
/// executable buffer, fix up relative E8 (CALL) / E9 (JMP) within them, expand `rel8_offsets`
/// (Jcc 0x70-0x7F / JMP 0xEB) to rel32 so they still reach their targets from the new location,
/// then append a JMP back to `target_addr + hook_size`. `hook_size` must be >= 5 and land on an
/// instruction boundary. `rel8_offsets` are hand-verified prologue offsets — never byte-scanned,
/// since a modrm/disp byte can alias a Jcc opcode. Returns null on allocation failure.
pub fn build(target_addr: usize, hook_size: usize, rel8_offsets: []const usize) ?Trampoline {
    // Each expanded rel8 grows by at most 4 bytes (rel8 -> rel32); + JMP back.
    const alloc_size = hook_size + 5 + 4 * rel8_offsets.len;
    const buf = VirtualAlloc(null, alloc_size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE) orelse return null;

    const src: [*]const BYTE = @ptrFromInt(target_addr);
    var i: usize = 0; // read cursor in the source prologue
    var o: usize = 0; // write cursor in the trampoline buffer
    while (i < hook_size) {
        // Explicit rel8 short branch -> rel32, recomputed against the new location.
        if (inList(rel8_offsets, i)) {
            const op = src[i];
            const disp: i8 = @bitCast(src[i + 1]);
            const abs_target: usize = @intCast(@as(isize, @intCast(target_addr + i + 2)) + @as(isize, disp));
            const insn_addr: usize = @intFromPtr(buf) + o;
            if (op == 0xEB) { // JMP rel8 -> E9 rel32
                buf[o] = 0xE9;
                writeI32(buf, o + 1, patch.calcRelAddr(insn_addr, abs_target, 5));
                o += 5;
            } else { // Jcc rel8 (0x70-0x7F) -> 0F 8x rel32
                buf[o] = 0x0F;
                buf[o + 1] = 0x80 | (op - 0x70);
                writeI32(buf, o + 2, patch.calcRelAddr(insn_addr, abs_target, 6));
                o += 6;
            }
            i += 2;
            continue;
        }
        // Near CALL (E8) / JMP (E9) rel32 fixup.
        if ((src[i] == 0xE8 or src[i] == 0xE9) and i + 5 <= hook_size) {
            const orig_rel: i32 = @bitCast([4]u8{ src[i + 1], src[i + 2], src[i + 3], src[i + 4] });
            const abs_target: usize = @intCast(@as(isize, @intCast(target_addr + i + 5)) + @as(isize, orig_rel));
            const insn_addr: usize = @intFromPtr(buf) + o;
            buf[o] = src[i];
            writeI32(buf, o + 1, patch.calcRelAddr(insn_addr, abs_target, 5));
            i += 5;
            o += 5;
            continue;
        }
        buf[o] = src[i];
        i += 1;
        o += 1;
    }

    // Append JMP back to original + hook_size at the output cursor.
    const jmp_back_addr: usize = @intFromPtr(buf) + o;
    const return_addr = target_addr + hook_size;
    buf[o] = 0xE9;
    writeI32(buf, o + 1, patch.calcRelAddr(jmp_back_addr, return_addr, 5));

    return .{ .buffer = buf, .buffer_size = alloc_size };
}
