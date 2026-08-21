#!/bin/bash
# make-minimal-engine.sh — build the game tree for the pre-1.14 engines, in two layers.
#
#   tools/make-minimal-engine.sh base         <out>      the expansion archives, shared by 1.07+
#   tools/make-minimal-engine.sh base-classic <out>      the classic archive, for 1.00/1.06b
#   tools/make-minimal-engine.sh engine <ver> <out>      that engine's DLLs and tables
#
# The split is the point. mpqmin keeps by EXTENSION, not by version, so the minimised archives come
# out identical whichever engine you build them for — about 10 MB that every image can share rather
# than carry a copy of. What genuinely differs per engine is small: its DLLs and its tables.
#
# It is fine that the shared set carries expansion files a classic engine never opens. Sharing costs
# a few megabytes once; splitting costs a separate archive per engine forever.
#
# Both layers come out of the same two inputs, so there is one thing to supply:
#   D2_BASE      a directory holding d2data.mpq and d2exp.mpq
#   D2_PATCHES   the directory of LODPatch_*/D2Patch_* installers
#   D2_LOD_BASE  the 1.07 expansion PE files, which every later DLL is a delta against
#
# A CLASSIC engine needs its own base, built with `base-classic`, and two more inputs:
#   D2_CLASSIC_ARCHIVE   a classic d2data.mpq (retail v1.00 does)
#   D2_CLASSIC_LISTFILE  its (listfile); the v1.00 archive ships one alongside
#
# Classic gets d2data.mpq and NOTHING ELSE. The engine opens d2exp.mpq FIRST when it is present
# and reads expansion-format tables out of it for everything it has no loose override for, which
# is not a licence question but a correctness one -- it was the whole reason 1.06b asserted in
# ItemTbls.cpp.
#
# This ships the RECIPE, not Blizzard's bytes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
MPQMIN="${MPQMIN:-$ROOT/tools/mpqmin/mpqmin}"
MPQCAT="${MPQCAT:-$ROOT/zig-out/bin/mpqcat}"
D2PATCH="${D2PATCH:-$ROOT/zig-out/bin/d2patch}"

usage() { sed -n '2,12p' "$0"; exit 1; }
MODE="${1:-}"; shift || usage

case "$MODE" in
base)
    OUT="${1:?usage: make-minimal-engine.sh base <out>}"
    BASE="${D2_BASE:?set D2_BASE to a directory holding d2data.mpq and d2exp.mpq}"
    # An archive's (listfile) is optional and older ones are badly incomplete: v1.00's d2data names
    # a few hundred bytes worth. A member the listfile does not name is invisible to the rebuild and
    # gets dropped, which does not fail loudly -- the engine asserts deep inside LoadAllTxts on a
    # table that is simply absent. Point D2_LISTFILE at a community listfile for pre-1.14 archives.
    LF=""
    [ -n "${D2_LISTFILE:-}" ] && LF="--listfile $D2_LISTFILE"
    if [ -z "$LF" ]; then
        echo "!!  no D2_LISTFILE set. 1.14d archives name everything they hold, but the older ones do"
        echo "!!  not, and what the listfile omits is dropped silently. Verify the result boots."
    fi
    mkdir -p "$OUT"
    # Both archives, always: a classic engine ignores d2exp rather than tripping over it, and one
    # shared layer is worth more than the megabytes saved by tailoring it.
    for a in d2data.mpq d2exp.mpq; do
        [ -f "$BASE/$a" ] || { echo "missing $BASE/$a"; exit 1; }
        echo "==> minimising $a"
        "$MPQMIN" $LF "$BASE/$a" "$OUT/$a"
    done
    # Patch_D2.mpq too, and it is not optional in practice. It overlays the base archives, and a
    # tree without it boots and loads its tables and then halts inside level generation --
    # "..\Source\D2Common\DRLG\DrlgLogic.cpp:876", a lookup in a table that came back empty.
    # 1.13c dies there the moment a client enters a game; with the patch archive present the same
    # build runs a client into the world. Nothing about the failure points at a missing archive.
    if [ -f "$BASE/Patch_D2.mpq" ]; then
        echo "==> minimising Patch_D2.mpq"
        "$MPQMIN" $LF "$BASE/Patch_D2.mpq" "$OUT/Patch_D2.mpq"
    else
        echo "!!  no Patch_D2.mpq in $BASE. The engine will boot and then halt in DRLG the first"
        echo "!!  time a client enters a game. See DrlgLogic.cpp:876."
    fi
    du -sh "$OUT" | sed 's/^/==> shared base: /'
    ;;
base-classic)
    OUT="${1:?usage: make-minimal-engine.sh base-classic <out>}"
    ARC="${D2_CLASSIC_ARCHIVE:?set D2_CLASSIC_ARCHIVE to a classic d2data.mpq (retail v1.00 has one)}"
    mkdir -p "$OUT"
    LF=""
    [ -n "${D2_CLASSIC_LISTFILE:-}" ] && LF="--listfile $D2_CLASSIC_LISTFILE"
    echo "==> minimising the classic d2data.mpq"
    "$MPQMIN" $LF "$ARC" "$OUT/d2data.mpq"
    # Deliberately no d2exp.mpq. See the header.
    du -sh "$OUT" | sed 's/^/==> classic base: /'
    ;;
engine)
    VER="${1:?usage: make-minimal-engine.sh engine <ver> <out>}"
    OUT="${2:?usage: make-minimal-engine.sh engine <ver> <out>}"
    BASE="${D2_BASE:?set D2_BASE}"
    PATCHES="${D2_PATCHES:?set D2_PATCHES}"
    # Which base a DLL delta is cut against follows the era, not the date: classic patches rebase
    # the v1.00 CD files, expansion patches rebase 1.07's. Handing a delta the wrong base is caught
    # by its own source CRC rather than silently producing a broken DLL.
    case "$VER" in
        1.00|1.06b)
            INST="$PATCHES/D2Patch_${VER//./}.exe"
            LOD="${D2_CLASSIC_BASE:?set D2_CLASSIC_BASE to the v1.00 classic PE files - classic engines rebase those, not the 1.07 ones}"
            ;;
        1.07)
            # 1.07 IS the expansion base: there is no patch to apply and no delta to rebase, so its
            # DLLs are copied straight out of that tree. Its tables are the base archives' own
            # members for the same reason -- every later patch overlaid Patch_D2.mpq rather than
            # rewriting d2data/d2exp, which is exactly why those members are still what the deltas
            # for 1.08 onward are cut against.
            INST=""
            LOD="${D2_LOD_BASE:?set D2_LOD_BASE to the 1.07 expansion PE files}"
            ;;
        *)
            # The final build of a patch line is the installer Blizzard shipped: 1.10f is
            # LODPatch_110, not a LODPatch_110f that never existed.
            INST="$PATCHES/LODPatch_${VER//./}.exe"
            [ -f "$INST" ] || INST="$PATCHES/LODPatch_$(echo "${VER//./}" | sed 's/[a-z]$//').exe"
            LOD="${D2_LOD_BASE:?set D2_LOD_BASE to the 1.07 expansion PE files}"
            ;;
    esac
    [ -z "$INST" ] || [ -f "$INST" ] || { echo "missing $INST"; exit 1; }
    mkdir -p "$OUT/data/global/excel"

    # 1.07: copy, do not patch.
    if [ -z "$INST" ]; then
        echo "==> taking $VER DLLs from the expansion base"
        for m in D2Game.dll D2Common.dll D2Lang.dll D2CMP.dll Storm.dll; do
            cp "$LOD/$m" "$OUT/$m" && echo "   $m ok"
        done
        rmdir "$OUT/data/global/excel" "$OUT/data/global" "$OUT/data" 2>/dev/null || true
        du -sh "$OUT" | sed 's/^/==> engine layer: /'
        exit 0
    fi

    # The DLLs are Ptc deltas against the 1.07 base, same as the tables — so one installer yields
    # both halves of what this engine needs and there is nothing else to source.
    echo "==> rebuilding $VER DLLs from $(basename "$INST")"
    WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
    "$D2PATCH" carve "$INST" "$WORK/patch.mpq" >/dev/null
    for m in D2Game.dll D2Common.dll D2Lang.dll D2CMP.dll Storm.dll; do
        "$MPQCAT" "$WORK/patch.mpq" "$m" "$WORK/$m.delta" >/dev/null 2>&1 || { echo "   $m: absent"; continue; }
        if "$D2PATCH" apply "$WORK/$m.delta" "$LOD/$m" "$OUT/$m" >/dev/null 2>&1; then
            echo "   $m ok"
        else
            echo "   $m FAILED"; exit 1
        fi
    done

    # Classic Fog was renumbered at the LoD boundary, so a classic module's imports mean something
    # else to our Fog — sometimes a DIFFERENT function of the same number. Retarget them here rather
    # than leaving a trap for whoever assembles the image.
    case "$VER" in
        1.00|1.06b)
            echo "==> retargeting $VER Fog imports onto the LoD numbering"
            for m in D2Game.dll D2Common.dll D2CMP.dll D2Lang.dll; do
                [ -f "$OUT/$m" ] || continue
                "$ROOT/zig-out/bin/fogrewrite" "$OUT/$m" "$OUT/$m.rw" --accept-inferred >/dev/null
                mv "$OUT/$m.rw" "$OUT/$m"
            done
            ;;
    esac

    # Classic ships its string tables in the patch too, and they are not excel — they belong under
    # data/local/lng/ENG. Without them a classic engine dies on `miss: patchstring.tbl` the moment
    # d2exp.mpq is (correctly) absent, because that is where it had been reading them from. They are
    # whole files rather than deltas (Ptc kind 0x0104), so applying them needs no base.
    case "$VER" in
        1.00|1.06b)
            echo "==> recovering $VER string tables"
            mkdir -p "$OUT/data/local/lng/ENG"
            : > "$WORK/empty"
            for t in string.tbl patchstring.tbl; do
                "$MPQCAT" "$WORK/patch.mpq" "$t" "$WORK/$t.rec" >/dev/null 2>&1 || { echo "   $t: absent"; continue; }
                if "$D2PATCH" apply "$WORK/$t.rec" "$WORK/empty" "$OUT/data/local/lng/ENG/$t" >/dev/null 2>&1; then
                    echo "   $t ok"
                else
                    echo "   $t FAILED"; exit 1
                fi
            done
            ;;
    esac

    echo "==> recovering $VER tables"
    MPQCAT="$MPQCAT" D2PATCH="$D2PATCH" python3 tools/re/patchdata.py "$INST" \
        "$BASE/d2exp.mpq,$BASE/d2data.mpq" "$OUT/data/global/excel"
    rm -rf "$OUT/data/global/excel/.patchdata"
    du -sh "$OUT" | sed 's/^/==> engine layer: /'
    ;;
*) usage ;;
esac
