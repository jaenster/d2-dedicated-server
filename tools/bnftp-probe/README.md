# bnftp-probe

A clientless **BNFTP discovery client** — points at a real Battle.net server and
dumps what it serves. BNFTP (protocol selector `0x02`) is *unauthenticated*: no
CD-key, no SRP, no login. So with two CD-key-free steps we can pull a real
server's version-check MPQ and compare its wire format against our own
`apps/realmd/bnftp.zig`.

What it does:

1. Connect `0x01` → `SID_AUTH_INFO` (echoing the `SID_PING` cookie Blizzard sends
   on connect). The reply is unconditional and names the version MPQ + filetime.
2. Open a fresh `0x02` connection → BNFTP-request that file. Hexdump the reply
   header and save the payload to `./bnftp-<name>`.

## Run

```
zig build bnftp-probe -- [opts] <target-host> [product] [filename]
```

- `product` — 4CC, default `D2XP` (LoD). Use `D2DV` for classic.
- `filename` — optional; if omitted, uses the name from `SID_AUTH_INFO`.
- `--out-dir DIR` — save under the real filename into DIR (e.g. `realmd-data/bnftp`).
- `--find-patch` — send `SID_AUTH_CHECK` with an old EXE version to provoke the
  "old game version" (result `0x100`) reply; its info string is the forced patch
  file, which is then BNFTP-downloaded. Still CD-key-free (version is checked
  before keys). `--old-ver N` overrides the deliberately-old version (default 1).
- `--head` — read only the BNFTP reply header (size + name), skip the body. Use
  to sweep candidate filenames for existence without pulling multi-MB payloads.
- `--socks5 HOST:PORT` — egress through a SOCKS5 proxy (the proxy does DNS).
- `--socks5-auth USER:PASS` — RFC 1929 user/pass for the proxy.
- `--port N` — default 6112.
- `--proto-ver 0xNNNN` — BNFTP version, default `0x0100`.

Verified live against `useast.battle.net`: pulls `CheckRevision.mpq` (168704 bytes)
and confirms our reply-header layout byte-for-byte. `--find-patch` reveals the
forced update MPQ and downloads it.

## What's hosted (discovered via the patterns above)

Patch filename pattern: `<product>_<platform>_1xx_<version>.mpq`.

- Blizzard hosts ONLY the current version (`114d`) — historical patches
  (`113c`, `112a`, `110`, …) are gone; the auto-patcher always jumps to current.
- Windows (`IX86`) and Intel-Mac (`XMAC`) builds exist for both `D2DV`/`D2XP`;
  PowerPC-Mac (`PMAC`) is retired.

Known-good files: `CheckRevision.mpq`, `D2DV_IX86_1xx_114d.mpq` (10497328),
`D2XP_IX86_1xx_114d.mpq` (6169139), `D2DV_XMAC_1xx_114d.mpq` (11140682),
`D2XP_XMAC_1xx_114d.mpq` (6828960).

## Egress via a proxy

The probe speaks SOCKS5, so any SOCKS5 proxy works — no proxy code needed:

- **Free, zero-setup:** `ssh -D 1080 you@hetzner` opens a SOCKS5 proxy on
  localhost:1080 that egresses from the Hetzner box. Then:
  `zig build bnftp-probe -- --socks5 127.0.0.1:1080 useast.battle.net D2DV`
- **Standalone:** run a small SOCKS5/HTTP proxy on Hetzner if you want it
  always-on (or over Tailscale) instead of an SSH tunnel.
