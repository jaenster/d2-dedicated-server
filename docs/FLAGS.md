# Flags

Passed to `Game.exe`, read by our DLLs. Several have an environment-variable equivalent, which
is what the container images and the Helm chart use.

## Boot / connection

| flag | effect |
|-|-|
| `--loaddll <path>` | (proxy) LoadLibrary an injected DLL; repeatable |
| `--d2gs` | attach + log; install crash/halt/multi-instance guards |
| `--d2gs-boot` | run the engine bootstrap + tick loop (the dedicated server) |
| `--realm` | join a realm: publish this server into the shared store, take create/join from its queue there, and read/write characters there |
| `--create-games` | load data tables so the engine can create games |
| `--redis <host:port>` | the shared store — this server's only link to a realm. Env: `D2GS_REDIS_ADDR` |
| `--gs-addr <ip:port>` | public address clients dial for this GS's games (self-reported to realmd). Env: `D2GS_GS_ADDR` |
| `--max-games <n>` | capacity this GS advertises to realmd. Env: `D2GS_MAX_GAMES` |
| `--reap-ms <n>` | how long an empty game is kept before it is destroyed (default 5000). Also this server's throughput ceiling -- see [How many games per server](PERFORMANCE.md#how-many-games-per-server). Env: `D2GS_REAP_MS` |
| `--realm-gw <ip>` | (client) point the game's bnet gateway list at your realm instead of Blizzard's |

## Feature toggles

Off by default unless noted. See [`docs/MODDING.md`](MODDING.md).

| flag | effect |
|-|-|
| `--headless` | apply survival/no-display patches (run with no GUI) |
| `--bypass-checkrev` | (client) skip the bnet version check |
| `--no-compress` | disable packet compression (debugging) |
| `--expmod` | server: XP scaling |
| `--ubers` | server: Pandemonium / Uber Tristram event |
| `--arena` | server: PvP arena rounds |
| `--ladder-items` | server: ladder-only item content (opt-in; bootstrap-flaky) |
| `--guild-panel` | client: Steeg Stone guild panel |
| `--omnivision` / `--mapunits` / `--mapreveal` | client: maphack (see-through, monster/item dots, auto-reveal) |

## Client driving / debug

| flag | effect |
|-|-|
| `--auto-login <acct:pass>` | (client) drive login -> char select -> create a game |
| `--auto-join <acct:pass:game>` | (client) drive login -> char select -> join a game |
| `--bot <name>` | run an in-game bot (`apps/d2gs/bot/`) |
| `--screenshot` | (client) take a screenshot every 3s (headed debugging) |
| `--pkttrace` | log every `:4000` client/GS packet id (verbose) |
| `--suppress-halts` | swallow engine asserts instead of exiting (debugging) |
| `--eipprof` | sample every thread's program counter from inside the process and report the hot engine addresses. No host profiler can see them: the 32-bit guest runs translated under wine, so a host sampler only ever sees the translator. Not for a live realm |
| `--memdiag` | report the engine's working set per bootstrap step |
| `--test-enter` | drive the server into a game on its own, with no client (DRLG capture) |
| `--fetch-char <acct:char>` / `--create-char` | exercise the d2dbs character fetch / creation paths |
| `--d2bs` | inject D2BS after the game window exists (kolbot on a stock client) |
| `--dump-cdkeys` | print the decoded classic/expansion CD-key globals |

## realmd configuration

`realmd` is configured by environment only (`REALMD_*`) -- see
[`REALMD.md`](../REALMD.md#configuration-env-only).

## d2gs-native configuration

The wine-free game server takes no flags but `--dry-run`; everything else is `D2GS_*`
environment, listed in [`apps/d2gs-native/README.md`](../apps/d2gs-native/README.md).

Two differences worth knowing if you run both kinds of server. `D2GS_MAX_GAMES` here is the
**actual** cap on concurrent games (1..7, default 1), where above it is the capacity this GS
advertises to realmd. And `D2GS_GS_ADDR` here only changes what clients are told -- the native
server always binds `:4000`, so map the port rather than expecting the listener to move.
