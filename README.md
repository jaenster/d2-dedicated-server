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
> server, and the character spawns in-world -- including a full eight-player party, and
> characters leaving one game and entering the next all evening.**
> Full detail, and the rough edges, in [`docs/STATUS.md`](docs/STATUS.md).

If you run this, you can [sponsor the work](https://github.com/sponsors/jaenster).

## The three services

Three independently-deployable pieces. Two are **pure-Zig native binaries** (no Windows, no game
files -- they scale freely); the third is the injected Zig DLL that drives the real game engine
under wine.

| service | what it is |
|-|-|
| **[`realmd`](#realmd-the-realm)** | The realm. One process doing every job PvPGN split across daemons: login/chat, character select, game create/join. To the client it *is* Battle.net, all on port 6112. |
| **[`d2gs`](#d2gs-the-headless-game-server)** | The headless game server. An injected DLL that boots the real `Game.exe` with no display, drives its server tick, and hosts the games. |
| **[`qqserver`](#qqserver-the-game-traffic-ingress)** | The ingress for game traffic. One public address in front of the whole game-server fleet, routed per connection on the game's own protocol. |

Underpinning all three, `packages/realm-proto/` (the `realm_proto` module) is the realmd<->d2gs wire
protocol that both ends import, so they agree on the wire by construction.

## Why this is cloud-native

Not "it has a Dockerfile". The design decisions that matter:

- **Stateless where it counts.** realmd keeps **no durable state of its own** -- persistence
  dispatches to `fs`, `redis`, or `pg` behind one facade, so sessions and games live in the
  backing services. qqserver keeps none at all: its route key is a realm-global token in redis,
  so **any** gateway pod resolves **any** connection. No session affinity, no warm-up.
- **An ingress, not an IP per server.** The game port is fixed at `:4000`, so without a gateway
  every game server needs its own client-routable address and the fleet can never outgrow the
  IPs you own. qqserver does what an HTTP ingress does with the `Host` header -- one layer down,
  on the game protocol. The fleet lives on pod IPs.
- **No shared disk.** On a join the game server **fetches the character over the network** from
  realmd's d2dbs. No RWX volume, no shared game-data mount between pods.
- **Scale the thing that actually has a ceiling.** Seven concurrent games per `Game.exe` is a
  hard engine limit, so capacity comes from adding game-server pods, not tuning one --
  see [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).
- **A normal workload to operate.** Config is environment-only, health/readiness probes on
  `:8080`, clean SIGTERM drain, structured JSON on stdout. `docker logs` / `kubectl logs` just
  work, and the gameplay metrics fall straight out of those logs
  ([Observability](#observability)).
- **Small.** Two of the three ship as `scratch` images with static musl binaries and sit at
  ~1--6 MiB resident. The realm costs about `1m` CPU.

One honest exception: a game server holds its gs-link control connection to exactly **one**
realmd, and create/join is a synchronous request over that socket. So **run realmd as a single
replica** today; the chart does, and says why. Multi-instance HA needs the fleet dialling every
pod, or dispatch relayed through the store.

realmd and qqserver sit behind public LoadBalancers on stable floating IPs (only 6112 + 4000
open); Redis + Postgres behind them; an internal GS fleet whose pods register their own pod IP:

![Kubernetes topology](docs/architecture/img/k8s_deploy.png)

## How it fits together

```
                unmodified 1.14d client (GUI)
                  |                            |
   login + realm  |  (BNCS + MCP on ONE        |  game traffic
                  v   port, like real bnet)    v  (D2Net)
       +----------------------+        +----------------------+
       |  realmd              |        |  qqserver            |
       |  :6112  login, realm |        |  :4000  public game  |
       |  :8080  health / UI  |        |         ingress      |
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
else (gs-link 6115, d2dbs 6114) is internal traffic between the fleet and realmd.

Locally you can skip the gateway (**DIRECT** mode): the client dials the single GS at `:4000`
itself. In the cloud (**GATEWAY** mode) realmd advertises the qqserver entry instead. Same
binaries either way -- see [`docs/DEPLOY.md`](docs/DEPLOY.md).

The full model lives in [`docs/architecture/`](docs/architecture/) (LikeC4) and can be browsed
live with `npx likec4 start docs/architecture`.

## Quick start

```sh
# Kubernetes: realmd + d2gs fleet + qqserver + pg + redis
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=203.0.113.10 \
  --set postgres.auth.password=$(openssl rand -hex 16)

# or one host: realmd + Postgres + Redis
docker compose -f deploy/compose.yaml up --build
curl localhost:18080/readyz
```

Then supply the proprietary game data (bring your own legit 1.14d copy) and point `realmAddr` at
the realmd LoadBalancer. Compose, the raw manifests, and the native-process path are all in
[`docs/DEPLOY.md`](docs/DEPLOY.md); the chart has its own reference in
[`deploy/chart/README.md`](deploy/chart/README.md).

## Build

```
zig build     # -> zig-out/bin/{dbghelp.dll, d2gs.dll, ver-IX86-1.dll}  (x86-windows)
              #    + zig-out/bin/{realmd, qqserver}  (native host binaries)
```

Nothing to check out beside it: the clean-room 1.14d core ([libd2](https://github.com/jaenster/libd2))
is pinned by URL in `build.zig.zon`, so a bare clone of this repo builds, and which version it was
built against is a commit here rather than whatever happens to be on your disk.

## The services up close

### realmd: the realm

`apps/realmd/` builds the `realmd` binary. One **pure-Zig** process that does the job of
all of PvPGN's separate daemons: login/chat, the realm (character select, game create/join), the
character database, and a registration endpoint the game-server fleet connects to.

To the retail client it looks exactly like Battle.net: the client logs in over **BNCS** (the
Battle.net chat protocol, login + the version gate) and then talks **MCP** (the realm protocol:
list/select characters, create/join a game) -- and, like real Battle.net, **both run on a single
port, 6112**. There is no pvpgn-style fan of client ports. Game-file delivery for the version
check uses **BNFTP** on the same port.

Behind that one client port, realmd also exposes two **internal** endpoints the fleet uses
(never the client): a **gs-link** (`:6115`) the fleet registers over and that routes create/join
to a server, and **d2dbs** (`:6114`) the server fetches/saves character bytes from.

More: [`REALMD.md`](REALMD.md) (configuration, trust model) and
[`apps/realmd/README.md`](apps/realmd/README.md) (internals).

### d2gs: the headless game server

`apps/d2gs/d2gs.zig` + `apps/d2gs/engine/` + `apps/d2gs/runtime/` build the injected `d2gs.dll`. It boots the real
1.14d `Game.exe` as a **headless dedicated server** and bridges it to `realmd`. Two layers:

- **Survival + optimization patches** -- byte-patches that let the Windows engine run with no
  display (stub the renderers/media loaders, hide the window) and frame-pace its idle loop so the
  server sits near-zero CPU. It also drives the engine's own server tick: drain inbound packets,
  tick all games, flush queued outbound.
- **A built-in mod framework** -- a registry of pure feature modules that hook the engine (exp
  scaling, ubers, an arena mode, client-side maphack, ...), each toggled on its own.

On a join the server does not read a shared disk -- it fetches the character over the network
from realmd's d2dbs, which serves it from whichever store backend is configured.

More: [`docs/MODDING.md`](docs/MODDING.md) (injection + the feature framework),
[`apps/d2gs/engine/README.md`](apps/d2gs/engine/README.md), [`apps/d2gs/runtime/README.md`](apps/d2gs/runtime/README.md).

realmd's gs-link registers many game servers; `CREATE` routes to the least-loaded, `JOIN` to the
one that owns the game, with persistence behind the `fs`/`redis`/`pg` facade:

![GS fleet](docs/architecture/img/gs_fleet.png)

### qqserver: the game-traffic ingress

`apps/qqserver/` builds the `qqserver` binary: a stateless ingress for game traffic. It
exists because the client gives you nothing to route on -- the realm can say *which host* to
dial, but the game port is fixed at `:4000`.

1. realmd mints a realm-globally-unique **token** per create/join and records
   `token -> {gs address, real engine game id}` in redis.
2. The client dials `qqserver:4000` and sends `GAMELOGON` (`0x68`), which carries that token.
3. qqserver looks up the route, **rewrites the token in the packet** to the game id the backend
   engine actually knows, dials that GS, replays the packet, and **splices**.

That is the entire extent of the protocol it understands: one field in the first packet, plus
the engine's `0xAF` greeting frame, which it strips. Everything after is opaque bytes both ways
-- so gameplay changes cannot break it. It is NAT-proof for the same reason the routing is
stateless: the key is the token, not the source address.

The implementation matches the job: **one thread, one `poll()` loop, zero heap, no globals**,
all state in a single value on `main()`'s stack, and idle it sits in `poll(-1)` at 0% CPU.

More: [`apps/qqserver/README.md`](apps/qqserver/README.md).

## Observability

Structured **JSON to stdout** from every service, with a per-connection and per-packet trace
context that spans realmd and the game servers. Shipped to **Loki** and paired with
**Prometheus** pod metrics, the whole realm is one Grafana dashboard:
[`deploy/grafana/d2-realm.json`](deploy/grafana/d2-realm.json) -- datasource-agnostic, import it
and pick your sources.

Almost none of it needs a metrics endpoint in the engine; the gameplay numbers fall out of the
logs:

```logql
sum(count_over_time({namespace="realmd", app="d2gs"} | json | evt=`game_create` [$__range]))
```

See [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

## Modding

A **feature is just a Zig module** that opts into a hook by declaring a `pub fn` of that name --
no base class, no vtable, and all config in one registry table. Hooks span lifecycle, client
frame loops, and the dedicated-server domain (`serverTick`, `gameCreate`, `roomInit`, `expAward`,
`packetIn`/`packetOut`, `playerJoin`/`playerLeave`), each with a per-game context whose allocator
**is the game's own memory pool**. Copy the template, add one line to the registry, done.

For native mods, the proxy loads **any** DLL you pass with `--loaddll`, repeatable. See
[`docs/MODDING.md`](docs/MODDING.md).

## Admin web UI

A small Vite + React UI ([`webui/`](webui/)) over realmd's `/admin/*` JSON API: fleet, games and
accounts at a glance, plus create-account, close-game and copy-char. It bundles to one
self-contained `index.html` embedded into the realmd binary and served on the health/admin port.
Admin-ness is a DB flag on the account; seed the first one with `realmd create-admin` or
`REALMD_ADMIN_BOOTSTRAP`, or front the whole thing with
[Authentik/oauth2-proxy SSO](deploy/AUTHENTIK-SSO.md). Keep port 8080 behind a port-forward or
the authed ingress, never public. Full detail: [`webui/README.md`](webui/README.md).

![realmd admin - overview](webui/img/overview.png)

## Layout

```
apps/       one directory per deployed thing: d2gs (the injected DLL pair), realmd, qqserver
packages/   what more than one app needs: realm-proto, realm-infra, realm-store, bncs-auth, obs
tools/      run by hand, never deployed: the e2e harness, the probes, ver-ix86, ghidra2cpp
deploy/     Dockerfile, compose.yaml, k8s manifests, Helm chart, Grafana
docs/       deploy, flags, modding, observability, performance, status, LikeC4 architecture
```

The split that matters is `realm-proto` vs `realm-infra`. The first is std-only and compiles
into the x86-windows DLL as well as the native binaries, which is what makes both ends of the
realm link agree on the wire by construction. The second is libc sockets and POSIX, and is
deliberately never handed to the DLL build. Each app and package has its own README.

## Documentation

| | |
|-|-|
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | Kubernetes, Compose, native; DIRECT vs GATEWAY |
| [`docs/FLAGS.md`](docs/FLAGS.md) | every flag and its env equivalent |
| [`docs/MODDING.md`](docs/MODDING.md) | how injection works; writing a feature |
| [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md) | logs, the dashboard, where `evt` comes from |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | measured footprint, the 7-games-per-server ceiling |
| [`docs/STATUS.md`](docs/STATUS.md) | what works, what doesn't yet |
| [`REALMD.md`](REALMD.md) · [`REALM.md`](REALM.md) | the realm server; the engine-side realm bridge |
| [`ARENA.md`](ARENA.md) · [`VERIFY.md`](VERIFY.md) · [`LEGAL.md`](LEGAL.md) | arena design; RE verification log; legal |

## License & legal

Code: [MIT](LICENSE). No Blizzard game files are distributed here -- bring your own legit copy of
Diablo II. Unofficial, not affiliated with Blizzard. See [`LEGAL.md`](LEGAL.md).
