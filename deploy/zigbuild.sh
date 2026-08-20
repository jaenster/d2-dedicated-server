#!/bin/sh
# `zig build`, retried when — and only when — the dependency FETCH failed.
#
# The dependency tree is fetched over the network at image-build time, and one of those hosts is
# not ours. A degraded codeberg, answering slowly enough that the git handshake times out
# mid-protocol, failed the unit tests, realmd and all nine engines in a single run — and every one
# of them reported it as though the code were at fault.
#
# A compile error is re-raised immediately and never retried. Retrying those would turn d2host's
# readiness gate into a three-minute wait for the same refusal, and would hide a real breakage
# behind an eventual failure that reads as flakiness.
set -e
err=$(mktemp)
n=0
while :; do
  if zig build "$@" 2>"$err"; then cat "$err" >&2; rm -f "$err"; exit 0; fi
  cat "$err" >&2
  if ! grep -qE 'unable to discover remote git server|ConnectionResetByPeer|ConnectionRefused|ConnectionTimedOut|TemporaryNameServerFailure|ProtocolError|TlsInitializationFailed|NetworkUnreachable' "$err"; then
    rm -f "$err"; exit 1
  fi
  n=$((n + 1))
  if [ "$n" -ge 4 ]; then
    echo "zigbuild: dependency fetch still failing after $n attempts" >&2
    rm -f "$err"; exit 1
  fi
  echo "zigbuild: dependency fetch failed (network), retry $n in $((n * 15))s" >&2
  sleep $((n * 15))
done
