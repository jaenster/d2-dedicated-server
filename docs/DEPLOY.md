# Deploying

Three ways to run the realm, in descending order of how much of it you want: Kubernetes, Docker
Compose, or native processes on your own box. The same binaries and the same images in every
case.

## Game traffic always goes through an ingress

Clients never dial a game server. On create/join realmd mints a **realm-global token** and records
`token -> {game server, engine game id}`; the ingress reads that token from the client's first
packet, rewrites it to the id the engine actually knows, and splices. A client pointed straight at
a game server would present a token that server has never heard of.

So `REALMD_GAME_ADDR` is **required** — realmd refuses to start without it — and it names one of
two ingresses. Both use the same builds and the same recorded routes:

- **d2ingress** (`floatingIPs` + `gameAddr`): a separate stateless process, routes in redis, so any
  gateway pod resolves any connection and the GS fleet stays on internal pod IPs. The Kubernetes
  path.
- **realmd's embedded edge** (`REALMD_GAME_PORT`): realmd splices in-process, no redis hop and no
  second binary. For one host — Compose, or a native run.

The client only ever uses two ports: **6112** (login + realm) and **4000** (game). Everything
else (gs-link 6115, d2dbs 6114) is internal traffic between the game-server fleet and realmd.

See [`apps/d2ingress/README.md`](../apps/d2ingress/README.md) for why the gateway exists
at all.

## Kubernetes (Helm)

[`deploy/chart`](../deploy/chart/) deploys the whole fleet -- realmd, the d2gs game-server
fleet, d2ingress, Postgres, and Redis -- wired together. It is a publishable mirror of a real
running cluster, with the cluster-specific IPs/passwords replaced by generic overridable
defaults. Full reference: [`deploy/chart/README.md`](../deploy/chart/README.md).

```sh
helm install myrealm deploy/chart \
  --namespace realm --create-namespace \
  --set realmAddr=203.0.113.10 \
  --set postgres.auth.password=$(openssl rand -hex 16)
```

Game data ships baked into the default `gameServer.dataImage` (a public image this repo's
pipeline builds from the minimal 1.14d set — see `tools/make-minimal.sh`); point `realmAddr`
at the realmd LoadBalancer's external IP and there's no further data step.

Useful toggles: `postgres.enabled` / `redis.enabled` (use external backends), `d2ingress.enabled`,
`gameServer.dataImage.repository` (ship data via an initContainer instead of a PVC),
`gameServer.maxGames`. The raw manifests behind the chart are also in [`deploy/`](../deploy/)
(`realmd.yaml`, `gs.yaml`).

## Docker Compose

The same `realmd` image and backends you'd run on Kubernetes, on one host: realmd with
**Postgres** (durable char saves) + **Redis** (ephemeral sessions/games). Full file at
[`deploy/compose.yaml`](../deploy/compose.yaml) (it also has a profile-gated `gs` game-server
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
`D2GS_GAME_SRC`). For machine-specific tweaks keep a gitignored `deploy/compose.local.yaml` and
add `-f deploy/compose.local.yaml`.

## Manual (native realmd + wine GS)

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

`zig build` produces the DLLs; assembling a wine test dir around them is up to your own launcher
(the ones in this tree hardcode local paths and stay gitignored).

## End-to-end test

The full create+join flow has one: [`tools/realmd-test/e2e-game.sh`](../tools/realmd-test/e2e-game.sh)
boots realmd + GS, drives two clients to create + join, and asserts both characters loaded. Needs
wine and a real 1.14d install via `E2E_GAME_SRC`.

## Related

- [`docs/FLAGS.md`](FLAGS.md) -- every flag and its env equivalent.
- [`REALMD.md`](../REALMD.md) -- realmd's own configuration and trust model.
- [`deploy/AUTHENTIK-SSO.md`](../deploy/AUTHENTIK-SSO.md) -- putting SSO in front of the admin UI.
