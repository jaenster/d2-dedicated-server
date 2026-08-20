//! Retarget a classic-era module's Fog imports onto the LoD numbering.
//!
//! Fog renumbered once, at the LoD boundary, and we implement the LoD numbering. A classic build's
//! D2Game/D2Common therefore import Fog ordinals that mean something else to us — sometimes a
//! *different function of the same number*, which is the failure this exists to prevent. An ordinal
//! import is a bare `0x80000000 | n` in the thunk arrays, so retargeting one is a u32 write.
//!
//! It writes a copy rather than editing in place, and the copy keeps the original filename: the
//! modules import each other by name, so renaming one would send its siblings to the unpatched
//! original.
//!
//! Every ordinal must have a row. A missing one is refused rather than passed through — passing it
//! through is precisely the silent wrong call, and nothing downstream can catch it.

const std = @import("std");
const rosetta = @import("d2engine").fogrosetta;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

fn readFile(gpa: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = open(path, @bitCast(std.posix.O{ .ACCMODE = .RDONLY }));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(gpa);
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const flags: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    const fd = open(path, flags, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var sent: usize = 0;
    while (sent < data.len) {
        const n = write(fd, data.ptr + sent, data.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

const Pe = struct {
    bytes: []u8,
    opt: usize,
    sections: []const Section,

    const Section = struct { va: u32, vsize: u32, raw: u32, rsize: u32 };

    fn parse(alloc: std.mem.Allocator, bytes: []u8) !Pe {
        if (bytes.len < 0x40) return error.NotPe;
        const pe = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
        if (pe + 24 > bytes.len or !std.mem.eql(u8, bytes[pe .. pe + 4], "PE\x00\x00")) return error.NotPe;
        const opt = pe + 24;
        const nsec = std.mem.readInt(u16, bytes[pe + 6 ..][0..2], .little);
        const opt_size = std.mem.readInt(u16, bytes[pe + 20 ..][0..2], .little);
        const table = opt + opt_size;
        var secs = try alloc.alloc(Section, nsec);
        for (0..nsec) |i| {
            const o = table + i * 40;
            secs[i] = .{
                .vsize = std.mem.readInt(u32, bytes[o + 8 ..][0..4], .little),
                .va = std.mem.readInt(u32, bytes[o + 12 ..][0..4], .little),
                .rsize = std.mem.readInt(u32, bytes[o + 16 ..][0..4], .little),
                .raw = std.mem.readInt(u32, bytes[o + 20 ..][0..4], .little),
            };
        }
        return .{ .bytes = bytes, .opt = opt, .sections = secs };
    }

    fn fileOff(self: Pe, rva: u32) ?usize {
        for (self.sections) |s| {
            const span = @max(s.vsize, s.rsize);
            if (rva >= s.va and rva < s.va + span) return s.raw + (rva - s.va);
        }
        return null;
    }

    /// Data directory 1 is the import table.
    fn importRva(self: Pe) u32 {
        return std.mem.readInt(u32, self.bytes[self.opt + 96 + 8 ..][0..4], .little);
    }
};

const Report = struct { rewritten: usize = 0, already: usize = 0 };

fn rewrite(pe: Pe, accept_inferred: bool) !Report {
    var report: Report = .{};
    const dir = pe.fileOff(pe.importRva()) orelse return error.NoImportTable;
    var i: usize = 0;
    while (true) : (i += 1) {
        const d = dir + i * 20;
        const ilt = std.mem.readInt(u32, pe.bytes[d..][0..4], .little);
        const name_rva = std.mem.readInt(u32, pe.bytes[d + 12 ..][0..4], .little);
        const iat = std.mem.readInt(u32, pe.bytes[d + 16 ..][0..4], .little);
        if (ilt == 0 and name_rva == 0 and iat == 0) break;

        const name_off = pe.fileOff(name_rva) orelse continue;
        const name = std.mem.sliceTo(pe.bytes[name_off..], 0);
        if (!std.ascii.startsWithIgnoreCase(name, "fog")) continue;

        // Both thunk arrays carry the ordinal, and the loader may read either.
        for ([_]u32{ ilt, iat }) |table_rva| {
            if (table_rva == 0) continue;
            const base = pe.fileOff(table_rva) orelse continue;
            var k: usize = 0;
            while (true) : (k += 1) {
                const at = base + k * 4;
                const v = std.mem.readInt(u32, pe.bytes[at..][0..4], .little);
                if (v == 0) break;
                // Imports by name need no rosetta: a name means the same thing on both sides of
                // the renumbering. D2CMP takes `gdwBitMasks` from Fog that way, and our Fog
                // exports it under exactly that name.
                if (v & 0x80000000 == 0) continue;
                const classic: u16 = @truncate(v & 0xffff);
                const lod = rosetta.lodFor(classic, accept_inferred) orelse {
                    std.debug.print("  REFUSED @{d}: no row good enough to act on\n", .{classic});
                    return error.UnmappedOrdinal;
                };
                if (lod == classic) {
                    report.already += 1;
                } else {
                    std.mem.writeInt(u32, pe.bytes[at..][0..4], 0x80000000 | @as(u32, lod), .little);
                    report.rewritten += 1;
                }
            }
        }
    }
    return report;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 3) {
        std.debug.print(
            \\usage: fogrewrite <in.dll> <out.dll> [--accept-inferred]
            \\
            \\Retarget a classic-era module's Fog import ordinals onto the LoD numbering this
            \\project implements. Write the output under its ORIGINAL filename: the modules import
            \\each other by name, so a renamed one sends its siblings to the unpatched original.
            \\
            \\Without --accept-inferred an ordinal whose row rests only on the structural
            \\constraints is refused rather than rewritten.
            \\
        , .{});
        return error.Usage;
    }
    var accept_inferred = false;
    for (args[3..]) |a| {
        if (std.mem.eql(u8, a, "--accept-inferred")) accept_inferred = true;
    }

    const bytes = try readFile(alloc, args[1]);
    const pe = try Pe.parse(alloc, bytes);
    const r = rewrite(pe, accept_inferred) catch |e| switch (e) {
        error.NoImportTable => Report{},
        else => return e,
    };
    try writeFile(args[2], bytes);
    std.debug.print("{s}: {d} Fog ordinals retargeted, {d} already correct -> {s}\n", .{
        args[1], r.rewritten, r.already, args[2],
    });
}
