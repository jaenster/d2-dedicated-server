//! Where a joining character comes from.
//!
//! `CLIENT_LoadCharacterSave` 0x0020a9b6 has two sources and picks between them on one byte,
//! `game+0x6a`:
//!
//!     in {1,2}, or the realm table *0x396220 is set:
//!         bytes = client+0x17c, size = client+0x180      // in memory
//!         size 0 -> 0x0e
//!     otherwise:
//!         sprintf(path, "%s%s.d2s", <save path>, charname); fopen(path, "rb"); fread(buf, 1, 0x2000)
//!         open or read failure -> 0x0e                   // off disk
//!
//! This build has no realm callback table — 0x396220 is never written — and a game the engine makes
//! has `game+0x6a` zero, so left alone it reads a file. That is where the save had to be put, and it
//! is a disk round trip for bytes this process already has: realmd's d2dbs hands them over on the
//! realm's JOINGAME, before the client connects.
//!
//! So the file is skipped. `CLIENT_LoadCharacterAndSendGameData` calls the loader from exactly one
//! place, 0x001a8576, and that call is redirected here: put the bytes in the client, flip
//! `game+0x6a` to the in-memory source for the length of the call, and put it back. Nothing else in
//! the game sees a different byte, and no file is written or read.
//!
//! **The buffer is the engine's, never ours.** `client+0x17c` is allocated by
//! `CLIENT_AccumulateSaveData` 0x001aa5fe from the client's own pool (`client+0x1a8 -> +0x1c`)
//! through `FOG_AllocPoolMem` 0x002f3348, and freed on that same pool by `CLIENT_FreeSaveData`
//! 0x001aa6f0 — which the loader itself calls the moment the load succeeds — and again by
//! `CleanUpClient`. A pointer of ours stored there would be handed to `SMemFree`. So the bytes go in
//! through `CLIENT_AccumulateSaveData`, which allocates and memcpys, and this file never writes
//! either field.
//!
//! `D2GS_CHAR_SOURCE=file` restores the old route — write `<save path><charname>.d2s` and let the
//! engine's own file branch read it — because that one is known good.
//!
//! The d2dbs wire format is the same one `apps/d2gs/realmclient/d2dbs.zig` speaks on Windows; only
//! the socket layer differs, because this host is Linux and that one is winsock.

const std = @import("std");
const macho = @import("macho");

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

const addr = struct {
    /// (char *out, uint32 cap) -> nonzero. The install directory with "Save" appended, and the
    /// directory made if it is not there — the engine's own, so the string this produces is the
    /// string its fopen will be given, separator conventions and all.
    const get_save_path: u32 = 0x002ef76c;
    /// (const char *path, const char *mode) -> FILE *. Translates an HFS-style path and forwards to
    /// fopen; used here rather than fopen directly so the file is written through exactly the
    /// translation the engine will read it back through.
    const open_file: u32 = 0x000363ca;
    /// The one `call CLIENT_LoadCharacterSave` in the image, inside
    /// `CLIENT_LoadCharacterAndSendGameData`. Five bytes, `e8 rel32`.
    const load_call: u32 = 0x001a8576;
    const load_character_save: u32 = 0x0020a9b6;
    /// (client, bytes, len) -> void. Frees whatever the client was holding, allocates `len` off the
    /// client's pool, stores it at client+0x17c/+0x180 and copies the bytes in.
    const accumulate_save: u32 = 0x001aa5fe;
    /// The engine's own no-save flag, the one `-nosave` clears through
    /// `ClientInit_SetNoSaveFlag` 0x00206a7c. `SaveToFile` reads it in the only branch that opens a
    /// file, and nothing else in the image reads or writes it.
    const save_to_file_enabled: u32 = 0x003bb0c4;
};

/// `game+0x6a`, the loader's source selector. 1 and 2 both mean "in memory"; the engine's own games
/// leave it 0, which means "off disk".
const game_save_source: u32 = 0x6a;
const save_source_memory: u8 = 2;

/// What the engine will read on the file path: `fread(buf, 1, 0x2000, f)` at 0x0020ab5b. A save
/// larger than this is one it would truncate, so it is not one worth carrying either way.
const max_save = 0x2000;

/// One save in flight per seat in the game, and the engine admits eight clients (0x001a7a66). Any
/// more would be a character nobody asked for.
const max_pending = 8;
const name_max = 24;

/// d2dbs, as `apps/realmd/d2dbs.zig` serves it.
const TYPE_SAVE: u16 = 0x30;
const TYPE_GET: u16 = 0x31;
const DATATYPE_CHARSAVE: u16 = 0x01;
const HEADER_LEN: usize = 8;

var image: *const macho.load.Loaded = undefined;
var dbs_ip: [4]u8 = .{ 127, 0, 0, 1 };
var dbs_port: u16 = 0;

/// Saves fetched but not yet claimed by a load, one per character name. Written on the gs-link
/// thread as JOINGAMEREQs arrive and read on the engine's own thread when the client finally gets
/// there, so both ends take `lock`; it is held across a memcpy and never across the network.
const Pending = struct {
    name: [name_max]u8 = @splat(0),
    len: usize = 0,
};
var pending: [max_pending]Pending = @splat(.{});
var pending_bytes: [max_pending][max_save]u8 = undefined;
var lock = std.atomic.Value(bool).init(false);

fn acquire() void {
    while (lock.swap(true, .acquire)) _ = usleep(200);
}

fn release() void {
    lock.store(false, .release);
}

/// `realm` is the gs-link address; d2dbs sits one port below it on the same host, which is how
/// `apps/d2gs/d2gs.zig` derives it too. `D2GS_D2DBS=host:port` overrides.
pub fn configure(loaded: *const macho.load.Loaded, realm_ip: [4]u8, realm_port: u16) void {
    image = loaded;
    dbs_ip = realm_ip;
    dbs_port = realm_port - 1;
}

pub fn setAddress(ip: [4]u8, port: u16) void {
    dbs_ip = ip;
    dbs_port = port;
}

/// Redirect the image's one call to `CLIENT_LoadCharacterSave` at this file's thunk. Runs where
/// `gslink.installTokenResolver` runs, and for the same two reasons: __TEXT is still writable, and
/// the relative call it writes only reaches our code while the image is mapped inside 32 bits.
pub fn installLoadHook(loaded: *const macho.load.Loaded) void {
    image = loaded;
    from_file = std.mem.eql(u8, env("D2GS_CHAR_SOURCE", "memory"), "file");
    if (from_file) {
        note("d2gs-native: chardb source=file\n", .{});
        return;
    }
    note("d2gs-native: chardb source=memory\n", .{});
    const site = loaded.at(addr.load_call);
    const rel: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(&loadCharacterSave))) -%
        @as(u32, @truncate(site + 5)));
    const at: [*]u8 = @ptrFromInt(site);
    at[0] = 0xe8;
    std.mem.writeInt(i32, at[1..5], rel, .little);

    // And stop the other half of the round trip. `SaveToFile` runs on a timer out of
    // `ServerGameLoop` and writes `<save path><charname>.d2s` every time, and with the load coming
    // from the realm nothing ever reads that file again: it is not what the next join is seated
    // from and it is not what the realm keeps. Clearing the flag is the engine's own `-nosave`, and
    // the save returns success without opening anything. Only `ClientInit_SetNoSaveFlag` writes
    // this word and it only ever writes 0, so a value put here before the initializers stays.
    const enabled: *u32 = @ptrFromInt(loaded.at(addr.save_to_file_enabled));
    enabled.* = 0;
}

/// Standing in for `CLIENT_LoadCharacterSave`, whose arguments these are — `game` and `client` are
/// live pointers, not image offsets, and everything past the character name is passed through
/// untouched.
///
/// The source byte is put back before returning because it is the game's, not this call's. Left at
/// 2 it would also make `SendSaveFileToClient` 0x001ad4fc push a 0xB3 save-file packet at every
/// client walking out, which is how an open TCP/IP game hands a character back to the machine that
/// supplied it — not how a realm keeps one, and not something a client joining a realm expects.
fn loadCharacterSave(
    game: u32,
    client: u32,
    charname: u32,
    load_existing: u32,
    out_unit: u32,
    a6: u32,
    a7: u32,
    a8: u32,
) callconv(.c) u32 {
    const source: *u8 = @ptrFromInt(game + game_save_source);
    const was = source.*;
    const handed = if (charname != 0) hand(client, std.mem.span(@as([*:0]const u8, @ptrFromInt(charname)))) else false;
    if (handed) source.* = save_source_memory;

    const Load = fn (u32, u32, u32, u32, u32, u32, u32, u32) callconv(.c) u32;
    const load: *const Load = @ptrFromInt(image.at(addr.load_character_save));
    const rc = load(game, client, charname, load_existing, out_unit, a6, a7, a8);

    if (handed) source.* = was;
    return rc;
}

/// Give the client the save fetched for `charname`, if one is waiting. The engine allocates and
/// copies, so the slot is free again the moment it returns.
fn hand(client: u32, charname: []const u8) bool {
    acquire();
    defer release();
    for (&pending, 0..) |*p, i| {
        if (p.len == 0 or !eqlIgnoreCase(cstr(&p.name), charname)) continue;
        const Accumulate = fn (u32, [*]const u8, u32) callconv(.c) void;
        const accumulate: *const Accumulate = @ptrFromInt(image.at(addr.accumulate_save));
        accumulate(client, &pending_bytes[i], @intCast(p.len));
        note("d2gs-native: chardb seated {s} ({d} bytes) in memory\n", .{ charname, p.len });
        p.len = 0;
        return true;
    }
    return false;
}

/// Have the save for a character the realm is sending ready before that client arrives. Returns
/// false if the realm has no such character, which is the answer that keeps the join from being
/// accepted and then failing with reason 0x0e.
pub fn place(account: []const u8, charname: []const u8) bool {
    if (charname.len >= name_max) {
        note("d2gs-native: chardb name too long: \"{s}\"\n", .{charname});
        return false;
    }
    var save: [max_save]u8 = undefined;
    const n = fetch(account, charname, &save);
    if (n == 0) {
        note("d2gs-native: chardb no save for {s}/{s}\n", .{ account, charname });
        if (from_file) clearFile(charname);
        return false;
    }
    return if (from_file) writeFile(charname, save[0..n]) else keep(charname, save[0..n]);
}

/// Park the bytes under the character's name, replacing anything left over from an earlier join by
/// the same character — that one is a save the engine never came for, and a stale one.
fn keep(charname: []const u8, save: []const u8) bool {
    acquire();
    defer release();
    var free: ?usize = null;
    for (&pending, 0..) |*p, i| {
        if (p.len != 0 and eqlIgnoreCase(cstr(&p.name), charname)) {
            fill(i, charname, save);
            return true;
        }
        if (p.len == 0 and free == null) free = i;
    }
    const i = free orelse {
        note("d2gs-native: chardb no free slot for {s}\n", .{charname});
        return false;
    };
    fill(i, charname, save);
    return true;
}

fn fill(i: usize, charname: []const u8, save: []const u8) void {
    @memset(&pending[i].name, 0);
    @memcpy(pending[i].name[0..charname.len], charname);
    @memcpy(pending_bytes[i][0..save.len], save);
    pending[i].len = save.len;
}

// ── the file route, kept because it is the one that is known to work ──────────

/// Whether to write `<save path><charname>.d2s` and let the engine read it back, rather than hand
/// the bytes over in memory. `D2GS_CHAR_SOURCE=file`.
var from_file = false;

fn writeFile(charname: []const u8, save: []const u8) bool {
    var path: [1024]u8 = undefined;
    const p = savePathFor(charname, &path) orelse {
        note("d2gs-native: chardb no save path for \"{s}\"\n", .{charname});
        return false;
    };
    const open: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque =
        @ptrFromInt(image.at(addr.open_file));
    const f = open(p.ptr, "wb") orelse {
        note("d2gs-native: chardb cannot write {s}\n", .{p});
        return false;
    };
    const wrote = fwrite(save.ptr, 1, save.len, f);
    _ = fclose(f);
    if (wrote != save.len) {
        note("d2gs-native: chardb short write for {s}\n", .{p});
        return false;
    }
    note("d2gs-native: chardb seated {s} ({d} bytes) at {s}\n", .{ charname, save.len, p });
    return true;
}

/// A character the realm no longer has must not be seated from a file left by an earlier join.
fn clearFile(charname: []const u8) void {
    var path: [1024]u8 = undefined;
    if (savePathFor(charname, &path)) |p| _ = unlink(p.ptr);
}

/// The engine's `sprintf(buf, "%s%s.d2s", <save path>, charname)`, built the same way so both ends
/// name the same file.
fn savePathFor(charname: []const u8, out: []u8) ?[:0]u8 {
    var dir: [1024]u8 = undefined;
    const get: *const fn ([*]u8, u32) callconv(.c) c_int = @ptrFromInt(image.at(addr.get_save_path));
    if (get(&dir, @intCast(dir.len)) == 0) return null;
    const d = std.mem.span(@as([*:0]const u8, @ptrCast(&dir)));
    return std.fmt.bufPrintZ(out, "{s}{s}.d2s", .{ d, charname }) catch null;
}

// ── d2dbs ────────────────────────────────────────────────────────────────────

/// GET_DATA_REQUEST -> GET_DATA_REPLY, one connection per fetch. Returns the bytes written to
/// `out`, or 0.
fn fetch(account: []const u8, charname: []const u8, out: []u8) usize {
    if (dbs_port == 0) return 0;
    const s = dial() orelse return 0;
    defer _ = close(s);

    var req: [320]u8 = undefined;
    var n: usize = HEADER_LEN;
    if (n + 2 + account.len + 1 + charname.len + 1 > req.len) return 0;
    std.mem.writeInt(u16, req[n..][0..2], DATATYPE_CHARSAVE, .little);
    n += 2;
    n += putCStr(req[n..], account);
    n += putCStr(req[n..], charname);
    std.mem.writeInt(u16, req[0..2], @intCast(n), .little);
    std.mem.writeInt(u16, req[2..4], TYPE_GET, .little);
    std.mem.writeInt(u32, req[4..8], 1, .little);
    if (!sendAll(s, req[0..n])) return 0;

    var head: [HEADER_LEN]u8 = undefined;
    if (!recvAll(s, &head)) return 0;
    const size = std.mem.readInt(u16, head[0..2], .little);
    if (std.mem.readInt(u16, head[2..4], .little) != TYPE_GET or size < HEADER_LEN) return 0;

    var body: [9000]u8 = undefined;
    const blen: usize = size - HEADER_LEN;
    if (blen > body.len) return 0;
    if (blen > 0 and !recvAll(s, body[0..blen])) return 0;

    // result(4) createtime(4) allowladder(4) datatype(2) datalen(2) charname\0 <bytes>
    if (blen < 16) return 0;
    if (std.mem.readInt(u32, body[0..4], .little) != 0) return 0;
    const datalen = std.mem.readInt(u16, body[14..16], .little);
    var off: usize = 16;
    while (off < blen and body[off] != 0) : (off += 1) {}
    off = @min(off + 1, blen);
    const take = @min(@min(@as(usize, datalen), blen - off), out.len);
    @memcpy(out[0..take], body[off..][0..take]);
    return take;
}

fn dial() ?c_int {
    const s = socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (s < 0) return null;
    const sa = std.posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, dbs_port),
        .addr = @bitCast(dbs_ip),
    };
    if (connect(s, &sa, @sizeOf(std.posix.sockaddr.in)) != 0) {
        _ = close(s);
        return null;
    }
    return s;
}

fn putCStr(dst: []u8, s: []const u8) usize {
    @memcpy(dst[0..s.len], s);
    dst[s.len] = 0;
    return s.len + 1;
}

fn sendAll(s: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(s, bytes.ptr + off, bytes.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn recvAll(s: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(s, buf.ptr + off, buf.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn cstr(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

/// The realm's spelling of a character name and the engine's need not agree on case — the file
/// route never had to care, because the filesystem underneath it does not either.
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn env(name: [*:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(name) orelse return default;
    const s = std.mem.span(v);
    return if (s.len == 0) default else s;
}

fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [1280]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

test "a GET_DATA reply is read past its variable-length name field" {
    // The bytes realmd writes for a two-byte save belonging to "Hero": header, result, createtime,
    // allowladder, datatype, datalen, name, data.
    var body: [23]u8 = undefined;
    @memset(&body, 0);
    std.mem.writeInt(u16, body[12..14], DATATYPE_CHARSAVE, .little);
    std.mem.writeInt(u16, body[14..16], 2, .little);
    @memcpy(body[16..21], "Hero\x00");
    body[21] = 0xaa;
    body[22] = 0xbb;

    var off: usize = 16;
    while (off < body.len and body[off] != 0) : (off += 1) {}
    off = @min(off + 1, body.len);
    try std.testing.expectEqual(@as(usize, 21), off);
    try std.testing.expectEqual(@as(u8, 0xaa), body[off]);
}

test "a second join by the same character replaces its save rather than taking another slot" {
    defer pending = @splat(.{});
    try std.testing.expect(keep("Hero", &.{ 1, 2, 3 }));
    try std.testing.expect(keep("Other", &.{4}));
    // Same character, different bytes, and the realm spells it differently this time.
    try std.testing.expect(keep("hero", &.{ 9, 9 }));

    try std.testing.expectEqualStrings("Hero", cstr(&pending[0].name));
    try std.testing.expectEqual(@as(usize, 2), pending[0].len);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9 }, pending_bytes[0][0..2]);
    try std.testing.expectEqualStrings("Other", cstr(&pending[1].name));
    for (pending[2..]) |p| try std.testing.expectEqual(@as(usize, 0), p.len);
}

test "the table holds one save per seat and refuses the ninth" {
    defer pending = @splat(.{});
    var name: [2]u8 = .{ 'a', 'a' };
    for (0..max_pending) |i| {
        name[1] = @intCast('a' + i);
        try std.testing.expect(keep(&name, &.{0}));
    }
    try std.testing.expect(!keep("zz", &.{0}));
}
