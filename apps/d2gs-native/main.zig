//! The game server as one native process: Diablo II's 1.14d Mac image mapped into this address
//! space and run directly, instead of a Windows Game.exe under a wine process tree.
//!
//! This host does the four things dyld would have done — parse, map, bind, protect — reports what it
//! found, and then either stops (`--dry-run`) or jumps to the image entry point.

const std = @import("std");
const builtin = @import("builtin");
const macho = @import("macho");
const darwin = @import("darwin");

/// `applyFixups` takes a plain function pointer with no context argument, so the resolver has to be
/// reachable from file scope.
var resolver: darwin.Resolver = undefined;

fn resolveThunk(name: []const u8) ?usize {
    return resolver.resolve(name);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    var path: ?[:0]const u8 = null;
    var dry_run = false;
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true else if (path == null) path = arg else return usage();
    }
    // An installed game is not in the repo, so the tests and this host find it the same way.
    if (path == null) path = std.mem.span(getenv("D2MAC_BIN") orelse return usage());

    const bytes = try macho.readFile(gpa, path.?.ptr);
    var img = try macho.image.parse(bytes);
    const names = try macho.collectImports(gpa, &img);

    resolver = try darwin.Resolver.init(names.len);
    defer resolver.deinit();

    var loaded = try macho.load.map(&img);
    defer loaded.unmap();

    // Resolve up front rather than only through the bind walk: it is the same work and the same
    // memoised addresses, and it still produces an exact import report on a host where the fixups
    // below cannot be written.
    for (names) |name| _ = resolver.resolve(name) orelse return error.OutOfThunks;

    // Every fixup slot is 32 bits wide, so a slid pointer or a host function address has to fit in
    // one. On i386 Linux it always does; on a 64-bit host the mapping and libc sit above 4 GiB and
    // the image can be inspected but never bound.
    const fits_32bit = @intFromPtr(loaded.memory.ptr) + loaded.memory.len <= 0xffff_ffff;
    if (fits_32bit) {
        macho.load.applyFixups(&loaded, resolveThunk) catch |err| {
            if (loaded.missing) |m| std.debug.print("d2gs-native: no address for import {s}\n", .{m});
            return err;
        };
    }
    // Sealing is what makes the thunks executable, so it has to follow every bind, not precede it.
    try resolver.seal();
    try macho.load.protect(&loaded);

    // A name the host libc provides is bound to the real function; the rest got a thunk, one per
    // distinct name however many slots referenced it.
    const thunked = resolver.thunks.count();

    const span = img.span();
    std.debug.print(
        \\d2gs-native: {s}
        \\  image   0x{x}..0x{x}  {d} KiB
        \\  mapped  0x{x}  slide {d}
        \\  entry   0x{x} -> 0x{x}
        \\  imports {d} = {d} host + {d} thunks
        \\  fixups  {s}
        \\
    , .{
        path.?,
        span.low,
        span.high,
        (span.high - span.low) / 1024,
        @intFromPtr(loaded.memory.ptr),
        loaded.slide,
        img.entry,
        loaded.entry(),
        names.len,
        names.len - thunked,
        thunked,
        if (fits_32bit) "applied" else "skipped, image mapped above 4 GiB",
    });

    if (dry_run) return;

    // The image is i386 code with i386 calling conventions; there is nothing to jump to anywhere
    // else, and a wrong-host jump would just be a crash with a worse message.
    if (builtin.cpu.arch != .x86 or builtin.os.tag != .linux) {
        std.debug.print(
            "d2gs-native: running the image needs an i386 Linux host (this is {s}-{s}); use --dry-run here\n",
            .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        );
        std.process.exit(2);
    }

    // Before the constructors, not after: any of them may read the command line, and the cache is
    // only fillable while it is still empty.
    setCommandLine(&loaded, "-server");

    // dyld's last job before the entry point, and the one with no visible symptom when it is
    // skipped: 45 C++ constructors that every global here depends on.
    macho.load.runInitializers(&loaded, if (std.mem.eql(u8, envOr("D2MAC_TRACE", "0"), "1")) traceInit else null);

    // Not `loaded.entry()`. The image's `start` reads argc off a Darwin process stack, walks argv
    // to find envp, discards the result and calls PreInitApplication — so building that stack
    // would buy nothing but a crash in the walk.
    const f: *const fn () callconv(.c) c_int = @ptrFromInt(loaded.at(pre_init_application));
    note("d2gs-native: entering PreInitApplication\n", .{});
    const rc = f();
    note("d2gs-native: PreInitApplication returned {d}\n", .{rc});
}

/// `PreInitApplication`, the first thing the image's own entry point calls.
const pre_init_application: u32 = 0x0019d582;

/// `StormMac::MAC_GetCommandLine`'s cache: an 0x800 byte buffer it fills once from
/// `[[NSProcessInfo processInfo] arguments]`, guarded by "is the first byte still zero".
const command_line_buffer: u32 = 0x003f1a74;
const command_line_len: u32 = 0x003f2278;

/// The application mode is not taken from argv. `CLIENT_CheckIfApplicationModeIsInCommandLine...`
/// asks MAC_GetCommandLine for it and strtok's the result on '-', matching each token against the
/// six mode names at 0x3e0e9c — "server" is one of them, and selecting it is what makes the process
/// headless by construction rather than by patching out the renderer.
///
/// Writing the cache rather than the arguments is the whole trick: the buffer is only filled while
/// its first byte is zero, so a value put there first is the value the game reads, and the
/// Objective-C path that would otherwise need NSProcessInfo never runs.
fn setCommandLine(loaded: *const macho.load.Loaded, cmdline: []const u8) void {
    const buf: [*]u8 = @ptrFromInt(loaded.at(command_line_buffer));
    @memcpy(buf[0..cmdline.len], cmdline);
    buf[cmdline.len] = 0;

    const len: *u32 = @ptrFromInt(loaded.at(command_line_len));
    len.* = @intCast(cmdline.len);
    note("d2gs-native: command line \"{s}\"\n", .{cmdline});
}

/// Unbuffered on purpose: this exists to survive a segfault, and anything buffered is lost.
fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

fn traceInit(index: usize, addr: u32) void {
    note("  init[{d}] 0x{x}\n", .{ index, addr });
}

fn envOr(name: [*:0]const u8, default: []const u8) []const u8 {
    return if (getenv(name)) |v| std.mem.span(v) else default;
}

fn usage() error{Usage} {
    std.debug.print("usage: d2gs-native <path-to-DiabloII-macho> [--dry-run]   (or set D2MAC_BIN)\n", .{});
    return error.Usage;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
