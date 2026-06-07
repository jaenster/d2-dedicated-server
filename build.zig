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

    // ver-IX86-1.dll — the CheckRevision module packed into the version-check MPQ
    // realmd serves over BNFTP. Same x86-windows target as the other DLLs.
    const checkrev = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ver-IX86-1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/checkrev/checkrev.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(checkrev);

    // realmd — the realm server (bnetd+d2cs+d2dbs in one binary). Native host
    // target by default (dev on macOS/Linux); cross-compile for deploy with
    // `-Dtarget=x86_64-linux-musl` for a static Linux binary.
    const realmd_target = b.standardTargetOptions(.{});
    const realmd = b.addExecutable(.{
        .name = "realmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/realmd/main.zig"),
            .target = realmd_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(realmd);

    const run_realmd = b.addRunArtifact(realmd);
    run_realmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_realmd.addArgs(args);
    const run_step = b.step("realmd", "Run the realm server");
    run_step.dependOn(&run_realmd.step);
}
