#!/bin/bash
# run-stress.sh — join games in a loop until something breaks, and say what broke.
#
# "It goes unstable after a few games" is not something you can fix, because it does not
# say which game, which piece, or what "unstable" was. This makes the same thing happen
# on purpose, with a round number attached, and checks after every round the things that
# a human only notices much later:
#
#   * did every client actually reach the world (not just connect)
#   * is the GS still alive, and did it panic (PANIC lines are symbolized for you)
#   * is it leaking — resident memory and open file descriptors, per round
#
# The GS answering its health check is NOT one of the checks, on purpose: a GS with a
# dead join thread answers health checks perfectly and that is the whole problem.
#
#   ./run-stress.sh                        20 rounds, 2 clients each
#   ./run-stress.sh --rounds 100           longer
#   ./run-stress.sh --clients 4            more clients per game
#   ./run-stress.sh --keep-going           don't stop at the first failure
#   ./run-stress.sh --same-game            every round reuses ONE game name
#   ./run-stress.sh --spread --clients 6   6 games ALIVE AT ONCE, one character each
#   ./run-stress.sh --dwell 1              seconds each client stays in the world (default 3)
#   ./run-stress.sh --runs 5               each client plays 5 games on ONE login, leaving
#                                          each one properly before making the next
#
# --runs is the lifecycle test. A process per game leaves nothing behind to trip over: every
# game gets a brand-new realm connection, a character nobody has seated yet and a server with
# no memory of the last attempt. What a real client does is come BACK — same connection, same
# character, next game — and that is the path that carries the state worth doubting: the realm's
# record of which game the character is in, the engine's seat for it, and the game itself once
# the last player walks out.
#
# --spread is the load shape: CLIENTS separate games running together, and each round reports
# what one costs (live memory minus idle, over the game count). Characters past the first two
# come from the Load%02d pool — clone them with POST /admin/chars/copy.
#
# Config (env or ./.env): as run-stack.sh, plus CLIENTLESS.
#
# NATIVE_GS=host:port sends the GAME leg at another game server — the wine-free native one — while
# the realm leg still runs against the local stack. Use it for a native server the realm knows
# nothing about; the client then joins with the realm's own token, which only works where the
# server is not the one the realm placed the game on.
#
# NATIVE_GS=realm is the other shape, and the one that tests the real path: the native server has
# registered over gs-link, so the realm places the game on it and the client is routed there like
# any other. Nothing is overridden.
#
# Either way the GS-process checks (alive, rss, fds, panics) go quiet: they read a local process,
# and there is none.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

INGRESS_PORT="${INGRESS_PORT:-4000}"
BNET_PORT="${BNET_PORT:-6112}"
LOG_DIR="${LOG_DIR:-$ROOT/.stack}"
CLIENTLESS="${CLIENTLESS:-$ROOT/../clientless/zig-out/bin/clientless}"
ACCOUNT="${STRESS_ACCOUNT:-tester:tester}"
# One character per client, comma-separated. They must differ: a character is a single
# person and the engine will not seat the same one twice, so reusing a name makes the
# second client hang on GAMELOGON and look exactly like a server fault.
CHARS="${STRESS_CHARS:-}"
NATIVE_GS="${NATIVE_GS:-}"

ROUNDS=20; CLIENTS=2; KEEP_GOING=0; SAME_GAME=0; SPREAD=0; DWELL=3; RUNS=1
while [ "$#" -gt 0 ]; do case "$1" in
  --rounds)     ROUNDS="$2"; shift 2 ;;
  --clients)    CLIENTS="$2"; shift 2 ;;
  --keep-going) KEEP_GOING=1; shift ;;
  --same-game)  SAME_GAME=1; shift ;;
  --spread)     SPREAD=1; shift ;;
  --dwell)      DWELL="$2"; shift 2 ;;
  --runs)       RUNS="$2"; shift 2 ;;
  *) echo "unknown flag $1" >&2; exit 2 ;;
esac; done
# Every client of every round has to reach the world, and with --runs each of its games does too.
WANT=$((CLIENTS * RUNS))

# Characters: the engine seats a character once, so every concurrent client needs its own. Two
# named ones on the shared account cover the default. Past that, each client gets its OWN
# ACCOUNT from the load%02d pool, one character on it — which is what a real load looks like,
# and it sidesteps the char-select list: the client asks for 8 characters (as the real one
# does, that being a page), so characters 9+ of a shared account are simply not offered.
#   for i in $(seq -f '%02g' 1 16); do
#     curl -sX POST -H "Authorization: Bearer $TOK" -d "{\"name\":\"load$i\",\"password\":\"load$i\"}" \
#       $ADMIN/admin/accounts
#     curl -sX POST -H "Authorization: Bearer $TOK" \
#       -d "{\"src_account\":\"tester\",\"src_char\":\"EpicSorc\",\"dst_account\":\"load$i\",\"dst_char\":\"Load$i\"}" \
#       $ADMIN/admin/chars/copy
#   done
# The pool names are LETTERS ONLY on purpose. A character name with a digit in it is refused by
# the engine (IsValidChecks -> STRING_CheckIfPlayerNameDoNotContainForbidenChars) and refused
# SILENTLY — "Load01" logs on, creates a game, sends GAMELOGON and is then simply never
# answered. The realm will happily create such a character, so the name has to be right here.
POOL_CHARS="LoadAlpha,LoadBravo,LoadCharlie,LoadDelta,LoadEcho,LoadFoxtrot,LoadGolf,LoadHotel,\
LoadIndia,LoadJuliet,LoadKilo,LoadLima,LoadMike,LoadNovember,LoadOscar,LoadPapa"
POOL=0
if [ -z "$CHARS" ]; then
  if [ "$CLIENTS" -le 2 ]; then CHARS="EpicSorc,EpicAma"; else
    POOL=1
    CHARS="$POOL_CHARS"
    have=$(printf '%s' "$POOL_CHARS" | tr ',' '\n' | wc -l | tr -d ' ')
    [ "$CLIENTS" -le "$have" ] || die "the load pool has $have characters, asked for $CLIENTS"
  fi
fi

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

listening() { nc -z -w1 "${1%%:*}" "${1##*:}" >/dev/null 2>&1; }

# Round times are the number this is compared on, and whole seconds cannot carry that: a round
# takes about four of them, so `date +%s` quantises every sample by 25%. macOS ships bash 3.2 (no
# EPOCHREALTIME) and BSD date has no %N, so the clock comes from perl, which both hosts have.
# A round therefore includes one perl start (~20 ms) — the same constant on either side of any
# comparison, so it shifts the totals and not the difference.
if perl -MTime::HiRes -e '' 2>/dev/null; then
  now_ms() { perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000'; }
else
  now_ms() { echo $(( $(date +%s) * 1000 )); }
fi
fmt_ms() { printf '%d.%02d' $(( $1 / 1000 )) $(( ($1 % 1000) / 10 )); }

OUT="$LOG_DIR/stress"
rm -rf "$OUT"; mkdir -p "$OUT"

say "preflight"
listening "127.0.0.1:$BNET_PORT" || die "realmd is not on :$BNET_PORT — ./run-stack.sh first"
listening "127.0.0.1:$INGRESS_PORT"   || die "d2ingress is not on :$INGRESS_PORT — ./run-stack.sh first"
[ -x "$CLIENTLESS" ] || die "no clientless at $CLIENTLESS (build it, or set CLIENTLESS=)"
# wine leaves a start.exe wrapper matching the same pattern; the engine itself is the one
# that grew a heap, so pick by resident size rather than by pid order.
GS_PID="$(ps -o pid=,rss=,command= -ax 2>/dev/null | grep 'testgame' | grep -v grep |
          sort -k2 -n -r | awk 'NR==1 {print $1}')"
gs_args=()
if [ "$NATIVE_GS" = realm ]; then
  GS_PID=""
  ok "realmd and d2ingress are up; the game leg goes wherever the realm placed it (no local GS to watch)"
elif [ -n "$NATIVE_GS" ]; then
  listening "$NATIVE_GS" || die "nothing is listening on $NATIVE_GS (NATIVE_GS)"
  gs_args=(--gs-host "${NATIVE_GS%%:*}" --gs-port "${NATIVE_GS##*:}")
  GS_PID=""
  ok "realmd and d2ingress are up; the game leg goes to $NATIVE_GS (no local GS to watch)"
else
  [ -n "$GS_PID" ] || die "no GS process — ./run-stack.sh first"
  ok "realmd, d2ingress and GS (pid $GS_PID) are up"
fi

# Only the part of the log a round produced is evidence about that round. Remember how
# far each log had got, and read forward from there — grepping the whole file re-reports
# every crash since boot and makes round 1 look like it failed.
gs_mark=$(wc -c < "$LOG_DIR/gs.log" 2>/dev/null || echo 0)

# Resident KB and open descriptors for the GS — the two numbers that climb quietly when
# a game leaks. lsof is slow, so it runs once per round, not per client.
gs_rss()  { [ -n "$GS_PID" ] && ps -o rss= -p "$GS_PID" 2>/dev/null | tr -d ' '; }
gs_fds()  { [ -n "$GS_PID" ] && lsof -p "$GS_PID" 2>/dev/null | wc -l | tr -d ' '; }

rss0=$(gs_rss); fds0=$(gs_fds)
ok "baseline: rss=${rss0}KB fds=${fds0}"

# Everything gs.log gained since $gs_mark, for the checks below.
gs_since_mark() { tail -c "+$((gs_mark + 1))" "$LOG_DIR/gs.log" 2>/dev/null; }

pass=0; first_fail=""; round_ms=()
if [ "$RUNS" -gt 1 ]; then
  say "$ROUNDS rounds x $CLIENTS client(s) x $RUNS games per login"
else
  say "$ROUNDS rounds x $CLIENTS client(s)"
fi

for round in $(seq 1 "$ROUNDS"); do
  t0=$(now_ms)
  if [ "$SAME_GAME" = 1 ]; then game="stress"; else game="st${round}x$$"; fi

  # By default all clients of a round race for the SAME game: the first creates it, the rest
  # fall through to JOIN — concurrent joins into one game is the case that broke. With --spread
  # each client gets its own game instead, so CLIENTS is a count of games alive at once, which
  # is what pressures the engine's per-game allocations rather than its join path.
  pids=()
  for c in $(seq 1 "$CLIENTS"); do
    char="$(printf '%s' "$CHARS" | cut -d, -f"$c")"
    [ -n "$char" ] || die "only $(printf '%s' "$CHARS" | tr ',' '\n' | wc -l | tr -d ' ') characters for $CLIENTS clients"
    if [ "$SPREAD" = 1 ]; then g="${game}_$c"; else g="$game"; fi
    if [ "$POOL" = 1 ]; then acct="$(printf 'load%02d:load%02d' "$c" "$c")"; else acct="$ACCOUNT"; fi
    # --runs keeps the realm login and plays several games down it; --same-game then means all
    # of them re-enter the one game rather than each making its own.
    lifecycle=()
    [ "$RUNS" -gt 1 ] && lifecycle+=(--runs "$RUNS")
    [ "$RUNS" -gt 1 ] && [ "$SAME_GAME" = 1 ] && lifecycle+=(--same-game)
    "$CLIENTLESS" 127.0.0.1 D2XP 1.14.3.71 --login "$acct" --char "$char" \
      --dwell "$DWELL" --game "$g" ${lifecycle[@]+"${lifecycle[@]}"} \
      ${gs_args[@]+"${gs_args[@]}"} > "$OUT/r${round}-c${c}.log" 2>&1 &
    pids+=($!)
  done
  # Sample while the games are actually LIVE. Reading memory after the clients exit measures a
  # server with no games in it, which is the one number that cannot answer "what does a game
  # cost". Give them a moment to get in, then look.
  ( sleep 2; gs_rss > "$OUT/r${round}.peak" ) &
  sampler=$!
  for p in "${pids[@]}"; do wait "$p"; done
  wait "$sampler" 2>/dev/null
  peak=$(cat "$OUT/r${round}.peak" 2>/dev/null)

  # "IN GAME" is NOT the test. clientless prints it whenever it managed to SEND the 0x6b
  # join, so a client that was refused straight afterwards prints it too — with act=0,
  # mapSeed=0 and an empty world. Count only clients the server actually gave a world to.
  in_game=$(grep -ah '^\[GS\] world: act=' "$OUT"/r${round}-c*.log 2>/dev/null |
            grep -vc 'units=0' | tr -d ' ')
  t1=$(now_ms)
  round_ms+=($((t1 - t0)))

  fail=""
  if [ "$in_game" -lt "$WANT" ]; then
    # A game the realm would not create because every GS was already at its cap is not the same
    # news as a game that was created and then went wrong. One says the load asked for more than
    # this fleet can host — a GS runs SEVEN games, because Fog hands out eight pool managers and
    # the Global Pool System keeps one — and the other says something is broken. They used to
    # print the same line, which is how a test that was simply overloaded read as a regression.
    # The CREATEGAME line only, not the JOINGAME that follows it repeating the same reason —
    # counting both makes a round look more refused than it has games.
    capped=$(grep -ahc '^\[MCP_CREATEGAME\].*game servers are down' "$OUT"/r${round}-c*.log 2>/dev/null |
             awk '{n+=$1} END{print n+0}')
    if [ "$((in_game + capped))" -ge "$WANT" ]; then
      fail="the GS was at its game cap for $capped of $WANT (not a fault: one GS hosts 7 —
       lengthen --dwell, drop --clients, or run more game servers)"
    else
      fail="only $in_game/$WANT games reached the world"
    fi
  fi
  [ -z "$GS_PID" ] || kill -0 "$GS_PID" 2>/dev/null || fail="${fail:+$fail; }the GS process died"

  new_log="$(gs_since_mark)"
  if printf '%s' "$new_log" | grep -q 'PANIC'; then
    fail="${fail:+$fail; }the GS panicked"
  elif printf '%s' "$new_log" | grep -qi 'thread [0-9]* panic'; then
    # A panic printed by Zig's own handler rather than ours means this GS is running a
    # d2gs.dll from before the panic handler existed — say so, don't just report a crash.
    fail="${fail:+$fail; }the GS panicked (stale DLL: no PANIC diagnostics — ./run-stack.sh --down && ./run-stack.sh)"
  fi

  rss=$(gs_rss); fds=$(gs_fds)
  # Process RSS is the wrong instrument for "what does a game cost": it moves with allocator
  # slack and lags the reap. The GS prints a pool census whenever the engine's manager count
  # changes, and THAT is exact — one manager per game, its byte count is the game's heap. Take
  # the highest in-use count this round, and what one game was holding.
  live=""
  if [ "$SPREAD" = 1 ]; then
    hi=0
    for h in $(printf '%s' "$new_log" | grep -a 'pools: in-use' | awk '{print $(NF-2)}'); do
      v=$(printf '%d' "$h" 2>/dev/null) || v=0
      [ "$v" -gt "$hi" ] && hi=$v
    done
    # Every game's manager is named after the game, so anything that is not the Global Pool
    # System's line is a game's heap; they come out identical, so the last one speaks for all.
    # The log line is JSON, so cut the trailing fields too — otherwise printf is handed
    # `0x3105f4","trace":...` and complains about an invalid number on every round.
    gb=$(printf '%s' "$new_log" | grep -a 'pools:     bytes=' | tail -1 |
         sed 's/.*bytes=//; s/[^0-9a-fA-Fx].*//')
    [ "$hi" -gt 0 ] && live="  pools=${hi}/8"
    [ -n "$gb" ] && live="$live ($(( $(printf '%d' "$gb") / 1024 ))KB/game)"
  fi
  line="  round $round  $in_game/$WANT in-game  $(fmt_ms $((t1 - t0)))s  rss=${rss}KB fds=${fds}${live}"
  if [ -z "$fail" ]; then
    pass=$((pass + 1)); printf '\033[32m%s\033[0m\n' "$line"
  else
    printf '\033[31m%s  <- %s\033[0m\n' "$line" "$fail"
    [ -z "$first_fail" ] && first_fail="round $round: $fail"
    say "what the GS logged during round $round"
    printf '%s\n' "$new_log" | grep -aE 'PANIC|panic|assert|rosetta|Exception' | tail -20 | sed 's/^/    /'
    printf '%s\n' "$new_log" | grep -a 'PANIC' > "$OUT/r${round}-panic.log" 2>/dev/null
    [ -s "$OUT/r${round}-panic.log" ] && ./tools/symbolize.sh "$OUT/r${round}-panic.log"
    say "what the last client saw"
    tail -15 "$OUT/r${round}-c${CLIENTS}.log" | sed 's/^/    /'
    [ "$KEEP_GOING" = 1 ] || break
  fi
  gs_mark=$(wc -c < "$LOG_DIR/gs.log" 2>/dev/null || echo 0)
done

say "result"
echo "  $pass/$ROUNDS rounds clean"

# Round times. Reported whole, and NOT with the dwell subtracted: the dwell is not a floor the
# round sits on top of. A client's dwell clock starts when it sends 0x6b, so the world arrives
# DURING it — at --dwell 0 the client leaves before the world does and every round fails — and a
# longer dwell also gives the previous game more time to be reaped, which shortens the next
# create. Measured on one server, "round minus dwell" came out at 2.05s with --dwell 1 and 1.40s
# with --dwell 3; a quantity that moves when you change the thing you are subtracting is not the
# server's time. Compare servers at the SAME dwell and compare the rounds.
if [ "${#round_ms[@]}" -gt 0 ]; then
  sorted=($(printf '%s\n' "${round_ms[@]}" | sort -n))
  n=${#sorted[@]}
  total=0; for m in "${sorted[@]}"; do total=$((total + m)); done
  mean=$((total / n))
  if [ $((n % 2)) = 1 ]; then median=${sorted[$((n / 2))]}
  else median=$(( (${sorted[$((n / 2 - 1))]} + ${sorted[$((n / 2))]}) / 2 )); fi
  echo "  rounds  min $(fmt_ms "${sorted[0]}")s  median $(fmt_ms $median)s  mean $(fmt_ms $mean)s  max $(fmt_ms "${sorted[$((n - 1))]}")s"
  echo "  total $(fmt_ms $total)s over $n rounds at --dwell $DWELL x $RUNS"
fi

rss=$(gs_rss); fds=$(gs_fds)
if [ -n "$rss" ]; then
  echo "  GS memory ${rss0}KB -> ${rss}KB, descriptors ${fds0} -> ${fds}"
  # Growth that tracks the round count is a leak; growth that stops is just warm-up.
  [ "$fds" -gt $((fds0 + ROUNDS)) ] &&
    bad "descriptors grew by more than one per round — something is not being closed"
fi
echo "  client logs in $OUT"
if [ -n "$first_fail" ]; then bad "$first_fail"; exit 1; fi

# Rounds only prove a client reached the world — not that what it loaded was intact. A cache that
# truncated every character to 1024 bytes once passed this harness 5/5 while quietly corrupting
# saves, so the saves themselves are checked before a run is called clean.
if [ -x ./tools/check-saves.sh ]; then
  say "save integrity"
  if ./tools/check-saves.sh > "$OUT/saves.log" 2>&1; then
    ok "$(grep -c '^ok ' "$OUT/saves.log" 2>/dev/null || echo 0) saves valid and consistent"
  else
    grep -E '^BAD ' "$OUT/saves.log" | head -5
    bad "a character is corrupt or inconsistent — see $OUT/saves.log"
    exit 1
  fi
fi

ok "no failures"
