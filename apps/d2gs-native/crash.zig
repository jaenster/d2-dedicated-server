//! Where an i386 fault happened, said in the image's own addresses.
//!
//! Zig's own handler unwinds with DWARF and then a frame chain, and the image has neither: the
//! trace it prints for a fault inside the game is four plausible-looking numbers that are not
//! frames. What is reliable is the register file the kernel hands the handler, plus the fact that
//! every code address in the image sits in one known 6 MB range — so this prints EIP, the word
//! `call` pushed at [ESP], and every stack word that lands inside the image, each converted back to
//! the static address Ghidra uses.

const std = @import("std");
const builtin = @import("builtin");

const enabled = builtin.os.tag == .linux and builtin.cpu.arch == .x86;

var slide: usize = 0;
var low: usize = 0;
var high: usize = 0;

/// i386 Linux's signal frame. `uc_mcontext` is the kernel's `struct sigcontext`, and it starts 20
/// bytes in: two words, then a 12-byte `stack_t`.
const SigContext = extern struct {
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    trapno: u32,
    err: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
    esp_at_signal: u32,
    ss: u32,
    fpstate: u32,
    oldmask: u32,
    cr2: u32,
};

const UContext = extern struct {
    flags: u32,
    link: u32,
    stack: [3]u32,
    mcontext: SigContext,
};

comptime {
    std.debug.assert(@offsetOf(UContext, "mcontext") == 20);
    std.debug.assert(@offsetOf(SigContext, "eip") == 56);
}

pub fn install(memory: []const u8, image_slide: i64) void {
    if (comptime !enabled) return;
    // The slide is signed and wider than a pointer; subtracting it from a runtime address is
    // wrapping arithmetic, so it is carried as the bit pattern that makes that work.
    slide = @bitCast(@as(isize, @truncate(image_slide)));
    low = @intFromPtr(memory.ptr);
    high = low + memory.len;

    const linux = std.os.linux;
    var act: linux.Sigaction = .{
        .handler = .{ .sigaction = @ptrCast(&realign) },
        .mask = linux.sigemptyset(),
        // The faulting instruction is game code on a stack the kernel can still use, so the handler
        // runs on it rather than on an alternate one; nothing here recurses and it keeps no frame
        // worth speaking of, its buffer being static.
        .flags = linux.SA.SIGINFO | linux.SA.RESETHAND,
    };
    for ([_]linux.SIG{ .SEGV, .BUS, .ILL, .FPE }) |sig| _ = linux.sigaction(sig, &act, null);

    // A hang is a failure with no address, and `kill -USR2` is how it gets one: the same trace, on
    // demand, as often as asked — so it stays armed and the process stays up. USR2 and not QUIT,
    // because the game blocks INT, QUIT, ABRT and TERM in every thread it makes. It gets no chance
    // to block this one, or the fault signals above — see `pthread.sigmask`.
    act.flags = linux.SA.SIGINFO;
    _ = linux.sigaction(.USR2, &act, null);
}

/// The handler's scratch, deliberately not a local. Four kilobytes of frame is more than the game
/// leaves spare on the thread stacks it makes, and a handler that overflows the stack it was called
/// on faults again — which with RESETHAND is a silent death. Static, it costs no frame. Two signals
/// at once would share it, and a garbled trace beats none.
var scratch: [4096]u8 = undefined;

/// The i386 ABI promises a handler that ESP+4 is 16-byte aligned on entry, and the compiler spends
/// that promise on `movaps` — an aligned SSE store into the frame. qemu-user builds the signal frame
/// it hands the guest to eight-byte alignment instead, so that store faults, inside the handler,
/// with RESETHAND already armed: a silent death. That is why this reporter never described a crash
/// and why `kill -USR2` killed the process instead of tracing it. Realigning here is cheaper than
/// forbidding SSE in everything the handler calls, and the arguments are simply passed on.
fn realign() callconv(.naked) void {
    asm volatile (
        \\pushl %%ebp
        \\movl %%esp, %%ebp
        \\andl $-16, %%esp
        \\subl $4, %%esp
        \\pushl 0x10(%%ebp)
        \\pushl 0xc(%%ebp)
        \\pushl 0x8(%%ebp)
        \\calll d2gs_on_fault
        \\movl %%ebp, %%esp
        \\popl %%ebp
        \\ret
    );
}

comptime {
    if (enabled) @export(&onFault, .{ .name = "d2gs_on_fault" });
}

fn onFault(sig: std.os.linux.SIG, info: *const std.os.linux.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    // The signal number and the context pointer, by themselves, before anything that could fault.
    // A handler that dies partway through is only debuggable if what it managed to reach is already
    // out — and `@tagName` is not on this side of that line, being a lookup the optimiser is free to
    // turn into a trap for a signal number it has no name for.
    var n: usize = 0;
    n = str(&scratch, n, "\nd2gs-native: signal ");
    n = hex(&scratch, n, @intFromEnum(sig));
    n = str(&scratch, n, " ctx 0x");
    n = hex(&scratch, n, @intFromPtr(ctx));
    n = str(&scratch, n, "\n");
    _ = std.os.linux.write(2, &scratch, n);

    n = 0;
    // Only a fault has a faulting address; on the asked-for trace that union member is stale.
    if (sig != .USR2) {
        n = str(&scratch, n, "  at 0x");
        n = hex(&scratch, n, @intFromPtr(info.fields.sigfault.addr));
        n = str(&scratch, n, "\n");
        _ = std.os.linux.write(2, &scratch, n);
        n = 0;
    }

    const uc: *const UContext = @ptrCast(@alignCast(ctx orelse {
        _ = std.os.linux.write(2, "  (no context)\n", 15);
        return;
    }));
    const m = &uc.mcontext;

    n = str(&scratch, n, "  eip");
    n = code(&scratch, n, m.eip);
    for ([_]struct { []const u8, u32 }{
        .{ "  esp 0x", m.esp },
        .{ " ebp 0x", m.ebp },
        .{ "\n  eax 0x", m.eax },
        .{ " ebx 0x", m.ebx },
        .{ " ecx 0x", m.ecx },
        .{ " edx 0x", m.edx },
        .{ " esi 0x", m.esi },
        .{ " edi 0x", m.edi },
    }) |reg| {
        n = str(&scratch, n, reg[0]);
        n = hex(&scratch, n, reg[1]);
    }

    // Out before the stack is touched: ESP itself may be the thing that is wrong, and a second fault
    // in here is a silent death with RESETHAND armed.
    n = str(&scratch, n, "\n");
    _ = std.os.linux.write(2, &scratch, n);

    // A call through a null pointer faults with the return address already pushed, so this one word
    // names the caller exactly. Everything after it is a guess by range.
    n = str(&scratch, 0, "  [esp]");
    n = code(&scratch, n, @as(*const u32, @ptrFromInt(m.esp)).*);
    n = str(&scratch, n, "\n  stack:");

    var addr: usize = m.esp;
    var found: usize = 0;
    while (addr < m.esp + 0x800 and found < 24) : (addr += 4) {
        const word = @as(*const u32, @ptrFromInt(addr)).*;
        if (word < low or word >= high) continue;
        found += 1;
        n = code(&scratch, n, word);
        if (n + 64 > scratch.len) break;
    }
    n = str(&scratch, n, "\n");
    _ = std.os.linux.write(2, &scratch, n);
    // `exit_group`, not `std.process.exit`: the fault left locks held all over the engine and an
    // orderly exit would take one of them. The trace is already out; nothing else has to work.
    if (sig != .USR2) std.os.linux.exit_group(3);
}

/// An image address as Ghidra spells it; anything else raw, since only the image has a symbol table.
fn code(buf: []u8, n_in: usize, addr: usize) usize {
    var n = str(buf, n_in, " 0x");
    if (addr >= low and addr < high) {
        n = hex(buf, n, addr -% slide);
        return str(buf, n, "*");
    }
    return hex(buf, n, addr);
}

fn str(buf: []u8, n_in: usize, s: []const u8) usize {
    var n = n_in;
    for (s) |c| {
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return n;
}

fn hex(buf: []u8, n_in: usize, value: usize) usize {
    var tmp: [16]u8 = undefined;
    var v = value;
    var i: usize = tmp.len;
    if (v == 0) {
        i -= 1;
        tmp[i] = '0';
    }
    while (v != 0) : (v >>= 4) {
        i -= 1;
        tmp[i] = "0123456789abcdef"[v & 0xf];
    }
    return str(buf, n_in, tmp[i..]);
}

const testing = std.testing;

test "the signal frame is the kernel's, field for field" {
    // The four segment registers are short pairs in the kernel's struct, so each still costs a word.
    try testing.expectEqual(@as(usize, 88), @sizeOf(SigContext));
    try testing.expectEqual(@as(usize, 16), @offsetOf(SigContext, "edi"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(SigContext, "ebp"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(SigContext, "esp"));
    try testing.expectEqual(@as(usize, 84), @offsetOf(SigContext, "cr2"));
}

test "an image address is printed static, anything else raw" {
    low = 0x1000_0000;
    high = 0x1010_0000;
    slide = 0x1000_0000;

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(" 0x1234*", buf[0..code(&buf, 0, 0x1000_1234)]);
    try testing.expectEqualStrings(" 0xdeadbeef", buf[0..code(&buf, 0, 0xdead_beef)]);
    try testing.expectEqualStrings(" 0x0", buf[0..code(&buf, 0, 0)]);
}
