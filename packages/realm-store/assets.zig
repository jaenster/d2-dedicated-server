//! BNFTP assets — the only thing the realm reads from local disk.
//!
//! These are the files the client downloads for its version check (`ver-IX86-1.mpq` and friends)
//! plus the optional banner ad. They are read-only content shipped in the image, identical on
//! every instance, so a file is exactly the right place for them: there is nothing to keep in
//! sync because nothing ever writes one.
//!
//! Everything else lives in the store — Postgres for the record, Redis for what is in flight.
//! That separation is deliberate: state that differs per instance is the whole class of bug this
//! package stopped having, and the way to keep it gone is to leave no writable disk path here.
const std = @import("std");
const Lock = @import("realm_infra").lock.Lock;

const Dir = std.Io.Dir;

var data_dir: []const u8 = "realmd-data";
var io: std.Io = undefined;
var lock: Lock = .{};

pub fn init(io_: std.Io, dir: []const u8) void {
    io = io_;
    data_dir = dir;
}

/// Reject anything that could escape the bnftp directory. A BNFTP filename comes straight
/// off the wire, so this is the boundary: no separators, no parent references, no empties.
fn bnftpPath(filename: []const u8, out: []u8) ?[]const u8 {
    if (filename.len == 0 or filename.len >= 128) return null;
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return null;
    if (std.mem.indexOfScalar(u8, filename, '\\') != null) return null;
    if (std.mem.indexOf(u8, filename, "..") != null) return null;
    return std.fmt.bufPrint(out, "{s}/bnftp/{s}", .{ data_dir, filename }) catch null;
}

/// Last-modified time of a BNFTP asset, in seconds since the unix epoch. Null when there
/// is no such file — which is what lets SID_GETFILETIME tell the truth about what we have
/// rather than denying everything.
pub fn bnftpMtime(filename: []const u8) ?i64 {
    var pbuf: [320]u8 = undefined;
    const path = bnftpPath(filename, &pbuf) orelse return null;
    lock.lock();
    defer lock.unlock();
    // Stat the OPEN HANDLE rather than the path: this is the same open that getBnftp uses
    // to serve the file, so "we can time it" and "we can serve it" cannot disagree.
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    return @intCast(@divFloor(@as(i128, st.mtime.toNanoseconds()), std.time.ns_per_s));
}

pub fn getBnftp(filename: []const u8, out: []u8) ?[]const u8 {
    var pbuf: [320]u8 = undefined;
    const path = bnftpPath(filename, &pbuf) orelse return null;
    lock.lock();
    defer lock.unlock();
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, out, 0) catch return null;
    return out[0..n];
}
