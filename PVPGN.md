# PvPGN integration

The dedicated server slots in behind **PvPGN** (pvpgn-server 1.99.x) as the D2GS
its D2CS dispatches games to. Two links:

- **D2CS ↔ GS** (`src/realm/d2cs.zig`): the GS connects outbound to D2CS, auths,
  advertises capacity, and services game create/join. Protocol in
  `src/realm/protocol.zig` (from pvpgn-server `src/common/d2cs_d2gs_protocol.h`).
- **D2DBS ↔ GS** (TODO): character load/save, driven by the engine's realm
  callbacks (`fpGetDatabaseCharacter` / `fpSaveDatabaseCharacter`).

## Wire format
8-byte little-endian header on every packet: `{ size:u16, type:u16, seqno:u32 }`,
`size` = total length incl. header.

| type | dir | meaning |
|-|-|-|
| 0x10 AUTHREQ | D2CS→GS | sessionnum, signlen, realmname, key checksum |
| 0x11 AUTHREPLY | GS→D2CS | version, checksum, randnum, signlen, sign[128] |
| 0x12 SETGSINFO | GS→D2CS | maxgame, gameflag |
| 0x13 ECHO | both | health check |
| 0x14 CONTROL | D2CS→GS | cmd (1=restart,2=shutdown), value |
| 0x20 CREATEGAME | D2CS→GS req / GS→D2CS reply | ladder, expansion, difficulty, hardcore |
| 0x21 JOINGAME | D2CS→GS req / GS→D2CS reply | gameid, token |
| 0x22 UPDATEGAMEINFO | GS→D2CS | game list/status |
| 0x23 CLOSEGAME | GS→D2CS | game ended |

## Flow
1. GS connects to D2CS, waits for `AUTHREQ`.
2. GS sends `AUTHREPLY` then `SETGSINFO`.  ← **implemented + tested**
3. D2CS sends `CREATEGAMEREQ` → GS creates the game (`GAME_CreateBattleNetGame`)
   and replies. *(TODO: wire create + reply)*
4. A client joins: D2CS sends `JOINGAMEREQ{gameid, token}` → GS registers the
   token (`QSERVER_PutNewGameOnTokenList`) so the engine's `fpFindPlayerToken`
   accepts the client, then the client connects to `:4000` and plays.
5. GS pushes `UPDATEGAMEINFO` / `CLOSEGAME` as games change.

## Run
```
... --d2cs <d2cs-ip:port>     # e.g. --d2cs 127.0.0.1:6113   (dotted-quad IPv4 for now)
```

## Status
- ✅ Connect + auth handshake (`AUTHREPLY` + `SETGSINFO`) — tested against a mock
  D2CS under wine.
- ✅ Full protocol exchange is **stable**: `CREATEGAMEREQ`→`CREATEGAMEREPLY` and
  `JOINGAMEREQ`→`JOINGAMEREPLY` are parsed and answered; the server stays alive
  through the whole sequence.
- ✅ CREATEGAME/JOINGAME → engine **wiring** done (parse strings/flags, call
  `GAME_CreateBattleNetGame` on the tick thread via a serialized command queue,
  return the engine's server token as gameid; JOINGAME registers the token).

### ⛔ Blocker: game-data init
`GAME_CreateBattleNetGame` **faults** in our server-only boot — its
`RollSeed` / `AllocObjectControl` / `AllocQuestControl` read D2Common excel data
tables that the dedicated bootstrap hasn't initialized (the host path reaches
them via the client message loop we skip). `QSERVER_PutNewGameOnTokenList` also
halts on an unmanaged token. So the engine calls are **gated behind
`--create-games`** (off by default → CREATE/JOIN reply "failed" but the server
stays stable). Next: find + call the server-side data-table / game-subsystem init
so creation succeeds, then re-enable by default.

### Remaining
- ⏳ Server-side game-data init (the blocker above) — then real game create/join.
- ⏳ Confirm real-realm `version`/`checksum`; whether `sign[128]` is verified.
- ⏳ D2DBS link for character fetch/save (realm callbacks).
- ⏳ DNS (dotted-quad IPv4 only for now).
