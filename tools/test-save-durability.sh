#!/bin/bash
# test-save-durability.sh — a save left behind by a realmd that died must not be lost.
#
# The character lives in redis and postgres is the store of record, so there is always a window
# where the only copy of a save is in redis. If the instance that was going to move it dies in that
# window, the next instance has to finish the job. Nothing else in this system loses a player's
# progress permanently, so this is the one worth testing rather than reasoning about.
#
#   tools/test-save-durability.sh
#
# Leaves the realm as it found it. Needs the dev stores up (./run-stack.sh brings them).
set -euo pipefail
cd "$(dirname "$0")/.."

REDIS_CONTAINER="${REDIS_CONTAINER:-d2gs-dev-redis}"
PG_CONTAINER="${PG_CONTAINER:-d2gs-dev-postgres}"
ACCOUNT="${ACCOUNT:-tester}"
CHAR="${CHAR:-DurabilityProbe}"
DATA_DIR="${REALMD_DATA_DIR:-$PWD/realmd-data}"

R() { docker exec "$REDIS_CONTAINER" redis-cli "$@"; }
# Size of the character in the store of record, or empty if it is not there at all.
PGSIZE() {
  docker exec "$PG_CONTAINER" psql -U realmd -d realmd -tAc \
    "select octet_length(d2s) from chars where account='$ACCOUNT' and name='$CHAR'" 2>/dev/null | tr -d '[:space:]'
}
fail() { echo "FAIL: $*" >&2; exit 1; }

# A probe character of its own, so a real one is never the thing being overwritten.
cleanup() {
  R DEL "realmd:char:$ACCOUNT:$CHAR" >/dev/null 2>&1 || true
  R DEL "realmd:charver:$ACCOUNT/$CHAR" >/dev/null 2>&1 || true
  R SREM realmd:dirty "$ACCOUNT/$CHAR" >/dev/null 2>&1 || true
  R SREM "realmd:chars:$ACCOUNT" "$CHAR" >/dev/null 2>&1 || true
  docker exec "$PG_CONTAINER" psql -U realmd -d realmd -qc \
    "delete from chars where account='$ACCOUNT' and name='$CHAR'" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo "==> staging a save that reached redis but not the store of record"
# Nothing is flushing yet — this test starts its own realmd below, after the save is staged, which
# is what makes the save genuinely orphaned rather than racing a live worker.
BYTES=4096
PAYLOAD=$(head -c "$BYTES" /dev/zero | tr '\0' 'X')
R SET "realmd:char:$ACCOUNT:$CHAR" "$PAYLOAD" >/dev/null
R SADD "realmd:chars:$ACCOUNT" "$CHAR" >/dev/null
R INCR "realmd:charver:$ACCOUNT/$CHAR" >/dev/null
R SADD realmd:dirty "$ACCOUNT/$CHAR" >/dev/null

[ "$(R STRLEN "realmd:char:$ACCOUNT:$CHAR")" = "$BYTES" ] || fail "redis did not take the staged save"
[ "$(R SISMEMBER realmd:dirty "$ACCOUNT/$CHAR")" = "1" ] || fail "the save was not marked dirty"
[ -z "$(PGSIZE)" ] || fail "the store of record already has it; the test proves nothing"
echo "    redis has $BYTES bytes, marked dirty, postgres has nothing"

echo "==> a fresh realmd starts and should finish what the dead one did not"
# realmd is started DIRECTLY rather than through run-stack.sh. The flush worker lives in realmd and
# touches no game server, so pulling in the whole stack would only add a smoke test that plays a
# real game — which needs a live GS and fails for reasons that have nothing to do with durability.
REALMD_BIND=127.0.0.1 REALMD_REALM_ADDR=127.0.0.1 REALMD_GAME_ADDR=127.0.0.1 \
  REALMD_PG_DSN="${PG_DSN:-postgres://realmd:realmd@127.0.0.1:55432/realmd}" \
  REALMD_REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6390}" REALMD_DATA_DIR="$DATA_DIR" \
  REALMD_BNET_PORT=16112 \
  REALMD_HEALTH_PORT=18099 \
  ./zig-out/bin/realmd >/tmp/durability-realmd.log 2>&1 &
REALMD_PID=$!
# Its own ports, so this never disturbs a stack someone else is running.
cleanup_all() { kill "$REALMD_PID" 2>/dev/null || true; cleanup; }
trap cleanup_all EXIT

for _ in $(seq 1 30); do
  nc -z 127.0.0.1 16112 2>/dev/null && break
  sleep 1
done
nc -z 127.0.0.1 16112 2>/dev/null || fail "realmd never came up (see /tmp/durability-realmd.log)"

for _ in $(seq 1 30); do
  [ "$(R SISMEMBER realmd:dirty "$ACCOUNT/$CHAR")" = "0" ] && break
  sleep 1
done

[ "$(R SISMEMBER realmd:dirty "$ACCOUNT/$CHAR")" = "0" ] || fail "still dirty after 30s — nothing picked it up"
got=$(PGSIZE)
[ -n "$got" ] || fail "the character never reached the store of record"
[ "$got" = "$BYTES" ] || fail "persisted $got bytes, expected $BYTES — the save was altered on the way"

echo "    recovered: $got bytes in postgres, dirty flag cleared"
echo
echo "PASS — a save orphaned by a dead instance is finished by the next one"
