#!/bin/bash
# Rebuild the version-check MPQ: build DLL -> Authenticode-sign -> pack+weak-sign.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
SL="${STORMLIB:-/opt/homebrew/opt/stormlib}"
( cd "$ROOT" && zig build )                                   # -> ver-IX86-1.dll
cp "$ROOT/zig-out/bin/ver-IX86-1.dll" ver-IX86-1.dll
# Build the MPQ packer (Zig, links StormLib).
zig build-exe make_vermpq.zig -O ReleaseSafe -femit-bin=make_vermpq \
  -lc -lstorm -lz -lbz2 -I"$SL/include" -L"$SL/lib"
rm -f ver-IX86-1.signed.dll   # osslsigncode 2.13+ refuses to overwrite the output
osslsigncode sign -certs blizz.crt -key blizz.key -n CheckRevision \
  -in ver-IX86-1.dll -out ver-IX86-1.signed.dll >/dev/null 2>&1
DYLD_LIBRARY_PATH="$SL/lib" ./make_vermpq ver-IX86-1.mpq ver-IX86-1.signed.dll "ver-IX86-1.dll"
mkdir -p "${1:-/tmp/rd-live}/bnftp"
cp ver-IX86-1.mpq "${1:-/tmp/rd-live}/bnftp/ver-IX86-1.mpq"
echo "deployed ver-IX86-1.mpq to ${1:-/tmp/rd-live}/bnftp/"
