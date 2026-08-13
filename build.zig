const std = @import("std");

// The repo is laid out as apps/ + packages/:
//
//   apps/d2gs      -> dbghelp.dll + d2gs.dll, the injected pair (x86-windows, run under wine)
//   apps/realmd    -> realmd, the realm server (bnetd + d2cs + d2dbs in one binary)
//   apps/qqserver  -> qqserver, the stateless ingress for game traffic
//   packages/*     -> what more than one of those needs, each one its own module
//   tools/*        -> everything that is built to be run by hand, not deployed
//
// The two DLLs are one app: dbghelp is the foothold (Game.exe loads it for its crash handler,
// and it LoadLibrary's whatever `-loaddll <winpath>` names), d2gs is the payload that drives
// 1.14d's built-in QServer/D2Game engine as a headless dedicated server. They ship together.
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const optimize = b.standardOptimizeOption(.{});

    // The native host target, for everything that is not injected into Game.exe.
    // Cross-compile for deploy with `-Dtarget=x86_64-linux-musl` for static Linux binaries.
    const host = b.standardTargetOptions(.{});

    // ── packages ─────────────────────────────────────────────────────────────────
    //
    // Target-less modules: each compiles in its importer's context, which is what lets
    // realm_proto and obs go into BOTH the x86-windows DLL and the native binaries.

    // The realmd <-> d2gs wire contract (protocol + the shared guild model), imported by both
    // ends of the realm link so the two agree on the wire by construction.
    const realm_proto = b.addModule("realm_proto", .{
        .root_source_file = b.path("packages/realm-proto/realm_proto.zig"),
    });

    // Per-thread trace/span context. Shared by the DLL and the host binaries because a trace
    // that stops at the process boundary is not a trace — the id a client's join is stamped
    // with in realmd is the id the game server logs it under.
    const obs = b.addModule("obs", .{
        .root_source_file = b.path("packages/obs/obs.zig"),
    });

    // Host-side infrastructure (net/log/config/lock/store types) for the NATIVE binaries.
    // Deliberately NOT given to the DLL, so libc-socket / POSIX code never enters that build.
    const realm_infra = b.addModule("realm_infra", .{
        .root_source_file = b.path("packages/realm-infra/realm_infra.zig"),
    });
    realm_infra.addImport("obs", obs);

    // One dependency on the libd2 monorepo, whose root re-exports every package's module.
    //
    // d2-formats is the clean-room 1.14d file formats — the realm's .d2s handling comes from
    // there rather than a second copy in this repo, because the header layout, the checksum and
    // the fresh-character writer are all already modelled there and two implementations of a byte
    // format is one more than can stay correct.
    const libd2 = b.dependency("libd2", .{ .target = host, .optimize = optimize });
    const d2_formats = libd2.module("d2-formats");

    // d2-bnet is the Battle.net protocol: the broken-SHA-1 password hash, the version
    // check, the CD-key decode, and the chat/realm message vocabulary they travel in. It lives
    // there and not here because a realm server is not its only consumer — the clientless
    // harnesses need the same hashes, and so does the version-check DLL below, which is why the
    // module is taken twice: libd2's packages bind their target, and that DLL is not this host.
    const d2_bnet = libd2.module("d2-bnet");
    const libd2_win = b.dependency("libd2", .{ .target = target, .optimize = optimize });
    const d2_bnet_win = libd2_win.module("d2-bnet");

    // The concrete persistence backends (fs/redis/pg) behind the store facade, imported by
    // realmd. Includes the Postgres client, so the pg dependency lives here (lazy, only fetched
    // when a step builds realmd). The qqserver does NOT use this: it talks to redis directly
    // with its own async client, so it never pulls pg.
    const realm_store = b.addModule("realm_store", .{
        .root_source_file = b.path("packages/realm-store/realm_store.zig"),
    });
    realm_store.addImport("realm_infra", realm_infra);
    if (b.lazyDependency("pg", .{ .target = host, .optimize = optimize })) |pg_dep| {
        realm_store.addImport("pg", pg_dep.module("pg"));
    }

    // ── apps/d2gs ────────────────────────────────────────────────────────────────

    const dbghelp = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "dbghelp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2gs/dbghelp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dbghelp.root_module.addImport("realm_proto", realm_proto);
    dbghelp.root_module.addImport("obs", obs);
    b.installArtifact(dbghelp);

    const d2gs = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "d2gs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2gs/d2gs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    d2gs.root_module.addImport("realm_proto", realm_proto);
    d2gs.root_module.addImport("obs", obs);
    b.installArtifact(d2gs);

    // `zig build dlls` — install ONLY the injected DLLs (no realmd, no pg fetch).
    // Used by the game-server container image, which needs the DLLs but not realmd.
    const dlls_step = b.step("dlls", "Build only the injected DLLs (dbghelp + d2gs)");
    dlls_step.dependOn(&b.addInstallArtifact(dbghelp, .{}).step);
    dlls_step.dependOn(&b.addInstallArtifact(d2gs, .{}).step);

    // ── apps/realmd ──────────────────────────────────────────────────────────────

    const realmd = b.addExecutable(.{
        .name = "realmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/realmd/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    realmd.root_module.addImport("realm_proto", realm_proto);
    realmd.root_module.addImport("realm_infra", realm_infra);
    realmd.root_module.addImport("realm_store", realm_store);
    realmd.root_module.addImport("d2_bnet", d2_bnet);
    realmd.root_module.addImport("d2_formats", d2_formats);

    // Web UI: -Dwebui=true builds webui/ (Vite + React → one self-contained
    // dist/index.html) and embeds it; otherwise embed a stub page so plain builds
    // need no Node. webui.zig @embedFile's the "webui_blob" import either way.
    const webui_enabled = b.option(bool, "webui", "Build and embed the admin web UI (requires Node)") orelse false;
    const webui_blob: std.Build.LazyPath = if (webui_enabled) blk: {
        const cmd = b.addSystemCommand(&.{ "sh", "-c", "set -e; npm --prefix \"$1\" ci && npm --prefix \"$1\" run build && cp \"$1/dist/index.html\" \"$2\"", "realmd-webui", b.pathFromRoot("webui") });
        cmd.has_side_effects = true; // npm/vite do their own incremental builds
        break :blk cmd.addOutputFileArg("index.html");
    } else b.path("apps/realmd/webui_stub.html");
    realmd.root_module.addAnonymousImport("webui_blob", .{ .root_source_file = webui_blob });

    b.installArtifact(realmd);

    // `zig build realmd-bin` — install ONLY the realmd binary (no windows DLLs).
    // Used by the realmd container image.
    const realmd_bin_step = b.step("realmd-bin", "Build only the realmd binary");
    realmd_bin_step.dependOn(&b.addInstallArtifact(realmd, .{}).step);

    // ── apps/qqserver ────────────────────────────────────────────────────────────
    //
    // The cloud-native game-traffic gateway: a token-translating, fully non-blocking poll()
    // splice proxy fronting the GS fleet. ZERO heap, bare libc sockets, and its OWN async redis
    // client (route lookups over a non-blocking redis connection in the same poll loop) — so it
    // imports neither the store package nor the pg dependency.
    const qqserver = b.addExecutable(.{
        .name = "qqserver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/qqserver/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    qqserver.root_module.addImport("realm_infra", realm_infra);
    b.installArtifact(qqserver);

    // `zig build qqserver` — build + install ONLY the qqserver binary.
    const qqserver_step = b.step("qqserver", "Build the qqserver game-traffic gateway");
    qqserver_step.dependOn(&b.addInstallArtifact(qqserver, .{}).step);

    // ── tests ────────────────────────────────────────────────────────────────────
    //
    // Zig collects `test` blocks only from files in a test artifact's ROOT module, so a package
    // is tested only by an artifact rooted at its own barrel — importing it from somewhere else
    // runs none of its tests. Hence one artifact per package rather than one big root.
    const test_step = b.step("test", "Run the unit tests");

    const realm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/realmd/realm_tests.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    realm_tests.root_module.addImport("realm_proto", realm_proto);
    realm_tests.root_module.addImport("realm_infra", realm_infra);
    realm_tests.root_module.addImport("realm_store", realm_store);
    realm_tests.root_module.addImport("d2_bnet", d2_bnet);
    realm_tests.root_module.addImport("d2_formats", d2_formats);
    test_step.dependOn(&b.addRunArtifact(realm_tests).step);

    // qqserver's pure wire logic (the 0xAF greeting strip it applies to the GS→client splice),
    // rooted at the binary itself with its infra import.
    const qq_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/qqserver/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    qq_tests.root_module.addImport("realm_infra", realm_infra);
    test_step.dependOn(&b.addRunArtifact(qq_tests).step);

    // The packages: realm_infra's lock/logger/config, realm_store's RESP codec and fs backend,
    // and realm_proto's wire types.
    inline for (.{
        .{ "packages/realm-infra/realm_infra.zig", true, false },
        .{ "packages/realm-store/realm_store.zig", true, true },
        .{ "packages/realm-proto/realm_proto.zig", false, false },
    }) |spec| {
        const mod_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec[0]),
                .target = host,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        mod_tests.root_module.addImport("obs", obs);
        if (spec[1]) mod_tests.root_module.addImport("realm_infra", realm_infra);
        if (spec[2]) {
            if (b.lazyDependency("pg", .{ .target = host, .optimize = optimize })) |pg_dep| {
                mod_tests.root_module.addImport("pg", pg_dep.module("pg"));
            }
        }
        test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    }

    // ── tools ────────────────────────────────────────────────────────────────────

    // ver-IX86-1.dll — the CheckRevision module packed into the version-check MPQ realmd serves
    // over BNFTP. Built for the client's target (x86-windows), not this host's.
    const checkrev = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ver-IX86-1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ver-ix86/checkrev.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    checkrev.root_module.addImport("d2_bnet", d2_bnet_win);
    // Module-definition file: export `CheckRevision` UNDECORATED (ordinal 1) so the
    // client's GetProcAddress("CheckRevision") resolves it (stdcall would otherwise
    // mangle it to CheckRevision@28).
    checkrev.root_module.addObjectFile(b.path("tools/ver-ix86/checkrev.def"));
    b.installArtifact(checkrev);

    // e2e — clientless wire-protocol test harness (pure Zig, no wine/Game.exe).
    // Builds realmd first, then `zig build e2e` builds AND runs the harness; it
    // auto-starts its own realmd child (REALMD_BIN, health 18080) and runs the
    // named scenarios. Native host target, link_libc (libc TCP sockets).
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    e2e.root_module.addImport("d2_bnet", d2_bnet);
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.step.dependOn(&b.addInstallArtifact(realmd, .{}).step);
    run_e2e.step.dependOn(&b.addInstallArtifact(qqserver, .{}).step); // qqserver_routing spawns it
    const e2e_step = b.step("e2e", "Build + run the clientless realmd E2E test harness");
    e2e_step.dependOn(&run_e2e.step);

    // gamestress — create N games against a RUNNING realm/GS (manual: `zig build gamestress`).
    // Used to verify the empty-game reaper fix (the GS shouldn't OOM past ~8 games).
    const gamestress_mod = b.createModule(.{
        .root_source_file = b.path("tools/gamestress/main.zig"),
        .target = host,
        .optimize = optimize,
        .link_libc = true,
    });
    const realmclient = b.createModule(.{ .root_source_file = b.path("tools/e2e/realmclient.zig") });
    realmclient.addImport("d2_bnet", d2_bnet);
    gamestress_mod.addImport("realmclient", realmclient);
    const gamestress = b.addExecutable(.{ .name = "gamestress", .root_module = gamestress_mod });
    const run_gamestress = b.addRunArtifact(gamestress);
    b.step("gamestress", "Create N games against a running realm (reaper stress test)").dependOn(&run_gamestress.step);

    // bnftp-probe — clientless BNFTP discovery client (point it at a real bnet,
    // optionally via SOCKS5). Manual: `zig build bnftp-probe -- [opts] <host> ...`
    const probe = b.addExecutable(.{
        .name = "bnftp-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bnftp-probe/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(probe);
    const run_probe = b.addRunArtifact(probe);
    if (b.args) |args| run_probe.addArgs(args);
    b.step("bnftp-probe", "Probe a real Battle.net server's BNFTP (optionally via SOCKS5)").dependOn(&run_probe.step);

    // checkrev-probe — clientless BNCS *version-check* client (selector 0x01): runs
    // SID_AUTH_INFO -> compute response (the same d2-bnet the DLL uses) -> SID_AUTH_CHECK
    // against a real bnet and prints the result code. Separate from BNFTP.
    const crprobe = b.addExecutable(.{
        .name = "checkrev-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/checkrev-probe/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    crprobe.root_module.addImport("d2_bnet", d2_bnet);
    b.installArtifact(crprobe);
    const run_crprobe = b.addRunArtifact(crprobe);
    if (b.args) |args| run_crprobe.addArgs(args);
    b.step("checkrev-probe", "Replay the BNCS version-check against a real Battle.net").dependOn(&run_crprobe.step);

    const run_realmd = b.addRunArtifact(realmd);
    run_realmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_realmd.addArgs(args);
    const run_step = b.step("realmd", "Run the realm server");
    run_step.dependOn(&run_realmd.step);
}
