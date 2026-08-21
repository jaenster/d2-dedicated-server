#!/bin/bash
# engine-e2e-ci.sh <engine> <expect> — run ONE pre-1.14 engine end to end, in containers.
#
# The containerised twin of tools/e2e-engines.sh, and it applies the same rule from the same file:
# `world` must reach a non-empty world, `boot` must publish itself and keep a clean log, and
# `broken` must fail the way deploy/e2e-engines.txt says it fails — including failing the run if it
# starts working, because a record nobody updates is a record nobody trusts.
#
# Each engine gets its own compose project, network and subnet and publishes no host ports, so
# several can run at once without fighting over 6112/4000. That is not tidiness: these are wine
# containers and two racing for a port fail in ways that read as protocol bugs.
#
#   D2GS_IMAGE=ghcr.io/jaenster/d2gs:1.10f-<sha> deploy/engine-e2e-ci.sh 1.10f world
#
# Env:
#   D2GS_IMAGE   (required) the engine image to test
#   SUBNET_OCTET  default 29   second octet of the /24 this run gets
set -uo pipefail
cd "$(dirname "$0")/.."

ENGINE="${1:?usage: engine-e2e-ci.sh <engine> <expect>}"
EXPECT="${2:?usage: engine-e2e-ci.sh <engine> <expect>}"
IMAGE="${D2GS_IMAGE:?set D2GS_IMAGE to the engine image under test}"
OCT="${SUBNET_OCTET:-29}"

TAG="$(printf '%s' "$ENGINE" | tr -d .)"
PROJ="d2e2e-$TAG"
export D2_ENGINE="$ENGINE"
export D2_SUBNET="172.$OCT.0.0/24"
export D2_REALM_IP="172.$OCT.0.10"
export D2_GS_IP="172.$OCT.0.20"
export D2_GSID="$((10#$(printf '%s' "$TAG" | tr -cd '0-9')))"

COMPOSE="docker compose -p $PROJ -f deploy/compose.yaml -f deploy/compose.engine.yaml --profile engine"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

cleanup() { $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

# compose.engine.yaml names the engine image `d2gs:<engine>`; the one under test is whatever the
# build produced, so it is retagged rather than the compose file being rewritten per run.
docker tag "$IMAGE" "d2gs:$ENGINE" || { bad "cannot tag $IMAGE"; exit 1; }

say "$ENGINE  (expects: $EXPECT)  subnet $D2_SUBNET"
$COMPOSE up -d --no-build redis postgres realmd gs-engine || { bad "compose up failed"; exit 1; }

# Registration, not a sleep: until the server publishes itself the realm has nothing to hand out.
up=0
for _ in $(seq 1 90); do
    if $COMPOSE exec -T redis redis-cli EXISTS "realmd:gs:$(printf '%x' "$D2_GSID")" 2>/dev/null | grep -q 1; then
        up=1; break
    fi
    sleep 1
done

$COMPOSE logs --no-log-prefix gs-engine > /tmp/gs-$TAG.log 2>&1 || true

if [ "$up" != 1 ]; then
    if [ "$EXPECT" = broken ]; then
        ok "still broken, as deploy/e2e-engines.txt records"
        grep -a -m1 -E 'assert from|halt from|ACCESS VIOLATION|unimplemented function' /tmp/gs-$TAG.log | cut -c1-160
        exit 0
    fi
    bad "$ENGINE never published itself"
    tail -30 /tmp/gs-$TAG.log
    exit 1
fi
if [ "$EXPECT" = broken ]; then
    bad "recorded as broken, but it booted. Promote it in deploy/e2e-engines.txt."
    exit 1
fi
ok "published itself"

rc=0
if [ "$EXPECT" = world ]; then
    $COMPOSE build stress-e2e >/dev/null || { bad "cannot build the test client"; exit 1; }
    # One client, one game. Throughput is not what this measures — whether THIS engine hands a
    # client a world is.
    if $COMPOSE run --rm stress-e2e --host realmd --rounds 1 --clients 1 --runs 1 \
            --account "e2e$TAG:pw" --chars "Eng$(printf '%s' "$TAG" | tr '0123456789' 'abcdefghij')x:1"; then
        ok "reached a world"
    else
        bad "never reached a world"
        rc=1
    fi
fi

# The server's own account of the same run. A clean client result over a log full of halts usually
# means the client gave up before the server reached the part that broke.
$COMPOSE logs --no-log-prefix gs-engine > /tmp/gs-$TAG.log 2>&1 || true
bash deploy/assert-gs-log-clean.sh /tmp/gs-$TAG.log || rc=1
exit $rc
