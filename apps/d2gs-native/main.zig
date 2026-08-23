//! The game server as one native process: Diablo II's 1.14d Mac image mapped into this address
//! space and run directly, instead of a Windows Game.exe under a wine process tree.
//!
//! This host does the four things dyld would have done — parse, map, bind, protect — reports what it
//! found, and then either stops (`--dry-run`) or jumps to the image entry point.

const std = @import("std");
const builtin = @import("builtin");
const macho = @import("macho");
const darwin = @import("darwin");
const crash = @import("crash.zig");
const qserver = @import("qserver.zig");
const realm = @import("realm.zig");
const chardb = @import("chardb.zig");

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

    var file = try macho.openImage(path.?.ptr);
    var img = try macho.image.parse(file.bytes);
    const names = try macho.collectImports(gpa, &img);

    resolver = try darwin.Resolver.init(names.len);
    defer resolver.deinit();

    // The descriptor is only needed while the segments are being mapped from it.
    var loaded = try macho.load.map(&img, file.fd);
    defer loaded.unmap();
    file.closeFd();

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
    // Before the segments get their real protections, while __TEXT is still writable.
    if (fits_32bit) {
        applyPatches(&loaded);
        // After the fixups, never before: the state table this rewrites holds image function
        // pointers, and a rebase pass would slide our entry along with them. Same for the join
        // hook, which is a relative call to code of ours.
        qserver.install(&loaded);
        realm.installTokenResolver(&loaded);
        chardb.installLoadHook(&loaded);
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

    // From here on every fault is the image's, and the only trace worth having is one written in the
    // image's own addresses.
    crash.install(loaded.memory, loaded.slide);

    // Before the constructors, not after: any of them may read the command line, and the cache is
    // only fillable while it is still empty.
    setCommandLine(&loaded, envOr("D2MAC_CMDLINE", "-skiptobnet"));

    // dyld's last job before the entry point, and the one with no visible symptom when it is
    // skipped: 45 C++ constructors that every global here depends on.
    macho.load.runInitializers(&loaded, if (std.mem.eql(u8, envOr("D2MAC_TRACE", "0"), "1")) traceInit else null);

    // The game boots itself from here, exactly as it would under dyld. `start` is skipped only
    // because everything it does is stack arithmetic we can do in Zig: it derives envp and apple
    // from argc/argv and calls this with all four.
    const Main = *const fn (c_int, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) callconv(.c) c_int;
    const game_main: Main = @ptrFromInt(loaded.at(pre_init_application));

    const argv0: [*:0]const u8 = path.?.ptr;
    var image_argv = [_:null]?[*:0]const u8{argv0};
    var empty = [_:null]?[*:0]const u8{};

    note("d2gs-native: entering main(1, [{s}], ...)\n", .{path.?});
    const rc = game_main(1, &image_argv, &empty, &empty);
    note("d2gs-native: main returned {d}\n", .{rc});
}

/// `PreInitApplication`, the first thing the image's own entry point calls.
const pre_init_application: u32 = 0x0019d582;

/// `geD2DefaultApplicationMode` — where the command-line parser starts before any token matches.
const default_app_mode: u32 = 0x005c8a30;

/// The mode to boot into — client, NOT server. The bootstrap table at 0x3e0eb8 is six 8-byte slots
/// (0 modstate0, 1 client=AppModeClientInit, 2 server={0,0}, 3 multiplayer, 4 launcher, 5 expand),
/// and slot 2 is {0, 0} — the Mac build has no dedicated-server mode compiled in, so ApplicationMain
/// fatals on server by construction. Costs nothing: the Windows build boots the client too and calls
/// QSERVER entry points itself. Client init sets up the memory managers and game tables;
/// `qserver.install` cuts in at the client state machine's first state, before the client proper.
const appmode_client: u32 = 1;

/// The two gates between a loaded image and a running game. Both are conditional jumps taken on a
/// condition a headless Linux process cannot satisfy, and both are answered the same way the
/// Windows build's engine patches are: by writing over the branch.
fn applyPatches(loaded: *const macho.load.Loaded) void {
    const patches = [_]struct { at: u32, bytes: []const u8, why: []const u8 }{
        // Renderer init cannot succeed without a window, and its failure otherwise skips the whole
        // game. `JZ` -> nothing.
        .{ .at = 0x0019b1b0, .bytes = &.{ 0x90, 0x90 }, .why = "call ApplicationMain even if renderer init fails" },
        // PreInitApplication is main, and the game runs inside a SetEvent() gate standing in for
        // Win32 single-instance detection. Ungated, pre-init merely completes and returns.
        .{ .at = 0x0019da54, .bytes = &.{ 0x90, 0x90 }, .why = "enter the game regardless of SetEvent" },
        // Renderer::Windowed::Initialize, whose result the patch above already discards. Enumerating
        // display modes on a machine with no display is not something to make succeed — it is
        // something not to call. `mov al, 1; ret`, and the server mode never touches the display
        // again.
        .{ .at = 0x0019cc81, .bytes = &.{ 0xb0, 0x01, 0xc3 }, .why = "skip renderer init entirely (headless)" },
        // Two UI calls ApplicationMain makes before it reaches the per-mode dispatch, even in server
        // mode: the menu bar, and the display-mode enumeration behind CGDisplayCopyAllDisplayModes.
        // Neither has anything to enumerate here and the second dereferences what it gets back.
        .{ .at = 0x0019ce5a, .bytes = &.{0xc3}, .why = "no menu bar to enable" },
        .{ .at = 0x002b4e7e, .bytes = &.{0xc3}, .why = "no display to pre-setup" },
        // MAC_LoadMediaMPQFiles. Graphics, Music and the expansion speech/movie archives are CD
        // content a data-only install does not carry and a headless server would never read, and it
        // asks an expansion-detect callback the launcher only fills in when it has a display.
        // `mov eax, 1; ret`.
        .{ .at = 0x00042c23, .bytes = &.{ 0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3 }, .why = "no media archives to load" },
        // D2GFX_CreateWindow — a Carbon window and an AGL context. Its caller UI_DISPLAY_Create is
        // left alone, so the display globals it owns are still initialised; only the window is not.
        .{ .at = 0x002b576b, .bytes = &.{ 0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3 }, .why = "no window to create" },
        // Carbon event handlers, installed on the window that no longer exists. The function is void
        // and its only caller ignores it; left alone it takes the null-window fatal-error path.
        .{ .at = 0x0004fca8, .bytes = &.{0xc3}, .why = "no window to install handlers on" },
        // OPENGLMAC_SwapContext, which looks 800x600x32 up in a display-mode list that is empty here
        // and logs "Failed to resize window... this is fatal!" when it is not found.
        .{ .at = 0x002dfbe3, .bytes = &.{ 0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3 }, .why = "no resolution to swap to" },
        // OPENGL_PresentFrame, the renderer vtable's present slot. It loads the context object from
        // 0x5e9edc and calls through its vtable, and that object is only ever built by the
        // D2GFX_CreateWindow above — so with no window the pointer is null and presenting a frame is
        // a null vtable dereference. Returns 1, as the real one does.
        .{ .at = 0x002df9b9, .bytes = &.{ 0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3 }, .why = "no context to present a frame to" },
        // UI_DISPLAY_RenderFrame's draw block (BeginScene..EndScene needs the missing window). Not
        // breaking a branch open but holding one shut: the game already skips this block itself
        // when the display flag at 0x554e94 is set. Panel-update callbacks outside the block still
        // run. `JNZ rel32` -> `JMP rel32`, same target.
        .{ .at = 0x0004a7c2, .bytes = &.{ 0xe9, 0xc9, 0x01, 0x00, 0x00, 0x90 }, .why = "no surface to draw the frame on" },
        // QSERVER_DispatchAndCleanup reaps an empty game only after `CMP ESI, 0x493e0` (five
        // minutes). Windows patches this too (`apps/d2gs/runtime/gamereap.zig`, there about not
        // exhausting the 8 Fog pool managers) but this engine has room for exactly one game, so the
        // idle window IS the gap between games. Cut to one millisecond; `realm.pump` guards against
        // reaping a just-made game by holding its empty-since stamp at zero until someone joins.
        .{ .at = 0x001ae8f2, .bytes = &.{ 0x01, 0x00, 0x00, 0x00 }, .why = "collect an empty game at once, not in five minutes" },
        // GAMELOGON's no-realm branch serves one game and calls it token 1: it refuses any other
        // token outright, then passes the immediate 1 to SERVER_IsTokenValid rather than the token
        // the packet carried. Both are the same assumption written twice. Drop the refusal...
        .{ .at = 0x001a7a26, .bytes = &.{ 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 }, .why = "any game token may be joined" },
        // ...and look up the one that was asked for. `movzx eax, word [esi+9]; mov [esp], eax` is
        // exactly the 7 bytes `mov dword [esp], 1` occupied, so nothing after it moves. EAX is dead
        // here — the call overwrites it and the test that follows reads the result.
        .{ .at = 0x001a7a2f, .bytes = &.{ 0x0f, 0xb7, 0x46, 0x09, 0x89, 0x04, 0x24 }, .why = "join the token the client asked for" },
        // Then the version gate the same handler applies two instructions later: `cmp edi, 0xe;
        // jne refuse`, where EDI is the version byte out of the packet at [esi+0xc]. 1.13c's
        // server-to-client table is byte-for-byte 1.14d's (libd2 packages/net/src/sc_versions.zig
        // records zero differing entries), so this engine can serve a 1.13c client and refuses it
        // on the number alone. Widened to "0x0d or later" rather than removed: a 1.09d client
        // frames GameFlags a byte shorter and would join to a silent hang, which is the one
        // failure mode worth keeping a gate for. `JNE` -> `JB`, same target, same length.
        .{ .at = 0x001a7a5a, .bytes = &.{ 0x83, 0xff, 0x0d }, .why = "accept 1.13c's version byte as well as 1.14d's" },
        .{ .at = 0x001a7a5d, .bytes = &.{0x72}, .why = "refuse only what is older than 1.13c" },
        // ...and then translate it somewhere with room: SERVER_IsTokenValid's table has one usable
        // slot (index 0 aliases the server-running byte at 0x53756c, allocator clamps its counter to
        // 1) and indexes with an unchecked u16, so a realm token is unstorable/unsafe there.
        // `realm.installTokenResolver` replaces that function instead, since a GAMELOGON looks the
        // token up from three separate functions; the table itself is left as the engine keeps it.
        // NET_D2GS_SERVER_SendPacketToClient 0x002ddd78 already has a verbatim path (mode 2); this
        // build split the compiler's one gate into two legs, so both need `JE raw` -> `JMP raw`,
        // with the greeting-only test on the other leg NOPed out — output is then Huffman-free and
        // unframed, the only thing a client greeted with 0xAF00 can read.
        .{ .at = 0x002dde12, .bytes = &.{ 0xeb, 0x09 }, .why = "send raw, not compressed" },
        .{ .at = 0x002dde1b, .bytes = &.{ 0x90, 0x90 }, .why = "send raw on the unlogged leg too" },
        // And say so: `movw $0x1af` builds the {0xAF, 0x01} greeting a byte at a time. 0x01 claims
        // a compressed, length-framed stream, which is no longer what follows it.
        .{ .at = 0x002ddd4b, .bytes = &.{0x00}, .why = "greet with 0xAF00 to match" },
    };
    for (patches) |p| {
        const at: [*]u8 = @ptrFromInt(loaded.at(p.at));
        @memcpy(at[0..p.bytes.len], p.bytes);
        note("d2gs-native: patch 0x{x} {s}\n", .{ p.at, p.why });
    }

    // Belt and braces with the command line: the parser starts from this and only moves if a token
    // matches, so setting it means a parse that finds nothing still lands on the server.
    const mode: *u32 = @ptrFromInt(loaded.at(default_app_mode));
    mode.* = appmode_client;
}

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
