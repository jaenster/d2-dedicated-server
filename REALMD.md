# realmd — a Zig Battle.net / Diablo II realm server

`src/realm/server/` is a clean-room replacement for **PvPGN** (bnetd + d2cs + d2dbs),
written in Zig as a single binary. It is the realm the unmodified 1.14d client
logs into, and it dispatches games to our injected game server (`d2gs.dll` in
`Game.exe`) over the same control protocol the GS already speaks.

It is a separate build target from the injection DLLs — a **native executable**,
built for the host and cross-compiled to a static Linux binary for deploy.

## Why, vs PvPGN
- **One process, not three.** PvPGN runs bnetd/d2cs/d2dbs as separate daemons
  glued over localhost TCP with sed-patched config files. realmd is one binary
  with three (plus a GS-link) listeners over shared state.
- **We own both ends of the realm↔GS link**, so the realm handoff carries a plain
  session id in the MCP chunk — no shared-secret crypto, no `gameservlist` IP
  whitelist, and crucially **no SNAT problem** (the GS-link has its own port and
  the GS's address is just the connection's peer IP).
- **Stateless fronts over a Store seam.** All durable/cross-connection state
  (sessions, games, character saves) lives behind one interface. Single instance
  = local files (survives restarts). Multi-instance = a shared volume, so N
  instances run in tandem and any of them resolves what another created.
- One static binary, env-only config, no config files.

## Listeners
| Port | Role |
|-|-|
| 6112 | bnetd — Battle.net login, realm list, realm handoff |
| 6113 | d2cs — realm: session, character list/logon/create, game create/join |
| 6114 | d2dbs — character save load/store |
| 6115 | gs-link — our injected game server connects here (its own port) |

## Configuration (env only)
| Var | Default | Meaning |
|-|-|-|
| `REALMD_BIND` | `0.0.0.0` | bind address |
| `REALMD_BNET_PORT` / `REALMD_D2CS_PORT` / `REALMD_D2DBS_PORT` / `REALMD_GS_PORT` | 6112–6115 | listener ports |
| `REALMD_REALM_NAME` | `TypeGuru` | realm name shown to clients |
| `REALMD_REALM_ADDR` | `127.0.0.1` | public IPv4 clients dial for d2cs (bnetd advertises it) |
| `REALMD_GS_ADDR` | (peer IP) | override the game-server IP given to clients (NAT) |
| `REALMD_DATA_DIR` | `realmd-data` | durable data dir (character saves; shared state) |
| `REALMD_SHARED` | off | multi-instance mode: sessions/games in the shared store |
| `REALMD_INSTANCE` | `realmd-0` | instance id (must be unique per instance in shared mode) |
| `REALMD_CAPTURE` | off | hexdump raw bytes instead of speaking the protocol |

## Build & run
```sh
zig build realmd              # build + run (native)
zig build install             # just build -> zig-out/bin/realmd

# single instance
REALMD_REALM_ADDR=<your-ip> ./zig-out/bin/realmd

# two instances in tandem over a shared dir
REALMD_SHARED=1 REALMD_INSTANCE=A REALMD_DATA_DIR=/srv/realmd ./zig-out/bin/realmd
REALMD_SHARED=1 REALMD_INSTANCE=B REALMD_DATA_DIR=/srv/realmd \
  REALMD_BNET_PORT=7112 REALMD_D2CS_PORT=7113 REALMD_D2DBS_PORT=7114 REALMD_GS_PORT=7115 \
  ./zig-out/bin/realmd
```

## Deploy
```sh
zig build install -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe   # static ELF, zero deps
docker build -f deploy/Dockerfile -t realmd:latest .
kubectl apply -f deploy/realmd.yaml                                    # N replicas + shared RWX PVC
```
The deploy image is `FROM scratch` (the binary is fully static). The k8s manifest
runs multiple replicas over a ReadWriteMany volume with `REALMD_INSTANCE` set to
the pod name.

## Status — validated vs pending
**Implemented and smoke-tested** (clients in `tools/realmd-test/`):
- bnetd full login: AUTH_INFO → AUTH_CHECK → LOGON → QUERYREALMS2 → LOGONREALMEX.
- d2cs: MCP_STARTUP (session resolve), CHARLIST2 (from store), CHARLOGON, CHARCREATE.
- d2cs games: CREATEGAME / JOINGAME, driving the GS over the control link.
- gs-link: AUTHREQ → AUTHREPLY/SETGSINFO, CREATEGAME/JOINGAME request-reply.
- d2dbs: GET/SAVE character saves. **Restart survival proven.**
- **Multi-instance proven**: session minted on instance A resolved on instance B;
  game created on A discovered/joined on B.

**Pending** (`tasks #9`):
- **Real 1.14d client E2E.** Encodings are internally consistent and smoke-tested,
  but not yet confirmed against the actual client. The character-list **statstring**
  especially needs a real capture (currently empty — the list shows names/count
  but the client renders each char minimally).
- Pointing the client at the realm (registry `HKCU\Software\Battle.net`).
- GS-side `fpFindPlayerToken` (in the d2gs DLL) for the final join validation.
- Account password verification (currently trust-all) and version/checksum gating.

## Trust model (MVP)
realmd is the authority and currently trusts the client: SID_AUTH_CHECK and the
password are accepted unconditionally, accounts auto-create on first logon.
Hardening (X-SHA-1 password, version MPQ) is a later pass — "just works" first.
