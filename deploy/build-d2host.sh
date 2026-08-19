#!/bin/sh
# Build one pre-1.14 game-server image per engine version.
#
#   deploy/build-d2host.sh 0.0.1            # every engine that is ready
#   deploy/build-d2host.sh 0.0.1 1.09d ...  # only the ones named
#
# Tags are <our release>-d2-<engine>: d2gs:0.0.1-d2-109d. The engine keeps its own spelling
# minus the dot, so 1.09d -> 109d, matching how the versions are named everywhere else.
#
# There is no list here of which engines are finished, on purpose. The version is compiled in
# (-Dengine-version), so d2host's readiness gate is a COMPILE error and an unfinished engine
# simply fails to build — the filter is the compiler, not a list someone has to remember to
# update. A refusal here is a correct outcome, not a broken pipeline.
set -e

APP_VERSION="${1:?usage: build-d2host.sh <app-version> [engine ...]}"
shift
REPO="${D2GS_IMAGE_REPO:-d2gs}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Every version the engine model knows about, in release order.
ALL="1.00 1.06b 1.07 1.08 1.09d 1.10f 1.13c"
ENGINES="${*:-$ALL}"

built="" refused=""
for engine in $ENGINES; do
  tag="${REPO}:${APP_VERSION}-d2-$(printf '%s' "$engine" | tr -d '.')"
  printf '==> %s ... ' "$tag"
  if docker build -q -f "$ROOT/deploy/Dockerfile" --target d2host \
       --build-arg "D2_VERSION=$engine" --build-arg "APP_VERSION=$APP_VERSION" \
       -t "$tag" "$ROOT" >/dev/null 2>"$ROOT/.build-$engine.err"; then
    echo "ok"
    built="$built $tag"
    rm -f "$ROOT/.build-$engine.err"
  else
    # Show why, from the compiler rather than a guess: usually the slots still unmeasured.
    why=$(grep -o 'is not ready to serve: [^"]*' "$ROOT/.build-$engine.err" | head -1)
    echo "refused${why:+ — ${why#is not ready to serve: }}"
    refused="$refused $engine"
    rm -f "$ROOT/.build-$engine.err"
  fi
done

echo
echo "built:  ${built:-<none>}"
echo "refused:${refused:-<none>}"
