//! Where a joining character comes from.
//!
//! On Windows the engine asks the realm for a character through the callback table
//! (`fpGetDatabaseCharacter`) and is handed the save bytes in memory. This build has no such table
//! — `DAT_005c8a50` is never written — so `CLIENT_LoadCharacterAndSendGameData` takes its other
//! branch, the one that reads the character off disk:
//!
//!     GetAndCreateSavePath(dir, 0x400);
//!     sprintf(path, "%s%s.d2s", dir, charname);
//!     f = fopen(path, "rb");            // 0x0020ab10
//!     if (!f || fread(...) == 0) return 0x0e;
//!
//! 0x0e is the reason code a client is kicked with when there is no such file, which is every
//! character on a server that keeps its saves in a realm rather than on its own disk. So the file
//! is what has to exist: realmd's d2dbs already holds the bytes, and the realm's own JOINGAME tells
//! this server which character is on its way and whose account it is, before that client connects.
//! Fetch it then, write it where the branch above looks, and the engine seats it unaided.
//!
//! The same wire format `apps/d2gs/realmclient/d2dbs.zig` speaks on Windows; only the socket layer
//! differs, because this host is Linux and that one is winsock.

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

const addr = struct {
    /// (char *out, uint32 cap) -> nonzero. The install directory with "Save" appended, and the
    /// directory made if it is not there — the engine's own, so the string this produces is the
    /// string its fopen will be given, separator conventions and all.
    const get_save_path: u32 = 0x002ef76c;
    /// (const char *path, const char *mode) -> FILE *. Translates an HFS-style path and forwards to
    /// fopen; used here rather than fopen directly so the file is written through exactly the
    /// translation the engine will read it back through.
    const open_file: u32 = 0x000363ca;
};

/// What the engine will read: `fread(buf, 1, 0x2000, f)` at 0x0020ab5b. A save larger than this is
/// one it would truncate, so it is not one worth writing.
const max_save = 0x2000;

/// d2dbs, as `apps/realmd/d2dbs.zig` serves it.
const TYPE_SAVE: u16 = 0x30;
const TYPE_GET: u16 = 0x31;
const DATATYPE_CHARSAVE: u16 = 0x01;
const HEADER_LEN: usize = 8;

var image: *const macho.load.Loaded = undefined;
var dbs_ip: [4]u8 = .{ 127, 0, 0, 1 };
var dbs_port: u16 = 0;

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

/// Put `<save path><charname>.d2s` where the engine's file branch will find it. Returns false if
/// the realm has no such character or the file could not be written — and removes any older file of
/// that name rather than letting the engine seat a stale one.
pub fn place(account: []const u8, charname: []const u8) bool {
    var path: [1024]u8 = undefined;
    const p = savePathFor(charname, &path) orelse {
        note("d2gs-native: chardb no save path for \"{s}\"\n", .{charname});
        return false;
    };

    var save: [max_save]u8 = undefined;
    const n = fetch(account, charname, &save);
    if (n == 0) {
        _ = unlink(p.ptr);
        note("d2gs-native: chardb no save for {s}/{s}\n", .{ account, charname });
        return false;
    }

    const open: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque =
        @ptrFromInt(image.at(addr.open_file));
    const f = open(p.ptr, "wb") orelse {
        note("d2gs-native: chardb cannot write {s}\n", .{p});
        return false;
    };
    const wrote = fwrite(&save, 1, n, f);
    _ = fclose(f);
    if (wrote != n) {
        note("d2gs-native: chardb short write for {s}\n", .{p});
        return false;
    }
    note("d2gs-native: chardb seated {s} ({d} bytes) at {s}\n", .{ charname, n, p });
    return true;
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
