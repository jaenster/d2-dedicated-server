#!/bin/bash
# make-minimal.sh — assemble a minimal D2 1.14d test install from YOUR own copy.
#
# This repo ships the *recipe*, not Blizzard's bytes: empty stub MPQs (no game content,
# tools/stub.mpq), a repacker (tools/mpqmin) and the list of files to take from your install. You
# supply a legit Diablo II (the free 1.14 patch + classic installer is enough).
#
#   D2_INSTALL=/path/to/Diablo\ II        tools/make-minimal.sh
#   D2_INSTALL=/path/to/mac/install       tools/make-minimal.sh --mac
#   # then:  D2GS_GAME_SRC=./testgame-min  ./run.sh --realm
#
# The archives are not copied, they are REBUILT. A retail d2data.mpq is ~256 MB and a headless
# server reads ~4 MB of it, so `mpqmin` drops every member the server never opens and strips the
# graphics blocks out of the tilesets it keeps. See tools/mpqmin/mpqmin.zig for the rule.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

MAC=0
if [ "${1:-}" = "--mac" ]; then MAC=1; shift; fi

D2_INSTALL="${D2_INSTALL:-${1:-}}"
STUB="$ROOT/tools/stub.mpq"
MPQMIN="$ROOT/tools/mpqmin/mpqmin"
# Where StormLib lives. Homebrew's prefix by default; set STORMLIB for anywhere else.
STORMLIB="${STORMLIB:-/opt/homebrew/opt/stormlib}"

[ -n "$D2_INSTALL" ] || { echo "set D2_INSTALL=/path/to/your/Diablo II install (or pass as arg 1)"; exit 1; }
[ -f "$STUB" ] || { echo "missing $STUB"; exit 1; }

# Built on demand rather than committed: it is a native binary against a library this repo does not
# vendor, and it is only needed by this script.
if [ ! -x "$MPQMIN" ]; then
    [ -d "$STORMLIB/include" ] || { echo "StormLib not found at $STORMLIB (brew install stormlib, or set STORMLIB)"; exit 1; }
    echo "building tools/mpqmin..."
    (cd "$ROOT/tools/mpqmin" && zig build-exe mpqmin.zig -O ReleaseSafe -lc -lstorm -lz -lbz2 \
        -I"$STORMLIB/include" -L"$STORMLIB/lib")
fi

# Case-insensitive lookup helper (installs vary: Game.exe / game.exe, D2.LNG / d2.lng).
# -L because an install is often reached through a symlink, and without it find silently matches
# nothing and every file is reported missing while sitting in plain view.
find_ci() { find -L "$D2_INSTALL" -maxdepth 1 -iname "$1" -print -quit 2>/dev/null; }

missing=0
take() { # take <name> [dest-name] — copy a file from the install verbatim
    local src; src="$(find_ci "$1")"
    if [ -n "$src" ]; then cp "$src" "$OUT/${2:-$1}"; else echo "MISSING: $1 (not found in $D2_INSTALL)"; missing=1; fi
}
shrink() { # shrink <name> [mpqmin flags...] — rebuild an archive with only what a server reads
    local name="$1"; shift
    local src; src="$(find_ci "$name")"
    if [ -z "$src" ]; then echo "MISSING: $name (not found in $D2_INSTALL)"; missing=1; return; fi
    rm -f "$OUT/$name"
    "$MPQMIN" "$@" "$src" "$OUT/$name"
}

if [ "$MAC" = 1 ]; then
    OUT="${MINIMAL_OUT:-$ROOT/testgame-min-mac}"
    mkdir -p "$OUT"
    # The i386 Mach-O, and the resource fork PreInitApplication expects to find beside it.
    take "DiabloII_macho"
    take "D2Resources.rsrc"
    # --ui because this build has no dedicated-server application mode: the host boots the client
    # with the renderer patched out, so the palette/font/cursor load still runs. Without it the
    # boot segfaults on the first act's missing Pal.PL2.
    shrink "Diablo II Game Data"      --ui
    shrink "Diablo II Expansion Data" --ui
    shrink "Diablo II Patch"          --ui
    # CD content: speech, sound effects, and two patch archives that are empty on a 1.14d install.
    for f in "Diablo II Sounds" "Diablo II Speech" "Diablo II Update" "Diablo II Korean Fixup"; do
        cp "$STUB" "$OUT/$f"
    done
    mkdir -p "$OUT/Save"
else
    OUT="${MINIMAL_OUT:-$ROOT/testgame-min}"
    mkdir -p "$OUT"
    for f in Game.exe D2.LNG binkw32.dll SmackW32.dll ijl11.dll; do take "$f"; done
    shrink d2data.mpq
    shrink d2exp.mpq
    # Patch_D2.mpq is copied, not rebuilt: it ships without a (listfile), so its members have no
    # names to filter on — and at 2 MB there is nothing worth filtering.
    take Patch_D2.mpq
    # Media MPQs the headless server doesn't need — replaced by empty stubs.
    for f in d2char.mpq d2music.mpq d2sfx.mpq d2speech.mpq d2Xmusic.mpq d2Xtalk.mpq d2Xvideo.mpq; do
        cp "$STUB" "$OUT/$f"
    done
fi

echo
[ "$missing" = 0 ] && echo "✓ minimal install assembled at $OUT ($(du -sh "$OUT" | cut -f1))" \
                    || echo "⚠ assembled with missing files — copy them in manually"
if [ "$MAC" = 1 ]; then echo "  run it:  mount $OUT at /game in the gs-native image, or ./run-native.sh"
                 else echo "  run it:  D2GS_GAME_SRC=$OUT ./run.sh --realm"; fi
