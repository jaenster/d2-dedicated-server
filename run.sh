#!/bin/bash
# run.sh — build d2gs.dll, assemble a wine test game dir, inject, show the log.
#
# Config via env vars (set them in your environment or a local ./.env file):
#   D2GS_GAME_SRC   (required) a ready D2 install to hardlink from (must contain d2data.mpq)
#   D2GS_DBGHELP    (required) path to a dbghelp.dll proxy that LoadLibrary's `-loaddll` DLLs
#   D2GS_TESTDIR    (optional) where the throwaway game dir is built. Default: ./testgame
#   WINE            (optional) wine binary. Default: wine
#
# Usage:
#   ./run.sh           # safe: prove injection + DllMain
#   ./run.sh --boot    # also run the engine bootstrap + tick loop (--d2gs-boot)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

# Local, gitignored overrides (machine-specific paths live here, not in the script).
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

D2GS_TESTDIR="${D2GS_TESTDIR:-$ROOT/testgame}"
D2GS_DBGHELP="${D2GS_DBGHELP:-$ROOT/zig-out/bin/dbghelp.dll}"  # our proxy, built below
WINE="${WINE:-wine}"

die() { echo "error: $1" >&2; exit 1; }
[ -n "${D2GS_GAME_SRC:-}" ] || die "D2GS_GAME_SRC not set (a D2 install dir with d2data.mpq). See .env.example"
[ -f "$D2GS_GAME_SRC/d2data.mpq" ] || die "no d2data.mpq under D2GS_GAME_SRC=$D2GS_GAME_SRC"
command -v "$WINE" >/dev/null || die "wine not found (set WINE=/path/to/wine)"

# Build (produces zig-out/bin/{dbghelp,d2gs}.dll)
zig build
[ -f "$D2GS_DBGHELP" ] || die "no dbghelp proxy at $D2GS_DBGHELP (zig build should produce it)"

# Assemble game dir: hardlink the big/static files (no copies), drop our DLLs.
mkdir -p "$D2GS_TESTDIR"
for f in "$D2GS_GAME_SRC"/*; do
    [ -f "$f" ] || continue
    ln -f "$f" "$D2GS_TESTDIR/$(basename "$f")" 2>/dev/null || cp "$f" "$D2GS_TESTDIR/$(basename "$f")"
done
cp "$D2GS_DBGHELP" "$D2GS_TESTDIR/dbghelp.dll"
cp "$ROOT/zig-out/bin/d2gs.dll" "$D2GS_TESTDIR/d2gs.dll"
rm -f "$D2GS_TESTDIR/d2gs_log.txt"

# wine path to our DLL (Z: maps to /)
DLL_WIN="Z:$(echo "$D2GS_TESTDIR/d2gs.dll" | tr '/' '\\')"

EXTRA=""
for a in "$@"; do
    case "$a" in
        --boot)  EXTRA="$EXTRA --d2gs-boot" ;;
        --realm) EXTRA="$EXTRA --d2gs-boot --realm" ;;  # realm implies boot
    esac
done

# Clean previous wine instance
pkill -9 -f '\\Game.exe' 2>/dev/null || true
wineserver --kill 2>/dev/null || true
sleep 1

# Run in the foreground and stream the server's logs to this terminal (stdout),
# like a normal Linux CLI process. WINEDEBUG=-all silences wine's own chatter so
# only our logs show; override WINEDEBUG to debug. Ctrl-C to stop.
cd "$D2GS_TESTDIR"
echo "launching: Game.exe -w -nosound --headless --loaddll <d2gs> --d2gs$EXTRA   (ctrl-c to stop)"
exec env WINEDEBUG="${WINEDEBUG:--all}" WINEDLLOVERRIDES="dbghelp=n" \
    "$WINE" Game.exe -w -nosound --headless --loaddll "$DLL_WIN" --d2gs$EXTRA
