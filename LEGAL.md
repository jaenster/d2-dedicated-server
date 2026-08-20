# Legal / Disclaimer

## Game data
This repository's source contains **no Diablo II game files and no Blizzard
code**. The only binary fixture is `tools/stub.mpq` — an *empty* MPQ container
(header + empty tables, no files inside), used as a placeholder for media
archives the headless server doesn't need.

`tools/make-minimal.sh` builds a minimal 1.14d install from a local copy: every
MPQ member a headless server never opens is stripped, and graphics blocks are
stripped out of the tilesets it keeps (`tools/mpqmin`) — no audio, no video, no
CD keys. Every published `ghcr.io/jaenster/d2gs` image bakes in a copy of that stripped
set, fetched at build time from a mirror at files.typeguru.nl, so the images run
without a manual data-supply step. Diablo II 1.14d receives no further updates or
enforcement from Blizzard and is treated here as abandonware; if that changes,
this section will too.

## Reverse engineering
The addresses, offsets, and struct layouts in this project describe the retail
1.14d `Game.exe` and were obtained by reverse engineering for the purpose of
**interoperability** (running the binary's own server engine in a dedicated
configuration). No Blizzard source code is included.

## Trademarks / affiliation
Diablo® II and Diablo® II: Lord of Destruction® are trademarks and/or copyright
of Blizzard Entertainment, Inc. This is an **unofficial, fan-made** project. It
is not affiliated with, endorsed by, sponsored by, or supported by Blizzard
Entertainment.

## No warranty
The code is provided "as is", without warranty of any kind. You are responsible
for complying with the Diablo II End User License Agreement and any applicable
laws in your jurisdiction. Use at your own risk.

## Code license
The source code in this repository is licensed under the MIT License — see
[`LICENSE`](LICENSE).
