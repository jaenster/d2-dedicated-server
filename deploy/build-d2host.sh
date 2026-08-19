#!/bin/sh
# Build one pre-1.14 game-server image per engine version.
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
  tag="${REPO}:${engine}-${APP_VERSION}"
  floating="${REPO}:${engine}"
  printf '==> %s ... ' "$tag"
  if docker build -q -f "$ROOT/deploy/Dockerfile" --target d2host \
       --build-arg "D2_VERSION=$engine" --build-arg "APP_VERSION=$APP_VERSION" \
       -t "$tag" -t "$floating" "$ROOT" >/dev/null 2>"$ROOT/.build-$engine.err"; then
    echo "ok"
    built="$built $tag"
    rm -f "$ROOT/.build-$engine.err"
  else
    # Say why, in the compiler's own words. docker prefixes build output with "#NN T.TT ", so
    # strip that; a refusal that does not explain itself is the one thing worse than a refusal.
    why=$(sed -n 's/^#[0-9]* *[0-9.]* *//; s/.*error: //p' "$ROOT/.build-$engine.err" \
          | grep -m1 -E 'is not ready to serve|is not a known version' || true)
    echo "refused${why:+ — $why}"
    refused="$refused $engine"
    rm -f "$ROOT/.build-$engine.err"
  fi
done

echo
echo "built:  ${built:-<none>}"
echo "refused:${refused:-<none>}"
