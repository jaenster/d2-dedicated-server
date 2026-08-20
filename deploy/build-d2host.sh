#!/bin/sh
# Build one game-server image per engine version — every variant of the server, under one
# `d2gs` repository.
#
#   deploy/build-d2host.sh 0.0.1            # every engine that is ready
#   deploy/build-d2host.sh 0.0.1 1.09d ...  # only the ones named
#
# Tags are <engine>-<our release>: d2gs:1.09d-0.0.1, plus a floating d2gs:1.09d for the newest
# build of that engine. Engine first because that is what a consumer is choosing — the same shape
# as postgres:16 / postgres:16-alpine, where the headline number is the thing you want and the
# suffix is which build of it. Release-first has no natural "latest 1.09d".
#
# There is no list here of which engines are finished, on purpose. The version is compiled in
# (-Dengine-version), so d2host's readiness gate is a COMPILE error and an unfinished engine
# simply fails to build — the filter is the compiler, not a list someone has to remember to
# update. A refusal here is a correct outcome, not a broken pipeline. That is also why CI drives
# this script rather than carrying its own matrix of version strings: a list in a workflow goes
# stale the day a version becomes ready and nobody remembers to add it.
#
# Environment, all optional — the defaults are what a developer building locally wants:
#   D2GS_IMAGE_REPO   where the images go (default `d2gs`; CI sets ghcr.io/jaenster/d2gs)
#   D2GS_TAG_EXTRA    further release suffixes, space-separated: `abc123` -> d2gs:1.09d-abc123.
#                     CI publishes the commit sha this way, as an immutable handle.
#   D2GS_TAG_FLOATING 1 (default) also tags the bare d2gs:<engine>. CI sets 0: that tag means
#                     "the build that passed", so only the promote step is allowed to move it.
#   D2GS_PUSH         1 pushes every tag as its image is built.
#   D2GS_BUILT_FILE   write the engines that built, space-separated, to this path — how CI hands
#                     the list to the step that promotes them.
set -e

APP_VERSION="${1:?usage: build-d2host.sh <app-version> [engine ...]}"
shift
REPO="${D2GS_IMAGE_REPO:-d2gs}"
# Same default as the Dockerfile ARG of this name, and passed down so the two cannot disagree
# about where a tree comes from.
D2_MINIMAL_ENGINE_BASE="${D2_MINIMAL_ENGINE_BASE:-https://files.typeguru.nl/diablo/minimal}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Every engine, in release order. 1.14d is one of them: it is a different mechanism — the server
# is injected into Game.exe rather than hosting D2Game.dll as a library, and 1.14d-native drops
# wine entirely — but that is an implementation detail the tag has no business exposing. A consumer
# picks an engine; which Dockerfile target builds it is our problem.
ALL="1.00 1.06b 1.07 1.08 1.09b 1.09d 1.10f 1.13c 1.14d 1.14d-native"
ENGINES="${*:-$ALL}"

# Which target builds a given engine. Only the pre-1.14 ones take -Dengine-version.
target_for() {
  case "$1" in
    1.14d)        echo "gs" ;;
    1.14d-native) echo "gs-native" ;;
    *)            echo "d2host" ;;
  esac
}

built="" refused=""
for engine in $ENGINES; do
  # -t once per release suffix, plus the floating tag unless something else owns it.
  set -- -t "${REPO}:${engine}-${APP_VERSION}"
  for extra in $D2GS_TAG_EXTRA; do set -- "$@" -t "${REPO}:${engine}-${extra}"; done
  if [ "${D2GS_TAG_FLOATING:-1}" = 1 ]; then set -- "$@" -t "${REPO}:${engine}"; fi
  if [ "${D2GS_PUSH:-0}" = 1 ]; then set -- "$@" --push; fi
  target=$(target_for "$engine")
  # Whether a game tree is published for this engine, asked of the same place the Dockerfile
  # fetches it from. The image builds either way -- one without a tree still runs off a mounted
  # install -- but the two must not look alike here, or an image that ships no data reads as a
  # clean build. Asked over HTTP rather than read out of the build log because a cached layer
  # prints nothing, and "cached" would then be indistinguishable from "no tree".
  tree="" tree_arg=""
  if [ "$target" = d2host ]; then
    tree_arg="--build-arg D2_MINIMAL_ENGINE_BASE=$D2_MINIMAL_ENGINE_BASE"
  fi
  if [ "$target" = d2host ] && \
     ! curl -fsI "${D2_MINIMAL_ENGINE_BASE}/${engine}/d2-${engine}-minimal.tgz" >/dev/null 2>&1; then
    tree=" (no game tree — needs an install mounted at /game)"
  fi
  printf '==> %s:%s-%s (%s) ... ' "$REPO" "$engine" "$APP_VERSION" "$target"
  # Both streams to the same file, and NOT -q. The compiler's refusal goes to stdout; with -q that
  # is discarded and stderr carries only "failed to solve", so the reason a version was turned down
  # -- the whole point of the gate -- was never visible. On success the file is thrown away, so the
  # console stays as quiet as it was.
  if docker build -f "$ROOT/deploy/Dockerfile" --target "$target" \
       --build-arg "D2_VERSION=$engine" --build-arg "APP_VERSION=$APP_VERSION" $tree_arg \
       "$@" "$ROOT" >"$ROOT/.build-$engine.err" 2>&1; then
    echo "ok${tree}"
    built="$built $engine"
    rm -f "$ROOT/.build-$engine.err"
  else
    # Say why, in the compiler's own words. docker prefixes build output with "#NN T.TT ", so
    # strip that; a refusal that does not explain itself is the one thing worse than a refusal.
    why=$(sed -n 's/^#[0-9]* *[0-9.]* *//; s/.*error: //p' "$ROOT/.build-$engine.err" \
          | grep -m1 -E 'is not ready to serve|is not a known version' || true)
    if [ -n "$why" ]; then
      # The compiler turned this engine down, which is the designed outcome for one that is not
      # finished. Report it and carry on.
      echo "refused — $why"
      refused="$refused $engine"
      rm -f "$ROOT/.build-$engine.err"
    else
      # Anything else is the build breaking, not the engine being unready, and calling it "refused"
      # reads as the opposite of what happened -- a broken mirror or a full disk would look like a
      # deliberate decision. Fail, and show what actually went wrong.
      echo "FAILED (not a refusal — the build itself broke)"
      sed -n 's/^#[0-9]* *[0-9.]* *//p' "$ROOT/.build-$engine.err" | tail -15
      rm -f "$ROOT/.build-$engine.err"
      exit 1
    fi
  fi
done

echo
echo "built:  ${built:-<none>}"
echo "refused:${refused:-<none>}"

# The list is an output, not just a log line: whatever promotes these tags has to know which
# engines exist without re-deriving readiness itself.
if [ -n "$D2GS_BUILT_FILE" ]; then printf '%s\n' "${built# }" > "$D2GS_BUILT_FILE"; fi

# A build that produced nothing is a failure even though each refusal was individually fine.
[ -n "$built" ] || { echo "no engine built at all"; exit 1; }
