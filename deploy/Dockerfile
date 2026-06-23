# Multi-target image build for the whole stack. Two very different runtime images
# share one zig-toolchain base; pick one with --target:
#
#   docker build -f deploy/Dockerfile --target realmd -t realmd:latest .
#   docker build -f deploy/Dockerfile --target gs     -t d2gs:latest   .
#
#   realmd — clean-room Zig realm server (bnetd+d2cs+d2dbs+gs-link). Static musl
#            binary shipped in scratch: a few-MB image, zero runtime deps.
#   gs     — headless Diablo II 1.14d under wine, driven by our injected DLLs. Game
#            files are proprietary and are NOT baked in — mount a real 1.14d install
#            at /game at runtime.
#
# --target gs builds only the windows DLLs (pg is a lazy dep, never pulled there);
# --target realmd builds only the realmd binary. Neither builds the other's artifacts.

# ── shared toolchain base: zig + the source tree ─────────────────────────────────
FROM alpine:3.20 AS zig
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.16.0
RUN curl -sSL https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
      | tar -xJ -C /opt && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

# ── build: realmd (static musl) ──────────────────────────────────────────────────
FROM zig AS build-realmd
RUN zig build realmd-bin -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# ── build: injected DLLs (x86-windows; dbghelp proxy + d2gs payload only) ─────────
FROM zig AS build-dlls
RUN zig build dlls -Doptimize=ReleaseSafe

# ── gs: headless wine runtime (no X, no desktop) ─────────────────────────────────
FROM debian:bookworm-slim AS gs
# 32-bit wine for the 32-bit Game.exe, and nothing else: NO Xvfb / X server, NO
# desktop. --no-install-recommends keeps Gecko/Mono/winetricks/desktop bits out; the
# engine is byte-patched to never render, and the entrypoint runs with DISPLAY unset
# and the Mono/Gecko/menu-builder DLLs disabled. (Swap in the WineHQ repo for a newer
# wine if your D2 build needs it.)
RUN dpkg --add-architecture i386 && apt-get update && \
    apt-get install -y --no-install-recommends wine wine32 curl ca-certificates && \
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

# ── realmd: static binary in scratch (default target) ────────────────────────────
FROM scratch AS realmd
COPY --from=build-realmd /src/zig-out/bin/realmd /realmd
# bnetd / d2cs / d2dbs / gs-link / health
EXPOSE 6112 6113 6114 6115 8080
ENTRYPOINT ["/realmd"]
