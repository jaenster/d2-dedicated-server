//! Host the pre-1.14 DLLs directly: load the module set, install a callback table, and see how far
//! D2Game gets before it complains. Runs as an x86-windows exe under wine.
//!
//! This is the other shape of game server. `apps/d2gs` injects into 1.14d's merged Game.exe and
//! detours it; here D2Game.dll is a library we drive, which is what it was built to be before 1.14
//! merged everything. The host contract is documented in `docs/dll-host.md` — notably it is the same
//! callback table `apps/d2gs/engine/realm.zig` already fills for 1.14d.
//!
//!   d2host <dir-with-the-dlls>
//!
//! It reports each step, so a failure names the module or call that broke rather than just dying.

const std = @import("std");
const fastcall = @import("fastcall");
const store = @import("gs_store");
const proto = @import("realm_proto").protocol;

const HMODULE = *anyopaque;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn InitializeCriticalSection(cs: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetProcAddress(m: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn SetCurrentDirectoryA(path: [*:0]const u8) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: *anyopaque, buf: [*]const u8, n: u32, wrote: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn AllocConsole() callconv(.winapi) i32;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]const u8;

var out_handle: ?*anyopaque = null;

fn say(msg: []const u8) void {
    const h = out_handle orelse return;
    var wrote: u32 = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &wrote, null);
    _ = WriteFile(h, "\r\n", 2, &wrote, null);
}

fn sayHex(prefix: []const u8, v: usize) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}0x{x}", .{ prefix, v }) catch return;
    say(s);
}

/// The port this server listens on — never 4000. d2ingress owns the client-facing 4000 (the port
/// the client hardcodes) and splices game traffic through to the port a GS advertises, so binding
/// it here would collide with the ingress and stop a fleet sharing a host. Same default and same
/// override as `apps/d2gs`: `--gs-addr ip:port`, or `D2GS_GS_ADDR` for k8s.
fn listenPort() u16 {
    var buf: [64]u8 = undefined;
    const n = GetEnvironmentVariableA("D2GS_GS_ADDR", &buf, buf.len);
    if (n == 0 or n >= buf.len) return 4100;
    const spec = buf[0..n];
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return 4100;
    return std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch 4100;
}

/// Read an environment variable into `buf`, or null when unset.
fn env(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    const n = GetEnvironmentVariableA(name, buf.ptr, @intCast(buf.len));
    return if (n == 0 or n >= buf.len) null else buf[0..n];
}

/// This server's identity in the shared store. Same knobs as `apps/d2gs`, because a fleet that
/// mixes both has to be configured one way.
var gsid: u32 = 0;
var public_ip: [4]u8 = .{ 127, 0, 0, 1 };
var public_port: u16 = 4100;
var max_games: u32 = 7;
var live_games: u32 = 0;

/// The realm link is optional. Without a store address this stays a standalone spike that creates
/// one game and ticks — which is exactly what it was, and still the quickest way to prove a build.
fn realmConfigured() bool {
    return gsid != 0 and store.enabled();
}

/// Read the store address and this server's identity, the same env the DLL server takes so a
/// fleet mixing both is configured one way.
fn configureRealm() void {
    var buf: [128]u8 = undefined;
    if (env("D2GS_REDIS_ADDR", &buf)) |addr| store.configure(addr);
    var idbuf: [32]u8 = undefined;
    if (env("D2GS_GSID", &idbuf)) |v| gsid = std.fmt.parseInt(u32, v, 10) catch 0;
    var abuf: [64]u8 = undefined;
    if (env("D2GS_GS_ADDR", &abuf)) |spec| {
        if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
            public_port = std.fmt.parseInt(u16, spec[c + 1 ..], 10) catch public_port;
            var it = std.mem.splitScalar(u8, spec[0..c], '.');
            var i: usize = 0;
            while (it.next()) |octet| : (i += 1) {
                if (i >= 4) break;
                public_ip[i] = std.fmt.parseInt(u8, octet, 10) catch return;
            }
        }
    }
}

/// The engine call that makes a game, resolved once at startup so the realm handler can use it.
const CreateGameFn = *const fn (
    [*:0]u8, // game name (written to, not const)
    [*:0]const u8, // password
    [*:0]const u8, // description
    u32, // flags
    u8, // arena template
    u8, // max level difference
    u8, // max players
    *u16, // out: game id
) callconv(.winapi) i32;

var create_game: ?CreateGameFn = null;

/// Answer one CREATEGAME from the realm by actually creating it. The realm keeps the authoritative
/// game list; this only reports what the engine did, so a refusal has to be reported as a refusal
/// rather than a silence — a client left waiting on a game that was never made just times out.
fn handleCreateGame(seq: u32, body: []const u8) void {
    var reply = std.mem.zeroes(proto.CreateGameReply);
    reply.h = proto.header(.creategame, @sizeOf(proto.CreateGameReply), seq);

    const make = create_game orelse {
        reply.result = 1;
        _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
        return;
    };
    if (body.len < 5) {
        reply.result = 1;
        _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
        return;
    }

    var off: usize = 4;
    const want_name = proto.readCStr(body, &off);
    const want_pass = proto.readCStr(body, &off);

    // The engine writes into the name buffer, so it cannot be the realm's bytes.
    var name: [32:0]u8 = @splat(0);
    var pass: [32:0]u8 = @splat(0);
    @memcpy(name[0..@min(want_name.len, 31)], want_name[0..@min(want_name.len, 31)]);
    @memcpy(pass[0..@min(want_pass.len, 31)], want_pass[0..@min(want_pass.len, 31)]);

    var game_id: u16 = 0;
    const ok = make(&name, &pass, "", 0, 0, 0, 8, &game_id);
    if (ok == 0) {
        say("d2host: CREATEGAME refused by the engine");
        reply.result = proto.CREATE_SERVER_FULL;
    } else {
        live_games += 1;
        reply.gameid = game_id;
        sayHex("d2host: CREATEGAME made game ", game_id);
    }
    _ = store.putReply(seq, std.mem.asBytes(&reply), 30);
}

/// Take at most one request per tick, which is what the DLL server does — the queue is drained by
/// the tick rate rather than in a burst, so one slow creation cannot stall the game loop.
fn pumpRealm() void {
    var buf: [1024]u8 = undefined;
    const n = store.popRequest(gsid, &buf);
    if (n < proto.HEADER_LEN) return;
    const size = std.mem.readInt(u16, buf[0..2], .little);
    const typ = std.mem.readInt(u16, buf[2..4], .little);
    const seq = std.mem.readInt(u32, buf[4..8], .little);
    if (size > n or size < proto.HEADER_LEN) return; // truncated; nothing sensible to answer
    switch (@as(proto.Type, @enumFromInt(typ))) {
        .creategame => handleCreateGame(seq, buf[proto.HEADER_LEN..size]),
        else => {},
    }
}

/// Frames to run before exiting. 50 ms apart, so this is about a minute — enough to attach a
/// client by hand and watch what the engine makes of it.
const tick_frames = 1200;

var arg_buf: [512]u8 = undefined;

/// The one argument we take, straight off the command line: argv[0] may be quoted, everything after
/// the first unquoted space is the directory. Returns null when no argument was given.
fn firstArg() ?[*:0]const u8 {
    const cmd = GetCommandLineA();
    var i: usize = 0;
    if (cmd[0] == '"') {
        i = 1;
        while (cmd[i] != 0 and cmd[i] != '"') i += 1;
        if (cmd[i] == '"') i += 1;
    } else {
        while (cmd[i] != 0 and cmd[i] != ' ') i += 1;
    }
    while (cmd[i] == ' ') i += 1;
    if (cmd[i] == 0) return null;
    var n: usize = 0;
    while (cmd[i + n] != 0 and n + 1 < arg_buf.len) : (n += 1) arg_buf[n] = cmd[i + n];
    while (n > 0 and (arg_buf[n - 1] == ' ' or arg_buf[n - 1] == '"')) n -= 1;
    arg_buf[n] = 0;
    if (n == 0) return null;
    return @ptrCast(&arg_buf);
}

/// Resolve an export by ordinal: GetProcAddress takes the ordinal in the low word of the name ptr.
fn byOrdinal(m: HMODULE, ordinal: u16) ?*anyopaque {
    return GetProcAddress(m, @ptrFromInt(@as(usize, ordinal)));
}

// ── the callback table ───────────────────────────────────────────────────────
//
// 16 pointers, 0x40 bytes, packed. Every stub only reports that it was reached: the point of the
// spike is to learn which ones D2Game actually calls during init, and in what order.

const CallbackTable = extern struct {
    close_game: *const anyopaque,
    leave_game: *const anyopaque,
    get_database_character: *const anyopaque,
    save_database_character: *const anyopaque,
    server_log_message: *const anyopaque,
    enter_game: *const anyopaque,
    find_player_token: *const anyopaque,
    save_database_guild: *const anyopaque,
    unlock_database_character: *const anyopaque,
    unk_0x24: *const anyopaque,
    update_character_ladder: *const anyopaque,
    update_game_information: *const anyopaque,
    handle_packet: *const anyopaque,
    set_game_data: *const anyopaque,
    relock_database_character: *const anyopaque,
    load_complete: *const anyopaque,
};

comptime {
    // The engine indexes this table by fixed offset; a layout change silently corrupts dispatch.
    std.debug.assert(@sizeOf(CallbackTable) == 0x40);
    std.debug.assert(@offsetOf(CallbackTable, "get_database_character") == 0x08);
    std.debug.assert(@offsetOf(CallbackTable, "save_database_character") == 0x0C);
    std.debug.assert(@offsetOf(CallbackTable, "enter_game") == 0x14);
    std.debug.assert(@offsetOf(CallbackTable, "find_player_token") == 0x18);
    std.debug.assert(@offsetOf(CallbackTable, "load_complete") == 0x3C);
}

/// Build a reporting stub for one slot. `n_stack` is the arg count past ECX/EDX, which is also what
/// the shim must pop — get it wrong and the engine's stack is corrupt on return.
fn Stub(comptime name: []const u8, comptime n_stack: usize) type {
    return struct {
        fn impl(ecx: usize, edx: usize, ...) callconv(.c) usize {
            _ = edx;
            say("d2host: engine called " ++ name);
            _ = ecx;
            return 0;
        }
        const ptr: *const anyopaque = @ptrCast(&fastcall.Callback2(n_stack, impl).shim);
    };
}

/// The four QServer callbacks Fog takes. Same reporting shape as `Stub`, kept separate so the
/// network side is obvious in the log when a client eventually connects.
fn QStub(comptime name: []const u8, comptime n_stack: usize) type {
    return struct {
        fn impl(ecx: usize, edx: usize, ...) callconv(.c) usize {
            _ = ecx;
            _ = edx;
            say("d2host: qserver called " ++ name);
            return 0;
        }
        const ptr: *const anyopaque = @ptrCast(&fastcall.Callback2(n_stack, impl).shim);
    };
}

/// cdecl varargs, not fastcall — the engine's own logger.
fn serverLogMessage(level: i32, fmt: [*:0]const u8, ...) callconv(.c) void {
    _ = level;
    say("d2host: engine called pfServerLogMessage");
    sayHex("d2host:   fmt=", @intFromPtr(fmt));
}

/// stdcall, one arg.
fn loadComplete(a: i32) callconv(.winapi) i32 {
    _ = a;
    say("d2host: engine called pfLoadComplete");
    return 0;
}

/// MUST outlive every call into D2Game: SetServerCallbackFunctions stores this pointer rather than
/// copying the struct (verified at 1.10f 0x6FC358E0), so a stack temporary would dangle.
var callbacks: CallbackTable = undefined;

/// The game-data table is not an opaque buffer — it is a host-owned object D2Game reaches into by
/// fixed offset, and Blizzard's own host built it with a C++ constructor. In 1.00's `D2Server.dll`
/// the two structures are statics 0x70 apart, and the ctor @0x1000A240 sets `[+0x24] = 3` and
/// points `[+0x1c]` at four 12-byte slots.
///
/// 1.10f's `GAME_CreateNewEmptyGame` shows how they are used (@0x6fc3b590):
/// `edx = [+0x24] & counter; entry = [+0x1c] + edx*12` — so **`+0x24` is a power-of-two mask**,
/// not a capacity, and `+0x1c` is its slot array. A zeroed buffer means a null array and mask 0,
/// which segfaults on the first game. The mask is also range-checked against 0x3FF, so it has to
/// stay below that.
const token_slots = 512;
const GameToken = extern struct { a: u32 = 0, b: u32 = 0, c: u32 = 0 };

comptime {
    std.debug.assert(@sizeOf(GameToken) == 12); // the engine's own stride: edx*12
    std.debug.assert(token_slots - 1 < 0x3FF); // the mask is rejected at or above this
}

var game_tokens: [token_slots]GameToken align(16) = @splat(.{});

/// Field offsets in the game-data table, named for what the engine does with them.
const gdt = struct {
    const vtable = 0x00; // -> GameDataVTable; the engine calls slot +0x04 to allocate a record
    const arena = 0x04; // record = [arena] + <slot1's return>; zero here makes that the pointer
    const list_head = 0x08; // intrusive list head, always a valid node (see linkRecord below)
    const counter = 0x10; // decremented in threes, floored at zero
    const slots = 0x1c; // -> game_tokens
    const mask = 0x24; // token_slots - 1
    const lock = 0x50; // CRITICAL_SECTION, the host's to initialise
};

/// The interface D2Game invokes on the game-data table. Four methods; the fifth entry in
/// Blizzard's is null, which is what bounds it. Arities are the `RET n` of D2Server's own
/// implementations — `__thiscall`, so `this` arrives in ECX and the callee pops the stack args.
const GameDataVTable = extern struct {
    destroy: *const anyopaque, // +0x00  (this, flags)      ret 4   — scalar deleting destructor
    alloc_record: *const anyopaque, // +0x04  (this, slot*, a, b) ret 0xc — the only one game creation uses
    release: *const anyopaque, // +0x08  (this, flags)      ret 4
    reset: *const anyopaque, // +0x0C  (this)             ret 0
    terminator: ?*const anyopaque = null,
};

/// One per-game record. The engine writes `[rec]` and `[rec+0x14]` and threads `[rec+4]` through
/// its list, so it is at least 0x18 bytes; the rest is headroom rather than a known layout.
const GameRecord = extern struct { bytes: [0x40]u8 align(4) = @splat(0) };

/// 0x400 is the size of D2Game's own game array, so it cannot need more records than that.
var game_records: [0x400]GameRecord = @splat(.{});
var records_used: usize = 0;

/// `[this+8]` is dereferenced as a node on every insert (`edx = [esi+8]; edi = [edx+4]`), including
/// the very first, so it can never be null. This is the sentinel it starts as.
var list_sentinel: [4]usize align(4) = @splat(0);

var vtable: GameDataVTable = undefined;

/// vtable +0x04. `__thiscall (this /*ECX*/, D2GameToken* slot, int a, int b) -> void*`.
///
/// The engine takes the result as the new game's record: it links it into `[this+8]` and then
/// writes through it, so returning null trips D2Game's own assert at DataTbls line 0x2d2. Handing
/// back zeroed storage also steers it to the insert path rather than the free-list pop, which is
/// the correct behaviour for a game that has never existed before.
fn allocRecord(this: usize, _: usize, slot: usize, a: usize, b: usize) callconv(.c) usize {
    _ = this;
    _ = slot;
    _ = a;
    _ = b;
    if (records_used >= game_records.len) {
        say("d2host: game-data records exhausted");
        return 0;
    }
    const rec = &game_records[records_used];
    records_used += 1;
    rec.* = .{};
    return @intFromPtr(rec);
}

fn gdtDestroy(_: usize, _: usize, _: usize) callconv(.c) usize {
    say("d2host: game-data table destroy");
    return 0;
}

fn gdtRelease(_: usize, _: usize, _: usize) callconv(.c) usize {
    say("d2host: game-data table release");
    return 0;
}

fn gdtReset(_: usize, _: usize) callconv(.c) usize {
    say("d2host: game-data table reset");
    return 0;
}

var game_data_table: [64 * 1024]u8 align(16) = @splat(0);
var game_list: [64 * 1024]u8 align(16) = @splat(0);

fn field(comptime T: type, offset: usize) *T {
    return @ptrCast(@alignCast(&game_data_table[offset]));
}

/// Put the table into the state D2Game expects before it is handed over. The engine treats it as a
/// live object from the first game creation onward, so every field it reads has to mean something
/// by then — there is no second chance to fill this in.
fn buildGameDataTable() void {
    // __thiscall is __stdcall with `this` in ECX, so the fastcall shims fit: they pop the same
    // stack args and simply pass an EDX the handlers ignore.
    vtable = .{
        .destroy = @ptrCast(&fastcall.Callback2(1, gdtDestroy).shim),
        .alloc_record = @ptrCast(&fastcall.Callback2(3, allocRecord).shim),
        .release = @ptrCast(&fastcall.Callback2(1, gdtRelease).shim),
        .reset = @ptrCast(&fastcall.Callback2(0, gdtReset).shim),
    };

    field(usize, gdt.vtable).* = @intFromPtr(&vtable);
    field(usize, gdt.arena).* = 0;
    field(usize, gdt.list_head).* = @intFromPtr(&list_sentinel);
    field(u32, gdt.counter).* = 0;
    field(usize, gdt.slots).* = @intFromPtr(&game_tokens);
    field(u32, gdt.mask).* = token_slots - 1;
    InitializeCriticalSection(@ptrCast(&game_data_table[gdt.lock]));
    sayHex("d2host: game-data table built, vtable at ", @intFromPtr(&vtable));
}

const Module = struct { name: [*:0]const u8, handle: ?HMODULE = null };

fn handleOf(name: []const u8) ?HMODULE {
    for (modules) |m| {
        if (std.mem.eql(u8, std.mem.sliceTo(m.name, 0), name)) return m.handle;
    }
    return null;
}

/// Load order matters twice over. Initialisation order — allocator and archives before the data
/// tables that use them, game logic last — is the obvious one.
///
/// The other is base addresses, and 1.10f's own layout is self-conflicting: D2Game
/// `0x6FC30000+0x127000` overruns D2Common's `0x6FD40000` by 92 KB (D2Game grew 160 KB in 1.10), and
/// D2Common in turn overruns D2CMP's `0x6FDF0000` by 16 KB. Whoever loads first keeps its link
/// address; the loser is relocated, so **D2Game and D2Common can never both sit at theirs**.
///
/// This order is the cheapest arrangement, measured: D2Game keeps `0x6FC30000` and only D2Common
/// moves. Loading D2Common first instead costs two relocations (D2CMP *and* D2Game). Either way,
/// resolve everything by ordinal — RVAs hold across relocation, absolute addresses do not.
var modules = [_]Module{
    .{ .name = "Storm.dll" },
    .{ .name = "Fog.dll" },
    .{ .name = "D2Lang.dll" },
    .{ .name = "D2CMP.dll" },
    .{ .name = "D2Common.dll" },
    .{ .name = "D2Net.dll" },
    .{ .name = "D2Game.dll" },
};

pub fn main() !void {
    _ = AllocConsole();
    out_handle = GetStdHandle(@bitCast(@as(i32, -11))); // STD_OUTPUT_HANDLE
    say("d2host: start");

    if (firstArg()) |dir| {
        if (SetCurrentDirectoryA(dir) == 0) {
            sayHex("d2host: SetCurrentDirectory failed, err=", GetLastError());
        } else {
            say("d2host: cwd set");
        }
    }

    for (&modules) |*m| {
        m.handle = LoadLibraryA(m.name);
        if (m.handle == null) {
            say("d2host: FAILED to load a module");
            sayHex("d2host:   err=", GetLastError());
            return error.LoadLibraryFailed;
        }
        sayHex("d2host: loaded, base=", @intFromPtr(m.handle.?));
    }
    say("d2host: all modules loaded");

    const d2game = modules[modules.len - 1].handle.?;
    const d2common = handleOf("D2Common.dll").?;
    const d2lang = handleOf("D2Lang.dll").?;
    const d2net = handleOf("D2Net.dll").?;


    const init_table = byOrdinal(d2game, 10002) orelse {
        say("d2host: D2Game ordinal 10002 (GAME_InitGameDataTable) missing");
        return error.MissingOrdinal;
    };
    const set_callbacks = byOrdinal(d2game, 10023) orelse {
        say("d2host: D2Game ordinal 10023 (GAME_SetServerCallbackFunctions) missing");
        return error.MissingOrdinal;
    };
    sayHex("d2host: GAME_InitGameDataTable=", @intFromPtr(init_table));
    sayHex("d2host: GAME_SetServerCallbackFunctions=", @intFromPtr(set_callbacks));

    callbacks = .{
        .close_game = Stub("pfCloseGame", 2).ptr,
        .leave_game = Stub("pfLeaveGame", 12).ptr,
        .get_database_character = Stub("pfGetDatabaseCharacter", 2).ptr,
        .save_database_character = Stub("pfSaveDatabaseCharacter", 4).ptr,
        .server_log_message = @ptrCast(&serverLogMessage),
        .enter_game = Stub("pfEnterGame", 3).ptr,
        .find_player_token = Stub("pfFindPlayerToken", 5).ptr,
        .save_database_guild = Stub("pfSaveDatabaseGuild", 1).ptr,
        .unlock_database_character = Stub("pfUnlockDatabaseCharacter", 1).ptr,
        .unk_0x24 = Stub("unk0x24", 0).ptr,
        .update_character_ladder = Stub("pfUpdateCharacterLadder", 5).ptr,
        .update_game_information = Stub("pfUpdateGameInformation", 2).ptr,
        .handle_packet = Stub("pfHandlePacket", 0).ptr,
        .set_game_data = Stub("pfSetGameData", 0).ptr,
        .relock_database_character = Stub("pfRelockDatabaseCharacter", 1).ptr,
        .load_complete = @ptrCast(&loadComplete),
    };
    say("d2host: callback table built");

    // Blizzard's own host (`D2Server.dll`, WinMain @0x10009EA0) defines the minimal init, and this
    // follows it. Two of its steps are deliberately absent: `FOG_10139` and `FOG_InitErrorMgr` are
    // Fog's HOST-facing API, and since we ship Fog ourselves there is nothing to initialise — our
    // Fog is ready on load. Likewise `LoadMPQArchives`: archives are our Fog's business, behind its
    // file ordinals. Everything below is the engine-facing part, in Blizzard's order.

    // D2Lang @10000, the string-table init, exactly where D2Server calls it. D2Lang's exports look
    // like nothing but `Unicode::` methods because the export NAME table is alphabetical while the
    // ordinal table is not: 10000-10013 are the NONAME C API and 10014+ are the named C++ ones.
    // It is __fastcall(hArchive, szLanguage, bExpansion), which is why calling it as stdcall faulted.
    // Skipping it leaves sghStringTable null and D2Common's charstats load asserts in strtable.cpp.
    if (byOrdinal(d2lang, 10000)) |p| {
        say("d2host: calling D2Lang @10000 (STRTABLE_Init)");
        const Init = fn (u32, [*:0]const u8, u32) callconv(.c) u32;
        const r = fastcall.fastcallAt(Init).call(@intFromPtr(p), .{ 0, "ENG", 1 });
        sayHex("d2host: D2Lang init returned=", r);
    } else say("d2host: D2Lang @10000 missing");

    // D2Common @10576 DATATBLS_LoadAllTxts(a, lang, flags) — D2Server passes (0, 1, 0).
    if (byOrdinal(d2common, 10576)) |p| {
        say("d2host: calling D2Common @10576 (DATATBLS_LoadAllTxts)");
        @as(*const fn (u32, u32, u32) callconv(.winapi) void, @ptrCast(@alignCast(p)))(0, 1, 0);
        say("d2host: DATATBLS_LoadAllTxts returned");
    } else say("d2host: D2Common @10576 missing");

    configureRealm();

    // Ours, by name: tell the transport where to listen before it binds. Not an ordinal, because
    // it is not part of the D2Net ABI the engine imports.
    if (GetProcAddress(d2net, "D2NET_SetListenPort")) |p| {
        const port = public_port;
        @as(*const fn (u16) callconv(.winapi) void, @ptrCast(@alignCast(p)))(port);
        sayHex("d2host: listen port set to ", port);
    }

    // D2Net: server up, client cap, hack list — the same three D2Server makes.
    if (byOrdinal(d2net, 10003)) |p| {
        say("d2host: calling D2Net @10003 (SERVER_Initialize)");
        _ = @as(*const fn (u32, u32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(0, 0);
    }
    if (byOrdinal(d2net, 10026)) |p| {
        _ = @as(*const fn (u32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(8);
        say("d2host: D2Net SetMaxClientsPerGame(8)");
    }
    if (byOrdinal(d2net, 10023)) |p| {
        _ = @as(*const fn (u32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(1);
        say("d2host: D2Net SetHackListEnabled(1)");
    }

    // D2Game @10046 — the module init, and it must come FIRST. It runs
    // InitializeCriticalSection on the game-list lock; skip it and the first game-list operation
    // blocks forever on an uninitialised section (wine says it plainly:
    // "RtlpWaitForCriticalSection section 6FD45800 blocked by 0000"). It also clears the 0x400-entry
    // game array, initialises the client table, installs D2Game's Fog error handler and fills the
    // item cache.
    if (byOrdinal(d2game, 10046)) |p| {
        const InitModule = *const fn () callconv(.winapi) i32;
        say("d2host: calling D2Game @10046 (GAME_InitServerModule)");
        const r = @as(InitModule, @ptrCast(@alignCast(p)))();
        sayHex("d2host: GAME_InitServerModule returned=", @intCast(r));
    } else {
        say("d2host: ordinal 10046 missing — the game-list lock will never be initialised");
        return error.MissingOrdinal;
    }

    // GAME_SetServerCallbackFunctions(pTable) — stdcall, stores the pointer.
    const SetFn = *const fn (*anyopaque) callconv(.winapi) void;
    const set: SetFn = @ptrCast(@alignCast(set_callbacks));
    say("d2host: calling GAME_SetServerCallbackFunctions");
    set(@ptrCast(&callbacks));
    say("d2host: GAME_SetServerCallbackFunctions returned");
    // GAME_InitGameDataTable(ptGameDataTbl, phGameList) — stdcall, both asserted non-null.
    const InitFn = *const fn (*anyopaque, *anyopaque) callconv(.winapi) void;
    const init: InitFn = @ptrCast(@alignCast(init_table));
    buildGameDataTable();

    say("d2host: calling GAME_InitGameDataTable");
    init(@ptrCast(&game_data_table), @ptrCast(&game_list));
    say("d2host: GAME_InitGameDataTable returned");

    say("d2host: init sequence survived");

    try createGame(d2game);
}

/// Try to stand a game up and tick it. Every call is announced before it happens, so a hard failure
/// names the step instead of just killing the process.
fn createGame(d2game: HMODULE) !void {
    // TASK_InitializeClock @10039 — the game clock the tick functions read.
    if (byOrdinal(d2game, 10039)) |p| {
        const InitClock = *const fn () callconv(.winapi) void;
        say("d2host: calling TASK_InitializeClock");
        @as(InitClock, @ptrCast(@alignCast(p)))();
        say("d2host: TASK_InitializeClock returned");
    } else say("d2host: ordinal 10039 (TASK_InitializeClock) missing");

    // GAME_SetInitSeed @10010 — fixes the world seed so a run is reproducible.
    if (byOrdinal(d2game, 10010)) |p| {
        const SetSeed = *const fn (i32) callconv(.winapi) void;
        say("d2host: calling GAME_SetInitSeed(1)");
        @as(SetSeed, @ptrCast(@alignCast(p)))(1);
        say("d2host: GAME_SetInitSeed returned");
    } else say("d2host: ordinal 10010 (GAME_SetInitSeed) missing");

    // GAME_CreateNewEmptyGame @10047 — stdcall, returns BOOL and writes the game id.
    const create = byOrdinal(d2game, 10047) orelse {
        say("d2host: ordinal 10047 (GAME_CreateNewEmptyGame) missing");
        return error.MissingOrdinal;
    };
    create_game = @ptrCast(@alignCast(create));

    // With a realm, games are made on request and creating one here would be a phantom the realm
    // does not know about. Without one, this is still the quickest proof the engine works.
    var ok: i32 = 1;
    if (!realmConfigured()) {
        var name: [32:0]u8 = @splat(0);
        @memcpy(name[0..5], "spike");
        var game_id: u16 = 0;
        say("d2host: no realm configured — creating one game directly");
        ok = create_game.?(&name, "", "d2host spike", 0, 0, 0, 8, &game_id);
        sayHex("d2host: GAME_CreateNewEmptyGame returned=", @intCast(ok));
        sayHex("d2host:   gameId=", game_id);
        if (ok != 0) live_games += 1;
    } else {
        sayHex("d2host: joined the realm as gsid ", gsid);
    }

    if (byOrdinal(d2game, 10012)) |p| {
        const Count = *const fn () callconv(.c) i32; // fastcall, no args — same as cdecl here
        const n = @as(Count, @ptrCast(@alignCast(p)))();
        sayHex("d2host: GAME_GetGamesCount=", @intCast(n));
    }

    if (ok == 0) {
        say("d2host: game creation refused — data tables are the likely gap");
        return;
    }

    // Tick it a few times: progress the games, pump the network, update clients.
    const progress = byOrdinal(d2game, 10004);
    const netmsgs = byOrdinal(d2game, 10003);
    const clients = byOrdinal(d2game, 10005);
    // Announced per call, not per frame: a tick that never returns is the failure mode here, and
    // only naming the call in flight distinguishes "hung in @10004" from "hung in @10005".
    // Long enough to connect to by hand. The transport polls inside the read path, so a frame is
    // also a network poll — there is no separate accept loop to run.
    say("d2host: ticking");
    var i: usize = 0;
    var last_beat: usize = 0;
    while (realmConfigured() or i < tick_frames) : (i += 1) {
        if (realmConfigured()) {
            pumpRealm();
            // ~5s at 50ms a frame. The record carries a 90s TTL, so missing a few beats under
            // load takes this server out of rotation rather than handing the realm a stale route.
            if (i - last_beat >= 100) {
                last_beat = i;
                _ = store.putHeartbeat(gsid, public_ip, public_port, max_games, live_games, live_games >= max_games, 90);
            }
        }
        if (progress) |p| {
            _ = @as(*const fn (i32) callconv(.winapi) i32, @ptrCast(@alignCast(p)))(0);
        }
        if (netmsgs) |p| {
            @as(*const fn () callconv(.c) void, @ptrCast(@alignCast(p)))();
        }
        if (clients) |p| {
            @as(*const fn (i32, i32) callconv(.winapi) void, @ptrCast(@alignCast(p)))(0, 0);
        }
        Sleep(50);
    }
    say("d2host: tick loop finished");
}
