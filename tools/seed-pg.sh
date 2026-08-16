#!/bin/bash
# seed-pg.sh — put the local test characters into postgres.
#
# Switching the durable store does not migrate what is already stored, so a realm pointed at a
# fresh postgres has no characters and the login looks broken when it is only empty. This fills it.
#
# It does not write to postgres directly. It stages each character into redis and marks it dirty,
# and realmd's own flush worker moves it across — the same path a real save takes, so seeding
# exercises the machinery rather than going around it.
#
#   ./tools/seed-pg.sh                     # every character under realmd-data/chars
#   ACCOUNT=tester ./tools/seed-pg.sh      # just one account's
#
# Needs redis and postgres up (docker compose -f deploy/compose.dev.yaml up -d) and a realmd
# running with REALMD_DURABLE_STORE=pg — DURABLE=pg ./run-stack.sh does that.
set -euo pipefail
cd "$(dirname "$0")/.."

REDIS_CONTAINER="${REDIS_CONTAINER:-d2gs-dev-redis}"
PG_CONTAINER="${PG_CONTAINER:-d2gs-dev-postgres}"
DATA_DIR="${REALMD_DATA_DIR:-$PWD/realmd-data}"
ONLY="${ACCOUNT:-}"

R() { docker exec "$REDIS_CONTAINER" redis-cli "$@"; }

staged=0
shopt -s nullglob
for f in "$DATA_DIR"/chars/*/*.d2s; do
    acct=$(basename "$(dirname "$f")")
    name=$(basename "$f" .d2s)
    [ -n "$ONLY" ] && [ "$acct" != "$ONLY" ] && continue

    # -x takes the value from stdin, which is the only way to get bytes through redis-cli intact:
    # a .d2s is full of NULs and newlines and would not survive being an argument.
    docker exec -i "$REDIS_CONTAINER" redis-cli -x SET "realmd:char:$acct:$name" < "$f" >/dev/null
    R SADD "realmd:chars:$acct" "$name" >/dev/null
    R INCR "realmd:charver:$acct/$name" >/dev/null
    R SADD realmd:dirty "$acct/$name" >/dev/null
    echo "  staged $acct/$name"
    staged=$((staged + 1))
done

[ "$staged" = 0 ] && { echo "no characters found under $DATA_DIR/chars"; exit 1; }

echo "waiting for realmd's flush worker to move $staged character(s)..."
for _ in $(seq 1 30); do
    [ "$(R SCARD realmd:dirty)" = "0" ] && break
    sleep 1
done
left=$(R SCARD realmd:dirty)
if [ "$left" != "0" ]; then
    echo "FAIL: $left still dirty — is a realmd running with REALMD_DURABLE_STORE=pg?" >&2
    exit 1
fi

echo
docker exec "$PG_CONTAINER" psql -U realmd -d realmd \
    -c "select account, name, octet_length(d2s) as bytes from chars order by account, name;"
