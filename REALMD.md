# realmd: a Zig Battle.net / Diablo II realm server

`apps/realmd/` is a clean-room replacement for **PvPGN** (bnetd + d2cs + d2dbs), written in
Zig as a single binary. It is the realm the unmodified 1.14d client logs into, and it dispatches
games to our injected game server (`d2gs.dll` in `Game.exe`) over the same control protocol the GS
already speaks.

It is a separate build target from the injection DLLs: a **native executable**, built for the host
and cross-compiled to a static Linux binary for deploy.

## Why, vs PvPGN
- **One process, not three.** PvPGN runs bnetd/d2cs/d2dbs as separate daemons glued over localhost
  TCP with sed-patched config files. realmd is one binary with shared in-memory state behind a few
  listeners.
- **One client port, like real Battle.net.** The client speaks both BNCS (login) and MCP (realm) on
  **6112** -- realmd demuxes them on the byte after the `0x01` selector, exactly as real bnet tells
  them apart by host. There is no pvpgn-style fan of client-facing ports.
- **We own both ends of the realm/GS relationship**, so the realm handoff carries a plain session
  id in the MCP chunk: no shared-secret crypto and no `gameservlist` IP whitelist. There is no SNAT
  problem either, because there is no connection to observe an address from -- a game server states
  its own client-facing address in the record it publishes.
- **Stateless fronts over a Store seam.** Every piece of cross-connection state — sessions, games,
  characters, accounts, profiles, guilds — lives behind one interface, and each has exactly one
  home: Postgres for the record, Redis for what is in flight. So does reaching a game server. Any
  instance resolves what another created and dispatches to the whole fleet. The only thing read
  from local disk is the BNFTP asset set, which is read-only image content.
- One static binary, env-only config, no config files.

## Listeners

| Port | Facing | Role |
|-|-|-|
| 6112 | client | bnetd login + MCP realm (list/select/create/join), muxed on one port |
| 8080 | ops | health/readiness + admin API + (optional) embedded web UI |

The game-server fleet has no port here: servers meet the realm in redis rather than connecting
to it. See [`docs/redis.md`](docs/redis.md).

## Configuration (env only)
| Var | Default | Meaning |
|-|-|-|
| `REALMD_BIND` | `0.0.0.0` | bind address |
| `REALMD_BNET_PORT` | 6112 | the client-facing listener |
| `REALMD_REDIS_ADDR` | `redis:6379` | REQUIRED — sessions, games, the fleet, the live character |
| `REALMD_PG_DSN` | -- | REQUIRED — the store of record: characters, accounts, profiles, guilds |
| `REALMD_REALM_NAME` | `TypeGuru` | realm name shown to clients |
| `REALMD_REALM_ADDR` | `127.0.0.1` | public IPv4 clients dial for the realm (advertised on login) |
| `REALMD_GAME_ADDR` | -- | GATEWAY mode: the d2ingress entry advertised for game traffic |
| `REALMD_GS_ADDR` | (peer IP) | override the game-server IP given to clients (NAT) |
| `REALMD_DATA_DIR` | `realmd-data` | where BNFTP assets are read from (read-only image content) |
| `REALMD_INSTANCE` | `realmd-0` | instance id (must be unique per instance in shared mode) |
| `REALMD_LOG_JSON` | off | structured JSON logs to stdout (for Loki) |
| `REALMD_CAPTURE` | off | hexdump raw bytes instead of speaking the protocol |

## Build & run
```sh
zig build realmd              # build + run (native)
zig build install             # just build -> zig-out/bin/realmd

# single instance
REALMD_REALM_ADDR=<your-ip> ./zig-out/bin/realmd

# two instances in tandem over a shared redis (ephemeral) + pg (durable)
REALMD_REDIS_ADDR=127.0.0.1:6379 \
  REALMD_PG_DSN=postgres://realmd:realmd@127.0.0.1:5432/realmd \
  REALMD_INSTANCE=A ./zig-out/bin/realmd
```

## Deploy
```sh
zig build install -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe   # static ELF, zero deps
docker build -f deploy/Dockerfile --target realmd -t realmd:latest .
helm install myrealm deploy/chart --set realmAddr=<your-ip>           # see deploy/chart/README.md
```
The deploy image is `FROM scratch` (the binary is fully static). On Kubernetes realmd is stateless
behind a LoadBalancer with Redis + Postgres backends; see [`deploy/chart`](deploy/chart/).

## Status
**Working** (driven by clients in `tools/realmd-test/` and by a real 1.14d client):
- bnetd full login: AUTH_INFO -> AUTH_CHECK -> LOGON -> QUERYREALMS2 -> LOGONREALMEX.
- d2cs: MCP_STARTUP (session resolve), CHARLIST2, CHARLOGON, CHARCREATE -- char select renders.
- d2cs games: CREATEGAME / JOINGAME, dispatched to a game server through its store queue.
- Characters: read and written by the game server itself, in redis; **restart survival proven**.
- **Multi-instance proven**: session minted on A resolved on B; game created on A joined on B,
  with two realmd processes against one fleet and both players in the world together.
- **Real client end to end**: a retail 1.14d client logs in, creates/joins a game on the headless
  GS, and the character spawns in-world -- including two clients in one game (see the top-level
  README Status).

**Next:**
- Ladder list is still a stub.
- Harden auth (OLS broken-SHA-1 password path) and version/checksum gating beyond the current gate.

## Trust model
realmd is the authority. Auth is enforced by default (`permissive_auth` is opt-in for the trust-all
dev path); accounts can auto-create on first logon. The version check is satisfied by the BNFTP MPQ
+ CheckRevision path. Password hardening (the OLS broken-SHA-1 path) is an ongoing pass.
