#!/bin/bash
# make-minimal-engine.sh — assemble a minimal, era-matched /game tree for ONE pre-1.14 engine.
#
# The 1.14d recipe (tools/make-minimal.sh) rebuilds that version's own archives. The older engines
# need something extra: their tables do not exist as files anywhere. Each patch shipped them as Ptc
# deltas over the expansion base, so they are recovered from the patch installer first
# (tools/re/patchdata.py) and dropped in as loose files, which our Fog prefers over the archives.
#
# This ships the RECIPE, not Blizzard's bytes: you supply the base archives and the patch installer.
#
#   D2_BASE=/path/with/d2data.mpq,d2exp.mpq \
#   D2_PATCHES=/path/with/LODPatch_109b.exe \
#     tools/make-minimal-engine.sh 1.09b out/game-1.09b
#
# Why loose tables rather than a rebuilt Patch_D2.mpq: a .bin is a raw struct dump with no version
# marker, so the ONLY thing keeping an engine from reading another era's table as garbage is that
# the right file is in front of it. Loose files make that visible in the tree instead of hidden
# inside an archive.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

ENGINE="${1:?usage: make-minimal-engine.sh <engine> <outdir>   e.g. 1.09b out/game-1.09b}"
OUT="${2:?usage: make-minimal-engine.sh <engine> <outdir>}"
BASE="${D2_BASE:?set D2_BASE to a directory holding d2data.mpq and d2exp.mpq}"
PATCHES="${D2_PATCHES:?set D2_PATCHES to the directory holding the LODPatch_*/D2Patch_* installers}"
MPQMIN="${MPQMIN:-$ROOT/tools/mpqmin/mpqmin}"

# Classic engines predate the expansion and read only d2data; LoD ones read both.
case "$ENGINE" in
    1.00|1.06b) ARCHIVES="d2data.mpq"; INSTALLER="D2Patch_${ENGINE/./}" ;;
    *)          ARCHIVES="d2data.mpq d2exp.mpq"; INSTALLER="LODPatch_${ENGINE//./}" ;;
esac
INSTALLER="$PATCHES/${INSTALLER/D2Patch_106b/D2Patch_106b}.exe"

mkdir -p "$OUT/data/global/excel"

# 1. Strip the archives to what a headless server reads. mpqmin's default rule keeps the data
#    extensions and drops the graphics blocks, which is most of a 256 MB d2data.
for a in $ARCHIVES; do
    [ -f "$BASE/$a" ] || { echo "missing $BASE/$a"; exit 1; }
    echo "==> minimising $a"
    "$MPQMIN" "$BASE/$a" "$OUT/$a"
done

# 2. Recover this engine's own tables from its patch installer. 1.06b is the exception: it reads
#    .txt straight from the archive and its patch carries no tables, so there is nothing to add.
if [ -f "$INSTALLER" ]; then
    echo "==> recovering tables from $(basename "$INSTALLER")"
    MPQCAT="$ROOT/zig-out/bin/mpqcat" D2PATCH="$ROOT/zig-out/bin/d2patch" \
        python3 tools/re/patchdata.py "$INSTALLER" "$(echo $ARCHIVES | tr ' ' '\n' | sed "s|^|$BASE/|" | paste -sd, -)" \
        "$OUT/data/global/excel"
    rm -rf "$OUT/data/global/excel/.patchdata"
else
    echo "==> no installer at $INSTALLER — the archives alone are this engine's era"
fi

du -sh "$OUT" | sed 's/^/==> /'
