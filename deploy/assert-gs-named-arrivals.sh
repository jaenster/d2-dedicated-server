#!/bin/bash
# assert-gs-named-arrivals.sh <gs-log> <character> [wait-seconds]
#
# Did the game server tell the realm, BY NAME, that this character entered its game and later left
# it? The realm keeps a join's character claim pending until that ENTER and frees it on the LEAVE;
# a server that reports head counts alone leaves a player who abandoned a join unable to play until
# the game closes. The departure is noticed a few seconds after the client goes, so a live log is
# polled for up to [wait-seconds] (default 15).
set -uo pipefail
LOG="${1:?usage: assert-gs-named-arrivals.sh <gs-log> <character> [wait-seconds]}"
CHAR="${2:?usage: assert-gs-named-arrivals.sh <gs-log> <character> [wait-seconds]}"
WAIT="${3:-15}"

# d2host:      "d2host: enter 'Name' game 3, 1 player(s)"
# d2gs-native: "d2gs-native: enter \"Name\" game 3, 1 player(s)"
seen() { grep -a -q -E "(d2host|d2gs-native): $1 ['\"]$CHAR['\"] game [0-9]+" "$LOG"; }

t=0
while [ "$t" -lt "$WAIT" ]; do
    seen enter && seen leave && break
    sleep 1; t=$((t+1))
done

rc=0
if seen enter; then
    printf '  \033[32mok\033[0m   arrival of %s reported by name\n' "$CHAR"
else
    printf '  \033[31mFAIL\033[0m no named ENTER for %s in %s\n' "$CHAR" "$LOG"; rc=1
fi
if seen leave; then
    printf '  \033[32mok\033[0m   departure of %s reported by name\n' "$CHAR"
else
    printf '  \033[31mFAIL\033[0m no named LEAVE for %s in %s\n' "$CHAR" "$LOG"; rc=1
fi
exit $rc
