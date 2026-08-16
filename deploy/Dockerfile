# Multi-target image build for the whole stack. Two very different runtime images
# share one zig-toolchain base; pick one with --target:
#
#   docker build -f deploy/Dockerfile --target realmd -t realmd:latest .
#   docker build -f deploy/Dockerfile --target gs     -t d2gs:latest   .
#
#   realmd     — clean-room Zig realm server (bnetd + MCP realm on one port). Static musl
#                binary shipped in scratch: a few-MB image, zero runtime deps.
#   gs         — headless Diablo II 1.14d under wine, driven by our injected DLLs.
#                Game data is NOT baked into this image — the chart's load-gamedata
#                initContainer (or a mounted install) supplies /game at runtime.
#   gamedata   — the minimal 1.14d data set alone, at /gamedata: what the chart's
#                initContainer copies into the gs pod's /game. See tools/make-minimal.sh
#                for how it's assembled; this stage fetches an already-assembled copy
#                (windows) from files.typeguru.nl rather than rebuilding it in CI.
#   gs-native  — the wine-free GS: game data IS baked in (the mac minimal set), since
#                nothing wires an initContainer for it yet — see that target below.
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

# gamedata: the windows minimal set alone, for the chart's load-gamedata initContainer
# Nothing but data at /gamedata — `gameServer.dataImage.repository` in deploy/chart points
# here by default, and the initContainer `cp -a /gamedata/. /game/`s it into each gs pod.
FROM scratch AS gamedata
COPY --from=gamedata-windows /gamedata /gamedata

# gs-native: the same server without wine
# One statically linked file against the wine image's debian + wine32 + wine + Xvfb.
# Labelled amd64, not 386, even though the binary inside is a 32-bit ELF. containerd matches the
# image platform against the node's and refuses a linux/386 image on an amd64 node outright ("no
# match for platform in manifest") — while the kernel it would have run on executes the i386 binary
# without help. The label is metadata; the ELF is what runs.
FROM --platform=linux/amd64 scratch AS gs-native
COPY --from=build-native /src/zig-out/bin/d2gs-native /d2gs-native
# Baked in directly rather than via an initContainer (unlike gs/gamedata above): nothing
# public wires up a native-GS deployment yet, so there's no chart step to copy it in.
# A bind mount at /game (below) still overrides this with a different install if you need one.
COPY --from=gamedata-mac /gamedata /game
WORKDIR /game
ENV D2MAC_BIN=/game/DiabloII_macho
# The engine writes its resource file to the temporary-items folder during startup, and a scratch
# image has no /tmp for it to land in. Declaring it as a volume is what creates the directory.
VOLUME ["/game", "/tmp"]
EXPOSE 4000
ENTRYPOINT ["/d2gs-native"]

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
COPY deploy/gs-entrypoint.sh /opt/d2gs/entrypoint.sh
RUN chmod +x /opt/d2gs/entrypoint.sh
ENV WINEPREFIX=/wine WINEDEBUG=-all
# /game = mounted D2 install (RO), /wine = wine prefix, /work = scratch (assembled game
# dir + logs), /mods = optional server-mod DLLs (each --loaddll'd after d2gs.dll),
# /moddata = optional extra data files (MPQs / loose data/ tree) overlaid on the game dir.
VOLUME ["/game", "/wine", "/work", "/mods", "/moddata"]
EXPOSE 4000
ENTRYPOINT ["/opt/d2gs/entrypoint.sh"]

# realmd: static binary in scratch (default target)
FROM scratch AS realmd
COPY --from=build-realmd /src/zig-out/bin/realmd /realmd
# bnetd + MCP realm (muxed, as real bnet does it) / health + admin
EXPOSE 6112 8080
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
# Not part of the realmd/gs/gs-native/gamedata deploy set; CI-only (and useful for local dev
# without wine — see run-stress.sh for the bash equivalent this ports).
FROM zig AS e2e-runner
COPY tools/stress-e2e ./tools/stress-e2e
# Forces the (lazy) clientless dependency to fetch and the binary to build now, at image-build
# time, instead of on every container start. --rounds 0 --wait-ms 0 is a deliberate no-op run
# (the round loop never executes and the readiness probe is skipped), so this needs no realm
# to actually be up yet.
RUN zig build stress-e2e -- --rounds 0 --wait-ms 0
ENTRYPOINT ["/src/zig-out/bin/stress-e2e"]
