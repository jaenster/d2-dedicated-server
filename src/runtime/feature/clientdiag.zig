//! Client-side D2GS join diagnostics. The d2gs.dll is injected into the real
//! client too (--d2gs without --d2gs-boot); these entry detours log the key
//! client-side decisions during the realm join handshake so we can see whether
//! the client receives the server's game-setup packets and advances:
//!
//!   PacketHandle_from0xAF   @0x45c850 — connection packet dispatch (logs id at [ecx])
//!   Incoming0x01_GameFlags  @0x45c8b0 — client dispatched game flags
//!   Send_0x6B               @0x477da0 — client SENT JOINGAME (0x6b)
//!   CLIENT_ConnectionRefused@0x44e380 — connection refused/timeout (ecx=reason)
//!
//! Each hook relocates the function's first `prologue_len` bytes into a VirtualAlloc
//! trampoline (must be PIC-safe and end on an instruction boundary, >=5), patches a
//! jmp at the entry, logs on hit, then resumes the original. `deref_ecx` logs the
//! byte at [ecx] (a packet id) instead of the raw ecx value.
const std = @import("std");
const patch = @import("../patch.zig");
const log = @import("../../log.zig");

extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, typ: u32, protect: u32) callconv(.winapi) ?*anyopaque;
const MEM_COMMIT_RESERVE: u32 = 0x3000;
const PAGE_EXECUTE_READWRITE: u32 = 0x40;

fn EntryHook(comptime addr: usize, comptime prologue_len: usize, comptime deref_ecx: bool, comptime label: []const u8) type {
    return struct {
        var tramp: usize = 0;

        fn logHit(v: usize) callconv(.c) void {
            log.hex("[clientdiag HIT] " ++ label ++ " v=0x", v);
        }

        fn shim() callconv(.naked) void {
            asm volatile ("pushal\npushfl\n" ++
                    (if (deref_ecx) "movzbl (%%ecx), %%eax\npush %%eax\n" else "pushl 0x1c(%%esp)\n") ++
                    "call %[f:P]\n" ++
                    "add $4, %%esp\n" ++
                    "popfl\npopal\n" ++
                    "mov %[tramp], %%eax\n" ++
                    "jmp *(%%eax)\n"
                :
                : [f] "X" (&logHit),
                  [tramp] "X" (&tramp),
            );
        }

        pub fn install() void {
            const src: [*]const u8 = @ptrFromInt(addr);
            const mem = VirtualAlloc(null, prologue_len + 8, MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE) orelse {
                log.print("clientdiag: VirtualAlloc failed — " ++ label);
                return;
            };
            const tr: [*]u8 = @ptrCast(mem);
            var i: usize = 0;
            while (i < prologue_len) : (i += 1) tr[i] = src[i];
            tr[prologue_len] = 0xE9; // jmp rel32 back to addr+prologue_len
            const back: usize = addr + prologue_len;
            const rel: i32 = @intCast(@as(isize, @bitCast(back)) - @as(isize, @bitCast(@intFromPtr(tr) + prologue_len)) - 5);
            const rb: [4]u8 = @bitCast(rel);
            tr[prologue_len + 1] = rb[0];
            tr[prologue_len + 2] = rb[1];
            tr[prologue_len + 3] = rb[2];
            tr[prologue_len + 4] = rb[3];
            tramp = @intFromPtr(tr);

            // JMP to our shim, NOP-padding the rest of the relocated prologue.
            if (patch.MemoryPatch(addr).jump(@intFromPtr(&shim)).nopTo(addr + prologue_len).commit()) {
                log.print("clientdiag: installed hook @" ++ std.fmt.comptimePrint("0x{x}", .{addr}));
            } else {
                log.print("clientdiag: hook FAILED " ++ label);
            }
        }
    };
}

const hConnecting = EntryHook(0x0044bad0, 8, false, "CLIENTMODE_Unused3 connecting-loop");
const hAfHandle = EntryHook(0x0045c850, 5, true, "PacketHandle_from0xAF id");
const hGameFlags = EntryHook(0x0045c8b0, 10, false, "recv 0x01 GameFlags");
const hSend6b = EntryHook(0x00477da0, 7, false, "CLIENT sent 0x6B JOINGAME");
const hRefused = EntryHook(0x0044e380, 8, false, "CLIENT ConnectionRefused reason");

pub fn install() void {
    hConnecting.install();
    hAfHandle.install();
    hGameFlags.install();
    hSend6b.install();
    hRefused.install();
    log.print("clientdiag: join-handshake hooks installed");
}
