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

    // realm_shared — the shared realm package (wire protocol + enums) imported by BOTH
    // the GS-side client (in d2gs.dll) and the realm server (realmd), so the two ends
    // agree on the wire by construction. Target-less: it compiles in each importer's context.
    const realm_shared = b.createModule(.{
        .root_source_file = b.path("src/realm/shared/shared.zig"),
    });

    // realm_infra — shared host-side infrastructure (net/log/config/lock/store types) for
    // the NATIVE binaries (realmd + qqserver). Deliberately NOT given to the x86-windows
    // DLL, so libc-socket / POSIX code never enters that build.
    const realm_infra = b.createModule(.{
        .root_source_file = b.path("src/realm/shared/infra.zig"),
    });

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
    d2gs.root_module.addImport("realm_shared", realm_shared);
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

    // `zig build dlls` — install ONLY the injected DLLs (no realmd, no pg fetch).
    // Used by the game-server container image, which needs the DLLs but not realmd.
    const dlls_step = b.step("dlls", "Build only the injected DLLs (dbghelp + d2gs)");
    dlls_step.dependOn(&b.addInstallArtifact(dbghelp, .{}).step);
    dlls_step.dependOn(&b.addInstallArtifact(d2gs, .{}).step);

    // realmd — the realm server (bnetd+d2cs+d2dbs in one binary). Native host
    // target by default (dev on macOS/Linux); cross-compile for deploy with
    // `-Dtarget=x86_64-linux-musl` for a static Linux binary.
    const realmd_target = b.standardTargetOptions(.{});

    // realm_adapter — the concrete persistence backends (fs/redis/pg) behind the store
    // facade, imported by realmd. Includes the Postgres client, so the pg dependency lives
    // here (lazy, only fetched when a step builds realmd). The qqserver does NOT use this:
    // it talks to redis directly with its own async client, so it never pulls pg.
    const realm_adapter = b.createModule(.{
        .root_source_file = b.path("src/realm/adapter/adapters.zig"),
    });
    realm_adapter.addImport("realm_infra", realm_infra);
    if (b.lazyDependency("pg", .{ .target = realmd_target, .optimize = optimize })) |pg_dep| {
        realm_adapter.addImport("pg", pg_dep.module("pg"));
    }

    const realmd = b.addExecutable(.{
        .name = "realmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/realm/server/main.zig"),
            .target = realmd_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    realmd.root_module.addImport("realm_shared", realm_shared);
    realmd.root_module.addImport("realm_infra", realm_infra);
    realmd.root_module.addImport("realm_adapter", realm_adapter);

    // Web UI: -Dwebui=true builds webui/ (Vite + React → one self-contained
    // dist/index.html) and embeds it; otherwise embed a stub page so plain builds
    // need no Node. webui.zig @embedFile's the "webui_blob" import either way.
    const webui_enabled = b.option(bool, "webui", "Build and embed the admin web UI (requires Node)") orelse false;
    const webui_blob: std.Build.LazyPath = if (webui_enabled) blk: {
        const cmd = b.addSystemCommand(&.{ "sh", "-c", "set -e; npm --prefix \"$1\" ci && npm --prefix \"$1\" run build && cp \"$1/dist/index.html\" \"$2\"", "realmd-webui", b.pathFromRoot("webui") });
        cmd.has_side_effects = true; // npm/vite do their own incremental builds
        break :blk cmd.addOutputFileArg("index.html");
    } else b.path("src/realm/server/webui_stub.html");
    realmd.root_module.addAnonymousImport("webui_blob", .{ .root_source_file = webui_blob });

    b.installArtifact(realmd);

    // `zig build realmd-bin` — install ONLY the realmd binary (no windows DLLs).
    // Used by the realmd container image.
    const realmd_bin_step = b.step("realmd-bin", "Build only the realmd binary");
    realmd_bin_step.dependOn(&b.addInstallArtifact(realmd, .{}).step);

    // `zig build test` — realm-server unit tests. Rooted at the guild service so it
    // pulls the store facade + realm modules; runs every `test` block reachable from
    // there (guild model/service serialization, store helpers, …).
    const realm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/realm/server/guilds.zig"),
            .target = realmd_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    realm_tests.root_module.addImport("realm_shared", realm_shared);
    realm_tests.root_module.addImport("realm_infra", realm_infra);
    realm_tests.root_module.addImport("realm_adapter", realm_adapter);
    const run_realm_tests = b.addRunArtifact(realm_tests);
    b.step("test", "Run realm-server unit tests").dependOn(&run_realm_tests.step);

    // qqserver — the cloud-native game-traffic gateway: a token-translating, fully
    // non-blocking poll() splice proxy fronting the GS fleet. ZERO heap, bare libc sockets,
    // and its OWN async redis client (route lookups over a non-blocking redis connection in
    // the same poll loop) — so it imports neither the adapter modules nor the pg dependency.
    const qqserver = b.addExecutable(.{
        .name = "qqserver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/realm/qqserver/main.zig"),
            .target = realmd_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    qqserver.root_module.addImport("realm_infra", realm_infra);
    b.installArtifact(qqserver);

    // `zig build qqserver` — build + install ONLY the qqserver binary.
    const qqserver_step = b.step("qqserver", "Build the qqserver game-traffic gateway");
    qqserver_step.dependOn(&b.addInstallArtifact(qqserver, .{}).step);

    // e2e — clientless wire-protocol test harness (pure Zig, no wine/Game.exe).
    // Builds realmd first, then `zig build e2e` builds AND runs the harness; it
    // auto-starts its own realmd child (REALMD_BIN, health 18080) and runs the
    // named scenarios. Native host target, link_libc (libc TCP sockets).
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e/main.zig"),
            .target = realmd_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.step.dependOn(&b.addInstallArtifact(realmd, .{}).step);
    run_e2e.step.dependOn(&b.addInstallArtifact(qqserver, .{}).step); // qqserver_routing spawns it
    const e2e_step = b.step("e2e", "Build + run the clientless realmd E2E test harness");
    e2e_step.dependOn(&run_e2e.step);

    // gamestress — create N games against a RUNNING realm/GS (manual: `zig build gamestress`).
    // Used to verify the empty-game reaper fix (the GS shouldn't OOM past ~8 games).
    const gamestress_mod = b.createModule(.{
        .root_source_file = b.path("tools/gamestress/main.zig"),
        .target = realmd_target,
        .optimize = optimize,
        .link_libc = true,
    });
    gamestress_mod.addAnonymousImport("realmclient", .{ .root_source_file = b.path("tools/e2e/realmclient.zig") });
    const gamestress = b.addExecutable(.{ .name = "gamestress", .root_module = gamestress_mod });
    const run_gamestress = b.addRunArtifact(gamestress);
    b.step("gamestress", "Create N games against a running realm (reaper stress test)").dependOn(&run_gamestress.step);

    // bnftp-probe — clientless BNFTP discovery client (point it at a real bnet,
    // optionally via SOCKS5). Manual: `zig build bnftp-probe -- [opts] <host> ...`
    const probe = b.addExecutable(.{
        .name = "bnftp-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bnftp-probe/main.zig"),
            .target = realmd_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(probe);
    const run_probe = b.addRunArtifact(probe);
    if (b.args) |args| run_probe.addArgs(args);
    b.step("bnftp-probe", "Probe a real Battle.net server's BNFTP (optionally via SOCKS5)").dependOn(&run_probe.step);

    const run_realmd = b.addRunArtifact(realmd);
    run_realmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_realmd.addArgs(args);
    const run_step = b.step("realmd", "Run the realm server");
    run_step.dependOn(&run_realmd.step);
}
