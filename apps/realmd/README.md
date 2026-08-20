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

Kubernetes deployment topology (LoadBalancer-fronted realmd + Redis/Postgres + an internal GS
fleet with no host ports — d2ingress splices to pod IPs):

![Kubernetes topology](../../docs/architecture/img/k8s_deploy.png)

## Files

- `realmd.zig` — the realm as a library: `run()` (config, bind the listeners, spawn the workers) and the re-exports an extension is built against.
- `main.zig` — the binary this repo ships: `realmd.run()` and nothing else. A realm with its own
  extensions is this same file plus a `realm_extensions` declaration.
- `hook.zig` — the extension surface: which hooks exist, and where the registry comes from.
- `proto.zig` — little-endian byte `Reader`/`Writer` (bounds-checked; a bad packet yields zeros, never panics a connection thread).
- `bncs.zig` — BNCS handlers. MVP policy: we are the authority and trust the client (version/password accepted, accounts auto-create). Includes `SID_AUTH_INFO/CHECK`, `SID_LOGONREALMEX`, `SID_QUERYREALMS2`, BNFTP handoff.
- `bnftp.zig` — BNFTP v1 file server (serves the version MPQ; **reply-header length is u32**, the client asserts if it reads `>0xff`).
- `d2cs.zig` — MCP: `MCP_STARTUP`, `MCP_CHARLIST2` (real statstrings), `MCP_CHARLOGON`, `MCP_CREATEGAME`/`MCP_JOINGAME`. On join it remembers the active char and tells the game server the account.
- `fleet.zig` — the game servers, as the whole realm sees them: create/join dispatch through their store queues, and the event stream they report back on.
- `charflush.zig` — moves saved characters from the redis cache to the store of record.
- `chat.zig` — channels, whispers and presence. Members are published into a shared per-channel roster and anything bound for another instance goes to its inbox, so a channel is the whole realm rather than one replica's half of it.
- `friends.zig` / `guilds.zig` — the friends list (stored in the account profile) and the cut Guild Halls feature.
- `state.zig` — sessions and games, kept in redis so any instance resolves what another created; instance-hashed ids keep them apart.
- `store.zig` — the persistence facade. Each domain op has exactly one home: Postgres for the record, redis for what is in flight. No backend selection.
- `admin.zig` / `webui.zig` — the admin API and its web UI, on the health port.
- `gameedge.zig` — the optional in-process game-traffic edge (`REALMD_GAME_PORT`), for a single host with no separate d2ingress.
- `health.zig` / `shutdown.zig` — probes, and the SIGTERM drain.
- `assets/` — `bnserver-D2DV.ini` (gateway/version config), the factored Blizzard weak-signature key, README.

## Testing it

`zig build e2e` runs 34 clientless scenarios against a real realmd, starting its own redis and
postgres containers. Two of them cover what this file is mostly about: `chat_across_instances`
(two instances, one channel — talk and whispers cross, another channel does not) and
`save_durability` (a save only redis had reaches postgres and survives losing the cache).

## Protocol notes

- BNCS framing: `FF <id:u8> <len:u16 LE>` (len includes the 4-byte header); the
  first socket byte is a protocol selector (`0x01` game, `0x02` BNFTP).
- MCP framing: `<len:u16 LE> <id:u8>`.
- realm↔game-server framing: 8-byte LE header `{size:u16, type:u16, seqno:u32}` — the same
  packets as before, now carried by redis instead of a socket. The `seqno` correlates a reply
  to its request, which a shared queue makes necessary and a single socket did not.

## Config (env)

Core: `REALMD_BIND`, `REALMD_BNET_PORT`, `REALMD_REALM_NAME`, `REALMD_REALM_ADDR`,
`REALMD_GAME_ADDR` (required), `REALMD_GS_ADDR`, `REALMD_CAPTURE` (hexdump mode).
`REALMD_DATA_DIR` supplies the BNFTP assets and nothing else.

`REALMD_INSTANCE` must differ per instance: it seeds session ids and dispatch request ids, so two
instances sharing one would collect each other's replies. In the chart it comes from
`metadata.name`.

Persistence — both required, neither selectable: `REALMD_REDIS_ADDR` (`host:port`) for everything
in flight, `REALMD_PG_DSN` (`postgres://…`) for the store of record.

Health / lifecycle: `REALMD_HEALTH_PORT` (default 8080; `/healthz` liveness, `/readyz`
readiness = stores reachable + a game server published + not draining), `REALMD_REQUIRE_GS` (gate
`/readyz` on ≥1 published game server), `REALMD_LOG_JSON` (JSON log lines),
`REALMD_SHUTDOWN_GRACE_MS` (SIGTERM drain window before exit).

## Run

```
REALMD_REDIS_ADDR=127.0.0.1:6379 \
  REALMD_PG_DSN=postgres://realmd:realmd@127.0.0.1:5432/realmd \
  REALMD_GAME_ADDR=127.0.0.1 REALMD_DATA_DIR=./realmd-data ./zig-out/bin/realmd
```

Multi-instance needs nothing extra beyond a distinct `REALMD_INSTANCE`: everything shared is
already in redis and Postgres. `./run-stack.sh` brings both stores up for you.
