#!/bin/bash
# symbolize.sh — turn d2gs panic addresses back into file:line.
#
# The GS logs panics as image-relative addresses (`d2gs+0x1a2b3`) because the DLL is
# injected and lands wherever wine puts it; the raw address means nothing tomorrow.
# This resolves them against the PDB that was built alongside the DLL.
#
#   ./tools/symbolize.sh .stack/gs.log        # every PANIC line in a log
#   grep PANIC .stack/gs.log | ./tools/symbolize.sh
#   ./tools/symbolize.sh 0x1a2b3 0x1c400      # bare RVAs
#
# The PDB must match the DLL that was running. If you rebuilt since the crash, the
# line numbers are fiction — rebuilding is what invalidates them, not time.
set -uo pipefail
cd "$(dirname "$0")/.."

DLL="${D2GS_DLL:-zig-out/bin/d2gs.dll}"
SYM="${LLVM_SYMBOLIZER:-llvm-symbolizer}"

command -v "$SYM" >/dev/null || { echo "error: $SYM not found (brew install llvm)" >&2; exit 1; }
[ -f "$DLL" ] || { echo "error: no DLL at $DLL (zig build dlls)" >&2; exit 1; }
[ -f "${DLL%.dll}.pdb" ] || echo "warning: no ${DLL%.dll}.pdb next to the DLL — expect names only" >&2

# One RVA -> "func  file:line", collapsed onto a single line per frame.
resolve() {
  "$SYM" --obj="$DLL" --relative-address --pretty-print "$1" 2>/dev/null |
    head -1 | sed 's/^/    /'
}

# Bare addresses on the command line: resolve them and stop.
if [ "$#" -gt 0 ] && printf '%s' "$1" | grep -qE '^0x[0-9a-fA-F]+$'; then
  for a in "$@"; do printf '%s\n' "$a"; resolve "$a"; done
  exit 0
fi

# Otherwise read a log (file argument or stdin) and expand every `d2gs+0x...` in it.
{ [ "$#" -gt 0 ] && cat "$@" || cat; } | while IFS= read -r line; do
  case "$line" in
    *PANIC*) ;;
    *) continue ;;
  esac
  printf '%s\n' "$line"
  # A line carries any number of frames; resolve each in the order they were logged.
  printf '%s\n' "$line" | grep -oE 'd2gs\+0x[0-9a-f]+' | while IFS= read -r frame; do
    resolve "${frame#d2gs+}"
  done
done
