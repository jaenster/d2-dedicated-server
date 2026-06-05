const std = @import("std");

// Builds d2gs.dll — an injected payload that drives 1.14d Game.exe's built-in
// QServer/D2Game engine as a headless dedicated game server.
//
// It is loaded into the real Game.exe process via a dbghelp.dll proxy (Game.exe
// loads dbghelp for crash dumps), which LoadLibrary's injected DLLs listed on the
// command line. Run the game with `--headless` so the client renderer never spins up.
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const optimize = b.standardOptimizeOption(.{});

    const dll = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "d2gs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(dll);
}
