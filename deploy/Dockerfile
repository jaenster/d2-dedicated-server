# Multi-target image build for the whole stack. Two very different runtime images
# share one zig-toolchain base; pick one with --target:
#
#   docker build -f deploy/Dockerfile --target realmd -t realmd:latest .
#   docker build -f deploy/Dockerfile --target gs     -t d2gs:latest   .
#
#   realmd     — clean-room Zig realm server (bnetd + MCP realm on one port). Static musl
#                binary shipped in scratch: a few-MB image, zero runtime deps.
#   gs         — headless Diablo II 1.14d under wine, driven by our injected DLLs. The
#                minimal 1.14d data set is baked in at /game, so the image runs with no
#                volume; mount your own install over /game to replace it.
#   gs-native  — the same 1.14d server without wine, its data baked in the same way.
#   d2host     — headless PRE-1.14 server: our host driving the engine's D2Game.dll as a
#                library, rather than injecting into Game.exe. Built for ONE engine version
#                and tagged for it, the way a base image is tagged for its distro:
#
#                  deploy/build-d2host.sh 0.0.1          # every engine that is ready
#                  deploy/build-d2host.sh 0.0.1 1.09d     # just one
#
#                Tags are <engine>-<our release>: d2gs:1.09d-0.0.1, plus a floating d2gs:1.09d
#                for the newest build of that engine — the postgres:16 / postgres:16.2 shape.
#
#                The version is a build argument on purpose. d2host carries every measured
#                version and can pick at runtime, but a release artifact should be built FOR
#                one engine: -Dengine-version makes the readiness gate a COMPILE error, so an
#                image for an unfinished version cannot be built. Its era-matched game tree is
#                baked in where one is published — see that target.
#
# --target gs builds only the windows DLLs (pg is a lazy dep, never pulled there);
# --target realmd builds only the realmd binary. Neither builds the other's artifacts.

# shared toolchain base: zig + the source tree
# Pinned to the BUILD platform, not the target: every stage below cross-compiles with -Dtarget, so
# the toolchain never needs to match what it produces. On an arm64 developer machine that is the
# difference between a native build and an emulated one.
FROM --platform=$BUILDPLATFORM alpine:3.20 AS zig
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.16.0
RUN ZA="$(uname -m)" && \
    curl -sSL https://ziglang.org/download/${ZIG_VERSION}/zig-${ZA}-linux-${ZIG_VERSION}.tar.xz \
      | tar -xJ -C /opt && ln -s /opt/zig-${ZA}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY apps ./apps
COPY packages ./packages

# build: realmd (static musl)
# Node builds the admin web UI (webui/ → one self-contained index.html), which the
# realmd binary embeds via -Dwebui=true. The UI is served on the health/admin port.
FROM zig AS build-realmd
RUN apk add --no-cache nodejs npm
COPY webui ./webui
RUN zig build realmd-bin -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dwebui=true

# build: d2ingress (static musl)
# The game-traffic gateway: token-translating poll() splice proxy fronting the GS
# fleet, with its own async redis client. No pg dep — never pulls it.
FROM zig AS build-d2ingress
RUN zig build d2ingress -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# build: injected DLLs (x86-windows; dbghelp proxy + d2gs payload only)
FROM zig AS build-dlls
RUN zig build dlls -Doptimize=ReleaseSafe

# build: d2gs-native (static musl, i386)
# The game is i386 code, so its host has to be i386 too — it is loaded into this process, not
# launched as a child. Static musl because the runtime image below has nothing else in it.
FROM zig AS build-native
RUN zig build d2gs-native -Dtarget=x86-linux-musl -Doptimize=ReleaseSafe

# fetch: minimal 1.14d game data
# tools/make-minimal.sh assembles this from a legitimately owned install (stripped MPQs —
# only what a headless server reads, media archives emptied): it's not committed to this
# repo (see LEGAL.md), but a pre-built copy of it is mirrored at files.typeguru.nl so the
# pipeline can fetch it rather than every image consumer having to run the script by hand.
# Two independent stages (mac + windows) so a target only pulls the platform it runs.
FROM alpine:3.20 AS gamedata-mac
ARG D2_MINIMAL_MAC_URL=https://files.typeguru.nl/diablo/minimal/114d/mac/d2-1.14d-minimal-mac.tgz
RUN apk add --no-cache curl && mkdir /gamedata && \
    curl -fsSL "$D2_MINIMAL_MAC_URL" | tar -xz -C /gamedata

FROM alpine:3.20 AS gamedata-windows
ARG D2_MINIMAL_WINDOWS_URL=https://files.typeguru.nl/diablo/minimal/114d/windows/d2-1.14d-minimal-windows.tgz
RUN apk add --no-cache curl && mkdir /gamedata && \
    curl -fsSL "$D2_MINIMAL_WINDOWS_URL" | tar -xz -C /gamedata

# fetch: the era-matched game tree for ONE pre-1.14 engine
# The era has to match the tag, not just the licence: a .bin table is a raw struct dump, so an
# install from another patch level decodes as garbage rather than failing cleanly.
# tools/make-minimal-engine.sh assembles a tree from a legitimately owned install -- the engine's
# own DLLs rebuilt from that version's patch installer, its tables, and the shared archives.
#
# An engine with no published tree is NOT a build failure. The image still runs; it just needs the
# matching install mounted at /game the way every pre-1.14 image used to. Say that loudly here
# rather than baking an empty directory, which would look like data and fail much later.
FROM alpine:3.20 AS gamedata-engine
ARG D2_VERSION=1.10f
ARG D2_MINIMAL_ENGINE_BASE=https://files.typeguru.nl/diablo/minimal
# "No tree published" and "the download broke" are different answers and must not share an exit
# path. A 404 is a statement -- this engine has no tree yet -- and the build carries on without one.
# Anything else is infrastructure: retried, and then fatal with a message, because a flaky mirror
# silently becoming an engine that ships no data is the failure this whole stage exists to prevent.
RUN apk add --no-cache curl && mkdir -p /gamedata && \
    url="${D2_MINIMAL_ENGINE_BASE}/${D2_VERSION}/d2-${D2_VERSION}-minimal.tgz" && \
    code=$(curl -sSL --retry 5 --retry-all-errors --retry-delay 2 \
             -o /tmp/tree.tgz -w '%{http_code}' "$url" || echo 000) && \
    if [ "$code" = 404 ]; then \
      echo "==> ${D2_VERSION}: NO PUBLISHED TREE -- this image needs one mounted at /game"; \
      rm -f /tmp/tree.tgz; \
    elif [ "$code" != 200 ]; then \
      echo "==> ${D2_VERSION}: FETCH FAILED (HTTP $code) for $url"; exit 1; \
    elif ! tar -xzf /tmp/tree.tgz -C /gamedata; then \
      echo "==> ${D2_VERSION}: tree downloaded but does not unpack -- refusing to ship half of it"; \
      exit 1; \
    else \
      rm /tmp/tree.tgz; \
      echo "==> ${D2_VERSION}: baked its own game tree in"; \
    fi

# gs-native: the same server without wine
# One statically linked file against the wine image's debian + wine32 + wine + Xvfb.
# Labelled amd64, not 386, even though the binary inside is a 32-bit ELF. containerd matches the
# image platform against the node's and refuses a linux/386 image on an amd64 node outright ("no
# match for platform in manifest") — while the kernel it would have run on executes the i386 binary
# without help. The label is metadata; the ELF is what runs.
FROM --platform=linux/amd64 scratch AS gs-native
COPY --from=build-native /src/zig-out/bin/d2gs-native /d2gs-native
# The mac minimal set, since this target loads the Mac image rather than Game.exe. A bind mount
# at /game still overrides it with a different install if you need one.
COPY --from=gamedata-mac /gamedata /game
WORKDIR /game
ENV D2MAC_BIN=/game/DiabloII_macho
# The engine writes its resource file to the temporary-items folder during startup, and a scratch
# image has no /tmp for it to land in. Declaring it as a volume is what creates the directory.
# /game is deliberately not one: an anonymous volume over it would hide the baked tree.
VOLUME ["/tmp"]
EXPOSE 4000
ENTRYPOINT ["/d2gs-native"]

# build: d2host (x86-windows) for ONE engine version
# The version is a BUILD argument, not a runtime one, and that is the point of tagging an image
# per engine: -Dengine-version turns d2host's readiness gate into a compile error, so an image for
# a version whose ABI is not finished cannot be produced at all. Building for 1.06b today fails
# with "missing fpEnterGame, fpUpdateCharacterLadder", which is exactly what should happen.
#
# Fog.dll and D2Net.dll are version-agnostic — they are told which engine they are standing in for
# at startup — so they build once regardless of D2_VERSION.
FROM zig AS build-d2host
ARG D2_VERSION=1.10f
RUN zig build d2host -Dengine-version=${D2_VERSION} -Doptimize=ReleaseSafe && \
    zig build d2fog d2net -Doptimize=ReleaseSafe

# d2host: headless pre-1.14 wine runtime
# Distinct from `gs` above: that one injects into 1.14d's Game.exe, this one IS the host and loads
# D2Game.dll/D2Common.dll as libraries. Tag it per engine — e.g.
#
#   deploy/build-d2host.sh 0.0.1 1.09d      ->  d2gs:1.09d-0.0.1  (+ d2gs:1.09d)
#
# Both halves of the tag are build args: APP_VERSION is our release, D2_VERSION the engine.
#
# The era-matched tree is baked in for every engine that has one published, so those tags run with
# no volume like `gs` does. Where none is published yet the image still needs one mounted at /game,
# and the era matters as much as the licence: a .bin table is a raw struct dump, so an install from
# another patch level decodes as garbage rather than failing cleanly.
FROM debian:bookworm-slim AS d2host
# wine BEFORE the ARGs, deliberately. An ARG declared above an instruction is part of that
# instruction's cache key, so declaring the engine first gave every version its own private copy of
# a 1.1 GB wine install -- seven near-identical layers that share nothing. Below the RUN, the layer
# is byte-identical for every engine, so it is built once, pushed once and pulled once, and what an
# engine adds on top is a few megabytes of our own binaries.
RUN dpkg --add-architecture i386 && apt-get update && \
    apt-get install -y --no-install-recommends wine wine32 curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
ARG D2_VERSION=1.10f
# The other half of the tag: <engine>-<APP_VERSION>, e.g. 1.09d-0.0.1.
ARG APP_VERSION=0.0.0
COPY --from=build-d2host /src/zig-out/bin/d2host.exe /opt/d2host/
COPY --from=build-d2host /src/zig-out/bin/Fog.dll /src/zig-out/bin/D2Net.dll /opt/d2host/
# This engine's own tree, when one is published. The entrypoint symlinks /game into a writable
# /work/game and drops our Fog.dll and D2Net.dll over the engine's, so a read-only copy is enough
# -- and a mount over /game still replaces the whole thing.
COPY --from=gamedata-engine /gamedata /game
COPY deploy/d2host-entrypoint.sh /opt/d2host/entrypoint.sh
RUN chmod +x /opt/d2host/entrypoint.sh
ENV WINEPREFIX=/wine WINEDEBUG=-all
# Announced, not obeyed: the binary was built for this engine and refuses to be told otherwise, so
# this is a label for humans and `docker inspect` rather than a switch.
ENV D2HOST_ENGINE=${D2_VERSION}
LABEL org.d2gs.engine-version="${D2_VERSION}" \
      org.opencontainers.image.version="${D2_VERSION}-${APP_VERSION}" \
      org.opencontainers.image.title="d2gs (pre-1.14 host)" \
      org.opencontainers.image.description="Headless Diablo II ${D2_VERSION} dedicated server"
# /game is NOT declared a volume, for the same reason it is not on `gs`: an anonymous volume over
# it would hide the tree this image ships. A bind mount there still replaces it.
VOLUME ["/wine", "/work"]
EXPOSE 4000
ENTRYPOINT ["/opt/d2host/entrypoint.sh"]

# gs: headless wine runtime (no X, no desktop)
FROM debian:bookworm-slim AS gs
# 32-bit wine for the 32-bit Game.exe, and nothing else: NO Xvfb / X server, NO
# desktop. --no-install-recommends keeps Gecko/Mono/winetricks/desktop bits out; the
# engine is byte-patched to never render, and the entrypoint runs with DISPLAY unset
# and the Mono/Gecko/menu-builder DLLs disabled. (Swap in the WineHQ repo for a newer
# wine if your D2 build needs it.)
# wine + a virtual X display (Xvfb). The engine needs a window/graphics context to
# exist or WinMain bails early (verified: with no display the host exits before the
# server thread boots). Xvfb provides a headless display; rendering itself stays
# stubbed by the injected DLL, so nothing actually draws.
RUN dpkg --add-architecture i386 && apt-get update && \
    apt-get install -y --no-install-recommends wine wine32 curl ca-certificates xvfb && \
    rm -rf /var/lib/apt/lists/*
# The GS needs only these two DLLs (dbghelp proxy + payload) — not realmd's checkrev.
COPY --from=build-dlls /src/zig-out/bin/dbghelp.dll /src/zig-out/bin/d2gs.dll /opt/d2gs/
# The minimal 1.14d install, baked in. It used to arrive at runtime from a separate
# `d2-gamedata` image via an initContainer — one more package to publish, keep public and keep in
# step with this one, for 16 MB that never changes independently of the server that reads it. The
# entrypoint symlinks /game into a writable /work/game, so a read-only copy here is enough, and a
# mount over /game still replaces it (a full install, another era, a mod).
COPY --from=gamedata-windows /gamedata /game
COPY deploy/gs-entrypoint.sh /opt/d2gs/entrypoint.sh
RUN chmod +x /opt/d2gs/entrypoint.sh
ENV WINEPREFIX=/wine WINEDEBUG=-all
# /game holds the baked install and is NOT declared a volume — an anonymous volume over it would
# hide the very data this image ships. /wine = wine prefix, /work = scratch (assembled game dir +
# logs), /mods = optional server-mod DLLs (each --loaddll'd after d2gs.dll), /moddata = optional
# extra data files (MPQs / loose data/ tree) overlaid on the game dir.
VOLUME ["/wine", "/work", "/mods", "/moddata"]
EXPOSE 4000
ENTRYPOINT ["/opt/d2gs/entrypoint.sh"]

# realmd: static binary in scratch (default target)
FROM scratch AS realmd
COPY --from=build-realmd /src/zig-out/bin/realmd /realmd
# The only client-facing port: BNCS login + MCP realm, muxed as real bnet does it. 8080 is bound
# too (health probes, admin API, web UI) but is deliberately NOT declared: it is cluster-internal
# and never belongs on a public Service.
EXPOSE 6112
ENTRYPOINT ["/realmd"]

# d2ingress: static binary in scratch
FROM scratch AS d2ingress
COPY --from=build-d2ingress /src/zig-out/bin/d2ingress /d2ingress
# Client-facing game traffic (REALMD_INGRESS_PORT, default 4000).
EXPOSE 4000
ENTRYPOINT ["/d2ingress"]

# e2e-runner: tools/stress-e2e, built to run AS A CONTAINER on the compose network
# (see deploy/compose.e2e.yaml) rather than against published host ports — no exposed ports,
# no wait-for-host-port shell loop, it dials realmd/gs-native by their compose service names.
# Not part of the realmd / d2gs / d2ingress deploy set; CI-only (and useful for local dev
# without wine — see run-stress.sh for the bash equivalent this ports).
FROM zig AS e2e-runner
COPY tools/stress-e2e ./tools/stress-e2e
# Forces the (lazy) clientless dependency to fetch and the binary to build now, at image-build
# time, instead of on every container start. --rounds 0 --wait-ms 0 is a deliberate no-op run
# (the round loop never executes and the readiness probe is skipped), so this needs no realm
# to actually be up yet.
RUN zig build stress-e2e -- --rounds 0 --wait-ms 0
ENTRYPOINT ["/src/zig-out/bin/stress-e2e"]
