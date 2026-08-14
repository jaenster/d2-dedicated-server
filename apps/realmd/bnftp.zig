//! BNFTP — Battle.net File Transfer (protocol selector 0x02 on the bnetd port).
//!
//! After SID_AUTH_INFO names a version-check MPQ, the client opens a SECOND
//! connection with protocol byte 0x02 and BNFTP-requests that file. The MPQ
//! carries the CheckRevision module the client runs to produce its version
//! checksum; since we accept any SID_AUTH_CHECK, the value is irrelevant — we
//! just have to deliver the file correctly. (Also used for ads/news/MOTD files.)
//!
//! The wire format lives in libd2's d2-bnet, shared with the clientless fetcher and the probe
//! that points at real Battle.net, so all three read and write one definition of it. What is
//! here is the SERVING: which file, from where, and how much of it.
//!
//! Files are served from <data_dir>/bnftp/<filename>.
const std = @import("std");
const bnftp = @import("libd2").bnet.bnftp;
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
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
    const reqlen = bnftp.Request.declaredLen(req[0..len]) catch return;
    if (reqlen < bnftp.Request.min_len or reqlen > req.len) {
        log.line(tag, "BNFTP bad request length {d}", .{reqlen});
        return;
    }
    while (len < reqlen) {
        const n = net.readSome(fd, req[len..]);
        if (n == 0) return;
        len += n;
    }

    const request = bnftp.Request.decode(req[0..reqlen]) catch |e| {
        log.line(tag, "BNFTP malformed request: {s}", .{@errorName(e)});
        return;
    };
    const fname = request.filename;
    const start_pos = request.start_pos;
    log.line(tag, "BNFTP request file='{s}' startPos={d} protoVer=0x{x}", .{ fname, start_pos, request.protocol_ver });

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

    var hbuf: [256]u8 = undefined;
    const header = (bnftp.ReplyHeader{
        .header_len = 0, // encode counts itself
        .file_size = total,
        .banner_id = request.banner_id,
        .banner_ext = request.banner_ext,
        .filename = fname,
    }).encode(&hbuf) catch return;
    if (!net.writeAll(fd, header)) return;
    if (data.len > 0) _ = net.writeAll(fd, data);
}
