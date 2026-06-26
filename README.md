# d2-dedicated-server — headless, cloud-native Diablo II 1.14d dedicated game server + realm

A **self-hosted, open-source Diablo II dedicated game server** for retail **1.14d**,
plus a clean-room **Battle.net realm server** — a modern, **cloud-native PvPGN
replacement** you run with Docker / Kubernetes. All in **Zig**.

Turns the single-binary Diablo II 1.14d `Game.exe` into a **headless dedicated game
server**, the way older versions do with the split DLLs — except in 1.14d the whole
server engine (`Fog::QServer` + `D2Game::Game::Server`) is statically linked inside
`Game.exe`. We don't reimplement it; we **drive the real engine** from an injected
Zig DLL. The bundled realm server (`realmd`) replaces **PvPGN** (bnetd + d2cs + d2dbs),
so the **unmodified retail client** logs in and plays end to end — no client mods.

> **Status: a real 1.14d client logs into the realm, creates/joins a game on the
> headless server, and the character spawns in-world — including two clients in
> the same game (multiplayer).** See [Status](#status).

Built for **containers and Kubernetes**: the Windows `Game.exe` runs under wine, fully
headless — no GUI, no X, no display — and `realmd` ships as a few-MB static binary.
A capacity-aware **game-server fleet** registers with the realm; state lives in
**Postgres + Redis** (or just the filesystem); health/readiness probes and graceful
shutdown make it a first-class **cloud-native** workload. Logs stream to **stdout**
(JSON optional) — `docker logs` / journald / `kubectl logs` just work. One
`docker compose up` runs the whole stack locally; manifests in [`deploy/`](deploy/).

## The pieces

```
          unmodified 1.14d client (GUI)
                     |  BNCS / MCP / BNFTP
                     v
   ┌─────────────────────────────────┐      gs-link (6115)     ┌──────────────────────┐
   │  realmd  (native Zig binary)     │ <───────────────────── │  headless Game.exe   │
   │  bnetd 6112  login + version MPQ │                        │  + d2gs.dll (injected)│
   │  d2cs  6113  realm / create-join │   char save (d2dbs)    │  drives QServer/D2Game│
   │  d2dbs 6114  character saves     │ <───────────────────── │  listens on :4000     │
   │  gslink 6115 GS dispatch         │                        └──────────────────────┘
   └─────────────────────────────────┘                                   ^
                     ^                                                    │ game traffic (:4000)
                     └────────────────── the client connects directly ───┘
```

- **realm server** (`src/realm/server/`, native; the `realmd` binary): one binary
  replacing pvpgn's bnetd + d2cs + d2dbs, plus a GS-link the injected server connects to.
  Pluggable persistence (fs/redis/pg) survives restarts; multi-instance. See
  [`src/realm/server/README.md`](src/realm/server/README.md).
- **game server** (`src/d2gs.zig` + `src/engine/` + `src/realm/client/`): the injected
  DLL that boots `Game.exe` as a headless dedicated server and bridges it to realmd via
  the engine's realm callback table. See [`src/engine/README.md`](src/engine/README.md).
- **shared realm contract** (`src/realm/shared/`): the d2cs↔d2gs wire protocol both ends
  import (the `realm_shared` module), so client and server agree on the wire by construction.

## Resource footprint (idle)

A common worry with a wine-based D2 server is that it idles hot — the 1.14d engine's
main loop busy-spins by default (it was written to render a client as fast as it can).
It doesn't here: the engine's out-of-game loop is frame-paced, so an **idle game server
sits near-zero**. Measured on a real Hetzner k3s node with no players online:

| service | CPU | memory | image |
|-|-|-|-|
| `realmd` (bnetd + d2cs + d2dbs + gslink) | ~1m | ~6 MiB | scratch, static musl |
| `qqserver` (game-traffic gateway) | **~0m** | **~1 MiB** | scratch, static musl |
| `d2gs` (wine, headless `Game.exe`) | ~15m | ~300 MiB | debian + wine32 |

The clean-room Zig services are effectively free (a few millicores, single-digit MiB);
the game server's footprint is just wine plus the loaded engine. Postgres/Redis are
optional — `fs` persistence drops them entirely.

## Architecture

The full model lives in [`docs/architecture/`](docs/architecture/) (LikeC4) and can
be browsed live with `npx likec4 start docs/architecture`. Rendered views:

**Landscape** — native D2 modules + the d2gs project parts:

![Landscape](docs/architecture/img/index.png)

**GS fleet** — realmd's `gslink` keeps a registry of *many* game servers. A GS
connects out (`:6115`), self-reports its public `<ip>:4000` + `gsid` + capacity
(ADDRINFO); `CREATE` routes to the least-loaded GS, `JOIN` to the owning `gsid`.
The persistence facade dispatches to `fs` / `redis` (ephemeral) / `pg` (durable):

![GS fleet](docs/architecture/img/gs_fleet.png)

**Kubernetes topology** — stateless realmd behind a LoadBalancer (`/readyz`-gated)
with Redis + Postgres backends, and a GS StatefulSet whose pods bind `hostPort 4000`
on their Node IP. The player logs in via the LB, then talks game traffic *directly*
to `nodeIP:4000`:

![Kubernetes topology](docs/architecture/img/k8s_deploy.png)

## Admin web UI

A small Vite + React UI ([`webui/`](webui/)) over realmd's `/admin/*` JSON API —
fleet/games/accounts at a glance, plus create-account, close-game and copy-char. It
bundles to one self-contained `index.html` and is embedded into the realmd binary
(`zig build realmd-bin -Dwebui=true`), served on the health/admin port. Admin-ness is a
DB flag on the account — seed one with `realmd create-admin <name> <password>` or
`REALMD_ADMIN_BOOTSTRAP`, then sign in (password → signed session cookie) and promote
others from the UI. Or front it with Authentik/oauth2-proxy SSO
([`deploy/AUTHENTIK-SSO.md`](deploy/AUTHENTIK-SSO.md)); a bearer token
(`REALMD_ADMIN_TOKEN`) stays for scripts/break-glass. Keep port 8080 behind a
port-forward or the authed ingress, never public.

![realmd admin — overview](webui/img/overview.png)

![realmd admin — accounts](webui/img/accounts.png)

![realmd admin — login](webui/img/login.png)

## How injection works

```
Game.exe --(loads)--> dbghelp.dll (our proxy) --(--loaddll)--> d2gs.dll [+ your mod DLLs]
                                                                  |
                                                DllMain spawns serverThread:
                                                  bootstrapRealmServer() + realm callbacks
                                                  loop: HandleAnyIncomingPacket
                                                        + TickAllGames + DispatchAndCleanup
```

- **Delivery:** `Game.exe` loads `dbghelp.dll` for its crash handler. Our proxy
  forwards the real exports and `LoadLibrary`s the DLLs passed via
  `--loaddll <winpath>` — that's how `d2gs.dll` gets in. No on-disk patch of `Game.exe`.
- **Headless:** `--headless` byte-patches (`src/runtime/headless.zig`) stub the
  renderers/media loaders and hide the window so the host survives with no display.
- **Server tick:** mirrors the engine's own `QSERVER_CoopThreadMain` — drain inbound
  packets, tick all games, then **flush queued outbound packets** (the
  `DispatchAndCleanup` step is what makes a joining client actually progress).

## Loading mods / server modifications

The proxy loads **any** DLL you pass with `--loaddll`, repeatable. A server mod is
just another injected DLL that hooks/patches the engine in its `DllMain`:

```
wine Game.exe ... --loaddll Z:\path\d2gs.dll --loaddll Z:\path\yourmod.dll --d2gs ...
```

Each runs in-process with full access to the engine at its fixed addresses (image
base `0x00400000`, no ASLR). `d2gs.dll` is just the first such DLL.

In the **container**, drop mod DLLs in `/mods` (each `--loaddll`'d after `d2gs.dll`)
or list them in `D2GS_EXTRA_DLLS`; overlay extra **data** (mod MPQs, or a loose
`data/` tree with `D2GS_EXTRA_ARGS="-direct -txt"`) by mounting it at `/moddata` —
it's merged onto the read-only game install in a writable work dir at startup.

## Build

```
zig build     # -> zig-out/bin/{dbghelp.dll, d2gs.dll, ver-IX86-1.dll}  (x86-windows)
              #    + zig-out/bin/realmd  (native host binary)
```

## Run the full stack

### Quick: the cloud stack with Docker Compose

The same `realmd` image and backends you'd run on Kubernetes, on one host — `realmd`
with **Postgres** (durable char saves) + **Redis** (ephemeral sessions/games). Full
file at [`deploy/compose.yaml`](deploy/compose.yaml) (it also has a profile-gated `gs`
game-server service); the core is just:

```yaml
services:
  redis:
    image: redis:7-alpine
  postgres:
    image: postgres:16-alpine
    environment: { POSTGRES_USER: realmd, POSTGRES_PASSWORD: realmd, POSTGRES_DB: realmd }
  realmd:
    build: { context: ., dockerfile: deploy/Dockerfile, target: realmd }
    depends_on: [redis, postgres]
    environment:
      REALMD_DURABLE_STORE: pg          # character saves
      REALMD_EPHEMERAL_STORE: redis     # sessions + games (native TTL)
      REALMD_REDIS_ADDR: redis:6379
      REALMD_PG_DSN: postgres://realmd:realmd@postgres:5432/realmd
      REALMD_LOG_JSON: "1"
    ports: ["6112:6112", "6113:6113", "6114:6114", "6115:6115", "18080:8080"]
```

```
docker compose -f deploy/compose.yaml up --build
curl localhost:18080/readyz        # 200 once Postgres + Redis are reachable

# also run the headless game server in-compose (needs your D2 1.14d install):
D2GS_GAME_SRC=/path/to/d2-1.14d docker compose -f deploy/compose.yaml --profile gs up --build
```

The `gs` service is profile-gated because the game files are proprietary (mount them via
`D2GS_GAME_SRC`). For machine-specific tweaks keep a gitignored
`deploy/compose.local.yaml` and add `-f deploy/compose.local.yaml`.

### Manual (native realmd + wine GS)

```
# 1) realm server (native; data dir holds accounts/chars/games)
REALMD_DATA_DIR=./realmd-data ./zig-out/bin/realmd

# 2) headless game server (wine), registers with realmd's gs-link
wine Game.exe -w -nosound --headless --loaddll Z:\...\d2gs.dll \
    --d2gs --d2gs-boot --realm --create-games \
    --d2cs 127.0.0.1:6115 --d2dbs 127.0.0.1:6114

# 3) a real client (point its bnet gateway at realmd, then log in normally)
wine Game.exe -w -skiptobnet --loaddll Z:\...\d2gs.dll --d2gs --bypass-checkrev
```

`./run.sh` builds the DLLs and assembles a wine test dir for the injection-only
case. The full create+join flow has an end-to-end test:
[`tools/realmd-test/e2e-game.sh`](tools/realmd-test/e2e-game.sh) (boots realmd + GS,
drives two clients to create + join, asserts both characters loaded; needs wine +
a real 1.14d install via `E2E_GAME_SRC`).

## Flags (passed to Game.exe, read by our DLLs)

| flag | effect |
|-|-|
| `--loaddll <path>` | (proxy) LoadLibrary an injected DLL; repeatable |
| `--d2gs` | attach + log; install crash/halt/multi-instance guards |
| `--headless` | apply survival/no-display patches |
| `--d2gs-boot` | run the engine bootstrap + tick loop (the dedicated server) |
| `--realm` | bootstrap in realm mode (register the realm callback table) |
| `--create-games` | load data tables so the engine can create games |
| `--realmd <host>` | connect to one realm server, deriving gs-link (`:6115`) + d2dbs (`:6114`); DNS ok. Env: `REALMD_HOST` |
| `--d2cs <ip:port>` | connect to realmd's gs-link for create/join dispatch (overrides `--realmd`) |
| `--d2dbs <ip:port>` | fetch character saves from realmd's d2dbs (overrides `--realmd`) |
| `--gs-addr <ip:port>` | public address clients dial for this GS's games (self-reported to realmd). Env: `D2GS_GS_ADDR` |
| `--max-games <n>` | capacity this GS advertises to realmd. Env: `D2GS_MAX_GAMES` |
| `--bypass-checkrev` | (client) skip the bnet version check |
| `--screenshot` | (client) take a screenshot every 3s (headed debugging) |
| `--auto-login <acct:pass>` | (client) drive login → char select → create a game |
| `--auto-join <acct:pass:game>` | (client) drive login → char select → join a game |
| `--pkttrace` | log every `:4000` client↔GS packet id (verbose) |
| `--suppress-halts` | swallow engine asserts instead of exiting (debugging) |

## Layout

```
src/
  dbghelp.zig    dbghelp.dll proxy — injection foothold (--loaddll loader)
  d2gs.zig       d2gs.dll entry — DllMain, flag parsing, server thread + tick loop
  log.zig        logger (stdout + file)
  realm/         the realm link — both ends + their shared contract        [README]
    shared/      d2cs<->d2gs wire protocol (the realm_shared module)
    client/      GS-side clients of the realm (d2cs/d2dbs, join context)   [README]
    server/      realm server / realmd binary: bnetd+d2cs+d2dbs+gs-link,
                 pluggable store (fs/redis/pg), health, graceful shutdown   [README]
  engine/        bindings into Game.exe's own engine + realm callback table [README]
  runtime/       in-process machinery: byte-patches, hooks, fastcall, diagnostics [README]
  test/          client-driving test harnesses (auto-login/join, screenshots) [README]
  checkrev/      CheckRevision.dll producer for the version-check MPQ       [README]
deploy/
  Dockerfile         multi-target image: `--target realmd` (scratch) | `--target gs` (wine)
  compose.yaml       local stack — realmd + Postgres + Redis (+ `gs` profile)
  realmd.yaml        k8s — realmd Deployment + redis/pg + probes + LoadBalancer
  gs.yaml            k8s — game-server StatefulSet (hostPort 4000 + node IP)
  gs-entrypoint.sh   headless-wine launcher (assembles game dir, loads mods)
docs/architecture/   LikeC4 model (diablo2.c4 + cloud.c4) + exported diagrams (img/)
```

Each `src/*` directory has its own `README.md`. Other docs:
[`REALM.md`](REALM.md), [`REALMD.md`](REALMD.md), [`VERIFY.md`](VERIFY.md), [`LEGAL.md`](LEGAL.md).

## Status

**Working** (tested under wine on the unmodified retail 1.14d `Game.exe`):
- ✅ Injection (`dbghelp` proxy → `--loaddll` → `DllMain`) + headless survival.
- ✅ Dedicated server boots, listens on `:4000`, ticks stably.
- ✅ `realmd`: real client logs in, passes the version check (BNFTP MPQ +
  CheckRevision), selects a realm, lists + loads characters.
- ✅ Create + join a game dispatched to the headless GS.
- ✅ **Character spawns in-world** (loaded from d2dbs, full life/mana, playable).
- ✅ **Multiplayer** — two real clients in one game, visible to each other.

**Rough edges / next:**
- ⏳ Verbose join diagnostics (`joindiag`) compiled in by default; `pkttrace` gated.
- ⏳ Two headed clients in one wineprefix can trip the bnet gateway-list parser on
  the second client's startup (intermittent); the e2e test retries.
- ⏳ Harden across restarts + many concurrent games; replace the fixed init delay
  with a proper engine-init hook.

## License & legal

Code: [MIT](LICENSE). No Blizzard game files are distributed here — bring your own
legit copy of Diablo II. Unofficial, not affiliated with Blizzard. See
[`LEGAL.md`](LEGAL.md).
