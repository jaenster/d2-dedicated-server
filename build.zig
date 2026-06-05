const std = @import("std");

// Builds two DLLs (both x86-windows, run under wine on Linux):
//   dbghelp.dll — injection foothold. Game.exe loads dbghelp for its crash
//                 handler; our proxy forwards the real exports and LoadLibrary's
//                 the DLLs passed via `-loaddll <winpath>`.
//   d2gs.dll    — the payload that drives 1.14d's built-in QServer/D2Game engine
//                 as a headless dedicated game server.
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const optimize = b.standardOptimizeOption(.{});

    const dbghelp = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "dbghelp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dbghelp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(dbghelp);

    const d2gs = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "d2gs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/d2gs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(d2gs);
}
