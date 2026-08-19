const std = @import("std");

// The repo is laid out as apps/ + packages/:
//
//   apps/d2gs      -> dbghelp.dll + d2gs.dll, the injected pair (x86-windows, run under wine)
//   apps/realmd    -> realmd, the realm server (bnetd + d2cs + d2dbs in one binary)
//   apps/d2ingress  -> d2ingress, the stateless ingress for game traffic
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

    // The Redis wire format as a pure codec — no sockets, no libc — so the x86-windows DLL can
    // speak it with its own Winsock while the native binaries use realm_infra's. One
    // implementation rather than a second one growing inside the DLL.
    const resp = b.addModule("resp", .{
        .root_source_file = b.path("packages/resp/resp.zig"),
    });

    // Per-thread trace/span context. Shared by the DLL and the host binaries because a trace
    // that stops at the process boundary is not a trace — the id a client's join is stamped
    // with in realmd is the id the game server logs it under.
    const obs = b.addModule("obs", .{
        .root_source_file = b.path("packages/obs/obs.zig"),
    });

    // Loading 1.14d's Mac build into a process: segments, dyld's rebase/bind streams, no dyld and
    // no format conversion. Host-target so the parser can be tested here; the i386 Linux build
    // that actually runs the image picks it up under its own target.
    const macho = b.addModule("macho", .{
        .root_source_file = b.path("packages/macho/macho.zig"),
    });

    // The engine's host-facing contracts. The server callback table is the same 16 slots from
    // 1.10f's D2Game.dll to 1.14d's monolith, so one definition serves the injected DLL and any
    // other host that drives a D2Game build; only the per-slot stack-arg counts differ per version.
    // It needs the fastcall shim builder, which stays with the DLL that has always owned it.
    const fastcall_mod = b.createModule(.{ .root_source_file = b.path("apps/d2gs/runtime/fastcall.zig") });
    const d2engine = b.addModule("d2engine", .{
        .root_source_file = b.path("packages/d2engine/d2engine.zig"),
    });
    d2engine.addImport("fastcall", fastcall_mod);

    // The game server's side of the shared store: the ops a GS needs of the realm — fetch and
    // save a character, advertise itself, take create/join requests, report events. Domain ops on
    // the outside, redis on the inside. It lives here rather than inside apps/d2gs because a
    // second game server already re-implemented it once (apps/d2gs-native/store.zig) and a third
    // is now driving the pre-1.14 DLLs; the protocol is the same for all of them.
    const gs_store = b.addModule("gs_store", .{
        .root_source_file = b.path("packages/gs-store/gs_store.zig"),
    });
    gs_store.addImport("resp", resp);

    // Host-side infrastructure (net/log/config/lock/store types) for the NATIVE binaries.
    // Deliberately NOT given to the DLL, so libc-socket / POSIX code never enters that build.
    const realm_infra = b.addModule("realm_infra", .{
        .root_source_file = b.path("packages/realm-infra/realm_infra.zig"),
    });
    realm_infra.addImport("obs", obs);

    // One dependency on libd2, and one import from it. The library re-exports every layer off
    // a single `libd2` module, so what this repo consumes reads as libd2.formats / libd2.bnet
    // rather than a list of module names that has to be kept in step with the library's own
    // layering. Naming a layer costs nothing until it is used.
    //
    // formats is the clean-room 1.14d file formats — the realm's .d2s handling comes from there
    // rather than a second copy here, because the header layout, the checksum and the fresh
    // character writer are all already modelled there and two implementations of a byte format
    // is one more than can stay correct. bnet is the Battle.net logon protocol, for the same
    // reason: it was three byte-identical copies across two repos before it moved.
    //
    // Taken TWICE, once per target: libd2's packages bind their target at addModule, and the
    // version-check DLL below is not this host. Deleting the second one breaks ver-IX86-1.dll
    // and nothing else.
    const libd2 = b.dependency("libd2", .{ .target = host, .optimize = optimize }).module("libd2");
    const libd2_win = b.dependency("libd2", .{ .target = target, .optimize = optimize }).module("libd2");

    // The concrete persistence backends (fs/redis/pg) behind the store facade, imported by
    // realmd. Includes the Postgres client, so the pg dependency lives here (lazy, only fetched
    // when a step builds realmd). The d2ingress does NOT use this: it talks to redis directly
    // with its own async client, so it never pulls pg.
    const realm_store = b.addModule("realm_store", .{
        .root_source_file = b.path("packages/realm-store/realm_store.zig"),
    });
    realm_store.addImport("realm_infra", realm_infra);
    realm_store.addImport("resp", resp);
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
    dbghelp.root_module.addImport("fastcall", fastcall_mod);
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
    d2gs.root_module.addImport("resp", resp);
    d2gs.root_module.addImport("gs_store", gs_store);
    d2gs.root_module.addImport("obs", obs);
    d2gs.root_module.addImport("d2engine", d2engine);
    // As a module, not a relative import: the same file is the root of the `fastcall` module that
    // d2engine uses, and a file may belong to only one module.
    d2gs.root_module.addImport("fastcall", fastcall_mod);
    b.installArtifact(d2gs);

    // apps/d2host — the pre-1.14 shape of the same server: D2Game.dll driven as a library instead
    // of a merged Game.exe detoured in place. x86-windows exe, run under wine. See docs/dll-host.md.
    const d2host = b.addExecutable(.{
        .name = "d2host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Pin the engine version at build time, so a release artifact is built FOR one engine rather
    // than carrying every one and choosing later. This is what makes a per-version container tag
    // mean something: `-Dengine-version=1.06b` turns the readiness gate into a BUILD error, so an
    // image for a version that is not finished cannot be produced at all. Left unset, the binary
    // keeps the runtime switch and `D2GS_ENGINE_VERSION` picks among the ready versions.
    const engine_version = b.option([]const u8, "engine-version",
        "Build d2host for ONE engine (e.g. 1.06b, 1.09d, 1.10f); omit to carry all of them");
    const d2host_options = b.addOptions();
    d2host_options.addOption(?[]const u8, "engine_version", engine_version);
    d2host.root_module.addOptions("build_options", d2host_options);
    d2host.root_module.addImport("fastcall", fastcall_mod);
    d2host.root_module.addImport("gs_store", gs_store);
    d2host.root_module.addImport("d2engine", d2engine);
    d2host.root_module.addImport("realm_proto", realm_proto);
    b.installArtifact(d2host);
    b.step("d2host", "Build the pre-1.14 DLL host (x86-windows exe)")
        .dependOn(&b.addInstallArtifact(d2host, .{}).step);

    // packages/d2fog — our own Fog.dll. D2Game/D2Common import 53 Fog ordinals and two data symbols,
    // none of them networking, so this is pure support code we would rather own than reverse.
    // Ordinals are the ABI: fog.def pins them to the real 1.10f numbers.
    const d2fog = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "Fog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/d2fog/fog.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    d2fog.root_module.addObjectFile(b.path("packages/d2fog/fog.def"));
    // The archive reader: Fog serves the engine's files straight out of the MPQs.
    d2fog.root_module.addImport("libd2", libd2_win);
    d2fog.root_module.addImport("d2engine", d2engine);
    b.installArtifact(d2fog);
    b.step("d2fog", "Build our replacement Fog.dll (x86-windows)")
        .dependOn(&b.addInstallArtifact(d2fog, .{}).step);

    // tools/mpqcat — pull one member out of an archive, to diff generated tables against shipped.
    const mpqcat = b.addExecutable(.{
        .name = "mpqcat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mpqcat/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    mpqcat.root_module.addImport("libd2", libd2);
    b.installArtifact(mpqcat);
    b.step("mpqcat", "Extract one member from an MPQ by name")
        .dependOn(&b.addInstallArtifact(mpqcat, .{}).step);

    // tools/fogrewrite — stage a classic-era install against our LoD-numbered Fog.
    const fogrewrite = b.addExecutable(.{
        .name = "fogrewrite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fogrewrite/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    fogrewrite.root_module.addImport("d2engine", d2engine);
    b.installArtifact(fogrewrite);
    b.step("fogrewrite", "Rewrite a classic install's Fog imports onto the LoD numbering")
        .dependOn(&b.addInstallArtifact(fogrewrite, .{}).step);

    // packages/d2net — our own D2Net.dll. The real one forwards every export into Fog's QServer, so
    // keeping it would mean writing 31 Fog networking ordinals to serve a module we are replacing
    // anyway. This is 14 stdcall entries, and it is where our own transport goes.
    const d2net = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "D2Net",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/d2net/d2net.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    d2net.root_module.addObjectFile(b.path("packages/d2net/d2net.def"));
    d2net.root_module.addImport("d2engine", d2engine);
    b.installArtifact(d2net);
    b.step("d2net", "Build our replacement D2Net.dll (x86-windows)")
        .dependOn(&b.addInstallArtifact(d2net, .{}).step);

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
    realmd.root_module.addImport("libd2", libd2);

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

    // ── apps/d2ingress ────────────────────────────────────────────────────────────
    //
    // The cloud-native game-traffic gateway: a token-translating, fully non-blocking poll()
    // splice proxy fronting the GS fleet. ZERO heap, bare libc sockets, and its OWN async redis
    // client (route lookups over a non-blocking redis connection in the same poll loop) — so it
    // imports neither the store package nor the pg dependency.
    const d2ingress = b.addExecutable(.{
        .name = "d2ingress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2ingress/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    d2ingress.root_module.addImport("realm_infra", realm_infra);
    b.installArtifact(d2ingress);

    // `zig build d2ingress` — build + install ONLY the d2ingress binary.
    const d2ingress_step = b.step("d2ingress", "Build the d2ingress game-traffic gateway");
    d2ingress_step.dependOn(&b.addInstallArtifact(d2ingress, .{}).step);

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
    realm_tests.root_module.addImport("libd2", libd2);
    test_step.dependOn(&b.addRunArtifact(realm_tests).step);

    // The RESP codec. Worth its own test binary rather than riding along with realmd's: it is
    // IO-free by design, so it is the one piece of the store path that can be tested exhaustively
    // without a server — and it is about to be compiled into the DLL, where a framing bug is far
    // harder to see.
    const resp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/resp/resp.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(resp_tests).step);

    // d2ingress's pure wire logic (the 0xAF greeting strip it applies to the GS→client splice),
    // rooted at the binary itself with its infra import.
    const ingress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2ingress/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ingress_tests.root_module.addImport("realm_infra", realm_infra);
    test_step.dependOn(&b.addRunArtifact(ingress_tests).step);

    // The packages: realm_infra's lock/logger/config, realm_store's RESP codec and fs backend,
    // and realm_proto's wire types.
    inline for (.{
        .{ "packages/realm-infra/realm_infra.zig", true, false },
        .{ "packages/realm-store/realm_store.zig", true, true },
        .{ "packages/realm-proto/realm_proto.zig", false, false },
        .{ "packages/macho/macho.zig", false, false },
        .{ "packages/darwin/darwin.zig", false, false },
        // The native host's crash reporter. Rooted here rather than at main.zig because that one
        // runs the game; this is the part with logic worth asserting.
        .{ "apps/d2gs-native/crash.zig", false, false },
        // The engine callback contract: its layout asserts are the point, and they fire at
        // compile time on any target, so they are worth checking here and not only in the DLL.
        .{ "packages/d2engine/d2engine.zig", false, false },
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
        mod_tests.root_module.addImport("resp", resp);
        mod_tests.root_module.addImport("fastcall", fastcall_mod);
        if (spec[1]) mod_tests.root_module.addImport("realm_infra", realm_infra);
        if (spec[2]) {
            if (b.lazyDependency("pg", .{ .target = host, .optimize = optimize })) |pg_dep| {
                mod_tests.root_module.addImport("pg", pg_dep.module("pg"));
            }
        }
        test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    }

    // ── apps/d2gs-native ─────────────────────────────────────────────────────────
    //
    // The same game server without wine: 1.14d's Mac build, loaded into this process and run as
    // i386 Linux code. Nothing is emulated and nothing is converted — the Mach-O is mapped as it
    // ships and its imports are answered by packages/darwin.
    //
    // Built for whatever -Dtarget says, because it has two jobs: `-Dtarget=x86-linux-musl` for the
    // deployable (one static file, so the runtime image is scratch), and the developer's own host
    // for `--dry-run`, which exercises the whole load path without an i386 machine.
    const darwin = b.addModule("darwin", .{
        .root_source_file = b.path("packages/darwin/darwin.zig"),
    });

    const d2gs_native = b.addExecutable(.{
        .name = "d2gs-native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2gs-native/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    d2gs_native.root_module.addImport("macho", macho);
    // Same IO-free RESP codec the wine DLL and realmd use, so the three cannot drift on the wire.
    d2gs_native.root_module.addImport("resp", resp);
    d2gs_native.root_module.addImport("darwin", darwin);
    d2gs_native.root_module.addImport("realm_proto", realm_proto);
    const native_realm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/d2gs-native/realm.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    native_realm_tests.root_module.addImport("macho", macho);
    native_realm_tests.root_module.addImport("realm_proto", realm_proto);
    test_step.dependOn(&b.addRunArtifact(native_realm_tests).step);

    b.step("d2gs-native", "Build the wine-free native game server").dependOn(
        &b.addInstallArtifact(d2gs_native, .{}).step,
    );
    b.installArtifact(d2gs_native);

    // ── tools ────────────────────────────────────────────────────────────────────

    // machoinfo — what the Mac build declares it needs. `--imports` prints the symbol list that
    // packages/darwin has to answer, read out of the image rather than maintained by hand.
    const machoinfo = b.addExecutable(.{
        .name = "machoinfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/machoinfo/main.zig"),
            .target = host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    machoinfo.root_module.addImport("macho", macho);
    b.installArtifact(machoinfo);

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
    checkrev.root_module.addImport("libd2", libd2_win);
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
    e2e.root_module.addImport("libd2", libd2);
    // The harness's stand-in game server meets realmd in redis like a real one, so it needs the
    // same IO-free RESP codec both real ends use — sharing it is what keeps the harness from
    // drifting away from the thing it tests.
    e2e.root_module.addImport("resp", resp);
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.step.dependOn(&b.addInstallArtifact(realmd, .{}).step);
    run_e2e.step.dependOn(&b.addInstallArtifact(d2ingress, .{}).step); // d2ingress_routing spawns it
    const e2e_step = b.step("e2e", "Build + run the clientless realmd E2E test harness");
    e2e_step.dependOn(&run_e2e.step);

    // stress-e2e — a round loop against a REAL GS (clientless's d2-realm/d2-session,
    // not FakeGS): each round spawns --clients threads that log in once and play --runs games.
    // Manual: `zig build stress-e2e -- --rounds N --clients N` against a running realm+GS.
    // Lazy: only fetches/builds clientless when this step is actually requested.
    if (b.lazyDependency("clientless", .{ .target = host, .optimize = optimize })) |clientless_dep| {
        const stress_e2e = b.addExecutable(.{
            .name = "stress-e2e",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/stress-e2e/main.zig"),
                .target = host,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        stress_e2e.root_module.addImport("d2-realm", clientless_dep.module("d2-realm"));
        stress_e2e.root_module.addImport("d2-session", clientless_dep.module("d2-session"));
        // addInstallArtifact directly, not the installArtifact sugar: that attaches to the
        // DEFAULT install step, which every other `zig build <target>` invocation also runs —
        // this tool is lazy and CI-only, so it stays out of that. The e2e-runner Dockerfile
        // stage execs zig-out/bin/stress-e2e directly, so "stress-e2e" has to actually install
        // it (addRunArtifact alone runs from the build cache, never touching zig-out).
        const install_stress_e2e = b.addInstallArtifact(stress_e2e, .{});
        const run_stress_e2e = b.addRunArtifact(stress_e2e);
        if (b.args) |args| run_stress_e2e.addArgs(args);
        const stress_e2e_step = b.step("stress-e2e", "Round-loop real-GS stress test");
        stress_e2e_step.dependOn(&install_stress_e2e.step);
        stress_e2e_step.dependOn(&run_stress_e2e.step);
    }

    // gamestress — create N games against a RUNNING realm/GS (manual: `zig build gamestress`).
    // Used to verify the empty-game reaper fix (the GS shouldn't OOM past ~8 games).
    const gamestress_mod = b.createModule(.{
        .root_source_file = b.path("tools/gamestress/main.zig"),
        .target = host,
        .optimize = optimize,
        .link_libc = true,
    });
    const realmclient = b.createModule(.{ .root_source_file = b.path("tools/e2e/realmclient.zig") });
    realmclient.addImport("libd2", libd2);
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
    probe.root_module.addImport("libd2", libd2); // the BNFTP wire, shared with realmd's server side
    b.installArtifact(probe);
    const run_probe = b.addRunArtifact(probe);
    if (b.args) |args| run_probe.addArgs(args);
    b.step("bnftp-probe", "Probe a real Battle.net server's BNFTP (optionally via SOCKS5)").dependOn(&run_probe.step);

    // checkrev-probe — clientless BNCS *version-check* client (selector 0x01): runs
    // SID_AUTH_INFO -> compute response (the same libd2.bnet the DLL uses) -> SID_AUTH_CHECK
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
    crprobe.root_module.addImport("libd2", libd2);
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
