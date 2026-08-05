# d2-dedicated-server: headless, cloud-native Diablo II 1.14d dedicated game server + realm

[![Discord](https://img.shields.io/badge/Discord-join%20the%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/MHK2Dg9)

A **self-hosted, open-source Diablo II dedicated game server** for retail **1.14d**, plus a
clean-room **Battle.net realm server** -- a modern, **cloud-native PvPGN replacement** you run
with Docker / Kubernetes. All in **Zig**.

Older D2 versions split the server into separate DLLs you could host on their own; in 1.14d
the whole server engine is statically linked inside the single `Game.exe`. We don't reimplement
it -- we **drive the real engine** from an injected Zig DLL, fully headless. The bundled realm
server replaces **PvPGN**, so the **unmodified retail client** logs in and plays end to end,
with no client mods.

> **Status: a real 1.14d client logs into the realm, creates/joins a game on the headless
> server, and the character spawns in-world -- including two clients in the same game
> (multiplayer).** See [Status](#status).

Built for **containers and Kubernetes**. The Windows `Game.exe` runs under wine with no GUI or
display; the realm and gateway are few-MB static binaries that contain no game files. State
lives in Postgres + Redis, or just the filesystem. Health/readiness probes, graceful shutdown,
and structured stdout logging (JSON optional) make it a first-class **cloud-native** workload --
`docker logs` / `kubectl logs` just work, and logs/metrics drop straight into a
[Grafana dashboard](#observability). A [Helm chart](#kubernetes-helm) and a
[Docker Compose](#docker-compose) stack are both in [`deploy/`](deploy/).

## The three packages

The project is three independently-deployable pieces. Two are **pure-Zig native binaries** (no
Windows, no game files -- they scale freely); the third is the injected Zig DLL that drives the
real game engine under wine.

### realmd: the realm (PvPGN replacement)

`src/realm/server/` builds the `realmd` binary. One **pure-Zig** process that does the job of
all of PvPGN's separate daemons: login/chat, the realm (character select, game create/join),
the character database, and a registration endpoint the game-server fleet connects to.

To the retail client it looks exactly like Battle.net: the client logs in over **BNCS** (the
Battle.net chat protocol, login + the version gate) and then talks **MCP** (the realm protocol:
list/select characters, create/join a game) -- and, like real Battle.net, **both run on a single
port, 6112**. There is no pvpgn-style fan of client ports. Game-file delivery for the version
check uses **BNFTP** on the same port.

Behind that one client port, realmd also exposes two **internal** endpoints the game-server fleet
uses (never the client): a **gs-link** (port 6115) the fleet registers over and that routes
create/join to a server, and **d2dbs** (port 6114) the server fetches/saves character bytes from.

Persistence dispatches to `fs` (default, zero deps), `redis` (ephemeral sessions/games), or `pg`
(durable chars), so realmd is **stateless and horizontally scalable** -- all state lives in the
backing services. Health/readiness and the admin UI are on `:8080`; SIGTERM drains cleanly.
See [`src/realm/server/README.md`](src/realm/server/README.md).

### d2gs: the headless game server (injected into Game.exe)

`src/d2gs.zig` + `src/engine/` + `src/runtime/` build the injected `d2gs.dll`. It boots the real
1.14d `Game.exe` as a **headless dedicated server** and bridges it to `realmd`. Two layers:

- **Survival + optimization patches** -- byte-patches that let the Windows engine run with no
  display (stub the renderers/media loaders, hide the window) and frame-pace its idle loop so the
  server sits near-zero CPU (see [Resource footprint](#resource-footprint-idle)). It also drives
  the engine's own server tick: drain inbound packets, tick all games, flush queued outbound.
- **A built-in mod framework** -- a registry of pure feature modules that hook the engine (exp
  scaling, ubers, an arena mode, client-side maphack, ...), each toggled on its own. Adding a
  server mod is writing a Zig module that declares the hooks it wants; see [Modding](#modding).
  You can also `--loaddll` your own DLLs alongside `d2gs.dll`.

On a join the server does not read a shared disk -- it **fetches the character over the network**
from realmd's d2dbs, which serves it from whichever store backend is configured (redis / pg / fs).
See [`src/engine/README.md`](src/engine/README.md) and [`src/runtime/README.md`](src/runtime/README.md).

### qqserver: the game-traffic gateway (one IP for the whole fleet)

`src/realm/qqserver/` builds the `qqserver` binary, a **pure-Zig**, stateless game-traffic
gateway. It gives the entire game-server fleet a **single public game port (`:4000`)**.

When a client joins, realmd hands it a short-lived **join token** and writes the route for that
token (`token -> GS pod + real game id`) into the shared store (redis). The client connects to
`qqserver:4000` carrying the token. The gateway reads it, looks up the route, and **splices** the
connection straight through to the owning game server's internal `:4000`.

Because tokens are realm-globally unique, **any** gateway pod behind **any** public IP can resolve
**any** token -- so it needs no session affinity and holds no state of its own. This is what lets
the game servers live on internal pod IPs (or the same host on other ports) while clients only ever
see one address. (In the lightweight single-binary path, realmd can do this splice in-process and
you don't run a separate qqserver at all.)

### Plus: the shared realm contract

Underpinning all three, `src/realm/shared/` (the `realm_shared` module) is the realmd<->d2gs wire
protocol that both the realm and the game server import, so they agree on the wire by construction.

## How it fits together

```
                unmodified 1.14d client (GUI)
                  |                            |
   login + realm  |  (BNCS + MCP on ONE        |  game traffic
                  v   port, like real bnet)    v  (D2Net)
       +----------------------+        +----------------------+
       |  realmd              |        |  qqserver            |
       |  :6112  login, realm |        |  :4000  public game  |
       |  :8080  health / UI  |        |         gateway      |
       +----------+-----------+        +-----------+----------+
            ^   ^      writes token route (redis)  |
  internal: |   +----------------------------------+
  gs-link   |              splice to the owning GS |
  :6115     |                                      v
  d2dbs     |   register + fetch     +----------------------+
  :6114     +------------------------|  Game.exe + d2gs.dll |
                character bytes      |  fleet 1..N          |
                                     |  internal :4000      |
                                     +----------------------+
```

The client only ever uses two ports: **6112** (login + realm) and **4000** (game). Everything
else (gs-link 6115, d2dbs 6114) is internal traffic between the game-server fleet and realmd.

Locally you can skip the gateway (**DIRECT** mode): the client dials the single GS at `:4000`
itself. In the cloud (**GATEWAY** mode) realmd advertises the qqserver entry instead, so the GS
fleet stays on internal pod IPs and scales past the node count. Same binaries either way.

### Rendered diagrams

The full model lives in [`docs/architecture/`](docs/architecture/) (LikeC4) and can be browsed
live with `npx likec4 start docs/architecture`. A few views:

**GS fleet** -- realmd's gs-link registers many game servers; `CREATE` routes to the least-loaded,
`JOIN` to the one that owns the game, with persistence behind the `fs`/`redis`/`pg` facade:

![GS fleet](docs/architecture/img/gs_fleet.png)

**d2gs.dll mod framework** -- the registry dispatches to pure feature modules; runtime drivers own
the engine byte-hooks and fan out; the d2 layer supplies structs, engine calls, and a per-game
memory pool:

![Feature framework](docs/architecture/img/feature_framework.png)

**Kubernetes topology** -- realmd and qqserver behind public LoadBalancers on stable floating IPs
(only 6112 + 4000 open); Redis + Postgres backends; an internal GS fleet whose pods register their
pod IP. The player logs in via the LB, then talks all game traffic to qqserver, which splices to
the owning GS:

![Kubernetes topology](docs/architecture/img/k8s_deploy.png)

## Resource footprint (idle)

The 1.14d engine's main loop busy-spins by default; d2gs frame-paces it, so an **idle game server
sits near-zero**. Measured on a real Hetzner k3s node with no players online:

| service | CPU | memory | image |
|-|-|-|-|
| `realmd` (login + realm + d2dbs + gs-link) | ~1m | ~6 MiB | scratch, static musl |
| `qqserver` (game-traffic gateway) | **~0m** | **~1 MiB** | scratch, static musl |
| `d2gs` (wine, headless `Game.exe`) | ~15m | ~300 MiB | debian + wine32 |

The pure-Zig services are effectively free; the game server's footprint is just wine plus the
loaded engine. Postgres/Redis are optional -- `fs` persistence drops them entirely.

## Build

```
zig build     # -> zig-out/bin/{dbghelp.dll, d2gs.dll, ver-IX86-1.dll}  (x86-windows)
              #    + zig-out/bin/{realmd, qqserver}  (native host binaries)
```

## Deploy

### Kubernetes (Helm)

[`deploy/chart`](deploy/chart/) is a Helm chart that deploys the whole fleet -- realmd, the d2gs
game-server fleet, qqserver, Postgres, and Redis -- wired together. It is a publishable mirror of
a real running cluster, with the cluster-specific IPs/passwords replaced by generic overridable
defaults. See [`deploy/chart/README.md`](deploy/chart/README.md).

```sh
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=203.0.113.10 \
  --set postgres.auth.password=$(openssl rand -hex 16)
```

Then supply the proprietary game data (a small private `dataImage`, or the `d2-gamefiles` PVC
fallback) and point `realmAddr` at the realmd LoadBalancer's external IP. Game traffic runs in one
of two modes:

- **DIRECT** (`gameAddr` empty, default): the GS keeps a client-routable address; clients dial it
  directly.
- **GATEWAY** (`floatingIPs` + `gameAddr` set): realmd advertises the qqserver entry; the GS is
  internal (pod-IP only, no hostPort) and the fleet can scale past the node count.

Useful toggles: `postgres.enabled` / `redis.enabled` (use external backends), `qqserver.enabled`,
`gameServer.dataImage.repository` (ship data via an initContainer instead of a PVC),
`gameServer.maxGames`. The raw manifests behind the chart are also in [`deploy/`](deploy/)
(`realmd.yaml`, `gs.yaml`).

### Docker Compose

The same `realmd` image and backends you'd run on Kubernetes, on one host: realmd with **Postgres**
(durable char saves) + **Redis** (ephemeral sessions/games). Full file at
[`deploy/compose.yaml`](deploy/compose.yaml) (it also has a profile-gated `gs` game-server
service); the core is just:

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
    ports: ["6112:6112", "6114:6114", "6115:6115", "18080:8080"]
```

```
docker compose -f deploy/compose.yaml up --build
curl localhost:18080/readyz        # 200 once Postgres + Redis are reachable

# also run the headless game server in-compose (needs your D2 1.14d install):
D2GS_GAME_SRC=/path/to/d2-1.14d docker compose -f deploy/compose.yaml --profile gs up --build
```

The `gs` service is profile-gated because the game files are proprietary (mount them via
`D2GS_GAME_SRC`). For machine-specific tweaks keep a gitignored `deploy/compose.local.yaml` and add
`-f deploy/compose.local.yaml`.

### Manual (native realmd + wine GS)

```
# 1) realm server (native). Char data lives in the configured store, not on the GS:
#    fs (a data dir, default), or redis/pg via REALMD_*_STORE.
REALMD_DATA_DIR=./realmd-data ./zig-out/bin/realmd

# 2) headless game server (wine). Registers over the gs-link and fetches characters
#    from realmd's d2dbs over the network -- it does NOT read a shared game-data mount.
wine Game.exe -w -nosound --headless --loaddll Z:\...\d2gs.dll \
    --d2gs --d2gs-boot --realm --create-games \
    --d2cs 127.0.0.1:6115 --d2dbs 127.0.0.1:6114

# 3) a real client (point its bnet gateway at realmd on :6112, then log in normally)
wine Game.exe -w -skiptobnet --loaddll Z:\...\d2gs.dll --d2gs --bypass-checkrev
```

`./run.sh` builds the DLLs and assembles a wine test dir for the injection-only case. The full
create+join flow has an end-to-end test: [`tools/realmd-test/e2e-game.sh`](tools/realmd-test/e2e-game.sh)
(boots realmd + GS, drives two clients to create + join, asserts both characters loaded; needs wine
+ a real 1.14d install via `E2E_GAME_SRC`).

## Observability

Every service logs structured **JSON to stdout** (`REALMD_LOG_JSON=1`), carrying a per-connection
and per-packet trace/span context across realmd and the game servers. Shipped to **Loki** (via
Promtail/Alloy) and paired with **Prometheus** pod metrics, the whole realm is one Grafana
dashboard: [`deploy/grafana/d2-realm.json`](deploy/grafana/d2-realm.json).

![Grafana - D2 Realm & Game Servers](docs/img/grafana-overview.png)


Its rows cover pod CPU/memory (Prometheus), **live state** (active games + players in-game, split
per game server), **realm activity** (games created, joins, refusals, qqserver drops, events/min),
a **GS fleet** view (games + load per `gsid`), a **health** row (engine halts/faults, pod restarts),
and a live log tail -- with deploys annotated on the timelines. The interesting part is that almost
none of this needs a metrics endpoint in the engine: the gameplay numbers fall out of the structured
logs in Loki. For example, "games created" and "player joins" are just `count_over_time` over the
parsed `evt` field:

```logql
sum(count_over_time({namespace="realmd", app="d2gs"} | json | evt=`game_create` [$__range]))
sum(count_over_time({namespace="realmd", app="d2gs"} | json | evt=`player_join`  [$__range]))
```

The dashboard is datasource-agnostic: its `${prom}` and `${loki}` variables are datasource pickers
(no URLs, tokens, or namespaces baked in). Import it in Grafana via **Dashboards -> New -> Import**,
upload the JSON, and pick your Prometheus + Loki sources.

## How injection works

```
Game.exe --(loads)--> dbghelp.dll (our proxy) --(--loaddll)--> d2gs.dll [+ your mod DLLs]
                                                                  |
                                                DllMain spawns serverThread:
                                                  bootstrapRealmServer() + realm callbacks
                                                  loop: HandleAnyIncomingPacket
                                                        + TickAllGames + DispatchAndCleanup
```

- **Delivery:** `Game.exe` loads `dbghelp.dll` for its crash handler. Our proxy forwards the real
  exports and `LoadLibrary`s the DLLs passed via `--loaddll <winpath>` -- that's how `d2gs.dll`
  gets in. No on-disk patch of `Game.exe`.
- **Headless:** `--headless` byte-patches stub the renderers/media loaders and hide the window so
  the host survives with no display.
- **Server tick:** mirrors the engine's own `QSERVER_CoopThreadMain`: drain inbound packets, tick
  all games, then **flush queued outbound packets** (the `DispatchAndCleanup` step is what makes a
  joining client actually progress).

## Modding

`d2gs.dll` has a small extensibility surface (`src/engine/feature.zig`). A **feature is just a Zig
module** (a namespace) that opts into a hook by declaring a `pub fn` of that name -- no base class,
no vtable. Dispatch is a comptime `inline for` over a single registry table that calls a hook only
on the features that declare it. Features stay pure behaviour; all config (name, toggle flag,
default state) lives in that **one registry table**.

Hooks a feature can declare include lifecycle (`install`, `postInit`, `deinit`), client frame loops
(`gameFrame`, `oogFrame`), and the dedicated-server domain (`serverTick`, `gameCreate` /
`gameDestroy`, `roomInit`, `expAward` to transform XP, `packetIn` / `packetOut`, `playerJoin` /
`playerLeave`). Each gets a per-game context whose allocator **is the game's own memory pool**, so
anything a feature allocates dies with the game. Copy
[`src/runtime/feature/template.zig`](src/runtime/feature/template.zig), add one line to the
registry, done.

Shipped features (see [`src/runtime/feature/`](src/runtime/feature/)): `expmod` (XP scaling),
`ubers` (Pandemonium / Uber Tristram), `arena` (server-side PvP rounds), `ladder-items`,
`guild-panel`, and client-side maphack (`omnivision`, `mapunits`, `mapreveal`) -- the same DLL
injects into a real client too. Each is toggled by its `--<flag>` ([Flags](#flags)).

For mods that need their own native code, the proxy loads **any** DLL you pass with `--loaddll`,
repeatable -- each runs in-process with full access to the engine at its fixed addresses (image
base `0x00400000`, no ASLR):

```
wine Game.exe ... --loaddll Z:\path\d2gs.dll --loaddll Z:\path\yourmod.dll --d2gs ...
```

In the **container**, drop mod DLLs in `/mods` (each `--loaddll`'d after `d2gs.dll`) or list them
in `D2GS_EXTRA_DLLS`; overlay extra **data** (mod MPQs, or a loose `data/` tree with
`D2GS_EXTRA_ARGS="-direct -txt"`) by mounting it at `/moddata`.

## Admin web UI

A small Vite + React UI ([`webui/`](webui/)) over realmd's `/admin/*` JSON API: fleet/games/accounts
at a glance, plus create-account, close-game, and copy-char. It bundles to one self-contained
`index.html` embedded into the realmd binary (`zig build realmd-bin -Dwebui=true`), served on the
health/admin port. Admin-ness is a DB flag on the account -- seed one with
`realmd create-admin <name> <password>` or `REALMD_ADMIN_BOOTSTRAP`, then sign in and promote others
from the UI. Or front it with [Authentik/oauth2-proxy SSO](deploy/AUTHENTIK-SSO.md); a bearer token
(`REALMD_ADMIN_TOKEN`) stays for scripts/break-glass. Keep port 8080 behind a port-forward or the
authed ingress, never public.

![realmd admin - overview](webui/img/overview.png)

![realmd admin - accounts](webui/img/accounts.png)

![realmd admin - login](webui/img/login.png)

## Flags

Passed to `Game.exe`, read by our DLLs.

**Boot / connection:**

| flag | effect |
|-|-|
| `--loaddll <path>` | (proxy) LoadLibrary an injected DLL; repeatable |
| `--d2gs` | attach + log; install crash/halt/multi-instance guards |
| `--d2gs-boot` | run the engine bootstrap + tick loop (the dedicated server) |
| `--realm` | bootstrap in realm mode (register the realm callback table) |
| `--create-games` | load data tables so the engine can create games |
| `--realmd <host>` | connect to one realm server, deriving gs-link (`:6115`) + d2dbs (`:6114`); DNS ok. Env: `REALMD_HOST` |
| `--d2cs <ip:port>` | connect to realmd's gs-link for create/join dispatch (overrides `--realmd`) |
| `--d2dbs <ip:port>` | fetch character saves from realmd's d2dbs (overrides `--realmd`) |
| `--gs-addr <ip:port>` | public address clients dial for this GS's games (self-reported to realmd). Env: `D2GS_GS_ADDR` |
| `--max-games <n>` | capacity this GS advertises to realmd. Env: `D2GS_MAX_GAMES` |

**Feature toggles** (off by default unless noted):

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

**Client driving / debug:**

| flag | effect |
|-|-|
| `--auto-login <acct:pass>` | (client) drive login -> char select -> create a game |
| `--auto-join <acct:pass:game>` | (client) drive login -> char select -> join a game |
| `--bot <name>` | run an in-game bot (`src/bot/`) |
| `--screenshot` | (client) take a screenshot every 3s (headed debugging) |
| `--pkttrace` | log every `:4000` client/GS packet id (verbose) |
| `--suppress-halts` | swallow engine asserts instead of exiting (debugging) |

## Layout

```
src/
  dbghelp.zig    dbghelp.dll proxy: injection foothold (--loaddll loader)
  d2gs.zig       d2gs.dll entry: DllMain, flag parsing, server thread + tick loop
  log.zig        logger (stdout + file)
  realm/         the realm: both ends, the gateway, + their shared contract     [README]
    shared/      realmd<->d2gs wire protocol (the realm_shared module)
    client/      GS-side clients of the realm (gs-link/d2dbs, join context)
    server/      realmd binary: login + realm + d2dbs + gs-link, pluggable store
                 (fs/redis/pg), health, graceful shutdown                       [README]
    qqserver/    qqserver binary: stateless token-translating game gateway
    adapter/     store backends (fs/redis/pg) behind the persistence facade
  engine/        bindings into Game.exe's own engine + realm callback table     [README]
    feature.zig  the mod framework registry (one table of features + toggles)
  runtime/       in-process machinery: byte-patches, hooks, fastcall, drivers   [README]
    feature/     the shipped feature modules (survival, maphack, server mods)
  bot/           in-game bot framework (--bot)
  checkrev/      CheckRevision.dll producer for the version-check MPQ           [README]
  test/          client-driving test harnesses (auto-login/join, screenshots)
deploy/
  chart/             Helm chart: realmd + d2gs fleet + qqserver + pg + redis     [README]
  grafana/           the D2 Realm Grafana dashboard (Prometheus + Loki)
  Dockerfile         multi-target image: `--target realmd` | `--target gs`
  compose.yaml       local stack: realmd + Postgres + Redis (+ `gs` profile)
  realmd.yaml        k8s: realmd Deployment + redis/pg + probes + LoadBalancer
  gs.yaml            k8s: game-server StatefulSet
  gs-entrypoint.sh   headless-wine launcher (assembles game dir, loads mods)
docs/architecture/   LikeC4 model (diablo2.c4 + cloud.c4) + exported diagrams (img/)
```

Other docs: [`REALM.md`](REALM.md), [`REALMD.md`](REALMD.md), [`VERIFY.md`](VERIFY.md),
[`ARENA.md`](ARENA.md), [`LEGAL.md`](LEGAL.md).

## Status

**Working** (tested under wine on the unmodified retail 1.14d `Game.exe`):

- Injection (`dbghelp` proxy -> `--loaddll` -> `DllMain`) + headless survival.
- Dedicated server boots, listens on `:4000`, ticks stably.
- `realmd`: real client logs in, passes the version check (BNFTP file integrity + CheckRevision),
  selects a realm, lists + loads characters.
- Create + join a game dispatched to the headless GS.
- **Character spawns in-world** (loaded from d2dbs, full life/mana, playable).
- **Multiplayer**: two real clients in one game, visible to each other.

**Rough edges / next:**

- Verbose join diagnostics compiled in by default; `pkttrace` gated.
- Two headed clients in one wineprefix can trip the bnet gateway-list parser on the second client's
  startup (intermittent); the e2e test retries.
- Harden across restarts + many concurrent games; replace the fixed init delay with a proper
  engine-init hook.

## License & legal

Code: [MIT](LICENSE). No Blizzard game files are distributed here -- bring your own legit copy of
Diablo II. Unofficial, not affiliated with Blizzard. See [`LEGAL.md`](LEGAL.md).
