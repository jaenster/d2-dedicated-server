#!/bin/bash
# assert-gs-log-clean.sh <gs-log>... — fail if a game server reported a failure about itself.
#
# The client's verdict is only half a test. Every failure that cost this project a week presented
# to the client as one thing — "the join is accepted and then nothing arrives" — while the server
# said exactly what was wrong in its own log and nobody was reading it. So the server's account is
# checked too, and it is checked for the failures it now knows how to name.
#
# Each pattern below is here because it was, at least once, the whole bug:
#
#   ENGINE HALT / ENGINE ASSERT   the engine stopping itself. 1.13c halted in DRLG for want of
#                                 Patch_D2.mpq and the run still looked like a client timeout.
#   ACCESS VIOLATION / segfault   a call through a slot we never filled — the 1.13c callback tail.
#   unimplemented function        wine ABORTS on one. Fog @10265. Presents as 0% CPU, not an error.
#   BITMANIP_Write x              the runaway-write detector: a stream that is written a million
#                                 times has a caller whose loop is not terminating.
#   Failed SrvLockGame            the character arrived while the game lock was held.
#   refused / no free slot        the server declining work it should have taken.
#
# Exit 0 when the log is clean, 1 otherwise, printing the offending lines.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: assert-gs-log-clean.sh <gs-log>..." >&2; exit 2; }

# Anchored where it matters: `refused` alone appears in ordinary token checks.
PATTERNS='\*\*\* ENGINE HALT \*\*\*
\*\*\* ENGINE ASSERT \*\*\*
ACCESS VIOLATION
Segmentation fault
Illegal instruction
unimplemented function
BITMANIP_Write x
Failed SrvLockGame
CREATEGAME refused by the engine
no free character slot
FATAL
panic:'

rc=0
for log in "$@"; do
    [ -f "$log" ] || { echo "  no such log: $log"; rc=1; continue; }
    # With trailing context: the marker line names nothing on its own — the reason ("assert from
    # 0x...: <msg> / <file> / <line>") is the line the reporter prints after it, and a failure whose
    # cause is one line out of reach is a CI run someone has to reproduce by hand to learn anything.
    hits=$(grep -a -n -A2 -E "$(printf '%s' "$PATTERNS" | paste -sd'|' -)" "$log" 2>/dev/null | head -60)
    if [ -n "$hits" ]; then
        echo "  $log — the server reported a failure about itself:"
        printf '%s\n' "$hits" | sed 's/^/      /'
        rc=1
    else
        echo "  $log — clean"
    fi
done
exit $rc
