#!/bin/bash
# make-minimal-engine.sh — build the game tree for the pre-1.14 engines, in two layers.
#
#   tools/make-minimal-engine.sh base         <out>      the expansion archives, shared by 1.07+
#   tools/make-minimal-engine.sh base-classic <out>      the classic archive, for 1.00/1.06b
#   tools/make-minimal-engine.sh engine <ver> <out>      that engine's DLLs and tables
#   tools/make-minimal-engine.sh from-install <dir> <out>  both layers, out of a finished install
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
# `from-install` takes a game directory that blizzard-legacy-dl already built and makes a tree out
# of it in one step, with no patch installers and no 1.07 base to point at. It is not a shortcut:
# that tool applies the same Ptc deltas to the same 1.07 files and its DLLs come out byte-identical
# to the ones `engine` builds here, which is checked rather than assumed. Two things are better
# that way round:
#
#   * Patch_D2.mpq is the ERA's. `engine` has only the 1.14d one to minimise, and hands it to every
#     engine from 1.10 on regardless of era; an install carries the one its own patch.lst rebuilt.
#   * One patch chain instead of two. Both used to derive the same DLLs by separate code, and the
#     failure mode of that is not a build error — it is one of them going quietly stale.
#
# That first point changes a rule further down this file. `engine` withholds Patch_D2.mpq from
# everything before 1.10 because the 1.14d-era one ACCESS VIOLATIONs a 1.09b boot — but that is a
# fact about THAT archive, not about the file. Given its own, 1.09b boots and serves: measured at
# 195 packets / 34 units through tools/e2e-engines.sh, the same as it manages with none. So this
# mode ships whatever the install built and does not gate on era.
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

    # Patch_D2.mpq is ERA-SPECIFIC and belongs to the engine, not to the shared base. The one we
    # have is 1.14d's, and each side of the 1.10 line reacts to it in the opposite way -- measured,
    # not assumed:
    #
    #   1.10f  without it: assert "pbData" DataTbls.cpp:0x8b3
    #   1.13c  without it: halts in level generation, DrlgLogic.cpp:876, the moment a client enters
    #   1.09b  WITH it:    ACCESS VIOLATION during boot; without it, it reaches the tick loop
    #
    # So it is required from 1.10 on and must be kept away from anything older. Putting it in the
    # shared base layer instead fixes 1.13c and breaks 1.09b, which is a trade nobody would choose
    # on purpose -- and one that presents as "the older engines regressed", not as a data problem.
    case "$VER" in
        1.10*|1.11*|1.12*|1.13*|1.14*)
            if [ -f "$BASE/Patch_D2.mpq" ]; then
                echo "==> minimising Patch_D2.mpq (required from 1.10 on)"
                "$MPQMIN" ${D2_LISTFILE:+--listfile $D2_LISTFILE} "$BASE/Patch_D2.mpq" "$OUT/Patch_D2.mpq"
            else
                echo "!!  no Patch_D2.mpq in $BASE, and $VER needs one: it will assert in DataTbls"
                echo "!!  or halt in DRLG the first time a client enters a game."
            fi
            ;;
        *)
            echo "==> no Patch_D2.mpq for $VER (pre-1.10; the 1.14d-era one faults it during boot)"
            ;;
    esac

    echo "==> recovering $VER tables"
    MPQCAT="$MPQCAT" D2PATCH="$D2PATCH" python3 tools/re/patchdata.py "$INST" \
        "$BASE/d2exp.mpq,$BASE/d2data.mpq" "$OUT/data/global/excel"
    rm -rf "$OUT/data/global/excel/.patchdata"
    du -sh "$OUT" | sed 's/^/==> engine layer: /'
    ;;
from-install)
    SRC="${1:?usage: make-minimal-engine.sh from-install <install-dir> <out>}"
    OUT="${2:?usage: make-minimal-engine.sh from-install <install-dir> <out>}"
    [ -f "$SRC/d2data.mpq" ] || { echo "no d2data.mpq in $SRC — is that a game directory?"; exit 1; }
    mkdir -p "$OUT"

    # The archives, minimised the same way the shared base is. An install built from a 1.14b payload
    # carries a full (listfile), so unlike the older archives nothing here needs one supplied.
    for a in d2data.mpq d2exp.mpq; do
        [ -f "$SRC/$a" ] || { echo "==> no $a (classic install)"; continue; }
        echo "==> minimising $a"
        "$MPQMIN" ${D2_LISTFILE:+--listfile $D2_LISTFILE} "$SRC/$a" "$OUT/$a"
    done

    # Already at the right version: these were patched on the way in, so there is nothing to apply.
    echo "==> taking the engine DLLs from the install"
    for m in D2Game.dll D2Common.dll D2Lang.dll D2CMP.dll Storm.dll; do
        [ -f "$SRC/$m" ] || { echo "   $m: absent"; continue; }
        cp "$SRC/$m" "$OUT/$m" && echo "   $m ok"
    done

    # The install's own patch archive, which is this era's rather than 1.14d's. Named with the
    # capitalisation the shipped trees use: a case-insensitive filesystem hides the difference
    # locally and a Linux container is where it would surface.
    for p in patch_d2.mpq Patch_D2.mpq; do
        [ -f "$SRC/$p" ] || continue
        echo "==> minimising $p (era-correct, from the install)"
        "$MPQMIN" ${D2_LISTFILE:+--listfile $D2_LISTFILE} "$SRC/$p" "$OUT/Patch_D2.mpq"
        # An archive that names nothing minimises to nothing, and mpqmin says so in a line that
        # reads like every other. Refuse it here: from 1.10 on the engine needs this file, and an
        # empty one does not fail at boot -- it halts in level generation the first time a client
        # enters, which points at everything except the archive.
        # 2>&1 because mpqmin reports on stderr; without it this counts nothing and always fires.
        if [ "$("$MPQMIN" --list "$OUT/Patch_D2.mpq" 2>&1 | wc -l)" -eq 0 ]; then
            echo "!!  $p minimised to nothing: it names no members and no --listfile covered it."
            echo "!!  Refusing to ship an empty Patch_D2.mpq."
            exit 1
        fi
        break
    done

    du -sh "$OUT" | sed 's/^/==> tree: /'
    ;;
*) usage ;;
esac
