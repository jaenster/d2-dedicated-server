# realm — Helm chart for a headless Diablo II 1.14d realm server

This chart deploys a complete, fleet-shaped Diablo II 1.14d realm on Kubernetes:

- **realmd** — the stateless protocol front (bnetd + d2cs + d2dbs + gs-link), fronted by
  a `LoadBalancer`. Scales freely because all state lives in backing services.
- **game-server fleet (d2gs)** — headless `Game.exe` under wine. In GATEWAY mode it is
  internal (pod-IP only); in DIRECT mode clients dial it for game traffic. See Topology.
- **qqserver** — a token-translating splice gateway. In GATEWAY mode it is the single public
  game entry on the floating IPs; otherwise it is internal-only (ClusterIP).
- **Postgres** — durable character saves.
- **Redis** — ephemeral sessions/games (native TTL).

It is a faithful, publishable mirror of a real running cluster, with the cluster-specific
IPs and passwords replaced by generic, overridable defaults. Treat it as a worked example.

## Topology

Game traffic runs in one of two modes, selected by `gameAddr` / `floatingIPs`:

- **DIRECT** (`gameAddr` empty, default): the GS keeps a client-routable address and clients
  dial the GS directly for game traffic. realmd advertises the GS's own address.
- **GATEWAY** (`floatingIPs` + `gameAddr` set): realmd advertises the qqserver entry point
  (normally the first `floatingIP`). realmd writes `{token -> the real GS pod ip:port}` to
  redis; the client connects to qqserver with that token and qqserver splices through to the
  right GS. The GS is internal (pod-IP only, no hostPort), so the fleet can scale past the
  node count and clients never hit a GS directly.

`floatingIPs` are stable public IPs (e.g. cloud floating IPs that fail over between nodes)
set as `externalIPs` on the public realmd **and** qqserver Services. The cluster firewall
only needs the client-facing ports open to those FIPs: **6112-6113** (bnet + d2cs) **and
4000** (qqserver game traffic). d2dbs (6114) + gs-link (6115) are GS↔realmd internal
traffic (the `realmd-gslink` ClusterIP Service) and stay unexposed.

## Quick start

```sh
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=203.0.113.10 \
  --set postgres.auth.password=$(openssl rand -hex 16)
```

Then supply the proprietary game data — either build a private `dataImage` (recommended;
see gotchas) or populate the `d2-gamefiles` PVC fallback with a real 1.14d install — and
watch the `realmd` LoadBalancer for its external IP — that IP is what `realmAddr` must be.

## Environment contract

realmd (`templates/realmd-deployment.yaml`):

| env | source |
|-|-|
| `REALMD_INSTANCE` | fieldRef `metadata.name` (unique per pod — session-id high bits) |
| `REALMD_REALM_NAME` | `.Values.realmName` |
| `REALMD_REALM_ADDR` | `.Values.realmAddr` (public IP clients dial; **required**) |
| `REALMD_GAME_ADDR` | `.Values.gameAddr` (GATEWAY mode only — the qqserver entry advertised for game traffic) |
| `REALMD_DURABLE_STORE` | `pg` |
| `REALMD_EPHEMERAL_STORE` | `redis` |
| `REALMD_REDIS_ADDR` | `realmd-redis:6379` |
| `REALMD_PG_DSN` | secretKeyRef `realmd-pg/DSN` |
| `REALMD_REQUIRE_GS` | `.Values.requireGS` |
| `REALMD_LOG_JSON` | `.Values.realmd.logJson` |
| `REALMD_SHUTDOWN_GRACE_MS` | `.Values.realmd.shutdownGraceMs` |

game server (`templates/gameserver-statefulset.yaml`, consumed by `deploy/gs-entrypoint.sh`):

| env | source |
|-|-|
| `REALMD_HOST` | `realmd-gslink.<namespace>.svc.cluster.local` |
| `POD_IP` | fieldRef `status.podIP` |
| `D2GS_GS_ADDR` | `$(POD_IP):4000` (internal pod IP — qqserver splices to it) |
| `D2GS_MAX_GAMES` | `.Values.gameServer.maxGames` |
| `D2GS_EXTRA_DLLS` / `D2GS_EXTRA_ARGS` | optional, `.Values.gameServer.extraDlls` / `extraArgs` |

qqserver: `REALMD_BIND`, `REALMD_QQ_PORT`, `REALMD_REDIS_ADDR`, `REALMD_LOG_JSON`.

## Gotchas this chart bakes in (the point of the example)

- **Postgres `PGDATA` must be a subdir of the mounted volume.** It is set to
  `/var/lib/postgresql/data/pgdata`, not the volume root — `initdb` refuses the root
  because the mount already contains `lost+found`.
- **The GS is internal — it registers its pod IP.** `D2GS_GS_ADDR=$(POD_IP):4000` reports
  the in-cluster pod IP; qqserver (also in-cluster) dials it to splice client game traffic
  through. No public exposure, no node-IP resolution needed.
- **No `hostPort`; anti-affinity is soft.** Without a node-level bind the fleet can exceed
  the node count, so pod anti-affinity is `preferred` (weight 100) — it still spreads
  replicas across nodes for fault tolerance but won't block scheduling.
- **Game data ships via a private image (no Longhorn).** Set `gameServer.dataImage.repository`
  to a small private image carrying the minimal (~16MB) proprietary 1.14d data set at
  `/gamedata`; a `load-gamedata` initContainer `cp -a`s it into an emptyDir game volume per
  pod — no persistent volume, nothing for Longhorn to replicate. Pass
  `gameServer.dataImage.pullSecret` for the registry secret. **Fallback:** leave
  `dataImage.repository` empty and mount your own real D2 1.14d install into the RWX
  `d2-gamefiles` PVC (read-only into each pod). The entrypoint aborts if `/game/Game.exe`
  is missing.
- **`REALMD_REQUIRE_GS` gates client traffic** until a GS registers over the gs-link, so
  clients never connect to a realm with no games behind it.

## Toggles

| value | effect |
|-|-|
| `postgres.enabled=false` | skip in-cluster Postgres; realmd still reads `realmd-pg/DSN` — override `postgres.auth.*` to point at an external DB |
| `redis.enabled=false` | skip in-cluster Redis (supply an external `realmd-redis:6379`) |
| `qqserver.enabled=false` | skip the gateway |
| `gameServer.dataImage.repository=<img>` | ship game data via the load-gamedata initContainer + emptyDir (no PVC); empty = use the `d2-gamefiles` PVC fallback |

The deployment namespace is the Helm release namespace (the hardcoded `realmd`
namespace from the raw manifests is dropped — Helm sets it).
