# Legal / Disclaimer

## No game content is distributed here
This repository contains **no Diablo II game files and no Blizzard code**. The
only binary fixture is `tools/stub.mpq` — an *empty* MPQ container (header +
empty tables, no files inside), used as a placeholder for media archives the
headless server doesn't need.

To use this project you must supply your **own, legitimately obtained** copy of
Diablo II: Lord of Destruction (1.14d). `tools/make-minimal.sh` copies files
**from your local install** into a test directory; it does not download,
contain, or redistribute any Blizzard data.

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
