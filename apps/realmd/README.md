# apps/realmd — the realm server (`realmd` binary)

A clean-room **Battle.net / Diablo II realm server** in Zig, one native binary
that replaces PvPGN's `bnetd` + `d2cs` + `d2dbs`. The unmodified 1.14d client logs
in here, passes the version check, lists/loads characters, and creates/joins games
that are dispatched to the headless game server through redis.

Clean-room: implemented from captured bytes + bnetdocs, **not** from PvPGN's GPL
source. MIT-licensed.

## Listeners

| port | name | role |
|-|-|-|
| 6112 | `bncs.zig` | BNCS chat/login **and** MCP: account login, realm query, BNFTP version MPQ, char list, create/join |
| 8080 | `health.zig` | probes + the admin API and web UI |

One client-facing port, as real Battle.net has it: `bncs.handle` selector-muxes MCP onto it.
Game servers have no port here at all — they meet the realm in redis.

## Architecture

`fleet.zig` sees the whole fleet through the shared store and dispatches to it there, so any
instance can serve any client. Everything durable is Postgres and everything in flight is Redis;
both are required and neither is selectable. See [`../../docs/redis.md`](../../docs/redis.md),
and the full model in
[`../../docs/architecture/`](../../docs/architecture/):

![GS fleet](../../docs/architecture/img/gs_fleet.png)

Kubernetes deployment topology (LoadBalancer-fronted realmd + Redis/Postgres +
GS StatefulSet with `hostPort 4000`):

![Kubernetes topology](../../docs/architecture/img/k8s_deploy.png)

## Files

- `main.zig` — entry: config, bind the listeners, spawn the workers.
- `config.zig` — env-driven config (`REALMD_*`: ports, bind, data dir, realm name/addr, instance id, shared mode).
- `net.zig` — tiny libc-socket TCP listener/serve loop (zig 0.16 has no std sockets).
- `proto.zig` — little-endian byte `Reader`/`Writer` (bounds-checked; a bad packet yields zeros, never panics a connection thread).
- `protocol.zig` — typed protocol enums: chat flags + D2GS message ids (bnetdocs docs 15 / 28).
- `bncs.zig` — BNCS handlers. MVP policy: we are the authority and trust the client (version/password accepted, accounts auto-create). Includes `SID_AUTH_INFO/CHECK`, `SID_LOGONREALMEX`, `SID_QUERYREALMS2`, BNFTP handoff.
- `bnftp.zig` — BNFTP v1 file server (serves the version MPQ; **reply-header length is u32**, the client asserts if it reads `>0xff`).
- `d2cs.zig` — MCP: `MCP_STARTUP`, `MCP_CHARLIST2` (real statstrings), `MCP_CHARLOGON`, `MCP_CREATEGAME`/`MCP_JOINGAME`. On join it remembers the active char and tells the game server the account.
- `fleet.zig` — the game servers, as the whole realm sees them: create/join dispatch through their store queues, and the event stream they report back on.
- `charflush.zig` — moves saved characters from the redis cache to the store of record.
- `state.zig` — in-memory sessions/games, instance-hashed ids for multi-instance.
- `store.zig` — durable Store seam: `chars/<account>/<char>.d2s` + small session/game records. File-backed today; the seam keeps multi-instance to a shared dir (e.g. a RWX PVC) with no extra service.
- `lock.zig` — the lock everything here uses (zig 0.16 dropped `Thread.Mutex`). Spins briefly, then yields, then sleeps: several of its callers hold it across IO.
- `log.zig` — line logger; one line costs one `write`.
- `assets/` — `bnserver-D2DV.ini` (gateway/version config), the factored Blizzard weak-signature key, README.

## Protocol notes

- BNCS framing: `FF <id:u8> <len:u16 LE>` (len includes the 4-byte header); the
  first socket byte is a protocol selector (`0x01` game, `0x02` BNFTP).
- MCP framing: `<len:u16 LE> <id:u8>`.
- realm↔game-server framing: 8-byte LE header `{size:u16, type:u16, seqno:u32}` — the same
  packets as before, now carried by redis instead of a socket. The `seqno` correlates a reply
  to its request, which a shared queue makes necessary and a single socket did not.

## Config (env)

Core: `REALMD_BIND`, `REALMD_BNET_PORT`/`D2CS_PORT`/`D2DBS_PORT`/`GS_PORT`,
`REALMD_DATA_DIR`, `REALMD_REALM_NAME`, `REALMD_REALM_ADDR`, `REALMD_GS_ADDR`,
`REALMD_INSTANCE`, `REALMD_SHARED`, `REALMD_CAPTURE` (hexdump mode).

Persistence (DDD facade → fs | redis | pg; no adapters): `REALMD_STORE` sets both
backends at once; `REALMD_DURABLE_STORE` (character saves) and
`REALMD_EPHEMERAL_STORE` (sessions + games) override each — the common cloud split is
`durable=pg`, `ephemeral=redis`. `REALMD_REDIS_ADDR` (`host:port`), `REALMD_PG_DSN`
(`postgres://…`). A redis/pg ephemeral backend is treated as shared (no `REALMD_SHARED`
needed).

Health / lifecycle: `REALMD_HEALTH_PORT` (default 8080; `/healthz` liveness, `/readyz`
readiness = store reachable + GS present + not draining), `REALMD_REQUIRE_GS` (gate
`/readyz` on ≥1 registered GS), `REALMD_LOG_JSON` (JSON log lines),
`REALMD_SHUTDOWN_GRACE_MS` (SIGTERM drain window before exit).

## Run

```
REALMD_DATA_DIR=./realmd-data ./zig-out/bin/realmd
```

Multi-instance: run several with a shared `REALMD_DATA_DIR` + distinct
`REALMD_INSTANCE` and `REALMD_SHARED=1`.
