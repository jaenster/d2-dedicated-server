#!/bin/bash
# Rebuild the version-check MPQ: build DLL -> Authenticode-sign -> pack+weak-sign.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
SL=/opt/homebrew/opt/stormlib
( cd "$ROOT" && zig build )                                   # -> ver-IX86-1.dll
cp "$ROOT/zig-out/bin/ver-IX86-1.dll" ver-IX86-1.dll
osslsigncode sign -certs blizz.crt -key blizz.key -n CheckRevision \
  -in ver-IX86-1.dll -out ver-IX86-1.signed.dll >/dev/null 2>&1
DYLD_LIBRARY_PATH="$SL/lib" ./make_vermpq ver-IX86-1.mpq ver-IX86-1.signed.dll "ver-IX86-1.dll"
mkdir -p "${1:-/tmp/rd-live}/bnftp"
cp ver-IX86-1.mpq "${1:-/tmp/rd-live}/bnftp/ver-IX86-1.mpq"
echo "deployed ver-IX86-1.mpq to ${1:-/tmp/rd-live}/bnftp/"
