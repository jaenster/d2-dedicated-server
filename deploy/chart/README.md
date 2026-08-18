# realm — Helm chart for a headless Diablo II 1.14d realm server

This chart deploys a complete, fleet-shaped Diablo II 1.14d realm on Kubernetes:

- **realmd** — the stateless protocol front (bnetd + MCP realm on one port), fronted by
  a `LoadBalancer`. Scales freely because all state lives in backing services.
- **game-server fleet (d2gs)** — headless `Game.exe` under wine. Internal (pod-IP only);
  clients never dial it. See Topology.
- **game server, wine-free (d2gs-native)** — optional (`gameServerNative.enabled`), the same
  server as one native process with its data baked in. Publishes into the same redis as the wine
  fleet, so enabling it puts both kinds of server on one realm.
- **d2ingress** — a token-translating splice gateway, the single public game entry on the
  floating IPs.
- **Postgres** — durable character saves.
- **Redis** — ephemeral sessions/games (native TTL).

It is a faithful, publishable mirror of a real running cluster, with the cluster-specific
IPs and passwords replaced by generic, overridable defaults. Treat it as a worked example.

## Topology

Game traffic always goes through the gateway; `gameAddr` is **required** and realmd refuses to
start without it.

realmd advertises the d2ingress entry point (normally the first `floatingIP`) and writes
`{token -> the real GS pod ip:port}` to redis; the client connects to d2ingress with that token
and d2ingress splices through to the right GS. The GS is internal (pod-IP only, no hostPort), so
the fleet can scale past the node count and clients never hit a GS directly.

There is no mode where clients dial a game server themselves: the token realmd hands out is
realm-global, and only the gateway can translate it to the id the engine knows.

`floatingIPs` are stable public IPs (e.g. cloud floating IPs that fail over between nodes)
set as `externalIPs` on the public realmd **and** d2ingress Services. The cluster firewall
only needs the client-facing ports open to those FIPs: **6112** (bnet, which carries the realm
protocol too) **and 4000** (d2ingress game traffic). Nothing else is reachable from outside —
game servers meet the realm in redis rather than over a port of their own.

## Quick start

```sh
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=203.0.113.10 \
  --set postgres.auth.password=$(openssl rand -hex 16)
```

Game data ships baked into the default `gameServer.dataImage` (see gotchas) — no manual
step needed unless you want different data. Watch the `realmd` LoadBalancer for its
external IP — that IP is what `realmAddr` must be.

## Environment contract

realmd (`templates/realmd-deployment.yaml`):

| env | source |
|-|-|
| `REALMD_INSTANCE` | fieldRef `metadata.name` (unique per pod — session-id high bits) |
| `REALMD_REALM_NAME` | `.Values.realmName` |
| `REALMD_REALM_ADDR` | `.Values.realmAddr` (public IP clients dial; **required**) |
| `REALMD_GAME_ADDR` | `.Values.gameAddr` (the d2ingress entry advertised for game traffic; **required**) |
| `REALMD_REDIS_ADDR` | `realmd-redis:6379` |
| `REALMD_PG_DSN` | secretKeyRef `realmd-pg/DSN` |
| `REALMD_REQUIRE_GS` | `.Values.requireGS` |
| `REALMD_LOG_JSON` | `.Values.realmd.logJson` |
| `REALMD_SHUTDOWN_GRACE_MS` | `.Values.realmd.shutdownGraceMs` |

game server (`templates/gameserver-statefulset.yaml` — a stateless `Deployment`, consumed by `deploy/gs-entrypoint.sh`):

| env | source |
|-|-|
| `D2GS_REDIS_ADDR` | `realmd-redis:6379` (its only link to the realm) |
| `POD_IP` | fieldRef `status.podIP` |
| `D2GS_GS_ADDR` | `$(POD_IP):4000` (internal pod IP — d2ingress splices to it) |
| `D2GS_MAX_GAMES` | `.Values.gameServer.maxGames` — omitted when empty, so the server advertises its real capacity |
| `D2GS_EXTRA_DLLS` / `D2GS_EXTRA_ARGS` | optional, `.Values.gameServer.extraDlls` / `extraArgs` |

native game server (`templates/gameserver-native-deployment.yaml`): the same `D2GS_REDIS_ADDR`,
`POD_IP`, `D2GS_GS_ADDR` and `D2GS_MAX_GAMES` contract, minus the wine-only extras. Two differences
that matter: it has no health endpoint (that is a `d2gs.dll` hook, and there is no DLL here), so its
probes are `tcpSocket` on 4000; and its image is `FROM scratch`, so an emptyDir is mounted at `/tmp`
for the resource file the engine writes at startup — Kubernetes ignores the Dockerfile's `VOLUME`.

d2ingress: `REALMD_BIND`, `REALMD_INGRESS_PORT`, `REALMD_REDIS_ADDR`, `REALMD_LOG_JSON`. Its image
is usually private — set `d2ingress.pullSecret` to a dockerconfigjson secret (e.g. `ghcr`).

Version check: the d2gs client bypasses it (`--bypass-checkrev`) and realmd accepts any auth-check, so no version MPQ is served.

`realmd` runs `replicas: 2` with a normal RollingUpdate. Replicas are interchangeable: game
servers meet the realm in redis rather than connecting to a pod, so a surged pod goes Ready as
soon as it can see a published game server, without waiting for the old one to go. Each pod takes
`REALMD_INSTANCE` from `metadata.name`, which keeps session ids, dispatch request ids and chat
inboxes in disjoint ranges — do not pin it. (`realmd.recreate` still forces `strategy: Recreate`
if you need it; it was required only while a game server held a control connection to one pod.)
All Deployments set `revisionHistoryLimit: {{ realmd.revisionHistoryLimit }}` (default 0 — GitOps
rolls back via git).

## Gotchas this chart bakes in (the point of the example)

- **Postgres `PGDATA` must be a subdir of the mounted volume.** It is set to
  `/var/lib/postgresql/data/pgdata`, not the volume root — `initdb` refuses the root
  because the mount already contains `lost+found`.
- **The GS is internal — it registers its pod IP.** `D2GS_GS_ADDR=$(POD_IP):4000` reports
  the in-cluster pod IP; d2ingress (also in-cluster) dials it to splice client game traffic
  through. No public exposure, no node-IP resolution needed.
- **No `hostPort`; anti-affinity is soft.** Without a node-level bind the fleet can exceed
  the node count, so pod anti-affinity is `preferred` (weight 100) — it still spreads
  replicas across nodes for fault tolerance but won't block scheduling.
- **Game data ships via an image (no Longhorn).** `gameServer.dataImage.repository`
  defaults to this repo's published `d2-gamedata` image — the minimal (~16MB) 1.14d data
  set (see `tools/make-minimal.sh`, `LEGAL.md`) baked in at `/gamedata`; a `load-gamedata`
  initContainer `cp -a`s it into an emptyDir game volume per pod — no persistent volume,
  nothing for Longhorn to replicate. Point it at your own image for different/updated
  data (`gameServer.dataImage.pullSecret` if that image is private). **Fallback:** set
  `dataImage.repository` to `""` to instead mount a real D2 1.14d install into the RWX
  `d2-gamefiles` PVC yourself (read-only into each pod). The entrypoint aborts if
  `/game/Game.exe` is missing.
- **`REALMD_REQUIRE_GS` gates client traffic** until a game server publishes itself, so
  clients never connect to a realm with no games behind it.
- **A hostname in `realmAddr`/`gameAddr` is resolved by realmd, inside the cluster.** Both are
  advertised to clients, so the name must resolve the same in the cluster as on the internet.
  Split-horizon DNS breaks this silently — a CoreDNS rewrite pointing the cluster's own domains
  at the ingress Service gives realmd a ClusterIP, which it then hands to every external client.
  Nothing looks wrong: realmd is healthy, the fleet is registered, and no one can log in. Verify
  from a pod (`kubectl run dns --rm -i --restart=Never --image=busybox -- nslookup <name>`), and
  use the IP if the answer is not the public address. Everything the realm dials *internally* —
  redis, Postgres, the game servers' pod IPs — is unaffected; it is only the advertised
  addresses that have to be resolvable from outside.

## Toggles

| value | effect |
|-|-|
| `postgres.enabled=false` | skip in-cluster Postgres; realmd still reads `realmd-pg/DSN` — override `postgres.auth.*` to point at an external DB |
| `redis.enabled=false` | skip in-cluster Redis (supply an external `realmd-redis:6379`) |
| `d2ingress.enabled=false` | skip the gateway |
| `gameServerNative.enabled=true` | additionally run the wine-free GS (data baked into its image; `gameServerNative.pullSecret` for the private package) |
| `permissiveAuth=true` | auto-register unknown accounts password-less instead of rejecting them (test realms) |
| `gameServer.dataImage.repository=<img>` | ship game data via the load-gamedata initContainer + emptyDir (no PVC); defaults to `ghcr.io/jaenster/d2-gamedata`; empty = use the `d2-gamefiles` PVC fallback |
| `realmd.recreate=true` | force `strategy: Recreate` (not needed any more; RollingUpdate is the default) |
| `d2ingress.pullSecret=<name>` | imagePullSecret for the (usually private) d2ingress image |

The deployment namespace is the Helm release namespace (the hardcoded `realmd`
namespace from the raw manifests is dropped — Helm sets it).
