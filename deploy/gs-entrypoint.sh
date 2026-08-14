#!/bin/sh
# Headless Diablo II 1.14d dedicated game server under wine.
#
# Mounts (only /game is required):
#   /game     pristine D2 1.14d install, READ-ONLY (proprietary; never baked in)
#   /moddata  extra DATA files overlaid onto the game dir: replacement / additional
#             MPQs (e.g. a mod's patch_d2.mpq, loaded over the base) and/or a loose
#             data/ tree (the engine reads that only with -direct -txt, see below)
#   /mods     server-mod DLLs — each *.dll is --loaddll'd after d2gs.dll
#   /wine     wine prefix (persist on a volume to skip re-init)
#   /work     scratch: the assembled game dir + the d2gs log
#
# Env read by d2gs.dll:   REALMD_HOST, D2GS_GS_ADDR, D2GS_MAX_GAMES
# Env read by this script: D2GS_EXTRA_DLLS (more --loaddll), D2GS_EXTRA_ARGS (extra
#   Game.exe flags — e.g. "-direct -txt" to load the loose /moddata data/ tree).
set -e

export WINEPREFIX="${WINEPREFIX:-/wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
# Truly headless: no X display, and wine's GUI bits disabled so nothing draws or pops a
# dialog (the engine is byte-patched to never render). mscoree/mshtml are the Mono/Gecko
# installers; winemenubuilder writes desktop menus. dbghelp=n,b loads our proxy.
WINE_HEADLESS_OVERRIDES="mscoree=d;mshtml=d;winemenubuilder.exe=d"

# Headless virtual display. The engine's WinMain needs a window/graphics context to
# exist or it returns early (the host then ExitProcess()es before the server thread
# boots). Xvfb gives wine a display; the injected DLL still stubs all rendering, so
# nothing draws. This mirrors a local run, where wine has a real GPU backend.
XVFB_DISPLAY="${XVFB_DISPLAY:-:99}"
Xvfb "$XVFB_DISPLAY" -screen 0 1024x768x16 -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null' EXIT
export DISPLAY="$XVFB_DISPLAY"
# Give Xvfb a moment to come up before wine connects.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "/tmp/.X11-unix/X${XVFB_DISPLAY#:}" ] && break; sleep 0.3; done

[ -f /game/Game.exe ] || { echo "FATAL: mount a D2 1.14d install at /game (no Game.exe found)"; exit 1; }

# One-time wine prefix init. The overrides keep wineboot from trying to fetch/install
# Gecko + Mono (no UI, no network).
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  echo "initialising wine prefix at $WINEPREFIX ..."
  WINEDLLOVERRIDES="$WINE_HEADLESS_OVERRIDES" wineboot --init >/dev/null 2>&1 || true
  wineserver -w 2>/dev/null || true
fi
export WINEDLLOVERRIDES="dbghelp=n,b;$WINE_HEADLESS_OVERRIDES"

# Assemble a WRITABLE game dir. D2 loads its data (MPQs; with -direct -txt also a loose
# data/ tree) AND Game.exe's crash-handler dbghelp from the EXE's own directory — but
# /game is a read-only pristine mount. So symlink the base install into /work/game,
# drop our dbghelp proxy beside it, then overlay any mod data (copies win over the
# symlinks → they replace base files / add new MPQs). This keeps /game untouched.
GAME_DIR=/work/game
rm -rf "$GAME_DIR"; mkdir -p "$GAME_DIR"
for f in /game/* /game/.[!.]*; do
  [ -e "$f" ] || continue
  ln -sf "$f" "$GAME_DIR/$(basename "$f")"
done
cp -f /opt/d2gs/dbghelp.dll "$GAME_DIR/dbghelp.dll"
if [ -d /moddata ]; then
  echo "overlaying mod data from /moddata ..."
  cp -a /moddata/. "$GAME_DIR/"
fi
cd "$GAME_DIR"   # writable cwd: d2gs log lands here; data + DLLs load from here

# loaddll args: d2gs.dll FIRST (it drives the engine), then mods hook on top of it:
#   * every *.dll mounted at /mods (alphabetical)
#   * then each entry in $D2GS_EXTRA_DLLS (unix /path -> Z:\path; Z:\... passed through)
set -- -w -nosound --headless --loaddll 'Z:\opt\d2gs\d2gs.dll'
if [ -d /mods ]; then
  for dll in /mods/*.dll; do
    [ -e "$dll" ] || continue
    set -- "$@" --loaddll "$(printf 'Z:%s' "$dll" | tr '/' '\\')"
    echo "  + mod dll $dll"
  done
fi
for dll in $D2GS_EXTRA_DLLS; do
  case "$dll" in
    /*) win=$(printf 'Z:%s' "$dll" | tr '/' '\\') ;;
    *)  win="$dll" ;;
  esac
  set -- "$@" --loaddll "$win"
  echo "  + mod dll $win"
done
# --no-compress because qqserver owns the client-facing port and swallows the GS's duplicate 0xAF00
# so the S->C stream matches a non-compressing client. Without it the local stack and a deployed
# container disagree, and the join dies silently: the client never sends 0x6b.
set -- "$@" --d2gs --d2gs-boot --realm --create-games --no-compress
# Extra engine flags (e.g. -direct -txt for the loose /moddata data/ tree).
[ -n "$D2GS_EXTRA_ARGS" ] && set -- "$@" $D2GS_EXTRA_ARGS

# Clients dial THIS server directly for game traffic, so D2GS_GS_ADDR must be a
# PUBLIC, client-routable address. On a cloud node the downward-API status.hostIP is
# the node's PRIVATE network IP (e.g. Hetzner 10.x), which clients can't reach. When
# D2GS_GS_ADDR is unset or "auto[:port]", resolve the node's public IPv4 from the
# cloud metadata service and append the game port.
case "${D2GS_GS_ADDR:-auto}" in
  auto|auto:*)
    port="4000"; case "$D2GS_GS_ADDR" in auto:*) port="${D2GS_GS_ADDR#auto:}";; esac
    pubip=""
    # Hetzner Cloud metadata (no auth, link-local). Fall back to an external echo.
    for url in \
      "http://169.254.169.254/hetzner/v1/metadata/public-ipv4" \
      "https://ifconfig.me/ip" "https://api.ipify.org"; do
      pubip=$(curl -fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
      case "$pubip" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) break;; *) pubip="";; esac
    done
    [ -n "$pubip" ] && export D2GS_GS_ADDR="$pubip:$port" \
      || echo "WARN: could not resolve public IP; leaving D2GS_GS_ADDR unset (realmd will use the gs-link peer IP)"
    ;;
esac

echo "starting headless GS: realm=${REALMD_HOST:-<unset>} gs_addr=${D2GS_GS_ADDR:-<peer-ip>} max_games=${D2GS_MAX_GAMES:-100}"
exec wine "$GAME_DIR/Game.exe" "$@"
