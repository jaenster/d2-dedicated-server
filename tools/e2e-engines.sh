#!/bin/bash
# e2e-engines.sh — run EVERY pre-1.14 engine end to end and say which ones still serve a world.
#
# The regression this exists to catch is specific and has happened repeatedly: a fix for one engine
# quietly stops another from serving. Every instance looks the same from the client — the join is
# accepted and nothing arrives — so the only way to know is to run them all, every time, and
# compare against what each one is supposed to manage (deploy/e2e-engines.txt).
#
# Each engine gets its own gsid, its own game-server port, its own account and its own character, so
# a leftover from one cannot be mistaken for a defect in the next. They run one at a time on
# purpose: these are wine processes, and two racing for a port fail in ways that read as protocol
# bugs.
#
#   tools/e2e-engines.sh                 every engine in deploy/e2e-engines.txt
#   tools/e2e-engines.sh 1.10f 1.13c     only these
#   tools/e2e-engines.sh --keep          leave the last engine running for poking at
#
# Needs the realm already up: ./run-stack.sh brings up redis, postgres, realmd and d2ingress. It
# does NOT need run-stack's own 1.14d game server, and will refuse to run alongside one, because two
# servers in one realm means a create can land on either.
#
# Config (env or ./.env):
#   TREES        default ./.stack        one <TREES>/gs<tag> per engine, assembled by tools/make-minimal-engine.sh
#   REDIS_ADDR   default 127.0.0.1:6390
#   CLIENTLESS   default ../clientless/zig-out/bin/clientless
#   GS_PORT_BASE default 14100           engine N listens on GS_PORT_BASE+N
#   BOOT_WAIT    default 45              seconds to wait for a server to publish itself
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

TREES="${TREES:-$ROOT/.stack}"
REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6390}"
CLIENTLESS="${CLIENTLESS:-$ROOT/../clientless/zig-out/bin/clientless}"
GS_PORT_BASE="${GS_PORT_BASE:-14100}"
BOOT_WAIT="${BOOT_WAIT:-45}"
WINE="${WINE:-wine}"
LOG_DIR="${LOG_DIR:-$ROOT/.stack}"
SPEC="$ROOT/deploy/e2e-engines.txt"
KEEP=0

args=()
for a in "$@"; do case "$a" in
  --keep) KEEP=1 ;;
  -*) echo "unknown flag $a" >&2; exit 2 ;;
  *) args+=("$a") ;;
esac; done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

redis() { docker exec d2gs-dev-redis redis-cli "$@" 2>/dev/null; }

# The tree is named for the engine with the dots taken out: 1.09b -> gs109b.
treeof() { printf '%s/gs%s' "$TREES" "$(printf '%s' "$1" | tr -d .)"; }

[ -f "$SPEC" ] || die "no $SPEC"
command -v "$WINE" >/dev/null || die "no wine (set WINE=)"
[ -x "$CLIENTLESS" ] || die "no clientless at $CLIENTLESS (set CLIENTLESS=)"
redis PING >/dev/null || die "no redis at $REDIS_ADDR — run ./run-stack.sh first"
nc -z 127.0.0.1 6112 >/dev/null 2>&1 || die "realmd is not listening on :6112 — run ./run-stack.sh first"

# A second game server in the same realm makes a create land on either one, so a failure here would
# not be attributable to the engine under test. Refuse rather than produce a result nobody can trust.
if pgrep -f 'testgame' >/dev/null 2>&1; then
    die "run-stack's 1.14d game server is running; a create could land on it instead. Stop it first."
fi

# engine -> expectation, in file order.
ENGINES=(); EXPECT=()
while read -r name want _rest; do
    case "$name" in ''|\#*) continue ;; esac
    ENGINES+=("$name"); EXPECT+=("$want")
done < "$SPEC"

# A named subset still uses the expectation the file gives it.
if [ ${#args[@]} -gt 0 ]; then
    sel_n=(); sel_e=()
    for want in "${args[@]}"; do
        found=0
        for i in "${!ENGINES[@]}"; do
            [ "${ENGINES[$i]}" = "$want" ] && { sel_n+=("$want"); sel_e+=("${EXPECT[$i]}"); found=1; }
        done
        [ "$found" = 1 ] || die "$want is not in $SPEC"
    done
    ENGINES=("${sel_n[@]}"); EXPECT=("${sel_e[@]}")
fi

stop_gs() { pkill -9 -f 'd2host.exe' >/dev/null 2>&1; sleep 2; }

# Everything one engine leaves behind. Games and character claims especially: a leftover claim makes
# the NEXT engine's join fail with "held by game:N", which is a defect report about the wrong engine.
clean_realm() {
    for pat in 'realmd:game*' 'realmd:charlock*' 'realmd:gamechars:*'; do
        for k in $(redis --scan --pattern "$pat"); do redis DEL "$k" >/dev/null; done
    done
    # The harness's own characters too, and this is not tidiness. `--new-char` only takes effect on
    # an account that has NONE, so a character left by an earlier run is silently logged onto
    # instead — including one made under a name the engine rejects. That presents as the engine
    # refusing to serve, which is a defect report about the wrong thing entirely.
    #
    # BOTH stores: redis holds what is in flight, postgres is the record. Clearing only the redis
    # side leaves the character in `chars` and the realm hands it straight back.
    for pat in 'realmd:char:e2e*' 'realmd:chars:e2e*' 'realmd:charver:e2e*'; do
        for k in $(redis --scan --pattern "$pat"); do redis DEL "$k" >/dev/null; done
    done
    docker exec d2gs-dev-postgres psql -qtAX -U realmd -d realmd \
        -c "delete from chars where account like 'e2e%'" >/dev/null 2>&1 || true
    redis DEL realmd:gs >/dev/null
}

results=()
overall=0
idx=0
for i in "${!ENGINES[@]}"; do
    eng="${ENGINES[$i]}"; want="${EXPECT[$i]}"
    idx=$((idx+1))
    tag="$(printf '%s' "$eng" | tr -d .)"
    tree="$(treeof "$eng")"
    gsid=$((7000+idx))
    port=$((GS_PORT_BASE+idx))
    log="$LOG_DIR/e2e-$tag.log"
    acct="e2e$tag"
    # LETTERS ONLY, and the engine is the one that cares: the realm happily creates "E2efx" and
    # then SrvVerifyJoinGame refuses it as an "Invalid player name" at the join, which reads as the
    # engine not serving. Digits are mapped to letters rather than stripped, so 1.07 and 1.08 do not
    # collapse to the same name and inherit each other's character lock.
    char="Eng$(printf '%s' "$tag" | tr '0123456789' 'abcdefghij')x"

    say "$eng  (expects: $want)"
    if [ ! -d "$tree" ]; then
        results+=("$eng|SKIP|no tree at $tree")
        bad "no tree at $tree — assemble it with tools/make-minimal-engine.sh"
        [ "$want" = world ] && overall=1
        continue
    fi

    # Built per engine, both of them: d2net's export numbering is selected by -Dengine-version and
    # d2host compiles the version in. Staging a stale pair is the quiet failure this avoids.
    if ! zig build d2host -Dengine-version="$eng" -Doptimize=ReleaseSafe >/dev/null 2>&1 ||
       ! zig build d2net  -Dengine-version="$eng" -Doptimize=ReleaseSafe >/dev/null 2>&1 ||
       ! zig build d2fog  -Doptimize=ReleaseSafe >/dev/null 2>&1; then
        results+=("$eng|BUILD|refused to build")
        bad "build refused"
        overall=1
        continue
    fi
    cp "$ROOT/zig-out/bin/Fog.dll" "$ROOT/zig-out/bin/D2Net.dll" "$tree/" || die "cannot stage into $tree"

    stop_gs
    clean_realm
    D2GS_ENGINE_VERSION="$eng" D2GS_REDIS_ADDR="$REDIS_ADDR" D2GS_GSID="$gsid" \
        D2GS_GS_ADDR="127.0.0.1:$port" WINEDEBUG=-all \
        "$WINE" "$ROOT/zig-out/bin/d2host.exe" "$tree" > "$log" 2>&1 &

    # Registration, not a sleep: the server publishes itself into redis when it is ready to take
    # work, and until it does the realm has nothing to hand a client.
    key="realmd:gs:$(printf '%x' "$gsid")"
    t=0; up=0
    while [ "$t" -lt "$BOOT_WAIT" ]; do
        [ -n "$(redis EXISTS "$key" 2>/dev/null | grep 1)" ] && { up=1; break; }
        pgrep -f 'd2host.exe' >/dev/null || break   # died during boot; no point waiting out the clock
        sleep 1; t=$((t+1))
    done
    if [ "$up" != 1 ]; then
        # A `broken` engine failing to boot is the expected result, not a failure of the run. What
        # it must not do is fail SILENTLY, so the reason is still printed.
        if [ "$want" = broken ]; then
            why=$(grep -a -m1 -E 'assert from|halt from|ACCESS VIOLATION|unimplemented function' "$log" | cut -c1-120)
            results+=("$eng|BROKEN|still broken as recorded: ${why:-no reason in $log}")
            ok "still broken, as deploy/e2e-engines.txt records"
            printf '      %s\n' "${why:-see $log}"
            stop_gs
            continue
        fi
        results+=("$eng|BOOT|never published itself (see $log)")
        bad "never published itself after ${BOOT_WAIT}s — $log"
        bash "$ROOT/deploy/assert-gs-log-clean.sh" "$log"
        overall=1
        stop_gs
        continue
    fi
    ok "published itself as gsid $gsid on :$port"
    # What the realm can actually see. A create answered "NO GS available" while this says the
    # server is registered means the two disagree, and that is worth one line rather than an hour.
    printf '       fleet set: [%s]  key %s: %s\n' \
        "$(redis SMEMBERS realmd:gs | tr '\n' ' ')" "$key" "$(redis EXISTS "$key")"
    # It booted when the file says it cannot. That is good news and still a failure: the file has
    # stopped describing reality, and a record nobody updates is a record nobody can trust.
    if [ "$want" = broken ]; then
        results+=("$eng|FIXED|boots now — promote it in deploy/e2e-engines.txt")
        bad "recorded as broken, but it booted. Promote it to 'boot' (or 'world' if it serves)."
        overall=1
        stop_gs
        continue
    fi

    verdict=PASS; note=""
    if [ "$want" = world ]; then
        # --engine is not cosmetic: the S->C size table is per build, and framing a pre-1.10f
        # server with 1.14d's eats the LoadSuccess behind GameFlags and hangs. A build whose table
        # nobody has read makes the client say so rather than hang.
        out="$(timeout 120 "$CLIENTLESS" 127.0.0.1 D2XP 1.14.3.71 --engine "$eng" \
                --create "$acct:pw" --new-char "$char" --game "e2e$tag" 2>&1 | tail -30)"
        if printf '%s' "$out" | grep -q 'IN GAME'; then
            units=$(printf '%s' "$out" | sed -n 's/.*units=\([0-9]*\).*/\1/p' | tail -1)
            pkts=$(printf '%s' "$out" | sed -n 's/.*joined: \([0-9]*\) packets.*/\1/p' | tail -1)
            if [ "${units:-0}" -gt 0 ] 2>/dev/null; then
                ok "in game — ${pkts:-?} packets, $units units"
                note="${pkts:-?} packets / $units units"
            else
                verdict=EMPTY; note="reached the GS, world empty"
                bad "$note"
            fi
        else
            verdict=NOWORLD; note="never reached the world"
            bad "$note"
            printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
        fi
    else
        note="boot only (not expected to serve yet)"
        ok "$note"
    fi

    # The server's own account of the same run. A clean client result over a log full of halts is
    # not a pass; it usually means the client gave up before the server got to the part that broke.
    if ! bash "$ROOT/deploy/assert-gs-log-clean.sh" "$log"; then
        [ "$verdict" = PASS ] && verdict=DIRTYLOG
        note="${note:+$note; }server reported a failure"
        overall=1
    fi
    [ "$verdict" = PASS ] || overall=1
    results+=("$eng|$verdict|$note")

    [ "$KEEP" = 1 ] && [ "$i" = "$((${#ENGINES[@]}-1))" ] || stop_gs
done

[ "$KEEP" = 1 ] || clean_realm

echo
say "result"
printf '  %-8s %-8s %-10s %s\n' ENGINE EXPECT VERDICT NOTES
for i in "${!results[@]}"; do
    IFS='|' read -r eng verdict note <<< "${results[$i]}"
    for j in "${!ENGINES[@]}"; do [ "${ENGINES[$j]}" = "$eng" ] && want="${EXPECT[$j]}"; done
    printf '  %-8s %-8s %-10s %s\n' "$eng" "$want" "$verdict" "$note"
done
echo
if [ "$overall" = 0 ]; then
    ok "every engine did what deploy/e2e-engines.txt says it should"
else
    bad "an engine fell short of deploy/e2e-engines.txt — do not edit that file to make this pass"
fi
exit $overall
