#!/bin/bash
# check-saves.sh — every character the realm holds is still a valid save.
#
# Run after a stress pass, or any time the save path has been touched. It exists because the
# stress harness cannot see this class of failure: a cache that truncated every character to 1024
# bytes reported 5/5 rounds clean, because a round only asks whether a client reached the world —
# not whether what it loaded was intact.
#
# A .d2s carries its own length and checksum, so a corrupt one is provable on its own. Both copies
# are checked: the live one in redis and the one in the store of record, and they must agree.
#
#   tools/check-saves.sh
#
# Exits non-zero on the first bad save, naming it.
set -uo pipefail
cd "$(dirname "$0")/.."

REDIS_CONTAINER="${REDIS_CONTAINER:-d2gs-dev-redis}"
DATA_DIR="${REALMD_DATA_DIR:-$PWD/realmd-data}"
CHECK="./tools/checksave.py"

bad=0
checked=0

echo "==> characters in the store of record"
shopt -s nullglob
for f in "$DATA_DIR"/chars/*/*.d2s; do
    checked=$((checked + 1))
    "$CHECK" "$f" || bad=1
done
[ "$checked" = 0 ] && echo "    (none on disk)"

echo "==> characters cached in redis, and whether they match"
for key in $(docker exec "$REDIS_CONTAINER" redis-cli --scan --pattern 'realmd:char:*' 2>/dev/null); do
    # realmd:char:<account>:<name>
    acct="${key#realmd:char:}"; acct="${acct%%:*}"
    name="${key##*:}"
    checked=$((checked + 1))

    # The blob has to come out byte-exact or the checksum is meaningless, so it goes to a file
    # rather than a shell variable. redis-cli --raw appends a newline of its own; rather than
    # guess whether a trailing byte is ours or its, take exactly the length redis reports.
    tmp=$(mktemp)
    len=$(docker exec "$REDIS_CONTAINER" redis-cli STRLEN "$key" 2>/dev/null | tr -d '\r')
    docker exec "$REDIS_CONTAINER" sh -c "redis-cli --raw GET '$key'" 2>/dev/null | head -c "$len" > "$tmp"

    if ! "$CHECK" --stdin "redis:$acct/$name" < "$tmp"; then
        bad=1
    fi

    disk="$DATA_DIR/chars/$acct/$name.d2s"
    if [ -f "$disk" ]; then
        # They may legitimately differ while a save is still dirty — that is the flush worker's
        # backlog, not corruption. Anything else means one of the two copies is wrong.
        if ! cmp -s "$tmp" "$disk"; then
            if [ "$(docker exec "$REDIS_CONTAINER" redis-cli SISMEMBER realmd:dirty "$acct/$name")" = "1" ]; then
                echo "     ~   redis:$acct/$name differs from disk, but is still dirty (flush pending)"
            else
                echo "BAD  redis:$acct/$name differs from disk and is NOT dirty — one copy is stale"
                bad=1
            fi
        fi
    fi
    rm -f "$tmp"
done

echo
if [ "$bad" = 0 ]; then
    echo "PASS — $checked copies checked, all valid and consistent"
else
    echo "FAIL — at least one save is corrupt or inconsistent"
fi
exit "$bad"
