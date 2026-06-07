# src/checkrev — the version-check CheckRevision DLL

Builds `ver-IX86-1.dll`, the small library the 1.14d client downloads (inside a
version MPQ, over BNFTP) and calls to prove its version during the Battle.net
version check. `realmd` serves this DLL to the client; this is the **producer**
side of that handshake (the server/BNFTP side is `../realm/server/bnftp.zig`).

## What it is

The client's version-check flow: download the version MPQ via BNFTP →
`SFILE_VerifyFileSignature` (Blizzard weak signature) → extract the DLL →
`D2FILE_VerifyFileSignature` (WinTrust Authenticode, signer org "Blizzard
Entertainment, Inc.") → `LoadLibraryA` → `GetProcAddress("CheckRevision")` → call.
The result goes back in `SID_AUTH_CHECK`; realmd accepts any (result 0 = passed).

`checkrev.zig` exports `CheckRevision` with the expected ABI so the client's call
succeeds. See `CHECKREVISION.md` for the exact two signature gates, export ABI, and
build pipeline.

> A client can skip this entirely with `--bypass-checkrev` (patches the check out);
> this DLL is the path for an *unmodified* client.
