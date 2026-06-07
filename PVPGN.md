# PvPGN integration

The dedicated server slots in behind **PvPGN** (pvpgn-server 1.99.x) as the D2GS
its D2CS dispatches games to. Two links:

- **D2CS ↔ GS** (`src/realm/client/d2cs.zig`): the GS connects outbound to D2CS, auths,
  advertises capacity, and services game create/join. Protocol in
  `src/realm/shared/protocol.zig` (from pvpgn-server `src/common/d2cs_d2gs_protocol.h`).
- **D2DBS ↔ GS** (`src/realm/client/d2dbs.zig`): character fetch/save. `fetchCharSave`
  works (GET_DATA 0x31, datatype CHARSAVE) — tested vs a mock D2DBS, retrieved a
  512-byte save. Demo: `--d2dbs <ip:port> --fetch-char acct:char`. Source:
  pvpgn-server `src/d2dbs/dbspacket.h`. Next: drive it from the engine's
  `fpGetDatabaseCharacter` callback on player join + deliver bytes to the engine.

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

### ✅ Game creation works
The blocker was uninitialized data tables: `GAME_CreateBattleNetGame`'s
`RollSeed`/`Alloc*Control` read D2Common excel tables that the server-only boot
never loaded (the client app-mode entry normally calls `TXT_InitTxtFiles`
@0x619300). We now call `TXT_InitTxtFiles(0, 0, 1)` in the bootstrap (under
`--create-games`) — and `CREATEGAMEREQ` then **spawns a real game** and returns
`result=0, gameid` (tested under wine).

### ✅ Created games tick stably (empty, awaiting players)
`UpdateClients` asserted because `ARENA_GetClientUpdateFlag` = `(eArenaFlags>>2)&1`
was 0 — the game flags we passed lacked bit 2 (the client-update flag). With
`ARENAFLAG_ClientUpdate (0x04)` set in `gameFlags()`, a created game now **ticks
stably with no players** — the normal "game created, waiting for clients" state.
(Diagnosed by hooking `ERROR_…_Halt` @0x408a60 to log the assert caller/line:
`UpdateClients` @0x52d497, line 0xd31.)

### ⛔ Next layer: player entry
A client must connect to `:4000` with a valid token; the engine then validates it
(`fpFindPlayerToken`), builds the act/level (DRLG), and the player enters. Needs
the `fpFindPlayerToken` handler + a client speaking the D2 game protocol. Still
gated behind `--create-games` until that's in.

### Remaining
- ⏳ Player entry: implement `fpFindPlayerToken`; have a client join `:4000` so the
  engine builds the game world (then ticking is valid).
- ⏳ D2DBS link for character fetch/save (`fpGetDatabaseCharacter` / `…Save`).
- ⏳ Confirm real-realm `version`/`checksum`; whether `sign[128]` is verified.
- ⏳ DNS (dotted-quad IPv4 only for now).
