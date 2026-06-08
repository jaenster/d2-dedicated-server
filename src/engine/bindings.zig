//! Engine function bindings — call into Game.exe's own functions at their fixed
//! 1.14d addresses. The Zig equivalent of Charon's remote.h.
//!
//! __fastcall is declared via the comptime `fastcall(addr, FnType)` generator
//! (ECX=arg1, EDX=arg2, rest on the stack right-to-left, callee-cleans). Zig's
//! native `.x86_fastcall` is broken (ziglang/zig#10363), so this emits correct
//! inline asm instead. Ported from aether's d2/functions.zig (jaenster).
//! __stdcall functions use a plain `callconv(.winapi)` pointer.
//!
//! Types come from engine/d2types.zig (mirrored from the Ghidra recon), opaque
//! where a feature doesn't yet read fields.
const std = @import("std");
const d2 = @import("d2types.zig");

const DWORD = u32;
const BOOL = i32;

fn funcPtr(comptime addr: usize, comptime FnT: type) FnT {
    return @ptrFromInt(addr);
}

// ── comptime fastcall generator ──────────────────────────────────────────────

fn argToU32(comptime T: type, val: T) u32 {
    return switch (@typeInfo(T)) {
        .pointer => @intFromPtr(val),
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .pointer => if (val) |p| @intFromPtr(p) else 0,
            .@"fn" => if (val) |p| @intFromPtr(p) else 0,
            else => @bitCast(val),
        },
        .@"enum" => @intFromEnum(val),
        .bool => if (val) @as(u32, 1) else 0,
        .int => @as(u32, @bitCast(@as(i32, @intCast(val)))),
        else => @compileError("unsupported arg type for fastcall: " ++ @typeName(T)),
    };
}

fn u32ToRet(comptime T: type, raw: u32) T {
    return switch (@typeInfo(T)) {
        .pointer => @ptrFromInt(raw),
        .optional => |opt| switch (@typeInfo(opt.child)) {
            .pointer => if (raw == 0) null else @ptrFromInt(raw),
            else => @bitCast(raw),
        },
        .int => |int_info| if (int_info.bits < 32)
            @bitCast(@as(std.meta.Int(.unsigned, int_info.bits), @truncate(raw)))
        else
            @bitCast(raw),
        .bool => raw != 0,
        else => @compileError("unsupported return type for fastcall: " ++ @typeName(T)),
    };
}

/// Build the inline-asm string for an N-arg fastcall: push stack args R→L, set
/// ECX/EDX from the arg buffer, then call.
fn buildFastcallAsm(comptime n: usize) []const u8 {
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

fn ArgsArray(comptime FnType: type) type {
    const n = @typeInfo(FnType).@"fn".params.len;
    return [if (n > 0) n else 1]u32;
}

/// `fastcall(addr, fn(...) Ret)` → a type with `.call(.{args})`.
pub fn fastcall(comptime addr: u32, comptime FnType: type) type {
    const info = @typeInfo(FnType).@"fn";
    const params = info.params;
    const n = params.len;
    const RetType = info.return_type orelse void;
    const has_ret = RetType != void;
    const Tuple = std.meta.ArgsTuple(FnType);

    return struct {
        pub inline fn call(args: Tuple) RetType {
            var buf: ArgsArray(FnType) = undefined;
            inline for (0..n) |i| {
                buf[i] = argToU32(params[i].type.?, args[i]);
            }
            const asm_str = comptime buildFastcallAsm(n);
            if (comptime has_ret) {
                const raw = asm volatile (asm_str
                    : [ret] "={eax}" (-> u32),
                    : [buf] "r" (&buf),
                      [func] "r" (addr),
                    : .{ .ecx = true, .edx = true, .memory = true });
                return u32ToRet(RetType, raw);
            } else {
                asm volatile (asm_str
                    :
                    : [buf] "r" (&buf),
                      [func] "r" (addr),
                    : .{ .eax = true, .ecx = true, .edx = true, .memory = true });
            }
        }
    };
}

// ── text / draw (__fastcall) ─────────────────────────────────────────────────

pub const SetFont = fastcall(0x502EF0, fn (DWORD) DWORD);
pub const DrawGameText = fastcall(0x502320, fn ([*:0]const u16, c_int, c_int, DWORD, BOOL) void);
pub const GetTextSize = fastcall(0x502520, fn ([*:0]const u16, *DWORD, *DWORD) DWORD);

// ── automap (__fastcall) ─────────────────────────────────────────────────────

pub const NewAutomapCell = fastcall(0x457C30, fn () ?*d2.D2AutomapCellStrc);
pub const AddAutomapCell = fastcall(0x457B00, fn (?*d2.D2AutomapCellStrc, *?*d2.D2AutomapCellStrc) void);
pub const GetLayer = fastcall(0x61E470, fn (DWORD) ?*d2.D2AutomapLayer2Strc);

// ── automap / room / level (__stdcall) ───────────────────────────────────────

pub const RevealAutomapRoom = struct {
    const Fn = *const fn (?*d2.D2RoomStrc, DWORD, ?*d2.D2AutomapLayerStrc) callconv(.winapi) void;
    const ptr: Fn = funcPtr(0x458F40, Fn);
    pub inline fn call(room1: ?*d2.D2RoomStrc, clip_flag: DWORD, layer: ?*d2.D2AutomapLayerStrc) void {
        ptr(room1, clip_flag, layer);
    }
};

pub const AddRoomData = struct {
    const Fn = *const fn (?*d2.D2ActStrc, c_int, c_int, c_int, ?*d2.D2RoomStrc) callconv(.winapi) void;
    const ptr: Fn = funcPtr(0x61A070, Fn);
    pub inline fn call(act: ?*d2.D2ActStrc, level_id: c_int, x: c_int, y: c_int, room: ?*d2.D2RoomStrc) void {
        ptr(act, level_id, x, y, room);
    }
};

pub const GetScreenMode = struct {
    const Fn = *const fn () callconv(.winapi) DWORD;
    const ptr: Fn = funcPtr(0x4F5160, Fn);
    pub inline fn call() DWORD {
        return ptr();
    }
};

comptime {
    // Keep every binding analyzed even before all call sites are wired (Phase-2
    // maphack consumes most of these).
    _ = SetFont;
    _ = DrawGameText;
    _ = GetTextSize;
    _ = NewAutomapCell;
    _ = AddAutomapCell;
    _ = GetLayer;
    _ = RevealAutomapRoom;
    _ = AddRoomData;
    _ = GetScreenMode;
}
