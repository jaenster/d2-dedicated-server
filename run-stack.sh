#!/bin/bash
# run-stack.sh — bring up the whole local realm and prove it works.
#
# redis -> realmd -> qqserver -> the engine GS, in that order, each one WAITED FOR rather than
# slept on, and finished with a real join so "it's up" is a fact instead of a hope.
#
# The reason this exists: every piece has a flag that is easy to omit and whose absence shows up
# three layers away as something unrelated. A GS without --gs-addr binds a port qqserver is not
# looking at. A GS that never reaches gs-link is invisible to realmd, so JOINGAME resolves to
# nothing and the client fails at a screen that says nothing. A client without --realm-gw quietly
# dials real Battle.net. Each of those cost an afternoon at least once; they are all baked in here.
#
#   ./run-stack.sh            bring the stack up and smoke-test it
#   ./run-stack.sh --trace    same, with qqserver hexdumping both directions of the game leg
#   ./run-stack.sh --status   report what is up and what is not, change nothing
#   ./run-stack.sh --down     stop what this script started (never touches wineserver)
#
# Config (env or ./.env):
#   REDIS_ADDR   default 127.0.0.1:6390     GS_PORT      default 14000  (engine, behind qqserver)
#   QQ_PORT      default 4000  (client-hardcoded)
#   GSLINK_PORT  default 6115              HEALTH_PORT  default 18080
#   TESTDIR      default ./testgame        LOG_DIR      default ./.stack
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6390}"
QQ_PORT="${QQ_PORT:-4000}"
GS_PORT="${GS_PORT:-14000}"
GSLINK_PORT="${GSLINK_PORT:-6115}"
HEALTH_PORT="${HEALTH_PORT:-18080}"
BNET_PORT="${BNET_PORT:-6112}"
TESTDIR="${TESTDIR:-$ROOT/testgame}"
LOG_DIR="${LOG_DIR:-$ROOT/.stack}"
REALMD_DATA_DIR="${REALMD_DATA_DIR:-$ROOT/realmd-data}"
WINE="${WINE:-wine}"
CLIENTLESS="${CLIENTLESS:-$ROOT/../clientless/zig-out/bin/clientless}"
mkdir -p "$LOG_DIR"

TRACE=0; MODE=up
for a in "$@"; do case "$a" in
  --trace) TRACE=1 ;;
  --status) MODE=status ;;
  --down) MODE=down ;;
  *) echo "unknown flag $a" >&2; exit 2 ;;
esac; done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

# A port being open is the only readiness signal that does not lie.
listening() { nc -z -w1 "${1%%:*}" "${1##*:}" >/dev/null 2>&1; }
# Who actually holds a local port: "<command> pid <n>", or empty if we cannot tell.
# An open port is not proof the right thing is behind it — a stale build, or another
# checkout entirely, answers just as readily and reports itself as a healthy stack.
holder() { lsof -nP -iTCP:"${1##*:}" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" pid "$2}'; }
# ok/bad for a port we expect a particular binary behind. $3 is the name to expect.
port_is() { # port_is <host:port> <label> <expected-command>
  local who; who=$(holder "$1")
  if ! listening "$1"; then bad "$2"; return 1; fi
  if [ -z "$who" ]; then ok "$2"; return 0; fi
  case "$who" in
    "$3"*) ok "$2 ($who)" ;;
    *) bad "$2 — held by $who, NOT $3. That is somebody else's server; the stack is not what you think it is." ;;
  esac
}
await() { # await <host:port> <seconds> <what>
  local t=0
  while [ "$t" -lt "$2" ]; do listening "$1" && { ok "$3 on $1"; return 0; }; sleep 1; t=$((t+1)); done
  bad "$3 never came up on $1"; return 1
}

# The GS is the one piece whose readiness is NOT a port of its own: it dials OUT to realmd's
# gs-link and registers. Until that lands, realmd has no server to hand out and every join fails
# somewhere that looks like a client problem. So wait for the registration, not the process.
await_gs_registered() {
  local t=0 log="$LOG_DIR/gs.log"
  while [ "$t" -lt "${1:-90}" ]; do
    if grep -aqiE 'addrinfo|setgsinfo|gs-link|gslink' "$log" 2>/dev/null; then
      ok "GS registered with realmd gs-link"; return 0
    fi
    grep -aqi 'panic\|assert' "$log" 2>/dev/null && { bad "GS died during boot — see $log"; return 1; }
    sleep 1; t=$((t+1))
  done
  bad "GS never registered with gs-link in ${1:-90}s — realmd has no game server, so every join
       will fail before it reaches qqserver. See $log"
  return 1
}

status() {
  say "status"
  listening "$REDIS_ADDR"        && ok "redis $REDIS_ADDR"          || bad "redis $REDIS_ADDR"
  port_is "127.0.0.1:$BNET_PORT"   "realmd bnet :$BNET_PORT"     realmd
  port_is "127.0.0.1:$GSLINK_PORT" "realmd gslink :$GSLINK_PORT" realmd
  port_is "127.0.0.1:$QQ_PORT"     "qqserver :$QQ_PORT"          qqserver
  # The GS picks its own game port and advertises it via ADDRINFO, so there is no fixed port to
  # probe — the process being alive and registered is the whole health signal.
  pgrep -f 'testgame' >/dev/null   && ok "GS process alive"         || bad "no GS process"
}

# Wait for a port to actually close. realmd answers SIGTERM by DRAINING — it keeps
# listening for another five seconds — so a --down immediately followed by a start used
# to see the dying realmd on :6112, decide one was "already running", start nothing, and
# leave a stack with no realm server at all. "Stopped" has to mean stopped.
await_gone() { # await_gone <host:port> <seconds> <what>
  local t=0
  while [ "$t" -lt "$2" ]; do listening "$1" || return 0; sleep 1; t=$((t+1)); done
  bad "$3 is still listening on $1 after $2s"; return 1
}

down() {
  say "stopping (wineserver is never touched)"
  pkill -9 -f 'testgame' 2>/dev/null && ok "GS stopped" || ok "no GS running"
  pkill -f 'zig-out/bin/qqserver' 2>/dev/null && ok "qqserver stopped" || ok "no qqserver"
  pkill -f 'zig-out/bin/realmd' 2>/dev/null && ok "realmd stopped (draining)" || ok "no realmd"
  await_gone "127.0.0.1:$QQ_PORT" 15 "qqserver" && ok "qqserver port released"
  await_gone "127.0.0.1:$BNET_PORT" 15 "realmd" && ok "realmd port released"
  await_gone "127.0.0.1:$GSLINK_PORT" 15 "realmd gs-link" >/dev/null
  echo "redis left running (docker compose -f deploy/compose.dev.yaml down to stop it)"
}

case "$MODE" in status) status; exit 0 ;; down) down; exit 0 ;; esac

say "building"
# Only the three pieces this stack runs. The default install step also builds d2gs-native, which
# targets i386 and does not compile for an arm64 host — an unrelated failure that stops the stack.
zig build dlls realmd-bin qqserver || die "zig build failed"
ok "d2gs.dll + realmd + qqserver built"

# Building is not installing. The GS loads $TESTDIR/d2gs.dll, which only run.sh ever
# wrote — so a fix could be built, launched and "tested" here while the engine went on
# running a DLL from hours ago, and the bug would still be there for no reason anyone
# could see. install_dlls is called from the GS section, right before a launch: never
# while a GS is running, because overwriting a DLL wine has mapped corrupts it in place.
install_dlls() {
  cp "$ROOT/zig-out/bin/d2gs.dll" "$TESTDIR/d2gs.dll" || die "could not install d2gs.dll into $TESTDIR"
  cp "$ROOT/zig-out/bin/dbghelp.dll" "$TESTDIR/dbghelp.dll" || die "could not install dbghelp.dll into $TESTDIR"
  ok "installed freshly built d2gs.dll + dbghelp.dll into $TESTDIR"
}

say "redis"
listening "$REDIS_ADDR" || docker compose -f deploy/compose.dev.yaml up -d >/dev/null 2>&1
await "$REDIS_ADDR" 20 "redis" || die "start it with: docker compose -f deploy/compose.dev.yaml up -d"

say "realmd"
if listening "127.0.0.1:$BNET_PORT"; then
  ok "already running (leaving it alone — restarting drops live realm sessions)"
else
  REALMD_EPHEMERAL_STORE=redis REALMD_DURABLE_STORE=fs REALMD_REDIS_ADDR="$REDIS_ADDR" \
  REALMD_DATA_DIR="$REALMD_DATA_DIR" REALMD_REALM_ADDR=127.0.0.1 REALMD_GAME_ADDR=127.0.0.1 \
  REALMD_QQ_PORT="$QQ_PORT" REALMD_HEALTH_PORT="$HEALTH_PORT" REALMD_PERMISSIVE_AUTH=1 \
  REALMD_ADMIN_TOKEN="${REALMD_ADMIN_TOKEN:-}" \
    ./zig-out/bin/realmd > "$LOG_DIR/realmd.log" 2>&1 &
  await "127.0.0.1:$BNET_PORT" 20 "realmd bnet" || die "see $LOG_DIR/realmd.log"
fi
await "127.0.0.1:$GSLINK_PORT" 10 "realmd gs-link" || die "see $LOG_DIR/realmd.log"

say "qqserver"
# It must own the client-hardcoded port: D2 sends game traffic to the advertised IP on :4000 and
# the join reply carries no port, so the public port is not ours to choose.
if listening "127.0.0.1:$QQ_PORT"; then
  ok "already running on :$QQ_PORT"
else
  # Built as an argv array rather than an expanded word: `${TRACE:+VAR=1}` on its own line is a
  # COMMAND to bash, not an assignment, and it fails with "command not found" while looking like
  # an env var that simply did not take.
  qq_env=(REALMD_REDIS_ADDR="$REDIS_ADDR" REALMD_QQ_PORT="$QQ_PORT")
  [ "$TRACE" = 1 ] && qq_env+=(REALMD_QQ_TRACE=1)
  env "${qq_env[@]}" ./zig-out/bin/qqserver > "$LOG_DIR/qq.log" 2>&1 &
  await "127.0.0.1:$QQ_PORT" 15 "qqserver" || die "see $LOG_DIR/qq.log"
fi
[ "$TRACE" = 1 ] && ok "qqserver tracing both directions -> $LOG_DIR/qq.log"

say "game server"
[ -f "$TESTDIR/Game.exe" ] || die "no Game.exe in $TESTDIR — run ./run.sh once to assemble it"
# Leave a healthy GS alone, the same as realmd and qqserver. It is the slowest piece to come back
# and the only one that sometimes refuses to: killing a working one to reach a green line at the
# bottom of this script trades a running stack for a coin flip.
if pgrep -f 'testgame' >/dev/null; then
  ok "already running (leaving it alone — use --down first to replace it)"
  [ "$ROOT/zig-out/bin/d2gs.dll" -nt "$TESTDIR/d2gs.dll" ] &&
    bad "...but it is running an OLDER d2gs.dll than the one just built — --down first to pick it up"
else
install_dlls
WINPATH="Z:$(printf '%s' "$TESTDIR/d2gs.dll" | tr '/' '\\')"
# These flags and no others. --create-games, --gs-addr, --d2cs and --d2dbs all appear in older
# notes, and on this build adding them crashes the engine during boot: an access violation at
# 0x4fa680 dereferencing 0x16, exit 0xc0000005, before it ever reaches d2cs. The GS finds gs-link
# and picks its own game port without them, and registers the result via ADDRINFO — which is what
# qqserver reads, so nothing downstream needs to be told the port either.
  # The boot is racy: the same command that works takes an access violation at 0x4fa680 often
  # enough that one attempt is not a fair test. Retry rather than report a broken stack.
  for attempt in 1 2 3; do
    ( cd "$TESTDIR" && WINEDEBUG=-all WINEDLLOVERRIDES="dbghelp=n" "$WINE" Game.exe \
        -w -nosound --headless --loaddll "$WINPATH" \
        --d2gs --d2gs-boot --realm --no-compress \
        > "$LOG_DIR/gs.log" 2>&1 & )
    await_gs_registered 60 && break
    bad "attempt $attempt died during boot — retrying"
    pkill -9 -f 'testgame' 2>/dev/null
    sleep 2
  done
  pgrep -f 'testgame' >/dev/null || die "the GS would not stay up after 3 attempts — see $LOG_DIR/gs.log"
fi

say "smoke test — a real login, a real game, a real join"
if [ -x "$CLIENTLESS" ]; then
  OUT="$("$CLIENTLESS" 127.0.0.1 D2XP 1.14.3.71 --login tester:tester --char EpicSorc \
        --game "stack$$" 2>&1 | tail -20)"
  if printf '%s' "$OUT" | grep -q 'IN GAME'; then
    ok "joined a game and received the world"
  else
    bad "join did not complete — the stack is up but not usable"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    exit 1
  fi
else
  echo "  (no clientless at $CLIENTLESS — skipping the smoke test)"
fi

say "up"
status
cat <<EOF

  logs      $LOG_DIR/{realmd,qq,gs}.log
  a client  cd <114Clean> && WINEDEBUG=-all WINEDLLOVERRIDES="dbghelp=n" wine Game.exe -w -ns \\
              -skiptobnet --loaddll 'Z:\\...\\d2gs.dll' --d2gs --realm-gw 127.0.0.1 \\
              --bypass-checkrev --auto-join tester:tester:mygame
            (--realm-gw is what points it at us; without it the client dials real Battle.net)
EOF
