//! The engines we claim to serve, and whether every per-era fact each one needs was ever measured.
//!
//! `deploy/e2e-engines.txt` is where the claim gets made: a row marked `world` says a real client
//! reaches a real world on that build. This file reads that claim at COMPILE TIME and checks it
//! against the tables the claim rests on, so adding a row is enough to be told what has not been
//! measured yet.
//!
//! It exists because of how this went wrong repeatedly. Every per-version fact here — a callback's
//! arity, AllocLinker's, the shape of the BitStream — is a number that is right for one era and
//! silently wrong for another, and none of them fail at the point of use. They shift ESP, or write
//! through the bottom of a caller's frame, and the damage surfaces somewhere unrelated much later.
//! A missing measurement therefore does not look like a missing measurement; it looks like the
//! engine being broken. Turning "nobody read this build's Fog" into a build error is the only
//! cheap moment to catch it.
//!
//! Null in those tables means UNMEASURED, which is a different statement from "the same as its
//! neighbour". Nothing here may infer one from the other.

const std = @import("std");
const version = @import("version.zig");
const fogabi = @import("fogabi.zig");
const callbacks = @import("callbacks.zig");

const claim = @embedFile("served_engines");

/// What a row says the engine must manage. Mirrors the states the harness accepts.
pub const Expectation = enum { world, boot, broken };

pub const Row = struct {
    v: version.Version,
    expect: Expectation,
};

/// Parsed at compile time, so a row naming an engine this code has never heard of — or an
/// expectation the harness would not understand — is a build error rather than a test someone has
/// to remember to run.
pub const rows: []const Row = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const Row = &.{};
    var lines = std.mem.tokenizeScalar(u8, claim, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var field = std.mem.tokenizeAny(u8, line, " \t");
        const name = field.next() orelse continue;
        const want = field.next() orelse
            @compileError("deploy/e2e-engines.txt: '" ++ name ++ "' names no expectation");
        const v = version.Version.parse(name) orelse
            @compileError("deploy/e2e-engines.txt names engine '" ++ name ++
                "', which d2engine has no Version for");
        const e = std.meta.stringToEnum(Expectation, want) orelse
            @compileError("deploy/e2e-engines.txt: '" ++ name ++ "' expects '" ++ want ++
                "', which is not world, boot or broken");
        out = out ++ &[_]Row{.{ .v = v, .expect = e }};
    }
    break :blk out;
};

test "the file names at least one engine, so a parse that silently found nothing is not a pass" {
    // Without this every assertion below is vacuously true, which is exactly how a broken parser
    // reads as full coverage.
    try std.testing.expect(rows.len >= 7);
}

test "every engine we claim serves a world has its Fog measured, both halves" {
    inline for (rows) |row| {
        if (row.expect == .world) {
            // AllocLinker's arity: wrong by two and every table load leaks eight bytes of ESP.
            try std.testing.expect(fogabi.ordinalArgs(row.v) != null);
            // The BitStream generation: wrong either way and Initialize writes through the bottom
            // of the caller's frame, or leaves the engine's own overflow test reading stack.
            try std.testing.expect(fogabi.bitstreamHasOverflow(row.v) != null);
        }
    }
}

test "every engine we claim serves a world has every callback slot counted" {
    inline for (rows) |row| {
        if (row.expect == .world) {
            const s = comptime version.spec(row.v);
            if (comptime !callbacks.isComplete(s.stack_args)) @compileError(
                s.name ++ " is expected to serve a world, but these callback slots were never counted: " ++
                    callbacks.missingSlots(s.stack_args),
            );
        }
    }
}

test "an engine we do NOT claim is allowed to be unmeasured" {
    // The point of the three states is that `broken` and `boot` cost nothing to record. If this
    // started failing it would mean the checks above had been widened to every row, which turns
    // the file from a record into a gate on work nobody has done yet.
    inline for (rows) |row| {
        if (row.expect != .world) {
            _ = fogabi.ordinalArgs(row.v); // may be null, and that is the correct answer
        }
    }
}
