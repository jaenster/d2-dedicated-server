# CheckRevision.dll (D2 1.14d) — how it works, and how we fake it

Reverse-engineered from the real `1.14d/CheckRevision.dll` (Ghidra, imagebase
`0x10000000`, export `CheckRevision` @ `0x100061b0`). Companion to
[[d2-checkrevision]]. This documents the **inner DLL** that the client extracts
from `ver-IX86-1.mpq` and calls — not the Game.exe download/verify state machine
around it (that's in `d2-checkrevision`).

## TL;DR
The 1.14d check is **not** the classic bnetdocs A/B/C MPQ-formula. The DLL is an
**Authenticode self-attestation + SHA-1 responder**. Its response cryptographically
asserts "the EXE that loaded me and I myself are both Blizzard-Authenticode-signed",
*without hashing the EXE's bytes* — it hashes the EXE **path** and folds in a single
"are the signatures valid?" bit. For **realmd** none of this matters: the realm
accepts any `SID_AUTH_CHECK`, so a trivial stub DLL works. It only matters if you
ever talk to a server that actually validates the response (real Battle.net, or a
strict reimplementation).

## The DLL itself
- Built from Blizzard's `service-cpp-bnet-legacy`. Statically links MSVC CRT, the
  Concurrency Runtime, **Botan 2.1.0** (crypto), and Blizzard's own `blz::`
  string/stream lib. ~2400 functions; only one is real product logic
  (`CheckRevision`), the rest is library code.
- Single export: `CheckRevision` (ordinal 1).

## Real ABI (recovered)
`__stdcall`, **7 args**, `RET 0x1c`. Returns the output buffer pointer in EAX.

```c
void* __stdcall CheckRevision(
    void* a1, void* a2, void* a3,   // pushed by caller, UNUSED by the body
    const char* formula,            // arg4: base64 challenge from the server
    int*  lpDialogResult,           // arg5: out — a MessageBoxW result (usually 0)
    int*  lpResultLength,           // arg6: out — length of the response text
    char* lpResultBuffer);          // arg7: out — response text (0x80 buf); also returned
```

`a1..a3` are unused — the classic "exePath/file1/file2" args don't matter because
the DLL discovers the paths itself. (Our existing `checkrev.zig` stub names them
`file1/file2/file3/formula/out_version/out_checksum/out_exeinfo`; that's the *old
guessed* ABI. Harmless for realmd since we ignore inputs and the server ignores
outputs, but the real meaning is the table above.)

## What it computes
1. **Decode** `formula` from base64 → raw challenge bytes.
2. If decoded length < 4 → bail, empty response.
3. If length ≥ 6 and `decoded[5] != 0` → pop a localized **"Taiwan Legal
   Disclaimer"** `MessageBoxW` (Yes/No); its result is written to `lpDialogResult`.
4. **Normalize** the challenge to its first 4 bytes (pad with `0` if exactly 4,
   truncate if longer).
5. **Discover the host EXE path two ways** and concatenate, `:`-separated:
   - `GetModuleFileNameW(NULL)` — the loading process's main module.
   - A `CreateToolhelp32Snapshot` + `Process32First/Next` (match current PID) +
     `OpenProcess` + `EnumProcessModules` + `GetModuleFileNameExW` walk — an
     **anti-spoof cross-check** that resolves the same path independently.
   - Result so far: `<4 challenge bytes> ":" <exePath> ":" <exePathViaSnapshot>`.
6. **Authenticode-verify, in-DLL** (this is the integrity gate, not a content hash):
   - `WinVerifyTrust(WINTRUST_ACTION_GENERIC_VERIFY_V2)` on the **host EXE**.
   - `WinVerifyTrust(...)` on **this DLL itself**.
   - `CryptQueryObject`/`CryptMsgGetParam`/`CertFindCertificateInStore` on the DLL
     to pull the **signer's RSA public key**, then byte-compare it to a **hardcoded
     ~0x110-byte expected pubkey blob** baked into the DLL (Blizzard's key).
   - `sigOk = exeTrusted && dllTrusted && pubkeyMatches` → one **byte (0 or 1)**.
7. **Append** that `sigOk` byte to the string from step 5.
8. **SHA-1** (Botan `SHA_160`) the whole string.
9. **base64-encode** the 20-byte digest (standard `A–Za–z0–9+/`, `=` padded) →
   write to `lpResultBuffer`, length to `lpResultLength`.

So, conceptually:

```
response = base64( SHA1( first4(b64decode(formula))
                         + ":" + exePath + ":" + exePath
                         + (signaturesValid ? 0x01 : 0x00) ) )
```

**Key insight:** tamper-resistance comes from the *Authenticode signature check*,
not from hashing the binary. A modified/unsigned EXE still produces a well-formed
response — but with the `sigOk` byte = `0`, so the digest differs from the
"genuine" one. A server that knows the algorithm can tell a signed Blizzard EXE
from anything else by recomputing and comparing.

## Faking it with a static / unsigned Game.exe
"Static" here = our own or an unmodified-but-not-Blizzard-signed `Game.exe`, i.e.
one for which `WinVerifyTrust` will **not** return trusted. Three levels:

### 1. realmd (what we actually do) — trivial
realmd accepts any `SID_AUTH_CHECK`, so the response value is irrelevant; the
client only has to *complete the flow without crashing*. We don't ship the real
DLL at all — we pack our **own** `ver-IX86-1.dll` (`src/checkrev/checkrev.zig`)
that ignores its inputs, writes dummy out-params, and returns. No Authenticode, no
SHA-1, works with any EXE. The hard part was never the crypto — it was the BNFTP
reply (u32 length header) and getting the download to complete; both solved (see
[[d2-checkrevision]]). The actual deployed path patches
`BNDOWNLOAD_PerformCheckRevision` client-side (`--bypass-checkrev`) once the
download succeeds.

### 2. Strict server, but we control the DLL — patch the gate
If something downstream validates the response yet we still control the inner DLL,
make `sigOk` always `1` and compute the genuine-shaped digest with any EXE:
- Patch out the two `WinVerifyTrust` results + the pubkey compare so step 6 yields
  `1` unconditionally, **or** reimplement steps 1–9 in our own DLL forcing `sigByte=1`.
- Then `response = base64(SHA1(first4(decode(formula)) + ":"+path+":"+path + 0x01))`
  for whatever path our EXE reports — and it looks "genuine signed" to the verifier.
- You can NOT instead re-sign the EXE to satisfy the *real* DLL: the expected pubkey
  blob is Blizzard's; you don't have the matching private key.

### 3. We don't control the DLL (real Blizzard DLL + strict/real server)
Then `sigOk` will be `0` for a non-Blizzard EXE and the response won't match a
genuine one. Options, in order of sanity:
- **Make `WinVerifyTrust` pass**: install our code-signing root as a trusted Root
  in the (wine) cert store and sign EXE+DLL with `O="Blizzard Entertainment, Inc."`.
  This flips `exeTrusted`/`dllTrusted` to true — but the **pubkey-blob compare**
  still fails (our key ≠ Blizzard's embedded key), so `sigOk` stays `0`. Dead end
  against the *real* DLL unless you also patch the blob compare (→ level 2).
- **Inject the response directly**: compute the level-2 formula yourself and write
  the `SID_AUTH_CHECK` from a client patch/proxy, skipping the DLL entirely.

## Bottom line for this repo
We're firmly in case 1. The reverse-engineering matters for *correctness/clarity*
(now we know the real ABI and that args 1–3 are unused, the response is
base64(SHA1(...)), and integrity = Authenticode not byte-hash), but it doesn't
change the working recipe: serve a downloadable weak-signed MPQ + bypass the call
client-side. If we ever want a *self-contained* (no client patch) story, level 2 —
ship our own signed `ver-IX86-1.dll` that forces `sigOk=1` — is the move, and only
then if a downstream actually checks the value.
```
