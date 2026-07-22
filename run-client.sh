#!/bin/bash
# run-client.sh — launch a HEADED, rendering D2 client with the d2gs.dll maphack
# injected. Use this to actually SEE client-side features (omnivision, mapreveal,
# mapunits). Unlike run.sh (headless dedicated server), this needs a FULL game
# install with all media MPQs — a stripped/minimal data-only install (the one
# run.sh hardlinks) has no palettes/sprites and the headed renderer null-derefs in
# D2WinPalette. So point this at a clean full install.
#
# Config via env (set in your gitignored ./.env):
#   D2GS_CLIENT_SRC  (required) a FULL D2 1.14d install (~270MB d2data.mpq, real
#                    d2char/d2sfx/... — NOT the minimal data-only dir). e.g. a
#                    "114Clean" install.
#   D2GS_CLIENTDIR   (optional) throwaway dir to assemble into. Default ./clientgame
#   WINE             (optional) wine binary. Default: wine
#
# Usage:
#   ./run-client.sh                          # maphack on, drops you at the menu
#   ./run-client.sh --test-enter             # also auto-drive into a game
#   ./run-client.sh --auto-login acct:pass   # drive the bnet login form
#   (any extra args are passed through to Game.exe)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

# Default to a repo-local gitignored symlink `./114clean` → your full install, so
# no path config is needed once it exists: `ln -s /path/to/114Clean ./114clean`.
# An explicit D2GS_CLIENT_SRC in .env still wins.
D2GS_CLIENT_SRC="${D2GS_CLIENT_SRC:-$ROOT/114clean}"
D2GS_CLIENTDIR="${D2GS_CLIENTDIR:-$ROOT/clientgame}"
WINE="${WINE:-wine}"

die() { echo "error: $1" >&2; exit 1; }
[ -e "$D2GS_CLIENT_SRC" ] || die "no client install at $D2GS_CLIENT_SRC — symlink it: ln -s /path/to/114Clean $ROOT/114clean (or set D2GS_CLIENT_SRC in .env)"
[ -f "$D2GS_CLIENT_SRC/d2data.mpq" ] || die "no d2data.mpq under D2GS_CLIENT_SRC=$D2GS_CLIENT_SRC"
# Guard against pointing at a stripped install: full d2data.mpq is ~270MB; the
# minimal one is a few MB and the headed renderer will crash on missing palettes.
sz=$(stat -f%z "$D2GS_CLIENT_SRC/d2data.mpq" 2>/dev/null || stat -c%s "$D2GS_CLIENT_SRC/d2data.mpq" 2>/dev/null || echo 0)
if [ "$sz" -lt 104857600 ]; then
    die "D2GS_CLIENT_SRC/d2data.mpq is only $((sz/1024/1024))MB — looks stripped/minimal. A headed client needs a FULL install (full d2data.mpq ~270MB)."
fi
command -v "$WINE" >/dev/null || die "wine not found (set WINE=/path/to/wine)"

# Build our DLLs (dbghelp proxy + d2gs payload).
zig build dlls

# Assemble the client dir: hardlink the install (no copies), drop our DLLs.
mkdir -p "$D2GS_CLIENTDIR"
for f in "$D2GS_CLIENT_SRC"/*; do
    [ -f "$f" ] || continue
    ln -f "$f" "$D2GS_CLIENTDIR/$(basename "$f")" 2>/dev/null || cp "$f" "$D2GS_CLIENTDIR/$(basename "$f")"
done
cp "$ROOT/zig-out/bin/dbghelp.dll" "$D2GS_CLIENTDIR/dbghelp.dll"
cp "$ROOT/zig-out/bin/d2gs.dll" "$D2GS_CLIENTDIR/d2gs.dll"
rm -f "$D2GS_CLIENTDIR/d2gs_log.txt"

DLL_WIN="Z:$(echo "$D2GS_CLIENTDIR/d2gs.dll" | tr '/' '\\')"

# Maphack flags on by default. NO --headless (we want rendering) and NO --d2gs-boot
# (this is a pure client, not the dedicated server).
# Maphack flags on by default; override with MAPHACK="" to disable — e.g.:
#   MAPHACK="" ./run-client.sh --realm-gw 127.0.0.1 --auto-login me:x -direct
MAPHACK="${MAPHACK-"--omnivision --mapreveal --mapunits"}"

# Connecting to a realm (--realm-gw)? The Battle.net version check is pointless against
# our realmd (it accepts any SID_AUTH_CHECK), so bypass it client-side by default —
# otherwise the stock CheckRevision flow fails ("Unable to Identify Version").
case " $* " in
    *" --realm-gw "*|*" --realm-gw="*)
        case " $* " in *" --bypass-checkrev "*) ;; *) MAPHACK="$MAPHACK --bypass-checkrev" ;; esac ;;
esac

pkill -9 -f '\\Game.exe' 2>/dev/null || true
wineserver --kill 2>/dev/null || true
sleep 1

cd "$D2GS_CLIENTDIR"
echo "launching HEADED client: Game.exe -w -nosound --loaddll <d2gs> --d2gs $MAPHACK $* (ctrl-c to stop)"
exec env WINEDEBUG="${WINEDEBUG:--all}" WINEDLLOVERRIDES="dbghelp=n" \
    "$WINE" Game.exe -w -nosound --loaddll "$DLL_WIN" --d2gs $MAPHACK "$@"
