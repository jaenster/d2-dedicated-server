#!/bin/bash
# build.sh — build msvcr100d.dll + msvcp100d.dll SHIMS that satisfy blizzhackers'
# DEBUG-build mozjs.dll (which imports the VS2010 DEBUG CRT) by forwarding to the
# RELEASE CRT already present in the wine prefix. This lets D2BS (which dynamically
# links that debug mozjs) survive JS_NewRuntime instead of throwing 0xe06d7363.
#
# Why this is needed: the shipped D2BS.dll imports 601 MSVC-mangled ?JS_*@@ symbols
# from mozjs.dll. The only symbol-matching mozjs on disk is a DEBUG build needing
# MSVCR100D/MSVCP100D — not in wine. All but 4 of its CRT imports exist verbatim in
# the release CRT (pure forwarders); the 4 debug-only ones get thin wrappers:
#   _malloc_dbg/_free_dbg -> release malloc/free ; _CrtSetReportMode/_CrtSetCheckCount -> no-op.
#
# Requires: i686-w64-mingw32-gcc/dlltool/objdump. Regenerates the .def forward lists
# from the ACTUAL mozjs import table so it stays correct if the mozjs build changes.
set -euo pipefail
cd "$(dirname "$0")"
: "${MOZJS:?set MOZJS=/path/to/the/debug mozjs.dll (the 601-symbol MSVC build)}"
PFX="${WINEPREFIX:-$HOME/.wine}"
RCRT="$PFX/drive_c/windows/syswow64/msvcr100.dll"
PCRT="$PFX/drive_c/windows/syswow64/msvcp100.dll"
[ -f "$RCRT" ] && [ -f "$PCRT" ] || { echo "release CRT not in $PFX (winetricks vcrun2010)"; exit 1; }

OD=i686-w64-mingw32-objdump
# Extract mozjs's imported symbols from MSVCR100D / MSVCP100D (import-table member names).
"$OD" -p "$MOZJS" | sed -n '/The Import Tables/,/There is an export table/p' | awk '
  /DLL Name: MSVCR100D.dll/{c="R";next} /DLL Name: MSVCP100D.dll/{c="P";next} /DLL Name:/{c="";next}
  c!="" && /<none>/ {print c, $NF}' | sort -u > .imp
grep '^R ' .imp | sed 's/^R //' | sort -u > .r_imp
grep '^P ' .imp | sed 's/^P //' | sort -u > .p_imp
"$OD" -p "$RCRT" | awk '/\[ *[0-9]+\]/{print $NF}' | sort -u > .r_exp
"$OD" -p "$PCRT" | awk '/\[ *[0-9]+\]/{print $NF}' | sort -u > .p_exp

# R100D: forward the ones present in release; wrap the 4 debug-only ones.
comm -12 .r_imp .r_exp > .r_fwd
{ echo "LIBRARY msvcr100d.dll"; echo "EXPORTS"
  while read -r s; do printf '%s = msvcr100.%s\n' "$s" "$s"; done < .r_fwd
  echo "_malloc_dbg"; echo "_free_dbg"; echo "_CrtSetReportMode"; echo "_CrtSetCheckCount"; } > msvcr100d.def
{ echo "LIBRARY msvcp100d.dll"; echo "EXPORTS"
  while read -r s; do printf '%s = msvcp100.%s\n' "$s" "$s"; done < .p_imp; } > msvcp100d.def

i686-w64-mingw32-gcc -m32 -O2 -c msvcr100d_wrap.c -o msvcr100d_wrap.o
i686-w64-mingw32-dlltool -d /dev/stdin -l libmsvcr100.a <<'EOF'
LIBRARY msvcr100.dll
EXPORTS
malloc
free
EOF
i686-w64-mingw32-gcc -m32 -shared -o msvcr100d.dll msvcr100d.def msvcr100d_wrap.o \
    -nostdlib -Wl,--enable-stdcall-fixup -L. -lmsvcr100 -lkernel32
i686-w64-mingw32-gcc -m32 -shared -o msvcp100d.dll msvcp100d.def \
    -nostdlib -Wl,--enable-stdcall-fixup -lkernel32
rm -f .imp .r_imp .p_imp .r_exp .p_exp .r_fwd libmsvcr100.a msvcr100d_wrap.o
echo "built msvcr100d.dll + msvcp100d.dll"
