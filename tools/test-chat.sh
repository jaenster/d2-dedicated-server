#!/bin/bash
# test-chat.sh — prove a channel is the whole realm, and that it stops at its own edge.
#
# Two realmd instances against one redis. Alice listens on instance A; Bob talks in her channel
# from instance B; Eva talks in a DIFFERENT channel from instance B. Alice must hear Bob and must
# not hear Eva.
#
# The negative half is the point. Cross-instance chat that leaks would look perfect in a test that
# only checks Bob arrives — every message reaching everyone passes that. The failure it guards is
# a channel key that is ignored on the receiving side, which is a one-character mistake.
#
# Uses the real wire client (../clientless), not the harness's own, so this exercises the bytes a
# 1.14d client would send.
#
#   ./tools/test-chat.sh
#
# Needs the dev stores up (./run-stack.sh does that, or docker compose -f deploy/compose.dev.yaml).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6390}"
PG_DSN="${PG_DSN:-postgres://realmd:realmd@127.0.0.1:55432/realmd}"
CLIENTLESS="${CLIENTLESS:-$ROOT/../clientless/zig-out/bin/clientless}"
WORK="${WORK:-$ROOT/.stack/chat}"
A_PORT=6412
B_PORT=6422

bold=$'\033[1m'; green=$'\033[32m'; red=$'\033[31m'; off=$'\033[0m'
say() { echo "${bold}==> $*${off}"; }
ok()  { echo "  ${green}ok${off}   $*"; }
bad() { echo "  ${red}FAIL${off} $*"; }

[ -x "$CLIENTLESS" ] || { bad "no clientless at $CLIENTLESS (build it there first)"; exit 1; }
mkdir -p "$WORK"; rm -f "$WORK"/*.log

cleanup() { [ -n "${A_PID:-}" ] && kill "$A_PID" 2>/dev/null; [ -n "${B_PID:-}" ] && kill "$B_PID" 2>/dev/null; }
trap cleanup EXIT

start_realmd() { # start_realmd <instance> <port> <logfile>
  REALMD_INSTANCE="$1" REALMD_BNET_PORT="$2" REALMD_HEALTH_PORT="$(( $2 + 100 ))" \
  REALMD_REDIS_ADDR="$REDIS_ADDR" REALMD_PG_DSN="$PG_DSN" \
  REALMD_REALM_ADDR=127.0.0.1 REALMD_GAME_ADDR=127.0.0.1 REALMD_PERMISSIVE_AUTH=1 \
    ./zig-out/bin/realmd > "$3" 2>&1 &
  echo $!
}

await_port() { # await_port <port> <seconds>
  local t=0
  while [ "$t" -lt "$2" ]; do
    nc -z 127.0.0.1 "$1" 2>/dev/null && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

say "two realmd instances on one redis"
A_PID=$(start_realmd chatA "$A_PORT" "$WORK/realmdA.log")
B_PID=$(start_realmd chatB "$B_PORT" "$WORK/realmdB.log")
await_port "$A_PORT" 20 || { bad "instance A never bound :$A_PORT"; sed -n '1,20p' "$WORK/realmdA.log"; exit 1; }
await_port "$B_PORT" 20 || { bad "instance B never bound :$B_PORT"; sed -n '1,20p' "$WORK/realmdB.log"; exit 1; }
ok "A on :$A_PORT (pid $A_PID), B on :$B_PORT (pid $B_PID)"

# Unique per run, so a stale log can never satisfy the assertions.
STAMP="$$$RANDOM"
BOB_MSG="bob-says-$STAMP"
EVA_MSG="eva-says-$STAMP"
LOBBY="Diablo II"
ELSEWHERE="Harrogath"

say "alice listens on A; bob talks in her channel from B; eva talks in '$ELSEWHERE' from B"
# Alice first and listening longest: she has to be in the channel before either of them speaks.
"$CLIENTLESS" 127.0.0.1 --port "$A_PORT" D2XP 1.14.3.71 --login alice:alice \
    --channel "$LOBBY" --listen 20 > "$WORK/alice.log" 2>&1 &
sleep 7
"$CLIENTLESS" 127.0.0.1 --port "$B_PORT" D2XP 1.14.3.71 --login bob:bob \
    --channel "$LOBBY" --say "$BOB_MSG" --say-after 4 --listen 12 > "$WORK/bob.log" 2>&1 &
"$CLIENTLESS" 127.0.0.1 --port "$B_PORT" D2XP 1.14.3.71 --login eva:eva \
    --channel "$ELSEWHERE" --say "$EVA_MSG" --say-after 4 --listen 12 > "$WORK/eva.log" 2>&1 &
wait

fails=0
say "what alice heard"
if grep -q "$BOB_MSG" "$WORK/alice.log"; then
  ok "alice heard bob — channel talk crossed from instance B to instance A"
else
  bad "alice never heard bob: cross-instance channel talk did not arrive"; fails=$((fails+1))
fi

if grep -q "$EVA_MSG" "$WORK/alice.log"; then
  bad "alice heard eva, who is in '$ELSEWHERE' — the channel key is being ignored on delivery"
  fails=$((fails+1))
else
  ok "alice did not hear eva — a channel stops at its own edge"
fi

# Alice must be told Bob arrived. Asserted on the EVENT, not on a name: a chat identity is the
# CHARACTER, and these fixture accounts happen to share one, so the name proves nothing here.
if grep -qE "«JOIN»" "$WORK/alice.log"; then
  ok "alice was told someone joined her channel, from the other instance"
else
  bad "alice never saw the join — EID_JOIN is not crossing instances"; fails=$((fails+1))
fi

say "the roster bob was shown when he joined"
# Bob is the only member of that channel on HIS instance, so any user his list names is one this
# instance does not hold — which is the whole point of the shared roster. Eva is the control: she
# joined an empty channel from the same instance and must be shown nobody at all, so a SHOWUSER
# for Bob cannot be dismissed as the client inventing one.
bob_users=$(grep -cE "«SHOWUSER»" "$WORK/bob.log")
eva_users=$(grep -cE "«SHOWUSER»" "$WORK/eva.log")
if [ "$bob_users" -ge 1 ] && [ "$eva_users" = 0 ]; then
  ok "bob's user list named $bob_users member held by the other instance; eva's empty channel named 0"
else
  bad "bob was shown $bob_users remote member(s) and eva $eva_users — the shared roster is wrong"
  fails=$((fails+1))
fi

say "and the other direction"
if grep -q "$EVA_MSG" "$WORK/eva.log" && ! grep -q "$BOB_MSG" "$WORK/eva.log"; then
  ok "eva saw her own line and none of bob's"
else
  bad "eva's channel is not isolated from bob's"; fails=$((fails+1))
fi

say "result"
if [ "$fails" = 0 ]; then
  ok "chat is one room across instances, and only one room"
  echo "  logs in $WORK"
  exit 0
fi
bad "$fails check(s) failed — logs in $WORK"
exit 1
