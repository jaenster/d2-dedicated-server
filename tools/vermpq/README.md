# tools/vermpq — build the version-check MPQ

Produces `ver-IX86-1.mpq`, the file `realmd` serves over BNFTP so the unmodified
1.14d client passes its Battle.net version check. The MPQ carries the
`CheckRevision` DLL the client runs to compute its version checksum.

## The two signature gates

The client verifies the download twice:

1. **Weak MPQ signature** — `SFILE_VerifyFileSignature` checks the `(signature)`
   file inside the MPQ against Blizzard's 512-bit "weak" RSA key. That key was
   publicly factored years ago; the private key is in the repo
   (`apps/realmd/assets/blizzard-weak-signature.pem`) and StormLib signs with it.
   `make_vermpq.zig` packs the DLL and weak-signs the archive.

2. **DLL Authenticode signature** — `D2FILE_VerifyFileSignature` runs a WinTrust
   Authenticode check and only accepts a signer whose org is
   "Blizzard Entertainment, Inc.". So we self-sign the DLL with exactly that
   subject (`osslsigncode` in `build.sh`).

## What's tracked vs. local

Tracked (in git): `make_vermpq.zig`, `build.sh`, `gen-cert.sh`, this README.

NOT tracked (generate locally): `blizz.key` / `blizz.crt` / `blizz.p12` — a
**self-signed cert impersonating "Blizzard Entertainment, Inc."** Shipping a
working Blizzard-impersonating signing key in a public repo is a leaked secret +
a trademark/abuse hazard, so each user generates their own (they're
interchangeable). Also untracked: the built `ver-IX86-1.dll`, `*.signed.dll`, and
`*.mpq` artifacts.

## Build

```
./gen-cert.sh                 # once: make your local blizz.{key,crt,p12}
./build.sh [/path/to/datadir] # build DLL -> sign -> pack -> deploy to <datadir>/bnftp/
                              #             default datadir: /tmp/rd-live
```

Needs `osslsigncode` and StormLib (`brew install osslsigncode stormlib`).

> If you don't need an unmodified client, skip all of this: launch the client
> with `--bypass-checkrev` and realmd never has to serve a valid MPQ.
