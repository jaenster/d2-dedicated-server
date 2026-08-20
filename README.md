# d2-dedicated-server: headless, cloud-native Diablo II 1.14d dedicated game server + realm

[![Discord](https://img.shields.io/badge/Discord-join%20the%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/MHK2Dg9)

This repo exists out of multiple components.

- **1.14d** d2gs via wine and **native** on linux (no wine)
- **1.06b**, **1.07**, **1.08**, **1.09b**, **1.09d**, **1.10f** d2gs
- A cloud native realm server
- D2Ingress, an ingress implementation for 

## Different services (containers) in this repo

| docker container                                       | what it is                                                                                                                                                             |
|--------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **[`realmd`](#realmd-the-realm)**                      | The realm. One process doing every job PvPGN split across daemons: login/chat, character select, game create/join. To the client it *is* Battle.net, all on port 6112. |
| **[`d2gs`](#d2gs-the-headless-game-server)**           | The headless game server, multiple variants, types below                                                                                                               |
| **[`d2ingress`](#d2ingress-the-game-traffic-ingress)** | The ingress for game traffic. One public address in front of the whole game-server fleet, routed per connection on the game's own protocol.                            |


## D2GS versions

Just like a typical docker package, that for example is ran with debian or alphine etc, we have different variants for different variants of the game

| version                                                           | what it is                                                                                             | wine | Needs volume |
|-------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|------|--------------|
| `d2gs:1.14d`                                                      | The headless game server, running from a 1.14d install via wine                                        | Yes  | No           |
| `d2gs:1.07`, `d2gs:1.08`, `d2gs:1.09b`, `d2gs:1.09d`, `d2gs:1.10f` | A headless game server for, using the game's dll's, replacable with your own versions of the dll       | Yes  | Yes          |
| `d2gs:1.06b`                                                      | A headless game server for, just like above yet this is for classic, no LOD                            | Yes  | Yes          |
| **[`d2gs:1.14d-native`](#d2gs-native-the-wine-free-game-server)** | Special port of the macos 1.14d version that is ported to linux, to run natively on linux without wine | No   | No           |


If you run this, you can [sponsor the work](https://github.com/sponsors/jaenster).

# What are we aiming to do

A modern **Cloud Native** platform to host the realm and game server of diablo 2 via kubernetes. Running via helm charts, argocd and beautiful dashboards in grafana.

## What is this not aiming to do

Be compatible with windows, made to run as separated containers. While technically you could, we dont spend time on making that work, this is a cloud first approach.

Because we can focus specifically on being a linux container, we can use this to our advantage, to use the posix functionality to our advantage, to make the `realmd` and `d2ingress` as lightweight and stateless as possible.

## Other services needed

| docker container | What it is used for                                                                                                     | Needs volume |
|------------------|-------------------------------------------------------------------------------------------------------------------------|--------------|
| Redis            | The source of truth during runtime, the cloud native heart of the system that is the link between d2gs/realmd/d2ingress | No           |
| pg               | Long term storage of realm information, account data, char data, etc                                                    | Yes          |

The only truly stateful application we have is pg, as that holds the actual long term storage. The redis servers just keep in memory what is happening live on the realms

## What makes this cloud-native?

- Redis and pg are both cloud native and are build to scale very well, scaling with statefulness is not an easy task to accomplish, and not something we attempt to do or replicate. By using proven tools for it, we can make our applications stateless.

- The d2ingress is the one that listens to port `4000`, and forwards the connection to the right pod once the client tells us which game to connect to. This in turn makes it possible to have game servers listen on whatever port and only on internal ips, e.g. the docker/k8s network. So you dont need different ips for different gameservers. You could even host multiple different versions of the game on the same host.
- Our realmd, the pvpgn replacement, is stateless and can be ran as multiple pods. Im thinking if d2ingress should also take care of the `6112` port, but right now it can just be low level balancer
- Every pod can be scaled, there is no leader selection or anything like that. Both redis and pg is what takes care of that.
- Redis solves the problems of have 1 char in multiple games. As each d2gs server owns a lock on the chars in game.
- Realm wide chat goes via redis too, where each realmd pod is a client to redis, which solves the entire problem of leader selection for realmd services.
- Nothing (except for a pg database) is on disk. No shared disk issues running servers accross the globe etc
- Logs are in a structured JSON, for modern loggers like loki
- exposed metrics for tools like prometheus
- No cross platform support, pure linux to take advantage of posix specific optimizations
- realmd and d2gs are never directly connected


## How it fits together

Please note here i use 1.14d as an example, but its the same concept for the other version

```
                unmodified 1.14d client (GUI)
                  |                            |
   login + realm  |  (BNCS + MCP on ONE        |  game traffic
                  v   port, like real bnet)    v  (D2Net)
       +----------------------+        +----------------------+
       |  realmd              |        |  d2ingress           |
       |  :6112  login, realm |        |  :4000  public game  |
       |  :8080  health / UI  |        |         ingress      |
       +----------+-----------+        +-----------+----------+
            |     |                                |
            |                                      |  splice to the owning GS
            |                                      |
            |                                      v
            |                          +----------------------+
            |                          |  Game.exe + d2gs.dll |
            |                          |  fleet 1..N          |
            v                          +----------+-----------+
       +---------------------------+              | takes create/join from its queue,
       |  redis                    |<-------------+ reports what happens, reads and
       |  characters, seats,       |                writes characters, publishes itself
       |  tokens, routes, fleet,   |
       |  the game-server queues   |
       +------------+--------------+
                    | flush worker (any realmd)
                    v
            +----------------+
            |    postgres    |   the store of record
            +----------------+
```

The client only ever uses two ports: **6112** (login + realm) and **4000** (game). There is no
third: `realmd` and the `d2gs` never speak to each other directly, they meet in redis.

Game traffic always crosses an ingress -- the token realmd hands the client is realm-global, and
only an ingress can translate it to the id the engine knows. On one host realmd can be that
ingress itself (`REALMD_GAME_PORT`, no second binary); in the cloud it advertises d2ingress. Same
binaries either way -- see [`docs/DEPLOY.md`](docs/DEPLOY.md).

## Quick start

```sh
# Kubernetes: realmd + d2gs fleet + d2ingress + pg + redis
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=realm.example.com \
  --set postgres.auth.password=$(openssl rand -hex 16)
```

The Helm chart's `gs` pods come up with game data already baked in (a minimal set of game files, for the selected version, set the
pipeline publishes, see `tools/make-minimal.sh`);

# Modding

It is rarely the case that people want to run an unmodified private realm. Typically people want to add more things to it.

All `d2gs` containers support additional dll's being loaded on startup. Use this to modify the game.exe (1.14d) or dlls in older versions to modify the game to your liking.

Please note that we do our best to touch the game as little as possible, to give the most service area to you the user to embed things, but be aware of places where it will collide.

Also the native variant `1.14d-native`, will not support dll injections as it runs on linux directly. I might add something to load additional .so files but not sure yet

## The services up close

### realmd: the realm

`realmd` is the realm deamon. It does the job of all protocols hosted on `6112`
- **BNetFTP** (the Battle.net ftp protocol)
- **BNCS** (the Battle.net chat protocol, login + the version gate)
- **MCP** (the realm protocol: list/select characters, create/join a game)

`realmd` is a fully standalone, has zero deps. It is written for linux (docker). 

It is trivial to add changes to it, but im thinking out how to make this also a moddable / extendable realmd. To be continued

That is the only port. `realmd` exposes nothing to the fleet, because the fleet does not connect to it:
`d2gs` publish themselves into redis and take create/join from a queue there.
Characters do not pass through `realmd` either — it stages one into redis on join and the game
server reads, plays and writes it back. See [`docs/redis.md`](docs/redis.md).

More: [`REALMD.md`](REALMD.md) (configuration, trust model) and
[`apps/realmd/README.md`](apps/realmd/README.md) (internals).

### d2gs: the headless game server

It comes in 3 variants -
- `d2gs:1.14d-latest` - Running game.exe, with the entire game's exe and a d2gs patched into it
- `d2gs:1.14d-native-latest` - Running the macos modified to a posix linux binary, with d2gs patched into it
  More: [`apps/d2gs-native/README.md`](apps/d2gs-native/README.md).

- `d2gs:[1.06b|1.07|1.08|1.09b|1.09d|1.10f]-latest` - a own written zig exe that uses the version's dll's to host a game server

  The engine is compiled in, not selected at runtime: an image tagged for one version refuses to be
  told to serve another, and a version whose ABI is not fully measured fails the *build* rather than
  shipping broken. Unlike `1.14d`, these need the matching game data mounted at `/game` -- a `.bin`
  table is a raw struct dump, so data from another patch level decodes as garbage rather than
  failing cleanly. `tools/re/patchdata.py` rebuilds a version's tables from its own patch installer.

  **1.13c is not working yet** -- its ABI is measured but it faults during game-data-table init.

On a join the server does not read a shared disk, and does not ask the realm -- it reads the character straight from redis and writes it back there when the game ends.

More: [`docs/MODDING.md`](docs/MODDING.md) (injection + the feature framework),
[`apps/d2gs/engine/README.md`](apps/d2gs/engine/README.md), [`apps/d2gs/runtime/README.md`](apps/d2gs/runtime/README.md).


Game servers publish themselves into redis; `CREATE` is routed to the least-loaded with room
(picked and reserved in one script, so two realmds cannot choose the same slot) and `JOIN` to the
one that owns the game, with persistence behind the Postgres/Redis facade:

### d2ingress: the game-traffic ingress

`d2ingress`: a stateless ingress for game traffic. It exists because the client gives you nothing to route on.
the realm can say *which host* to dial, but the game port is fixed at `:4000`.

1. realmd mints a realm-globally-unique **token** per create/join and records
   `token -> {gs address, real engine game id}` in redis.
2. The client dials `d2ingress:4000` and sends `GAMELOGON` (`0x68`), which carries that token.
3. d2ingress looks up the route, **rewrites the token in the packet** to the game id the backend
   engine actually knows, dials that GS, replays the packet, and **splices**.

That is the entire extent of the protocol it understands: one field in the first packet, plus
the engine's `0xAF` greeting frame, which it strips. Everything after is opaque bytes both ways
-- so gameplay changes cannot break it. It is NAT-proof for the same reason the routing is
stateless: the key is the token, not the source address.

The implementation matches the job: **one thread, one `poll()` loop, zero heap, no globals**,
all state in a single value on `main()`'s stack, and idle it sits in `poll(-1)` at 0% CPU.

More: [`apps/d2ingress/README.md`](apps/d2ingress/README.md).

A small additional note to make for d2ingress, if you have servers all over the world, 
they tend to have a relatively quick connection between them. If the player is in europe, 
and it wants to connect to a game server in the usa. It can be quicker to give the user the ip for the d2ingress in europe. As datacenters have an internal network that often is quicker from data center to data center as the client to the data center far away for the user. With the way how d2ingress works you can give it any ip that host it for your realm

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
apps/       one directory per deployed thing: d2gs (the injected DLL pair), d2gs-native, realmd, d2ingress
packages/   what more than one app needs: realm-proto, realm-infra, realm-store, bncs-auth, obs
tools/      run by hand, never deployed: the e2e harness, the probes, ver-ix86, ghidra2cpp
deploy/     Dockerfile, compose.yaml, k8s manifests, Helm chart, Grafana
docs/       deploy, flags, modding, observability, performance, status, LikeC4 architecture
```

The split that matters is `realm-proto` vs `realm-infra`. The first is std-only and compiles
into the x86-windows DLL as well as the native binaries, which is what makes both ends of the
realm link agree on the wire by construction. The second is libc sockets and POSIX, and is
deliberately never handed to the DLL build. Each app and package has its own README.

## How it's verified

Every claim above is something a command reproduces, and none of it mocks the realm or the engine:
the suites speak the client's own wire protocol against a real realmd and a real game server.

| | what it proves |
|-|-|
| `zig build test` | unit tests: wire codecs, save integrity, the seeded generators |
| `zig build e2e` | 34 clientless scenarios against a real realmd — login, characters, games, the fleet, chat, the ingress. Starts its own Redis + Postgres containers, so it needs Docker and nothing else |
| `zig build stress-e2e` | rounds of real games against a real game server, decoding each client's world to confirm it actually arrived. Runs on the compose network in CI (`deploy/compose.e2e.yaml`) |
| `./run-stack.sh` | brings the whole stack up on one host and finishes with a real login, game create and join |

Two utilities rather than tests: `tools/seed-pg.sh` moves characters from an older filesystem
realm into Postgres, and `tools/symbolize.sh` turns a game-server panic back into `file:line`.

## Documentation

| | |
|-|-|
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | Kubernetes, Compose, native; the game-traffic ingress |
| [`docs/FLAGS.md`](docs/FLAGS.md) | every flag and its env equivalent |
| [`docs/MODDING.md`](docs/MODDING.md) | how injection works; writing a feature |
| [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md) | logs, the dashboard, where `evt` comes from |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | measured footprint, the 7-games-per-server ceiling |
| [`docs/redis.md`](docs/redis.md) | the realm's shared state: key schema, locks, save durability |
| [`docs/native-vs-wine.md`](docs/native-vs-wine.md) | native vs wine game server, measured side by side |
| [`docs/STATUS.md`](docs/STATUS.md) | what works, what doesn't yet |
| [`REALMD.md`](REALMD.md) · [`REALM.md`](REALM.md) | the realm server; the engine-side realm bridge |
| [`ARENA.md`](ARENA.md) · [`VERIFY.md`](VERIFY.md) · [`LEGAL.md`](LEGAL.md) | arena design; RE verification log; legal |

## License & legal

Code: [MIT](LICENSE). No Blizzard game files are in this repo's source; the published container
images bake in a stripped, minimal 1.14d data set (see [`LEGAL.md`](LEGAL.md)). Unofficial, not
affiliated with Blizzard.
