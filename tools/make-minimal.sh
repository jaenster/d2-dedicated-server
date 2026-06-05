#!/bin/bash
# make-minimal.sh — assemble a minimal D2 1.14d test install from YOUR own copy.
#
# This repo ships the *recipe*, not Blizzard's bytes: empty stub MPQs (no game
# content, tools/stub.mpq) plus a list of the real files to copy from your install.
# You supply a legit Diablo II (the free 1.14 patch + classic installer is enough).
#
#   D2_INSTALL=/path/to/Diablo\ II  tools/make-minimal.sh
#   # then:  D2GS_GAME_SRC=./testgame-min  ./run.sh --realm
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

D2_INSTALL="${D2_INSTALL:-${1:-}}"
OUT="${MINIMAL_OUT:-$ROOT/testgame-min}"
STUB="$ROOT/tools/stub.mpq"

[ -n "$D2_INSTALL" ] || { echo "set D2_INSTALL=/path/to/your/Diablo II install (or pass as arg 1)"; exit 1; }
[ -f "$STUB" ] || { echo "missing $STUB"; exit 1; }

# Real files copied from your install (game content / 3rd-party DLLs).
REAL=(Game.exe d2data.mpq d2exp.mpq Patch_D2.mpq D2.LNG binkw32.dll SmackW32.dll ijl11.dll)
# Media MPQs the headless server doesn't need — replaced by empty stubs.
STUBS=(d2char.mpq d2music.mpq d2sfx.mpq d2speech.mpq d2Xmusic.mpq d2Xtalk.mpq d2Xvideo.mpq)

# Case-insensitive lookup helper (installs vary: Game.exe / game.exe, D2.LNG / d2.lng).
find_ci() { find "$D2_INSTALL" -maxdepth 1 -iname "$1" -print -quit 2>/dev/null; }

mkdir -p "$OUT"
missing=0
for f in "${REAL[@]}"; do
    src="$(find_ci "$f")"
    if [ -n "$src" ]; then cp "$src" "$OUT/$f"; else echo "MISSING: $f (not found in $D2_INSTALL)"; missing=1; fi
done
for f in "${STUBS[@]}"; do cp "$STUB" "$OUT/$f"; done

echo
[ "$missing" = 0 ] && echo "✓ minimal install assembled at $OUT ($(du -sh "$OUT" | cut -f1))" \
                    || echo "⚠ assembled with missing files — copy them in manually"
echo "  run it:  D2GS_GAME_SRC=$OUT ./run.sh --realm"
