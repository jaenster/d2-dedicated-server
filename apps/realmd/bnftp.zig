//! BNFTP — Battle.net File Transfer (protocol selector 0x02 on the bnetd port).
//!
//! After SID_AUTH_INFO names a version-check MPQ, the client opens a SECOND
//! connection with protocol byte 0x02 and BNFTP-requests that file. The MPQ
//! carries the CheckRevision module the client runs to produce its version
//! checksum; since we accept any SID_AUTH_CHECK, the value is irrelevant — we
//! just have to deliver the file correctly. (Also used for ads/news/MOTD files.)
//!
//! BNFTP v1 (protocol version 0x0100). Request (after the 0x02 byte):
//!   u16 reqLen, u16 protocolVer, u32 platform, u32 product, u32 bannerId,
//!   u32 bannerExt, u32 startPos, u64 fileTime, cstr filename
//! Reply:
//!   u16 headerLen, u32 fileSize, u32 bannerId, u32 bannerExt, u64 fileTime,
//!   cstr filename, <file bytes from startPos>
//!
//! Files are served from <data_dir>/bnftp/<filename>.
const std = @import("std");
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const proto = @import("proto.zig");
const store = @import("store.zig");

const max_file = 1 << 20; // 1 MiB — version MPQs are tiny; ads small

/// `initial` is whatever was already read after the 0x02 protocol byte.
pub fn handle(fd: net.Socket, tag: []const u8, initial: []const u8) void {
    var req: [2048]u8 = undefined;
    var len: usize = @min(initial.len, req.len);
    @memcpy(req[0..len], initial[0..len]);

    // The first u16 is the request length; read until we have the whole header.
    while (len < 2) {
        const n = net.readSome(fd, req[len..]);
        if (n == 0) return;
        len += n;
    }
    const reqlen = std.mem.readInt(u16, req[0..2], .little);
    if (reqlen < 33 or reqlen > req.len) {
        log.line(tag, "BNFTP bad request length {d}", .{reqlen});
        return;
    }
    while (len < reqlen) {
        const n = net.readSome(fd, req[len..]);
        if (n == 0) return;
        len += n;
    }

    var r = proto.Reader.init(req[0..reqlen]);
    _ = r.getU16(); // request length
    const protover = r.getU16();
    _ = r.getU32(); // platform
    _ = r.getU32(); // product
    const banner_id = r.getU32();
    const banner_ext = r.getU32();
    const start_pos = r.getU32();
    _ = r.getU64(); // local file time
    const fname = r.getStr();
    log.line(tag, "BNFTP request file='{s}' startPos={d} protoVer=0x{x}", .{ fname, start_pos, protover });

    // Load the requested file from <data_dir>/bnftp/.
    var fbuf: [max_file]u8 = undefined;
    const file = store.getBnftp(fname, &fbuf) orelse &[_]u8{};
    const total: u32 = @intCast(file.len);
    const from: u32 = @min(start_pos, total);
    const data = file[from..];
    if (total == 0) {
        log.line(tag, "BNFTP '{s}' NOT FOUND (replying size 0) — drop the file in <data_dir>/bnftp/", .{fname});
    } else {
        log.line(tag, "BNFTP serving '{s}' ({d} bytes, from offset {d})", .{ fname, total, from });
    }

    // Reply header. The client reads the FIRST 4 BYTES as the header length (a
    // u32) and HALTS if it is > 0xff (BnetDownloadFile_II @0x51f310, line 0x2ee),
    // so the length field is u32, not u16. Then: fileSize@4, fileTime@0x10,
    // filename@0x18 (BNDOWNLOAD_GetCachedFileSize reads those offsets).
    var hbuf: [256]u8 = undefined;
    var w = proto.Writer.init(&hbuf);
    w.putU32(0); // [0x00] header length placeholder (u32, <= 0xff)
    w.putU32(total); // [0x04] total file size
    w.putU32(banner_id); // [0x08]
    w.putU32(banner_ext); // [0x0C]
    w.putU64(0); // [0x10] file time
    w.putStr(fname); // [0x18] filename
    w.patchU32(0, @intCast(w.pos));
    if (!net.writeAll(fd, w.slice())) return;
    if (data.len > 0) _ = net.writeAll(fd, data);
}
