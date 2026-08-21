//! Does our `Fog.dll` export everything the engines actually ask for?
//!
//! Our Fog replaces Blizzard's, so an ordinal an engine imports and we do not export is not a
//! degraded feature — wine ABORTS the process the first time it is called. It presents as the
//! server going silent at 0% CPU, with nothing in any log, which is how Fog `@10265` cost a day:
//! 1.10f's Fog ends at ordinal 10264 and 1.13c quietly added three more.
//!
//! `required-ordinals.txt` is the engines' own import tables, read out of the real DLLs by
//! `tools/fog-required-ordinals.sh` and committed. Checking against the file rather than the DLLs
//! is the point: it runs on a machine with no game files, so the check happens on every build
//! instead of only where someone has a game installed.
//!
//! Three things are asserted, and the last two are what keep the first honest:
//!
//!   1. every ordinal an engine imports is exported;
//!   2. every ordinal exported only as a reporting stub is still imported by someone — an entry
//!      nothing needs gets deleted, which is what "we implemented it" looks like;
//!   3. every stub in that list is really in the `.def`, so it can be reached at all.

const std = @import("std");
const unimplemented = @import("unimplemented.zig");

const required = @embedFile("required-ordinals.txt");
const def = @embedFile("fog.def");

/// Every ordinal `fog.def` exports. The `.def` is the ABI — the Zig names beside them are ours and
/// mean nothing to the engine, which imports by number.
fn exported(out: *std.ArrayList(u32), gpa: std.mem.Allocator) !void {
    var lines = std.mem.splitScalar(u8, def, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), ";")) continue;
        const at = std.mem.indexOfScalar(u8, line, '@') orelse continue;
        var end = at + 1;
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        if (end == at + 1) continue;
        try out.append(gpa, std.fmt.parseInt(u32, line[at + 1 .. end], 10) catch continue);
    }
}

test "our Fog exports every ordinal the engines import" {
    const gpa = std.testing.allocator;
    var have: std.ArrayList(u32) = .empty;
    defer have.deinit(gpa);
    try exported(&have, gpa);
    // The manifest proves nothing if the .def failed to parse and came back empty.
    try std.testing.expect(have.items.len > 40);

    var missing: std.ArrayList(u8) = .empty;
    defer missing.deinit(gpa);
    var stub_is_needed = [_]bool{false} ** unimplemented.ordinals.len;

    var lines = std.mem.splitScalar(u8, required, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const version = it.next() orelse continue;
        const dll = it.next() orelse continue;
        while (it.next()) |tok| {
            const ord = std.fmt.parseInt(u32, tok, 10) catch continue;
            for (unimplemented.ordinals, 0..) |u, i| {
                if (u == ord) stub_is_needed[i] = true;
            }
            if (std.mem.indexOfScalar(u32, have.items, ord) != null) continue;
            try missing.print(gpa, "\n  {s} {s} imports @{d}, which fog.def does not export", .{ version, dll, ord });
        }
    }

    if (missing.items.len != 0) {
        std.debug.print(
            "\nfog.def is missing an ordinal an engine calls. Wine ABORTS on one of these and the" ++
                " abort names nothing — implement it, or list it in unimplemented.zig so that it at" ++
                " least reports itself:{s}\n",
            .{missing.items},
        );
        return error.FogOrdinalMissing;
    }

    for (stub_is_needed, unimplemented.ordinals) |needed, ord| {
        if (needed) continue;
        std.debug.print(
            "\nunimplemented.zig lists @{d} but no engine imports it any more — delete the row.\n",
            .{ord},
        );
        return error.StaleUnimplementedOrdinal;
    }
}

test "every unimplemented ordinal is actually exported, or its stub is unreachable" {
    const gpa = std.testing.allocator;
    var have: std.ArrayList(u32) = .empty;
    defer have.deinit(gpa);
    try exported(&have, gpa);
    for (unimplemented.ordinals) |ord| {
        if (std.mem.indexOfScalar(u32, have.items, ord) == null) {
            std.debug.print("\n@{d} is listed in unimplemented.zig but missing from fog.def\n", .{ord});
            return error.StubNotExported;
        }
    }
}
