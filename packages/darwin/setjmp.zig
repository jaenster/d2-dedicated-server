//! `setjmp` and `longjmp`, in i386 assembly — no other honest way to write them. A thunk
//! returning 0 works for the first return, but the matching `longjmp` (used by the
//! `SFILE_Explode` decompressor on every failure) then jumps through a buffer nobody wrote. A
//! Zig wrapper around the host's `setjmp` has the same bug: the host saves the WRAPPER's frame,
//! which is gone by the time `longjmp` restores it — registers must be taken in the caller's
//! frame, hence naked code, no prologue. The buffer layout is ours, not Darwin's: safe because
//! the game only ever hands the same buffer back to us. Darwin's i386 `jmp_buf` is `int[18]` (72
//! bytes), so our six words fit with room to spare; Darwin's `setjmp` also saves the signal mask
//! and FP control word, but neither changes on the boot path so they aren't carried.

const std = @import("std");
const builtin = @import("builtin");

/// The words of our `jmp_buf`, in the order the code below writes them.
pub const Slot = enum(usize) {
    eip = 0,
    esp = 1,
    ebx = 2,
    esi = 3,
    edi = 4,
    ebp = 5,
};

/// Words used, out of Darwin's 18.
pub const words = 6;

const x86 = struct {
    /// `int setjmp(jmp_buf env)` — cdecl: `env` at [esp+4], return address at [esp]. Saved ESP is
    /// the caller's, taken after the return address, so `longjmp` restores the stack as it stood
    /// at the call. EAX/ECX/EDX are caller-saved on i386 so clobbering them is free; the
    /// callee-saved four plus SP and PC are the whole machine state a C frame can depend on.
    fn setjmp() callconv(.naked) void {
        asm volatile (
            \\ movl 4(%%esp), %%ecx
            \\ movl (%%esp), %%edx
            \\ movl %%edx, 0(%%ecx)
            \\ leal 4(%%esp), %%edx
            \\ movl %%edx, 4(%%ecx)
            \\ movl %%ebx, 8(%%ecx)
            \\ movl %%esi, 12(%%ecx)
            \\ movl %%edi, 16(%%ecx)
            \\ movl %%ebp, 20(%%ecx)
            \\ xorl %%eax, %%eax
            \\ ret
        );
    }

    /// `void longjmp(jmp_buf env, int val)`. Both arguments are read off the stack before ESP moves,
    /// because after it the stack they were on is gone. A `val` of 0 comes back as 1 — otherwise the
    /// caller could not tell the jump from the original return.
    fn longjmp() callconv(.naked) void {
        asm volatile (
            \\ movl 4(%%esp), %%ecx
            \\ movl 8(%%esp), %%eax
            \\ testl %%eax, %%eax
            \\ jnz 1f
            \\ incl %%eax
            \\1:
            \\ movl 8(%%ecx), %%ebx
            \\ movl 12(%%ecx), %%esi
            \\ movl 16(%%ecx), %%edi
            \\ movl 20(%%ecx), %%ebp
            \\ movl 0(%%ecx), %%edx
            \\ movl 4(%%ecx), %%esp
            \\ jmp *%%edx
        );
    }
};

/// Address of a normalised import name, or null if this package does not provide it.
///
/// Null on every host but i386: there is no portable version of this, and answering with one that
/// only half works is the thing this file exists to avoid. Nothing runs the image off i386 anyway.
pub fn address(name: []const u8) ?usize {
    if (comptime builtin.cpu.arch != .x86) return null;
    if (std.mem.eql(u8, name, "setjmp")) return @intFromPtr(&x86.setjmp);
    if (std.mem.eql(u8, name, "longjmp")) return @intFromPtr(&x86.longjmp);
    return null;
}

const testing = std.testing;

// Darwin's `jmp_buf` is what the game allocates, so the layout has to fit inside it.
test "the buffer stays inside the one the caller allocated" {
    const darwin_jmp_buf_words = 18;
    try testing.expect(words <= darwin_jmp_buf_words);
    try testing.expectEqual(@as(usize, 5), @intFromEnum(Slot.ebp));
}

test "setjmp and longjmp are answered only where the assembly is real" {
    if (comptime builtin.cpu.arch == .x86) {
        try testing.expect(address("setjmp").? != 0);
        try testing.expect(address("longjmp").? != 0);
    } else {
        try testing.expectEqual(@as(?usize, null), address("setjmp"));
        try testing.expectEqual(@as(?usize, null), address("longjmp"));
    }
    try testing.expectEqual(@as(?usize, null), address("sigsetjmp"));
}

/// Volatile through this, because no compiler knows a call can return twice: a counter kept in a
/// callee-saved register would be restored to its first-pass value along with everything else.
var trips: u32 = 0;

test "a longjmp comes back through setjmp carrying its value" {
    if (comptime builtin.cpu.arch != .x86) return error.SkipZigTest;

    const Buf = [18]u32;
    const set: *const fn (*Buf) callconv(.c) c_int = @ptrCast(&x86.setjmp);
    const long: *const fn (*Buf, c_int) callconv(.c) noreturn = @ptrCast(&x86.longjmp);
    const counter: *volatile u32 = &trips;

    var env: Buf = @splat(0xdead_beef);
    counter.* = 0;

    const arrival = set(&env);
    counter.* += 1;
    if (arrival == 0) long(&env, 42);

    // Twice through, and the second arrival carries the value longjmp was given.
    try testing.expectEqual(@as(u32, 2), counter.*);
    try testing.expectEqual(@as(c_int, 42), arrival);

    // Zero is the one value longjmp may not hand back, because it is what the first return means.
    var env2: Buf = @splat(0);
    const again = set(&env2);
    if (again == 0) long(&env2, 0);
    try testing.expectEqual(@as(c_int, 1), again);
}
