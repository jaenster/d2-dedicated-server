//! Naked-asm shims for engine-called __fastcall callbacks.
//!
//! D2 callbacks are __fastcall: arg1 in ECX, arg2 in EDX, rest on the stack, callee-cleanup
//! (`ret N`). Zig's x86 fastcall callconv is buggy (ziglang/zig#10363), so a `callconv(.naked)`
//! shim adapts the engine's fastcall ABI to a plain cdecl handler and cleans the stack itself:
//!   push ebp/ebx/esi/edi; pushl <stack args, high→low>; push edx; push ecx
//!   call impl (cdecl handler(ecx, edx, s1..sN)); add esp,(N+2)*4; pop edi/esi/ebx/ebp; ret N*4

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

// fastcall CALLER (us → engine)
// Calling a __fastcall engine function (ECX, EDX + stack). Ported from aether's
// d2/functions.zig — Zig's x86 fastcall callconv is unreliable, so we build the
// call in inline asm. Usage:
//   const SelectedChar = fastcall_call(0x434a00, fn (*X, u16, u32, [*:0]const u8) u32);
//   _ = SelectedChar.call(.{ p, flags, class, "" });

fn argToU32(comptime T: type, val: T) u32 {
    return switch (@typeInfo(T)) {
        .pointer => @intFromPtr(val),
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .pointer => if (val) |pp| @intFromPtr(pp) else 0,
            .@"fn" => if (val) |pp| @intFromPtr(pp) else 0,
            else => @bitCast(val),
        },
        .@"enum" => @intFromEnum(val),
        .bool => if (val) @as(u32, 1) else 0,
        .int => @as(u32, @bitCast(@as(i32, @intCast(val)))),
        else => @compileError("unsupported fastcall arg type: " ++ @typeName(T)),
    };
}

fn u32ToRet(comptime T: type, raw: u32) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .pointer => @ptrFromInt(raw),
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .pointer => if (raw == 0) null else @ptrFromInt(raw),
            else => @bitCast(raw),
        },
        .int => |ii| if (ii.bits < 32)
            @bitCast(@as(std.meta.Int(.unsigned, ii.bits), @truncate(raw)))
        else
            @bitCast(raw),
        .bool => raw != 0,
        else => @compileError("unsupported fastcall ret type: " ++ @typeName(T)),
    };
}

fn buildCallAsm(comptime n: usize) []const u8 {
    comptime {
        var s: []const u8 = "";
        var i: usize = n;
        while (i > 2) {
            i -= 1;
            s = s ++ std.fmt.comptimePrint("pushl {d}(%[buf])\n", .{i * 4});
        }
        if (n >= 1) s = s ++ "movl (%[buf]), %ecx\n";
        if (n >= 2) s = s ++ "movl 4(%[buf]), %edx\n";
        s = s ++ "call *%[func]\n";
        return s;
    }
}

pub fn fastcall_call(comptime addr: usize, comptime FnType: type) type {
    const info = @typeInfo(FnType).@"fn";
    const params = info.params;
    const n = params.len;
    const Ret = info.return_type orelse void;
    const Tuple = std.meta.ArgsTuple(FnType);
    return struct {
        pub inline fn call(args: Tuple) Ret {
            var buf: [if (n > 0) n else 1]u32 = undefined;
            inline for (0..n) |i| buf[i] = argToU32(params[i].type.?, args[i]);
            const a = comptime buildCallAsm(n);
            const raw = asm volatile (a
                : [ret] "={eax}" (-> u32),
                : [buf] "r" (&buf),
                  [func] "r" (@as(usize, addr)),
                : .{ .ecx = true, .edx = true, .memory = true });
            return u32ToRet(Ret, raw);
        }
    };
}
