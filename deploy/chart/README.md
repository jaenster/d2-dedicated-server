# realm — Helm chart for a headless Diablo II 1.14d realm server

This chart deploys a complete, fleet-shaped Diablo II 1.14d realm on Kubernetes:

- **realmd** — the stateless protocol front (bnetd + d2cs + d2dbs + gs-link), fronted by
  a `LoadBalancer`. Scales freely because all state lives in backing services.
- **game-server fleet (d2gs)** — headless `Game.exe` under wine, one per node, that clients
  dial directly for game traffic.
- **qqserver** — a token-translating splice gateway (deployed internal-only for now).
- **Postgres** — durable character saves.
- **Redis** — ephemeral sessions/games (native TTL).

It is a faithful, publishable mirror of a real running cluster, with the cluster-specific
IPs and passwords replaced by generic, overridable defaults. Treat it as a worked example.

## Quick start

```sh
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=203.0.113.10 \
  --set postgres.auth.password=$(openssl rand -hex 16)
```

Then populate the `d2-gamefiles` PVC with a real 1.14d install (see gotchas) and watch the
`realmd` LoadBalancer for its external IP — that IP is what `realmAddr` must be.

## Environment contract

realmd (`templates/realmd-deployment.yaml`):

| env | source |
|-|-|
| `REALMD_INSTANCE` | fieldRef `metadata.name` (unique per pod — session-id high bits) |
| `REALMD_REALM_NAME` | `.Values.realmName` |
| `REALMD_REALM_ADDR` | `.Values.realmAddr` (public IP clients dial; **required**) |
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
| `REALMD_HOST` | `realmd.<namespace>.svc.cluster.local` |
| `NODE_IP` | fieldRef `status.hostIP` |
| `D2GS_GS_ADDR` | `.Values.gameServer.gsAddr` (default `auto:4000`) |
| `D2GS_MAX_GAMES` | `.Values.gameServer.maxGames` |
| `D2GS_EXTRA_DLLS` / `D2GS_EXTRA_ARGS` | optional, `.Values.gameServer.extraDlls` / `extraArgs` |

qqserver: `REALMD_BIND`, `REALMD_QQ_PORT`, `REALMD_REDIS_ADDR`, `REALMD_LOG_JSON`.

## Gotchas this chart bakes in (the point of the example)

- **Postgres `PGDATA` must be a subdir of the mounted volume.** It is set to
  `/var/lib/postgresql/data/pgdata`, not the volume root — `initdb` refuses the root
  because the mount already contains `lost+found`.
- **The GS advertises a PUBLIC address.** On cloud nodes the downward-API `status.hostIP`
  is the node's PRIVATE IP (e.g. Hetzner `10.x`), which clients can't reach. So
  `D2GS_GS_ADDR=auto:4000` tells the entrypoint to resolve the node's public IPv4 from
  the cloud metadata service (Hetzner link-local, with an external-echo fallback) and
  append the game port.
- **The GS uses `hostPort: 4000` + pod anti-affinity (one GS per node).** Clients dial
  `<node-ip>:4000` directly, so the GS binds the node port; anti-affinity keeps two pods
  off the same node so the hostPort never collides and every pod has a distinct node IP.
- **Game files are proprietary — never baked in.** Mount a real D2 1.14d install into the
  RWX `d2-gamefiles` PVC at runtime (read-only into each pod). The entrypoint aborts if
  `/game/Game.exe` is missing.
- **`REALMD_REQUIRE_GS` gates client traffic** until a GS registers over the gs-link, so
  clients never connect to a realm with no games behind it.

## Toggles

| value | effect |
|-|-|
| `postgres.enabled=false` | skip in-cluster Postgres; realmd still reads `realmd-pg/DSN` — override `postgres.auth.*` to point at an external DB |
| `redis.enabled=false` | skip in-cluster Redis (supply an external `realmd-redis:6379`) |
| `qqserver.enabled=false` | skip the gateway |

The deployment namespace is the Helm release namespace (the hardcoded `realmd`
namespace from the raw manifests is dropped — Helm sets it).
