# Verification log

Addresses below come from a decompiled/reconstructed map of retail 1.14d
`Game.exe`, cross-checked against disassembly of the retail binary.

## Verified (cross-checked against .cpp.map / `1.14d win:` comments)
| addr | symbol | sig |
|-|-|-|
| 0x0052b7a0 | QSERVER_CreateAndInit | (eConn, eGameType) stdcall |
| 0x0052b250 | NET_SetPlayersCount | (int) stdcall |
| 0x0052b280 | NET_HACK_SetUseQServerHack | (int) stdcall |
| 0x0052fc20 | QSERVER_TickAllGames | (int bLimitFrameSkip) stdcall |
| 0x0052cfe0 | NET_D2GS_SERVER_HandleAnyIncomingPacket | () stdcall |
| 0x00530930 | GAME_CreateBattleNetGame | (8 args) stdcall |
| 0x006bf760 | NET_QServer_Init | (8 args) stdcall — port 0xfa0=4000 |
| 0x006bf520 | Listen98Nt | (pQServer, port) |

## Open items — confirm in Ghidra before wiring
1. ~~**Listen trigger for CONNECTIONTYPE_SERVER.**~~ ✅ RESOLVED by test. Calling
   `QSERVER_CreateAndInit(SERVER, BNET)` from our thread results in the process
   LISTENING on `*:4000` (verified with `lsof -iTCP:4000` → wineserver LISTEN).
   No separate `Listen98Nt`/`StartListening` call needed — the CreateAndInit /
   tick path opens the socket itself. The QServer is live and accepting on 4000.

2. ~~**Globals.**~~ ✅ RESOLVED. Decompiled `NET_QServer_StartServer @0x0044bc30`
   (the canonical startup) + data_symbols.json:
   - `gQServerGameState` @ **0x007a0690** (D2QServerGameStateStrc, 104 bytes, static)
   - `gbQServerRunning` @ **0x007a0458** (u32)
   - `gpQServerGameState` @ 0x00883d38 (ptr set by SetGlobalInstance)
   - host's `0x7a0630` cookie = `gInterfaceConfig1` (just needs to be ≠0 → skip halt)
   - `SetupAsBnetServer @0x0052c0e0` has **zero xrefs** in retail — dormant realm-host
     entry, exactly the dead code we resurrect.
   Full sequence wired into `bootstrapRealmServer()` and tested: open + realm mode
   both LISTEN on :4000 and stay alive. A dedicated server does NOT need the host's
   `NET_D2GS_ConnectToServer` (that's host-as-player-1).

3. **Tick pump.** Confirm `QSERVER_TickAllGames(1)` is the right standalone pump,
   vs. the engine driving it through `MessageGameLoop(CLIENTMODE_Unused3)`. Check
   callers of `QSERVER_TickAllGames` (`Src/GameData.cpp:660,1892,1900`).

4. **Init ordering.** Replace the 2s `Sleep` in `serverThread` with a hook on the
   engine's init-complete point (so we bootstrap deterministically, not on a timer).

5. ~~**ASLR.**~~ ✅ RESOLVED. Wine injection test logged `Game.exe base=0x400000`
   — fixed base, no DYNAMICBASE. Absolute reconstruction addresses apply 1:1.
   (`at()` rebase kept anyway, harmless.)

## Test status (wine, retail OG Game.exe sha256 631066c1…, base 0x400000)
- ✅ Injection pipeline: dbghelp proxy → `-loaddll d2gs.dll` → `DllMain` runs.
- ✅ `--headless` byte-patches let the host survive with no display.
- ✅ `--d2gs-boot` / `--realm`: `bootstrapRealmServer()` runs, process LISTENS on
  `*:4000` (verified via `lsof`) and stays alive in the tick loop.
