//! Naked-asm shims for engine-called __fastcall callbacks.
//!
//! D2 callbacks are __fastcall: arg1 in ECX, arg2 in EDX, the rest on the stack,
//! callee-cleanup (`ret N`). Zig's x86 fastcall callconv is buggy
//! (ziglang/zig#10363), so we never define callbacks with it — instead a
//! `callconv(.naked)` shim adapts the engine's fastcall ABI to a plain cdecl
//! handler and cleans the stack itself.
//!
//! Shim for 2 reg + N stack args (e.g. the 9-param case at N=7):
//!   push ebp; mov esp,ebp; push ebx/esi/edi
//!   pushl <stack args, high→low>      ; N stack args
//!   push edx; push ecx                ; 2 fastcall regs
//!   call impl                         ; cdecl handler(ecx, edx, s1..sN)
//!   add esp, (N+2)*4                  ; clean our cdecl pushes
//!   pop edi/esi/ebx/ebp
//!   ret N*4                           ; callee-clean the engine's N stack args

const std = @import("std");

/// Build the `pushl off(%%ebp)` chain for N stack args, highest offset first
/// (cdecl pushes right-to-left). First stack arg sits at [ebp+8].
fn pushChain(comptime n: usize) []const u8 {
    comptime {
        var s: []const u8 = "";
        var i: usize = n;
        while (i > 0) : (i -= 1) {
            s = s ++ std.fmt.comptimePrint("pushl {d}(%%ebp)\n", .{8 + (i - 1) * 4});
        }
        return s;
    }
}

/// Make a __fastcall callback shim with 2 register args (ECX, EDX) + `n_stack`
/// stack args. `impl` is a plain handler: `fn (ecx, edx, s1..sN) callconv(.c) T`.
/// Returns a struct with `shim` — take `&Callback2(n, impl).shim` as the fn ptr
/// the engine calls.
pub fn Callback2(comptime n_stack: usize, comptime impl: anytype) type {
    return struct {
        pub fn shim() callconv(.naked) void {
            asm volatile ("push %%ebp\n" ++
                    "mov %%esp, %%ebp\n" ++
                    "push %%ebx\n push %%esi\n push %%edi\n" ++
                    pushChain(n_stack) ++
                    "push %%edx\n push %%ecx\n" ++
                    "call %[impl:P]\n" ++
                    std.fmt.comptimePrint("add ${d}, %%esp\n", .{(n_stack + 2) * 4}) ++
                    "pop %%edi\n pop %%esi\n pop %%ebx\n pop %%ebp\n" ++
                    std.fmt.comptimePrint("ret ${d}\n", .{n_stack * 4})
                :
                : [impl] "X" (&impl),
            );
        }
    };
}
