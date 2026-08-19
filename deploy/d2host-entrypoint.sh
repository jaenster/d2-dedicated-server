#!/bin/sh
# Headless pre-1.14 Diablo II dedicated game server under wine.
#
# Unlike the 1.14d `gs` image, nothing is injected into Game.exe here: this runs OUR host
# (d2host.exe), which loads the engine's D2Game.dll/D2Common.dll as libraries and supplies
# Fog.dll and D2Net.dll itself. The image is built FOR one engine version — see the
# `d2host` target in deploy/Dockerfile — and the binary refuses to run as any other.
#
# Mounts (only /game is required):
#   /game   the engine's own DLLs + that ERA's data archives, READ-ONLY (proprietary;
#           never baked in). Must match the version this image was built for: a .bin
#           table is a raw struct dump, so another era's tables decode as garbage.
#   /wine   wine prefix (persist on a volume to skip re-init)
#   /work   scratch: the assembled game dir + logs
#
# Env: D2GS_REDIS_ADDR, D2GS_GSID, D2GS_GS_ADDR — read by d2host itself.
set -e

export WINEPREFIX="${WINEPREFIX:-/wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
# No Xvfb here, deliberately: the 1.14d image needs one because Game.exe's WinMain bails
# without a window, and d2host has no WinMain — it is our own console exe.
WINE_HEADLESS_OVERRIDES="mscoree=d;mshtml=d;winemenubuilder.exe=d"

[ -f /game/D2Game.dll ] || { echo "FATAL: mount an engine install at /game (no D2Game.dll found)"; exit 1; }

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  echo "initialising wine prefix at $WINEPREFIX ..."
  WINEDLLOVERRIDES="$WINE_HEADLESS_OVERRIDES" wineboot --init >/dev/null 2>&1 || true
  wineserver -w 2>/dev/null || true
fi
export WINEDLLOVERRIDES="$WINE_HEADLESS_OVERRIDES"

# Assemble a WRITABLE dir: symlink the read-only install, then copy OUR Fog.dll and D2Net.dll
# over the engine's. Those two are replacements, not additions — the engine imports them by
# name, so ours have to sit where the originals did.
GAME_DIR=/work/game
rm -rf "$GAME_DIR"; mkdir -p "$GAME_DIR"
for f in /game/* /game/.[!.]*; do
  [ -e "$f" ] || continue
  ln -sf "$f" "$GAME_DIR/$(basename "$f")"
done
cp -f /opt/d2host/Fog.dll /opt/d2host/D2Net.dll "$GAME_DIR/"
cp -f /opt/d2host/d2host.exe "$GAME_DIR/"
cd "$GAME_DIR"

# Same public-address problem the 1.14d entrypoint solves: clients dial the GS directly, and a
# node's downward-API IP is its private one.
case "${D2GS_GS_ADDR:-auto}" in
  auto|auto:*)
    port="4000"; case "$D2GS_GS_ADDR" in auto:*) port="${D2GS_GS_ADDR#auto:}";; esac
    pubip=""
    for url in \
      "http://169.254.169.254/hetzner/v1/metadata/public-ipv4" \
      "https://ifconfig.me/ip" "https://api.ipify.org"; do
      pubip=$(curl -fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
      case "$pubip" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) break;; *) pubip="";; esac
    done
    [ -n "$pubip" ] && export D2GS_GS_ADDR="$pubip:$port" \
      || echo "WARN: could not resolve public IP; leaving D2GS_GS_ADDR unset"
    ;;
esac

echo "starting ${D2HOST_ENGINE:-pre-1.14} GS: realm_store=${D2GS_REDIS_ADDR:-<unset>} gs_addr=${D2GS_GS_ADDR:-<unset>}"
exec wine "$GAME_DIR/d2host.exe" "$GAME_DIR"
