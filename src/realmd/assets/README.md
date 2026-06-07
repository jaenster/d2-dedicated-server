# Version-check assets

## blizzard-weak-signature.pem

The **Blizzard "weak" digital signature** RSA-512 private key. This 512-bit key
was factored long ago and is public knowledge (it ships with PvPGN and every D2
private-server toolchain). It is NOT a secret and grants no access to anything
Blizzard — it only lets a server produce MPQs that the D2 client's Storm
`SFILE_VerifyFileSignature` accepts.

We use it to sign the version-check MPQ (`ver-IX86-1.mpq`) that realmd serves over
BNFTP. The D2 1.14d client (`BNDOWNLOAD_PerformCheckRevision`):
1. downloads the MPQ over BNFTP,
2. `SFILE_VerifyFileSignature` — checks the MPQ's weak signature (this key),
3. extracts a DLL from it and `D2FILE_VerifyFileSignature` (WinTrust) it,
4. `LoadLibraryA` + `GetProcAddress` the CheckRevision export and calls it,
5. sends the resulting version/checksum in `SID_AUTH_CHECK`.

Since realmd accepts any `SID_AUTH_CHECK`, the checksum value is irrelevant — the
client just has to complete the flow without crashing.

Refs: bnetdocs 41 (Blizzard weak digital signature), bnetdocs 47 (CheckRevision).
