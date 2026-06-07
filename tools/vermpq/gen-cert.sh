#!/bin/bash
# gen-cert.sh — generate the self-signed code-signing cert build.sh uses to
# Authenticode-sign the CheckRevision DLL.
#
# The 1.14d client's D2FILE_VerifyFileSignature does a WinTrust Authenticode check
# and only accepts a signer whose org is "Blizzard Entertainment, Inc.". So we
# self-sign with exactly that subject. This is a FORGED Blizzard identity — it is
# generated locally and MUST NOT be committed (gen yours, keep it out of git).
# There is nothing special about any particular key; each is interchangeable.
set -euo pipefail
cd "$(dirname "$0")"

SUBJ="/O=Blizzard Entertainment, Inc./CN=Blizzard Entertainment, Inc."

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout blizz.key -out blizz.crt -subj "$SUBJ"
openssl pkcs12 -export -out blizz.p12 -inkey blizz.key -in blizz.crt -passout pass:

chmod 600 blizz.key blizz.p12
echo "generated blizz.{key,crt,p12} (self-signed, O=Blizzard Entertainment, Inc.)"
echo "these are gitignored — do not commit them."
