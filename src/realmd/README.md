# src/realmd — the realm server

A clean-room **Battle.net / Diablo II realm server** in Zig, one native binary
that replaces PvPGN's `bnetd` + `d2cs` + `d2dbs` (plus a GS-link the injected game
server connects to). The unmodified 1.14d client logs in here, passes the version
check, lists/loads characters, and creates/joins games that are dispatched to the
headless game server.

Clean-room: implemented from captured bytes + bnetdocs, **not** from PvPGN's GPL
source. MIT-licensed.

## Listeners

| port | name | role |
|-|-|-|
| 6112 | `bncs.zig` | BNCS chat/login: account login, realm query, **BNFTP** version MPQ, char list |
| 6113 | `d2cs.zig` | MCP (client-facing realm): session startup, char logon, create/join game |
| 6114 | `d2dbs.zig` | character save get/save (the GS fetches `.d2s` here) |
| 6115 | `gslink.zig` | GS-facing control: the injected server registers + receives create/join dispatch |

`main.zig` binds all four and serves each on its own thread.

## Files

- `main.zig` — entry: config, bind the 4 listeners, spawn serve threads.
- `config.zig` — env-driven config (`REALMD_*`: ports, bind, data dir, realm name/addr, instance id, shared mode).
- `net.zig` — tiny libc-socket TCP listener/serve loop (zig 0.16 has no std sockets).
- `proto.zig` — little-endian byte `Reader`/`Writer` (bounds-checked; a bad packet yields zeros, never panics a connection thread).
- `protocol.zig` — typed protocol enums: chat flags + D2GS message ids (bnetdocs docs 15 / 28).
- `bncs.zig` — BNCS handlers. MVP policy: we are the authority and trust the client (version/password accepted, accounts auto-create). Includes `SID_AUTH_INFO/CHECK`, `SID_LOGONREALMEX`, `SID_QUERYREALMS2`, BNFTP handoff.
- `bnftp.zig` — BNFTP v1 file server (serves the version MPQ; **reply-header length is u32**, the client asserts if it reads `>0xff`).
- `d2cs.zig` — MCP: `MCP_STARTUP`, `MCP_CHARLIST2` (real statstrings), `MCP_CHARLOGON`, `MCP_CREATEGAME`/`MCP_JOINGAME`. On join it remembers the active char and tells the GS the account over the gs-link.
- `d2dbs.zig` — character DB: `GET_DATA`/`SAVE_DATA` for char saves.
- `gslink.zig` — d2cs↔d2gs control channel: AUTHREQ/REPLY, SETGSINFO, CREATEGAME/JOINGAME dispatch (sends account+char so the GS can fetch the save).
- `state.zig` — in-memory sessions/games, instance-hashed ids for multi-instance.
- `store.zig` — durable Store seam: `chars/<account>/<char>.d2s` + small session/game records. File-backed today; the seam keeps multi-instance to a shared dir (e.g. a RWX PVC) with no extra service.
- `lock.zig` — spinlock (zig 0.16 dropped `Thread.Mutex`).
- `log.zig` — line logger.
- `assets/` — `bnserver-D2DV.ini` (gateway/version config), the factored Blizzard weak-signature key, README.

## Protocol notes

- BNCS framing: `FF <id:u8> <len:u16 LE>` (len includes the 4-byte header); the
  first socket byte is a protocol selector (`0x01` game, `0x02` BNFTP).
- MCP framing: `<len:u16 LE> <id:u8>`.
- d2cs↔d2gs / d2dbs framing: 8-byte LE header `{size:u16, type:u16, seqno:u32}`.

## Config (env)

`REALMD_BIND`, `REALMD_BNET_PORT`/`D2CS_PORT`/`D2DBS_PORT`/`GS_PORT`,
`REALMD_DATA_DIR`, `REALMD_REALM_NAME`, `REALMD_REALM_ADDR`, `REALMD_GS_ADDR`,
`REALMD_INSTANCE`, `REALMD_SHARED`, `REALMD_CAPTURE` (hexdump mode).

## Run

```
REALMD_DATA_DIR=./realmd-data ./zig-out/bin/realmd
```

Multi-instance: run several with a shared `REALMD_DATA_DIR` + distinct
`REALMD_INSTANCE` and `REALMD_SHARED=1`.
