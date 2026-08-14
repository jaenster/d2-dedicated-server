# The Mac 1.14d TCP/IP host path into QSERVER

All addresses are file/image offsets in the `DiabloII` i386 Mach-O (Ghidra session `ce51a192`).
Windows 1.14d `Game.exe` addresses are marked `win:` and come from session `c18aa0f2` /
`apps/d2gs/engine/server.zig`.

## 1. Verdict

**Yes. The hypothesis holds.** The Mac build has no dedicated-server application mode — the app-mode
bootstrap table at `0x003e0eb8` has six `{Init, Shutdown}` slots and slot 2 (server) is `{0, 0}` —
but "Host Game" on the TCP/IP screen reaches exactly the same `QSERVER_CreateAndInit(CONNECTIONTYPE_SERVER, 1)`
call the dedicated server would have used. The chain is short and, crucially, **contains no branch that
depends on the menu**: the HOST GAME button (widget id `0x106`) sets one field — the connection type,
to `8` — in the process-wide session struct; `LoadDataForGame` publishes that field into the global
`geClientConnectionType` (`0x005c15d4`); and the client state machine then runs a **fixed, unconditional**
sequence `3 → 5 → 2 → 6 → 4 → 1` in which state 5 is `NET_QServer_StartServer` (`0x00073ac3`) — the only
place in the whole image that builds a QSERVER — and state 2 is `pfModes_EnterGame` (`0x00070e8f`), which
spawns the `"OpenServerThread"` tick loop. Every game type walks through state 5; the connection type is
the sole thing that decides whether it creates a server or merely dials out. That makes the Mac host path
strictly *better* than synthesising an app mode that was never compiled in: it is one integer, not a
missing subsystem.

## 2. Call chain, address by address

|address|symbol|what it does|how confirmed|
|-|-|-|-|
|`0x003cb9cc + 0x30*n`|widget descriptor table (base `UNK_003c896c`, stride `0x30`)|Descriptor for id `0x106` is `[type=6 button, x=0x109, y=0xce, w=0x110, h=0x23, flags=0, str=0x13fe, img=0x5cc060, **click=0x002c3bf2**]`|Decoded the raw bytes at `0x003cb9cc`. `UIMENU_TCPIPOptions` `0x002c58e5` creates exactly ids `0x102..0x10b` via `D2WINMAIN_SetBackgroundDC6` `0x002c4355`, whose body is `UI_WIDGET_CreateByType(&UNK_003c896c + id*0x30)`. Sibling id `0x107`'s click is `0x002c3ca8` (the join/address dialog), so `0x106` is the other button, HOST.|
|`0x002c3bf2`|`MAINMENU_TcpIpHostGame` (was `MAINMENU_ConnectViaTCPIPAndSelectChar`)|`pSession->0x19 = 8`; `strcpy(pSession->0x37, NET_GetLocalIp())`; `gnMenuGameType = 2`; `pSession->0x209 = 4`; then character select|Decompiled. The **local** IP is what makes this the host: the join handler `MAINMENU_TcpIpJoinGameConnect` `0x002c3e2e` writes the *typed* address and connection type **9**. Only real xref to this function in the image is the widget table.|
|`0x002bda5d`|`SelectCharHandler`|On character click: `if (gnMenuGameType == 0 \|\| (gnMenuGameType == 2 && pSession->0x19 == 8)) → UIMENU_SelectDifficultySinglePlayerOrTcpip`|Decompiled; the literal `CMP dword ptr [ECX + 0x19], 0x8` is at `0x002bdcbe`. Independent confirmation that 8 is the host side — only a host picks the difficulty.|
|`0x002ca581`|`CHARSEL_LaunchGameWithCharacter` (was `UNICODE_WideToMultiByte`)|`gnMenuGameType == 2` branch: `pSession->0x35e = 3`, `pSession->0x209 = 4\|0x804`, **`gnNextAppMode (0x005cbffc) = 1`**, `UI_DISPLAY_SetRunLoopActive()` (ends the launcher event loop). It does **not** touch `pSession->0x19`, so the `8` survives.|Decompiled. Its single-player sibling branch writes `pSession->0x19 = 0`, which is how `0` is proven to be CONNECTIONTYPE_SINGLEPLAYER.|
|`0x002c7f07`|`fAPPMODE_launcher_ReturnAppMode_Caller`|The launcher app mode. Returns `gnNextAppMode` = 1 = APPMODE_CLIENT.|Epilogue disassembly at `0x002c8ff2`: `MOV EAX,[0x5cbffc]` immediately before the stack-guard check and `RET`. `0x5cbffc` has exactly one reader in the image, this one.|
|`0x003e0eb8[1]`|`{0x0005d12d AppModeClientInit, 0x0005d157}`|APPMODE_CLIENT. `AppModeClientInit` returns `&PTR_fAPPMODE_client_ReturnAppMode_Caller_00398010`.|Read the table bytes; slot 2 is `{0,0}`, slot 4 is the launcher pair `{0x2c1447, 0x2c1461}`.|
|`0x0005dc61`|`fAPPMODE_client_ReturnAppMode`|`LoadDataForGame(pSession)` → `TABLES_LoadStrings` → `TXT_LoadAllTxtTables` → then `state = 3; do { state = pfModes[state](); } while (state != 1);`|Decompiled: `DAT_00398014 = (**(code **)(&pfModes + DAT_00398014*4))()`, table base `0x003cfc30`.|
|`0x000714ea`|`LoadDataForGame`|Calls the 52-entry client-init table at `0x003cfdb0` with `pSession`; entries 12..16 are `0x00071957`.|Decompiled loop `i = 0..0x33, skip 0x2b and 0x30`. `0x00071957` sits at `0x003cfde0..0x003cfdf0` = indices 12..16.|
|`0x00071957`|`NET_ApplyMenuSessionSettingsToGlobals` (was a **duplicate, wrong** `NET_QServer_StartServer`)|`geClientConnectionType = pSession->0x19`; `gszClientGameName = pSession->0x1f`; and if `pSession->0x37 != "0"` then `gszD2GSServerAddress = pSession->0x37`|Disassembly `0x000719b9`: `MOV EAX,[EDI+0x19]` / `MOV [ESI+0x54fc6f],EAX` with `ESI = 0x71965`, i.e. `0x005c15d4`. The "battle.net IP" `0x00398420` is a **writable global** initialised to `"207.82.87.243"`, not a literal — that is the destination of the `strlcpy`, not the source.|
|`pfModes[3] = 0x0006feea`|`pfModes_BeginSession` (was `pfModes_PostGameClearCaches`)|`CLIENTMODE_PushMode(2); return 5;`|Decompiled. `CLIENTMODE_PushMode` `0x0005dab3` (was `D2GFX_ClearCaches`) is a 5-deep integer queue at `0x004336ac` — no graphics state is touched.|
|`pfModes[5] = 0x00073ac3`|`NET_QServer_StartServer` (win: `0x0044bc30`)|`case 6: case 8:` → `QSERVER_CreateAndInit(0, 1)`; `NET_SetPlayersCount(8)`; `NET_HACK_SetUseQServerHack(0)`; `NET_D2GS_ConnectToServer(0, gszD2GSServerAddress)`; `CLIENTMODE_RunFrameLoop(GameLoopFuncInitGame)`; `QSERVER_SetGlobalInstance(...)`; **`gbQServerRunning = 1`**; `QSERVER_InitializeServerState()`|Decompiled. `QSERVER_CreateAndInit` `0x002ddfa7` embeds the immediate `4000` (the D2GS listener port) and stores to `pQServer`. Returns `CLIENTMODE_PopMode()` = 2.|
|`pfModes[2] = 0x00070e8f`|`pfModes_EnterGame`|For connection type 6 or 8 **only**: `MAC_beginthreadex(0, 0x20000, QSERVER_CooperativeThreadMain, 0, 0, &DAT_00441ad4, "OpenServerThread")`|Decompiled; the thread name is a literal in the call.|
|`0x0006fd13`|`QSERVER_CooperativeThreadMain`|`NET_D2GS_SERVER_HandleAnyIncomingPacket(); if (QSERVER_TickAllGames(1)) QSERVER_DispatchAndCleanup(0,0); Sleep(10\|30);` until the stop flag; logs `"Open server thread shut down"`|Decompiled; the shutdown string is a literal.|

Two more corroborations that 6 and 8 are *the* host pair, found independently of the menu:

- `CLIENTMODE_RunFrameLoop` `0x0005e2ee` skips its `MAC_Sleep(10)` exactly when
  `geClientConnectionType` is 6 or 8 — those two run uncapped, like a server.
- `fAPPMODE_client_ReturnAppMode`'s tail picks the *next* app mode with the bitmask
  `0xcc >> connType` (bits 2,3,6,7 → APPMODE_CHAT 3, everything else → APPMODE_LAUNCHER 4). TCP/IP
  (8, 9) returns to the launcher menu; open battle.net (6, 7) returns to the chat mode. The two
  families are structurally distinct but share the host/join shape.

### The connection-type enum (all values now proven)

|value|meaning|writer|effect in `NET_QServer_StartServer`|
|-|-|-|-|
|0|single player|`CHARSEL_LaunchGameWithCharacter`, `gnMenuGameType == 0`|`QSERVER_CreateAndInit(1, 1)`|
|1|single player, alt|—|`QSERVER_CreateAndInit(2, 1)`|
|2|open battle.net create, alt|`OOGMENU_CreateGame` when `pSession->0x22d != 0`|connect only|
|3|open battle.net join, alt|`OOGMENU_JoinGame` when `pSession->0x22d != 0`|connect only|
|4|realm / closed battle.net|realm login path|connect only|
|**6**|**open battle.net HOST**|`OOGMENU_CreateGame` `0x002d1f60`|**`QSERVER_CreateAndInit(0, 1)` + OpenServerThread**|
|7|open battle.net join|`OOGMENU_JoinGame` `0x002d20b0`|connect only|
|**8**|**TCP/IP HOST**|`MAINMENU_TcpIpHostGame` `0x002c3bf2`|**`QSERVER_CreateAndInit(0, 1)` + OpenServerThread**|
|9|TCP/IP join|`MAINMENU_TcpIpJoinGameConnect` `0x002c3e2e`|connect only|

`QSERVER_CreateAndInit`'s first argument is a *different* enum — the server type — and `0` there is
`CONNECTIONTYPE_SERVER`, matching `apps/d2gs/engine/server.zig`'s `ConnectionType.server = 0`.

### `gnExpansionGame` is misnamed

`0x005cc000`, renamed **`gnMenuGameType`**. It is the front-end game-type selector, nothing to do with
the expansion (that test is `D2CheckExpansionGame`):

|value|meaning|
|-|-|
|0|single player|
|1|Battle.net (realm / closed)|
|2|TCP/IP|
|3|open Battle.net|

Proof: `fAPPMODE_launcher_ReturnAppMode_Caller` maps the launcher return byte `pSession->0x35e`
`1/2/3/4` onto `0/1/2/3` and opens the matching screen (`3 → UIMENU_TCPIPOptions`);
`CHARSEL_LaunchGameWithCharacter` writes that byte back per type and treats 1 and 3 as the two
battle.net variants, choosing 4 (→ `gnMenuGameType = 3`) when the account name is empty (open) and 2
(→ 1) when it is not (realm); `SelectCharHandler` gates the difficulty screen on
`gnMenuGameType == 0 || (gnMenuGameType == 2 && connType == 8)`.

## 3. Required process state

Everything the host path needs, and nothing more. `pSession` is `*gpMenuSessionData` (`0x005cbfcc`),
the struct the app-mode driver hands to each mode.

|location|must hold|why|
|-|-|-|
|`pSession->0x19` (u32)|`8` (TCP/IP host) or `6` (open bnet host)|the only input to the `NET_QServer_StartServer` switch, via `geClientConnectionType`|
|`pSession->0x37` (char[])|the address the local client dials, e.g. `"127.0.0.1"`; must not be the literal `"0"` or the default `"207.82.87.243"` is kept|copied to `gszD2GSServerAddress` `0x00398420`; state 5 calls `NET_D2GS_ConnectToServer(0, that)` **for the host too**|
|`pSession->0x1f` (char[])|game name|copied to `gszClientGameName` `0x005c1684`|
|`pSession->0xbd` / `0xd5`|character name / account name|`GAME_InitClientSide` and the char-load path|
|`pSession->0x1ef` (u16)|character status word: bit 5 = expansion, bits 8..12 = difficulty/title|read all over `pfModes_EnterGame`|
|`pSession->0x209` (u32)|`4`, or `0x804` when the char is hardcore, `+0x100000` when expansion|written by `MAINMENU_TcpIpHostGame` / `CHARSEL_LaunchGameWithCharacter`|
|`pSession->0x229` (u32)|copied to `DAT_005c1698`, which `pfModes_EnterGame` feeds to `MESSAGE_RegisterEventHandlerBatch`|only meaningful for the 3/7/9 client branch; harmless for a host|
|`pSession->0x22d` (u8)|`0`|otherwise `OOGMENU_CreateGame` uses the alt types 2/3 which never build a server|
|`pSession->0x225`|renderer/context object|stored to `PTR_DAT_003962f4`; the launcher calls `(**(obj+0x68))()`. The host path itself never dereferences it, but `pfModes_EnterGame` does through the sound/cursor init.|
|`gnMenuGameType` `0x005cc000`|`2`|only read by menu code, but set it for consistency — `SelectCharHandler` and `CHARSEL_LaunchGameWithCharacter` both key off it|
|`gnNextAppMode` `0x005cbffc`|`1` (APPMODE_CLIENT)|the value the launcher app mode returns to the driver|
|`geClientConnectionType` `0x005c15d4`|`8`|derived; set by `NET_ApplyMenuSessionSettingsToGlobals`, do not write it by hand *before* `LoadDataForGame` or it will be overwritten|
|`gbQServerRunning`|set to 1 by state 5 itself|do not pre-set|

The data-load order is already correct on this path and differs from the Windows d2gs bootstrap:
`fAPPMODE_client_ReturnAppMode` does `LoadDataForGame` → `TABLES_LoadStrings` → `TXT_LoadAllTxtTables`
**before** the state machine, so by the time `QSERVER_InitializeServerState` runs, MonStats is loaded
and `SUNITPROXY_InitAllNpcItemTables` populates the vendor tables properly. The
"re-run the NPC vendor tables afterwards" workaround in `server.zig` is not needed here.

## 4. The smallest intervention

**Two writes and one call — do not drive the menu.** Confidence: high for reaching
`gbQServerRunning = 1`; medium for the process then staying alive and serving joins, because
`pfModes_EnterGame` (state 2) is genuinely a client and pulls in cursor/sound/`GAME_InitClientSide`.

Ranked, cheapest first:

1. **Enter APPMODE_CLIENT directly.** Populate a `pSession` (`0x19 = 8`, `0x37 = "127.0.0.1"`, a game
   name, a character, `0x22d = 0`), then call `fAPPMODE_client_ReturnAppMode` (`0x0005dc61`) with it.
   That single function does the data load, the settings publish, and the whole `3 → 5 → 2 → …`
   sequence. Nothing above it — no launcher, no widgets, no character-select screen — is needed. This
   is the intervention the hypothesis was hoping for and it is real.
2. **Skip the client state 2 as well.** If `pfModes_EnterGame`'s client-side work is unwanted, call
   `LoadDataForGame(pSession)` and then `NET_QServer_StartServer` (`0x00073ac3`) directly with
   `geClientConnectionType == 8`, and start `QSERVER_CooperativeThreadMain` yourself (or just call the
   drain/tick/dispatch triple on your own thread). That is exactly what `bootstrapRealmServer` +
   `tick()` already do on Windows, only with a real shipped entry point rather than a reconstructed
   sequence. The one thing to keep from state 5 is that it dials `NET_D2GS_ConnectToServer` for the
   host as well — a host is always also player 1 on this path. If you do not want a local player, drop
   that call and `QSERVER_SetGlobalInstance` / `gbQServerRunning = 1` / `QSERVER_InitializeServerState`
   still stand alone, as `server.zig` proves on Windows.
3. **Drive the menu state machine.** ~5 steps (main screen → other multiplayer → TCP/IP → host → char
   select → difficulty). Needs the whole widget system, keyboard focus and synthetic clicks. There is
   no reason to pay this: the button handler is a 116-byte function that writes four fields.

Note that patching the empty app-mode slot 2 is *not* a cheaper alternative — there is no code behind
it to call. Option 1 is strictly less work than reviving a mode that was never compiled.

## 5. What hard-requires the UI

Split by thread, because that split is the whole point:

**The QSERVER itself requires nothing graphical.** `QSERVER_CreateAndInit` opens a socket on port
4000 and installs four packet callbacks. `QSERVER_InitializeServerState`, `QSERVER_TickAllGames`,
`NET_D2GS_SERVER_HandleAnyIncomingPacket` and `QSERVER_DispatchAndCleanup` touch no window, no
widget and no renderer. `QSERVER_CooperativeThreadMain` runs on its own OS thread
(`MAC_beginthreadex`) and never pumps events.

**The path above it does touch UI, in three places:**

|site|requirement|can it be patched around|
|-|-|-|
|`UIMENU_TCPIPOptions` `0x002c58e5` and the whole TCP/IP screen|widget creation, string table, `UI_WIDGET_SetKeyboardFocus`, `UI_WIDGET_InstallTimerHandler`|**Not needed at all** if you take intervention 1 or 2 — this is menu code, strictly above the button handler|
|`CLIENTMODE_RunFrameLoop` `0x0005e2ee`, called twice inside state 5|calls `MACSETUP_RunEventLoop()` + `StormMac::SEVENT_ProcessNextMessage` every iteration, i.e. the Carbon/Storm event pump must be initialised, and returns 1 if the pump says the app is quitting|The pump must exist. On a headless build with `D2GFX_CreateWindow` / `OPENGLMAC_SwapContext` already patched out, this is the remaining dependency to verify. It does **not** draw; the drawing is inside the step callback (`GameLoopFuncInitGame`).|
|`pfModes_EnterGame` `0x00070e8f` (state 2)|`UI_InitializeCursor`, `VIEW_InitLookupTables`, DC6 assignment, `SOUNDHDR`, `GAME_InitClientSide`, `MACSETUP_RunEventLoop`|Avoidable: it is a separate pfModes state. You can let state 5 create the server and then not enter state 2 (intervention 2). If you do want a local player-1 client, you keep it and pay the client cost.|

So: **no widget, window or keyboard focus is required to reach `gbQServerRunning = 1`.** The one thing
that must be alive is the Storm/Carbon event pump, because `CLIENTMODE_RunFrameLoop` sits inside state 5.
Note that this loop already takes a per-frame step callback (`CALL EBX`), so unlike the Windows build
there is nothing to patch to get a per-frame foothold — you pass one in.

## 6. Compared with what our Windows d2gs does

`apps/d2gs/engine/server.zig` `bootstrapRealmServer()` open-codes exactly the tail of
`NET_QServer_StartServer` (win: `0x0044bc30`):
`QSERVER_CreateAndInit(.server, .bnet)` → `NET_SetPlayersCount` → `NET_HACK_SetUseQServerHack(0)` →
`QSERVER_SetGlobalInstance` → `gbQServerRunning = 1` → `QSERVER_InitializeServerState`, plus
`SetupAsBnetServer` and a post-hoc `TXT_InitTxtFiles` / `SUNITPROXY_InitAllNpcItemTables` to repair the
data-load ordering. `apps/d2gs/runtime/gameloop.zig` then patches over the engine's own `Sleep` calls at
`ADDR_GAME_LOOP 0x00451C2A` and `ADDR_OOG_LOOP 0x004FA663` to get a per-frame hook, and
`installServerOogPacing` throttles the idle menu loop that a headless GS is otherwise stuck in.

**The Mac path is cheaper on four counts, and more expensive on one:**

|concern|Windows d2gs today|Mac TCP/IP host|
|-|-|-|
|entry into the server|reconstructed: our Zig replays the tail of `NET_QServer_StartServer` by hand|shipped: set one integer, the engine runs its own `NET_QServer_StartServer`|
|server tick|our own `tick()` on a hooked game loop|the engine's own `"OpenServerThread"`, on its own thread, already correct|
|per-frame foothold|byte-patch two `Sleep` call sites, then re-add a yield by hand because we clobbered the engine's pacing|`CLIENTMODE_RunFrameLoop` **takes a step callback as a parameter**, and already skips its own sleep for connection types 6/8. Nothing to patch.|
|idle CPU|`installServerOogPacing` exists purely because the headless GS sits in the OOG menu loop|no OOG loop involved; the client thread is in the game loop or exits|
|data-load order|had to re-run `TXT_InitTxtFiles` + `SUNITPROXY_InitAllNpcItemTables` after server init|`fAPPMODE_client_ReturnAppMode` loads tables before the state machine, so the order is already right|
|realm integration|`SetupAsBnetServer` gives us the D2CS/D2DBS callback table, and `.bnet` game type|the host path uses `QSERVER_CreateAndInit(0, 1)` — game type **1**, not `.bnet` (3). Games are created locally, not by realm token. If we want realm-driven games we still call `SetupAsBnetServer` + `GAME_CreateBattleNetGame` ourselves, on top.|
|host is also player 1|no local client at all|state 5 dials `NET_D2GS_ConnectToServer` at the host too. Either accept a local player, or skip that one call.|

Recommendation: on Mac, take intervention 2 — `LoadDataForGame(pSession)` with `pSession->0x19 = 8`,
then `NET_QServer_StartServer`, minus the local-client connect, plus `SetupAsBnetServer` and the
`.bnet` game type if realm mode is wanted. That is the same shape as `bootstrapRealmServer` but with
the engine doing the sequencing, and it lets us drop the game-loop `Sleep` patch entirely.

## Ghidra names applied (session `ce51a192`)

|address|was|now|
|-|-|-|
|`0x00071957`|`NET_QServer_StartServer` (duplicate, wrong)|`NET_ApplyMenuSessionSettingsToGlobals`|
|`0x0005dab3`|`D2GFX_ClearCaches`|`CLIENTMODE_PushMode`|
|`0x0005db09`|`CLIENTMODE_GetCurrentAppMode`|`CLIENTMODE_PopMode`|
|`0x0006feea`|`pfModes_PostGameClearCaches`|`pfModes_BeginSession`|
|`0x002ca581`|`UNICODE_WideToMultiByte`|`CHARSEL_LaunchGameWithCharacter`|
|`0x002c3bf2`|`MAINMENU_ConnectViaTCPIPAndSelectChar`|`MAINMENU_TcpIpHostGame`|
|`0x002c3ca8`|`UIMENU_TCPIPAddressInput`|`MAINMENU_TcpIpShowJoinAddressDialog`|
|`0x002c3e2e`|`UIMENU_ConnectToServerCallback`|`MAINMENU_TcpIpJoinGameConnect`|
|`0x002d1f60`|`FORMS_CreateAnyForm`|`OOGMENU_CreateGame`|
|`0x005cc000`|`gnExpansionGame`|`gnMenuGameType`|
|`0x005c15d4`|`DAT_005c15d4`|`geClientConnectionType`|
|`0x005cbfcc`|`DAT_005cbfcc`|`gpMenuSessionData`|
|`0x005cbffc`|`DAT_005cbffc`|`gnNextAppMode`|
|`0x005c1684`|`DAT_005c1684`|`gszClientGameName`|
|`0x00398420`|`s_207_82_87_243`|`gszD2GSServerAddress`|
|`0x003cfc30`|`UNK_003cfc30`|`pfModes`|

Plate comments recording the evidence were added at `0x005c15d4`, `0x005cc000`, `0x005cbfcc`,
`0x00073ac3`, `0x00070e8f`, `0x0006fd13`, `0x000714ea`, `0x003cfc30`, `0x003e0eb8`, `0x003cb9cc`
and `0x002c58e5`.

### Names in that database that turned out to be wrong

Consistent with the warning that roughly a third of the user-applied names sit on the wrong function:
`D2GFX_ClearCaches` (a queue push), `CLIENTMODE_GetCurrentAppMode` (a queue pop),
`UNICODE_WideToMultiByte` (the character-select game launcher), `FORMS_CreateAnyForm` (the open-bnet
create-game handler), and a second `NET_QServer_StartServer` at `0x00071957` colliding with the real
one at `0x00073ac3`. `PTR_s_207_82_87_243_00396130` reads like a hardcoded Blizzard address but points
at a writable global that the menu overwrites — treating it as a literal is what makes the case-4
branch look like "connect to battle.net" when it is really "connect to whatever the menu set".
