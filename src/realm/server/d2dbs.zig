//! D2DBS — character database server (port 6114). Loads/stores character saves
//! for the game server. Both ends of this link are ours: the injected GS uses
//! src/realm/d2dbs.zig as the client, so realmd matches that exact wire format.
//!
//! Framing: 8-byte LE header `{ size:u16, type:u16, seqno:u32 }`, size = total
//! incl. header (same as the d2cs<->d2gs control link).
//!   GET_DATA 0x31 req:  datatype:u16, account\0, char\0
//!   GET_DATA 0x31 reply: result:u32, createtime:u32, allowladder:u32,
//!                        datatype:u16, datalen:u16, char\0, <save bytes>
//!   SAVE_DATA 0x30 req:  datatype:u16, account\0, char\0, datalen:u16, <bytes>
//!   SAVE_DATA 0x30 reply: result:u32
const std = @import("std");
const net = @import("realm_infra").net;
const log = @import("realm_infra").log;
const proto = @import("proto.zig");
const store = @import("store.zig");

const TYPE_SAVE = 0x30;
const TYPE_GET = 0x31;
const DATATYPE_CHARSAVE = 0x01;

pub fn handle(fd: net.Socket, tag: []const u8) void {
    log.line(tag, "client connected", .{});
    while (true) {
        var hbuf: [8]u8 = undefined;
        if (!net.readFull(fd, &hbuf)) break;
        const size = std.mem.readInt(u16, hbuf[0..2], .little);
        const typ = std.mem.readInt(u16, hbuf[2..4], .little);
        const seq = std.mem.readInt(u32, hbuf[4..8], .little);
        if (size < 8) {
            log.line(tag, "bad header size {d}", .{size});
            break;
        }
        var body: [9000]u8 = undefined;
        const blen: usize = size - 8;
        if (blen > body.len) {
            log.line(tag, "oversized packet {d}", .{size});
            break;
        }
        if (blen > 0 and !net.readFull(fd, body[0..blen])) break;
        switch (typ) {
            TYPE_GET => onGet(fd, tag, seq, body[0..blen]),
            TYPE_SAVE => onSave(fd, tag, seq, body[0..blen]),
            else => log.line(tag, "unhandled d2dbs type 0x{x:0>2}", .{typ}),
        }
    }
    log.line(tag, "client disconnected", .{});
}

fn onGet(fd: net.Socket, tag: []const u8, seq: u32, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU16(); // datatype
    const account = r.getStr();
    const charname = r.getStr();

    var save: [8192]u8 = undefined;
    const n = store.getCharD2s(account, charname, &save);
    log.line(tag, "GET {s}/{s} -> {d} bytes", .{ account, charname, n });

    var out: [9000]u8 = undefined;
    var w = proto.Writer.init(&out);
    w.putU16(0); // size placeholder
    w.putU16(TYPE_GET);
    w.putU32(seq);
    w.putU32(if (n > 0) @as(u32, 0) else 1); // result: 0 ok, 1 not found
    w.putU32(0); // createtime
    w.putU32(0); // allowladder
    w.putU16(DATATYPE_CHARSAVE);
    w.putU16(@intCast(n)); // datalen
    w.putStr(charname);
    if (n > 0) w.putBytes(save[0..n]);
    w.patchU16(0, @intCast(w.pos));
    _ = net.writeAll(fd, w.slice());
}

fn onSave(fd: net.Socket, tag: []const u8, seq: u32, body: []const u8) void {
    var r = proto.Reader.init(body);
    _ = r.getU16(); // datatype
    const account = r.getStr();
    const charname = r.getStr();
    const datalen = r.getU16();
    const avail = r.remaining();
    const take = @min(datalen, avail);
    const data = body[r.pos..][0..take];

    const ok = store.saveCharD2s(account, charname, data);
    log.line(tag, "SAVE {s}/{s} {d} bytes -> {s}", .{ account, charname, take, if (ok) "ok" else "FAIL" });

    var out: [16]u8 = undefined;
    var w = proto.Writer.init(&out);
    w.putU16(0); // size placeholder
    w.putU16(TYPE_SAVE);
    w.putU32(seq);
    w.putU32(if (ok) @as(u32, 0) else 1);
    w.patchU16(0, @intCast(w.pos));
    _ = net.writeAll(fd, w.slice());
}
