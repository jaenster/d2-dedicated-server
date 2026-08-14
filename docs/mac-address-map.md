# 1.14d Windows -> macOS address map

Every hard-coded `Game.exe` address in `apps/d2gs/engine/` and `apps/d2gs/runtime/`, with its
counterpart in the 1.14d macOS Mach-O (`DiabloII_macho`, image base `0x00001000`), for the
wine-free host in `apps/d2gs-native/`.

## Headline

|set|addresses|confirmed|unconfirmed guess|refuted|not found|Windows-only|globals|
|-|-|-|-|-|-|-|-|
|hook layer (engine/ + runtime/)|189|62|16|35|59|6|11|
|bot call table (engine/d2/)|131|12|16|30|37|2|34|
|total|320|74|32|65|96|8|45|

**62 of the 189 hook-layer addresses (33%) have a confirmed Mac counterpart.** Another 16 have a
single plausible candidate that no independent evidence supports -- counted as unresolved, not as
hits. 35 are actively refuted: a function of that name exists in the Mac Ghidra database but
provably is not the same function. 59 have no Mac counterpart named at all, and 11 are globals.

## How a match was confirmed

The Mac database is **not** authoritative. It has 594 imported symbols against 11,375 user-applied
names -- the names were propagated onto it, and spot checks show a meaningful error rate. A name
collision was never accepted as a match on its own. Two independent checks were used:

The TU technique below is now written up in full, with every range, in
[`mac-tu-map.md`](mac-tu-map.md). Use that document rather than re-deriving ranges by hand.

- **TU** -- the Mac build keeps full `__FILE__` assert strings (e.g.
  `.../DiabloAll/../D2Game/Src/Game.cpp`). 252 distinct source paths anchor 1,146 functions, which
  reconstructs the translation-unit layout of `__text`. Object-file sections are contiguous, so a
  candidate falling strictly between two functions anchored to file X *is* in file X -- and a
  candidate falling inside a different TU is refuted outright.
- **STR** -- shared string literals between the Windows function and the Mac candidate. Only ~20
  targets reference any string (1.14d Windows has no assert strings), but where it applies it is
  decisive, and it caught three cases where the Mac DB name sat on the wrong function.

Size and callee-count ratios were used only to reject, never to confirm.

The `purpose` column is the d2gs symbol or comment at the use site; `(IN+n)` marks an address that
is a byte offset inside the function, not its entry.

## Map

### engine/server

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|gptr()|`0x0044bc30`|`D2Client::ClientModeInGame::NET_QServer_StartServer`|`0x00073ac3`|string fingerprint 2/1|
|NET_SetPlayersCount()|`0x0052b250`|`D2Game::Game::Server::NET_SetPlayersCount`|`0x002de00a`?|UNCONFIRMED -- name-only, immediately before the D2Net Server.cpp anchor|
|NET_HACK_SetUseQServerHack()|`0x0052b280`|`D2Game::Game::Server::NET_HACK_SetUseQServerHack`|`0x002de030`?|UNCONFIRMED -- leaf-only, immediately before the D2Net Server.cpp anchor|
|QSERVER_CreateAndInit()|`0x0052b7a0`|`D2Game::Game::Server::QSERVER_CreateAndInit`|`0x002ddfa7`?|UNCONFIRMED -- leaf-only, immediately before the D2Net Server.cpp anchor|
|QSERVER_SetGlobalInstance()|`0x0052c0a0`|`D2Game::Game::Server::QSERVER_SetGlobalInstance`|`0x001abe46`?|UNCONFIRMED -- name-only, at the Event.cpp/Game.cpp boundary|
|SetupAsBnetServer()|`0x0052c0e0`|`D2Game::Game::Server::SetupAsBnetServer`|--|not found -- no function of this name in the Mac DB|
|QSERVER_PutNewGameOnTokenList()|`0x0052c110`|`D2Game::Game::Server::QSERVER_PutNewGameOnTokenList`|--|not found -- no function of this name in the Mac DB|
|QSERVER_GenerateToken()|`0x0052c170`|`D2Game::Game::Server::QSERVER_GenerateToken`|--|REFUTED -- DB says `0x001e012d`, inside the MonsterRegion.cpp/Objects.cpp neighbourhood|
|NET_D2GS_SERVER_HandleAnyIncomingPacket()|`0x0052cfe0`|`D2Game::Game::Server::NET_D2GS_SERVER_HandleAnyIncomingPacket`|`0x001ade1c`|TU=Game.cpp (D2Game), size 144/157|
|QSERVER_TickAllGames()|`0x0052fc20`|`D2Game::Game::Server::QSERVER_TickAllGames`|`0x001ae778`|TU=Game.cpp (D2Game), size 355/177|
|QSERVER_DispatchAndCleanup()|`0x0052fd90`|`D2Game::Game::Server::QSERVER_DispatchAndCleanup`|`0x001ae82b`|TU=Game.cpp (D2Game), size 331/269|
|f|`0x005302d0`|`D2Game::Game::Server::QSERVER_DisconnectClientByName`|--|not found -- no function of this name in the Mac DB|
|QSERVER_InitializeServerState()|`0x00530690`|`D2Game::Game::Server::QSERVER_InitializeServerState`|`0x001abbf2`|string fingerprint 1/0, D2Game Game.cpp neighbourhood|
|f|`0x00530930`|`D2Game::Game::Server::GAME_CreateBattleNetGame`|--|not found -- no function of this name in the Mac DB|
|SUNITPROXY_InitAllNpcItemTables()|`0x00536f80`|`D2Common::Unit::SUnitProxy::SUNITPROXY_InitAllNpcItemTables`|--|not found -- no function of this name in the Mac DB|
|TXT_InitTxtFiles()|`0x00619300`|`D2Common::DataTbls::DataTbls::TXT_InitTxtFiles`|--|not found -- no function of this name in the Mac DB|

### engine/realm

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|getDatabaseCharShim|`0x0052ca10`|`D2Game::Game::Server::SaveAllPlayers`|--|not found -- no function of this name in the Mac DB|
|NET_D2GS_SERVER_ProcessClientMessage_System @0x0052cc20 and|`0x0052cc20`|`D2Game::Game::Server::NET_D2GS_SERVER_ProcessClientMessage_System`|`0x001adb00`|TU=Game.cpp (D2Game), size 681/780|
|NET_D2GS_SERVER_SrvJoinGame @0x0052fa50 ), so an all-null ta|`0x0052fa50`|`D2Game::Game::Server::NET_D2GS_SERVER_SrvJoinGame`|--|REFUTED -- TU=Game.cpp is right but the target is a 38-byte stub vs 448 bytes on Windows|
|log|`0x005306e0`|`D2Game::Game::Server::CLIENT_OnDatabaseCharacterReceived`|--|not found -- no function of this name in the Mac DB|
|getDatabaseCharShim|`0x00531eb0`|`D2Game::Player::PlayerSave::SaveToFileBnet`|--|not found -- no function of this name in the Mac DB|
|getDatabaseCharShim|`0x00532400`|`D2Game::Player::PlayerSave::SaveGameAllGameTypes`|--|REFUTED -- DB says `0x001f6a8c`, inside the PartyScreen.cpp TU run, not PlrSave.cpp|
|leaveGameStub()|`0x00569d80`|`D2Game::Player::PlayerSave2::CalculateGetFlags`|--|not found -- no function of this name in the Mac DB|
|addr|`0x00569dc3`|`D2Game::Player::PlayerSave2::CalculateGetFlags` (IN+43)|--|not found -- no function of this name in the Mac DB|
|init()|`0x00569e17`|`D2Game::Player::PlayerSave2::CalculateGetFlags` (IN+97)|--|not found -- no function of this name in the Mac DB|

### engine/fog

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|ADDR_POOL_FREE|`0x00409ab0`|`Fog::Memory::Free`|--|REFUTED -- only a bare leaf `Free` (5 candidates, none in a Fog TU)|
|ADDR_FREE_MEMORY_POOL|`0x00409c80`|`Fog::Memory::FreeMemoryPool`|--|not found -- no function of this name in the Mac DB|
|ADDR_INIT_POOL_SYSTEM|`0x00409dd0`|`Fog::Memory::InitializePoolSystem`|--|REFUTED -- DB says `0x002f40fb`, which lies inside the QServer.cpp TU run (002f3494-002f5370)|
|ADDR_POOL_ALLOC|`0x0040a080`|`Fog::Memory::Alloc`|--|REFUTED -- only a bare leaf `Alloc` (6 candidates), lands in the automap.cpp neighbourhood|
|ADDR_POOL_REALLOC|`0x0040a1f0`|`Fog::Memory::ReAlloc`|--|not found -- no function of this name in the Mac DB|

### runtime/gameloop

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|ADDR_GAME_LOOP|`0x00451c2a`|`D2Client::_Message::MessageGameLoop` (IN+7a)|--|REFUTED -- DB says `0x002f33fa`, a 5-byte stub; cannot be MessageGameLoop|
|ADDR_OOG_LOOP|`0x004fa663`|`D2Win::D2WinMain::MessagePump` (IN+d3)|--|Windows-only -- DB says `0x002c4b8d`; D2WinMain.cpp TU run is 0004a41f-0004b1f2|

### runtime/gamereap

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|has been idle for 300000 ms (5 minutes): `CMP EDX, 0x493e0;|`0x0052fe57`|`D2Game::Game::Server::QSERVER_DispatchAndCleanup` (IN+c7)|`0x001ae82b`|TU=Game.cpp (D2Game), size 331/269|
|so the imm32 (e0 93 04 00) lives at 0x0052fe59. On a dedicat|`0x0052fe59`|`D2Game::Game::Server::QSERVER_DispatchAndCleanup` (IN+c9)|`0x001ae82b`|TU=Game.cpp (D2Game), size 331/269|

### runtime/gsport

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|game port 4000 is pushed as `push 0xfa0` @0x0052b7be, so its|`0x0052b7be`|`D2Game::Game::Server::QSERVER_CreateAndInit` (IN+1e)|`0x002ddfa7`?|UNCONFIRMED -- leaf-only, immediately before the D2Net Server.cpp anchor|
|game port 4000 is pushed as `push 0xfa0` @0x0052b7be, so its|`0x0052b7bf`|`D2Game::Game::Server::QSERVER_CreateAndInit` (IN+1f)|`0x002ddfa7`?|UNCONFIRMED -- leaf-only, immediately before the D2Net Server.cpp anchor|

### runtime/roominit

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|Hooks SUNITINACTIVE_RoomInit @0x542b40 (__fastcall(D2GameStr|`0x00542b40`|`D2Common::Unit::SUnitInactive::SUNITINACTIVE_RoomInit`|--|not found -- no function of this name in the Mac DB|
|ROOMINIT_REJOIN|`0x00542b46`|`D2Common::Unit::SUnitInactive::SUNITINACTIVE_RoomInit` (IN+6)|--|not found -- no function of this name in the Mac DB|

### runtime/rejoin

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|f|`0x0052b610`|`D2Game::Game::Server::QSERVER_GetClientGameToken`|--|not found -- no function of this name in the Mac DB|
|SEAT_CHECK_CALLSITE|`0x0052c70c`|`D2Game::Game::Server::NET_D2GS_SERVER_IsValidChecks` (IN+7c)|`0x001acd78`|TU=Game.cpp (D2Game), size 285/443|
|shim()|`0x0052caf0`|`D2Game::Game::Server::SERVER_DisconnectClient`|--|REFUTED -- DB says `0x00211eb0`, a 26-byte stub inside the PlrTrade.cpp TU run|
|shim()|`0x0052da90`|`D2Game::Game::Server::Unlock`|--|not found -- no function of this name in the Mac DB|
|shim()|`0x0052e860`|`D2Game::Game::Server::QSERVER_FindAndLockGame`|--|REFUTED -- DB says `0x0013b255`, inside the AnimTbls.cpp/DataTbls.cpp neighbourhood|
|shim()|`0x00537810`|`D2Game::Game::Clients::SERVER_GetClientFromGmeByClientId`|--|REFUTED -- DB says `0x001ad074`, inside Game.cpp; Clients.cpp run is 001a88f5-001aac62|
|IS_PLAYER_CHARACTER_IN_GAME|`0x00538c60`|`D2Game::Game::Clients::SERVER_IsPlayerCharacterInGame`|--|not found -- no function of this name in the Mac DB|
|BUCKET_BY_NAME|`0x00883ea8`|`QServerClientBucketByName`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|BY_NAME_CS|`0x008846c0`|`gQServerClientByNameCs`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

### runtime/joindiag

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|SERVER_IS_TOKEN_VALID|`0x0052c060`|`D2Game::Game::Server::SERVER_IsTokenValid`|`0x001abcff`|CONFIRMED -- same shape (lock, `DATA_LastGameServer[nToken]`, reject 0 and -1). Carried a duplicate, wrong `ProcessClientMessage_GameSetup` name; renamed|
|CHECK_FORBIDDEN_CHARS|`0x0052c5b0`|`D2Game::Game::Server::STRING_CheckIfPlayerNameDoNotContainForbidenChars`|--|not found -- no function of this name in the Mac DB|
|b4Intercept()|`0x0052c690`|`D2Game::Game::Server::NET_D2GS_SERVER_IsValidChecks`|`0x001acd78`|TU=Game.cpp (D2Game), size 285/443|
|NAME_LEN_CALLSITE|`0x0052c6d5`|`D2Game::Game::Server::NET_D2GS_SERVER_IsValidChecks` (IN+45)|`0x001acd78`|TU=Game.cpp (D2Game), size 285/443|
|NAME_BY_ID_CALLSITE|`0x0052c6fe`|`D2Game::Game::Server::NET_D2GS_SERVER_IsValidChecks` (IN+6e)|`0x001acd78`|TU=Game.cpp (D2Game), size 285/443|
|TOKEN_VALID_CALLSITE|`0x0052c717`|`D2Game::Game::Server::NET_D2GS_SERVER_IsValidChecks` (IN+87)|`0x001acd78`|TU=Game.cpp (D2Game), size 285/443|
|NAME_CHARS_CALLSITE|`0x0052c72d`|`D2Game::Game::Server::NET_D2GS_SERVER_IsValidChecks` (IN+9d)|`0x001acd78`|TU=Game.cpp (D2Game), size 285/443|
|SRVJOINACT|`0x00530190`|`D2Game::Game::Server::NET_D2GS_SERVER_SrvJoinAct`|--|REFUTED -- TU=Game.cpp is right but the target is a 68-byte stub vs 211 bytes on Windows|
|B4_CALLSITE|`0x005301f1`|`D2Game::Game::Server::NET_D2GS_SERVER_SrvJoinAct` (IN+61)|--|REFUTED -- TU=Game.cpp is right but the target is a 68-byte stub vs 211 bytes on Windows|
|GET_PLAYER_NAME_BY_CLIENT_ID|`0x00538b70`|`D2Game::Game::Clients::NET_D2GS_SERVER_GetPlayerNameByClientId`|`0x001a9de9`|TU=Clients.cpp|
|SEND_0XB4|`0x0053b260`|`D2Game::Game::Server::ServerCmd::NET_D2GS_SERVER_Send_0xB4_ConnectionRefused`|`0x002de167`?|UNCONFIRMED -- name-only, immediately before the D2Net Server.cpp anchor|
|STRING_LENGTH_CHECK|`0x0053efc0`|`D2Game::Game::SCmd::STRING_CheckIfStringLengthDoNotExceedSize`|`0x001b03b8`?|UNCONFIRMED -- name-only, at the Level.cpp/SCmd.cpp boundary|
|JOINACT_CALLSITE|`0x0053f2dc`|`D2Game::Game::CCmd::NET_D2GS_SERVER_ProcessClientMessage_GameSetup` (IN+1dc)|--|REFUTED -- DB says `0x00213930`, inside the PlrTrade.cpp/a1q1.cpp neighbourhood|

### the GAMELOGON refusal (`b4 06 00 00 00`)

Reason 6 is not a character-load failure. Windows `NET_D2GS_SERVER_ProcessClientMessage_GameSetup`
`0x0053f100` case 1 calls `IsTokenFirstGame` `0x0053eff0` **only when `BattleNetServerService` is
null**, and every 6 that function returns means "this server has no game on that token":

- `CMP dword[EBP+8],1` at `0x0053eff9` -> the packet's u16 game token must be 1
- `SERVER_IsTokenValid(1)` -> `DATA_LastGameServer[1]` must be a live game
- `QSERVER_FindAndLockGame` must return it; then the char name must be non-empty, under 16, and not
  already seated in that game

The Mac build inlines the whole thing into the `0x68` case of `NET_D2GS_SERVER_ProcessClientMessage_GameSetup`
`0x001a77bd`, byte for byte:

|mac addr|instruction|meaning|
|-|-|-|
|`0x001a78b6`|`MOV EAX,[ECX+0x1eea52]` / `CMP dword[EAX],0`|`BattleNetServerService` `0x005c8a50`; non-null skips the whole block|
|`0x001a7a1a`|`MOV dword[EBP-0x60],6`|nReason = 6|
|`0x001a7a21`|`CMP word[ESI+9],1`|the packet's game token must be 1|
|`0x001a7a36`|`CALL 0x001abcff` with `[ESP]=1`|`SERVER_IsTokenValid(1)`|
|`0x001a7a46`|`CALL 0x001abd47`|`QSERVER_FindAndLockGame`|
|`0x001a7a53`/`0x001a7a5f`|`MOV ...,0x10` / `0x0f`|verbyte != 0xe / game already has 8 clients|

`BattleNetServerService` `0x005c8a50` has 37 xrefs and all 37 are reads -- `SetupAsBnetServer`
(win `0x0052c0e0`) was never linked into the Mac image, so the value is permanently null and the
GS always runs open. That is not the blocker: open mode is a supported path, it just restricts the
server to one game, on token 1, created by a client's `0x67`.

Measured on the native host (`b4 06` before, `0x01` GameFlags after):

|step|reply (raw / huffman-decoded)|
|-|-|
|`0x68` token 1 or 0x2a, no game|`04 05 48 78` -> `b4 06 00 00 00`|
|`0x67` create-game on connection A|`06 7a 09 a5 f5 c0` -> `01 00 04 00 10 00 01 00 00 02` (GameFlags)|
|`0x68` token 1 on connection B, game alive|same GameFlags -- accepted|
|`0x6b` sent without waiting for `0x02`|`04 05 44 6e` -> `b4 0e 00 00 00` (no player unit)|

### runtime/pkttrace

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|GAMESETUP_CALL|`0x0052d011`|`D2Game::Game::Server::NET_D2GS_SERVER_HandleAnyIncomingPacket` (IN+31)|`0x001ade1c`|TU=Game.cpp (D2Game), size 144/157|
|INGAME_CALL|`0x0052d03e`|`D2Game::Game::Server::NET_D2GS_SERVER_HandleAnyIncomingPacket` (IN+5e)|`0x001ade1c`|TU=Game.cpp (D2Game), size 144/157|
|SYSTEM_CALL|`0x0052d06e`|`D2Game::Game::Server::NET_D2GS_SERVER_HandleAnyIncomingPacket` (IN+8e)|`0x001ade1c`|TU=Game.cpp (D2Game), size 144/157|
|systemShim()|`0x0053b280`|`D2Game::Game::SCmd::NET_D2GS_SERVER_SendPacket_Helper`|--|REFUTED -- DB says `0x0023cfdb`, inside the a5q2.cpp/a5q3.cpp neighbourhood|
|GAMESETUP_FN|`0x0053f100`|`D2Game::Game::CCmd::NET_D2GS_SERVER_ProcessClientMessage_GameSetup`|--|REFUTED -- DB says `0x00213930`, inside the PlrTrade.cpp/a1q1.cpp neighbourhood|
|INGAME_FN|`0x0053f3d0`|`D2Game::Game::CCmd::NET_D2GS_SERVER_ProcessClientMessage_InGame`|`0x001a7c54`|TU=CCmd.cpp|

### runtime/realmgw

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|SMemAlloc|`0x00413020`|`Fog::SMem::SMemAlloc`|--|REFUTED -- DB says `0x002ef904`; Storm SMem lives in the StormMac region (< 0x0003ffff)|
|D2Client::BNGatewayAccess::Load @0x5186d0 calls GetGatewayLi|`0x00518190`|`D2Client::BNGatewayAccess::GetGatewayList`|`0x000550d4`|TU=BNetGW.cpp|
|(FindSection @0x5183f0 -> NULL -> BNetGW.cpp:0x277 -> 0xc000|`0x005183f0`|`D2Client::BNGatewayAccess::FindSection`|`0x00055674`?|UNCONFIRMED -- name-only, at the BNetGW.cpp/BnMessQueue.cpp boundary|
|contention -> Load falls to UpdateGatewaysFromIni @0x518850,|`0x00518850`|`D2Client::BNGatewayAccess::UpdateGatewaysFromIni`|`0x0005521e`|TU=BNetGW.cpp + string fingerprint 4/0|

### runtime/poolgrow

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|prod|`0x005309ec`|`D2Game::Game::Server::GAME_CreateBattleNetGame` (IN+bc)|--|not found -- no function of this name in the Mac DB|

### runtime/poolstat

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|Addresses verified against 1.14d Game.exe: pManagers[0] @0x7|`0x0074f104`|`pGlobalPoolSystem.pManagers[0].nPoolId`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|Addresses verified against 1.14d Game.exe: pManagers[0] @0x7|`0x0075af64`|`pGlobalPoolSystem.nManagers`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

### runtime/memstat

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|me|`0x00457300`|`D2Client::UI::Draw::CLIENT_AdjustMemoryBudget`|--|REFUTED -- string fingerprint points at 0005d184, the DB name sits on 0009fd27|
|me|`0x005ffd40`|`D2CMP::SpriteCache::GFX_InitCelDataCache`|--|not found -- no function of this name in the Mac DB|
|me|`0x0088cadc`|`D2PoolManagerStrc_0088cadc`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

### runtime/cdkeydump

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|KeyClassic|`0x00482744`|`D2Sound::Sound::SoundHdr::SOUNDHDR_BuildSoundPath` (IN+34)|`0x00095b59`?|UNCONFIRMED -- name-only, immediately after the SoundHdr.cpp anchor run|
|--dump-cdkeys). The game's DecodeAndLoadKeys (@0x5234d0) dec|`0x005234d0`|`D2Client::_net_sid::DecodeAndLoadKeys`|`0x0005b1e3`|string fingerprint 1/0, BnSend.cpp neighbourhood|
|key files into the globals D2Client::_CdKey::KeyClassic (@0x|`0x00882744`|`D2Client::_CdKey::KeyClassic`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|KeyExpansion (@0x88274c) — pointers to plaintext key strings|`0x0088274c`|`D2Client::_CdKey::KeyExpansion`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

### runtime/drawing

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|GAME_POST_DRAW_CALLSITE|`0x0044cb14`|`D2Client::Game::InGameDraw` (IN+184)|`0x0006ecc8`|TU=Game.cpp (D2Client), size 442/588|
|0x456fa5 (`call 0x45ad60`, verified in recon 9df5e900); we r|`0x00456fa5`|`D2Client::UI::Draw::DRAW_UI` (IN+c5)|--|not found -- no function of this name in the Mac DB|

### runtime/framepace

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|Retail's own loop slept 30 ms with games live (QSERVER_Coope|`0x0044cf20`|`D2Game::Game::Server::QSERVER_CooperativeThreadMain`|`0x0006fd13`|string fingerprint 1/0, Mac namespace D2Game::GameData|

### runtime/patch

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|dest|`0x0047c4e4`|`D2Client::UI::Chat::ChatCommandProcessor` (IN+c4)|`0x0009f13d`|string fingerprint 10/0|
|dest|`0x0047c50e`|`D2Client::UI::Chat::ChatCommandProcessor` (IN+ee)|`0x0009f13d`|string fingerprint 10/0|

### feature/srvtrace

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|hooks|`0x00451000`|`D2Client::Game::CreateGame`|--|not found -- no function of this name in the Mac DB|
|onItemUse()|`0x0052c280`|`D2Game::Game::Server::RollSeed`|--|REFUTED -- leaf-only `RollSeed`, DB pick is inside the D2Common Drlg.cpp TU run|
|onItemUse()|`0x0052c320`|`D2Game::Game::Server::GAME_SetForcedGameSeed`|--|not found -- no function of this name in the Mac DB|
|hooks|`0x0052c7f0`|`D2Game::Game::Server::GAME_DestroyGame`|`0x001acf33`|TU=Game.cpp (D2Game), size 235/283|
|hooks|`0x0053ff00`|`D2Game::Game::Party::ChangeGoldForPlayer`|--|not found -- no function of this name in the Mac DB|
|hooks|`0x00544720`|`D2Game::Quests::Quests::QUEST_SetQuestRecordState`|`0x0021d2a9`?|UNCONFIRMED -- name-only, a1q4.cpp/a1q5.cpp neighbourhood, size 54/789|
|hooks|`0x00549d80`|`D2Game::Player::PlayerMsg::SCMD_0x06_LeftSkillOnEntity`|`0x00200570`|TU=PlrMsg.cpp|
|hooks|`0x00549fc0`|`D2Game::Player::PlayerMsg::SCMD_0x0C_RightSkillOnLocation`|`0x00200841`|TU=PlrMsg.cpp|
|hooks|`0x0054a040`|`D2Game::Player::PlayerMsg::SCMD_0x0D_RightSkillOnEntity`|`0x002008f0`|TU=PlrMsg.cpp|
|hooks|`0x0054a290`|`D2Game::Player::PlayerMsg::SCMD_0x14_OverheadMessage`|--|REFUTED -- DB says `0x00269680`, inside the D2Game Skills.cpp TU run|
|hooks|`0x0054aa90`|`D2Game::Player::PlayerMsg::SCMD_0x13_InteractWithEntity`|`0x00200be8`|TU=PlrMsg.cpp|
|hooks|`0x0054ab40`|`D2Game::Player::PlayerMsg::SCMD_0x17_DropItem`|`0x002012a9`|TU=PlrMsg.cpp|
|hooks|`0x0054abb0`|`D2Game::Player::PlayerMsg::SCMD_0x18_ItemToInventory`|`0x001fffd8`|TU=PlrMsg.cpp|
|hooks|`0x0054acd0`|`D2Game::Player::PlayerMsg::SCMD_0x19_PickUpToCursor`|`0x00201326`|TU=PlrMsg.cpp|
|hooks|`0x0054ad90`|`D2Game::Player::PlayerMsg::SCMD_0x1A_EquipItem`|`0x00201434`|TU=PlrMsg.cpp|
|hooks|`0x0054b1e0`|`D2Game::Player::PlayerMsg::SCMD_0x20_UseItemAtLocation`|`0x00201979`|TU=PlrMsg.cpp|
|hooks|`0x0054b560`|`D2Game::Player::PlayerMsg::SCMD_0x26_UseItemAtPlayerCoords`|`0x00201d42`|TU=PlrMsg.cpp|
|hooks|`0x0054b930`|`D2Game::Player::PlayerMsg::SCMD_0x2F_NpcInteract`|`0x002021c9`|TU=PlrMsg.cpp|
|hooks|`0x0054bca0`|`D2Game::Player::PlayerMsg::SCMD_0x38_NpcMenuSelect`|`0x00202540`|TU=PlrMsg.cpp|
|hooks|`0x0054c300`|`D2Game::Player::PlayerMsg::SCMD_0x5E_CubeApply`|`0x00203ea8`|TU=PlrMsg.cpp|
|hooks|`0x0054c5d0`|`D2Game::Player::PlayerMsg::SCMD_0x49_TakeWaypoint`|`0x002035bc`|TU=PlrMsg.cpp|
|hooks|`0x005550b0`|`D2Common::Unit::SUnit::TakeStairs`|--|not found -- no function of this name in the Mac DB|
|hooks|`0x00563c00`|`D2Common::Items::ItemMode::SERVER_DropItemFromPlayer`|`0x001b8e66`|TU=ItemMode.cpp|
|hooks|`0x00576330`|`D2Common::Unit::SUnitNpc::SUNITNPC_GenerateNpcItems`|--|not found -- no function of this name in the Mac DB|
|hooks|`0x0057c6c0`|`D2Common::Unit::SUnitDmg::DAMAGE_ApplyDamageToUnit`|--|not found -- no function of this name in the Mac DB|
|hooks|`0x005a5be0`|`D2Game::Player::PlayerScreen::PARTYSCREEN_SendPartyInvite`|--|not found -- no function of this name in the Mac DB|
|hooks|`0x005a5e50`|`D2Game::Player::PlayerScreen::PARTYSCREEN_ToggleHostile`|`0x001f6736`|TU=PartyScreen.cpp, size 416/429|
|hooks|`0x005be290`|`D2Common::Skills::SkillItem::SKILLITEM_TownPortalScrollSpell`|`0x0025af65`|TU=SkillItem.cpp|
|DRLG_NEAR_CAP|`0x0061afd0`|`D2Common::Dungeon::Dungeon::FreeAct`|`0x00164cd2`|TU=Dungeon.cpp|
|onItemUse()|`0x00642390`|`D2Common::Drlg::Drlg::DRLG_ApplyRoomExStateFlags`|--|not found -- no function of this name in the Mac DB|
|DRLG_NEAR_CAP|`0x00642bb0`|`D2Common::Drlg::Drlg::GetLevelAndAlloc`|--|REFUTED -- DB says `0x001507e0`, in DrlgRoom.cpp/DrlgVer.cpp, not Drlg.cpp|
|PRDATA_FLOORGRID0|`0x006667d0`|`D2Common::Drlg::Preset::DRLGPRESET_InitGridsFromDS1File`|--|not found -- no function of this name in the Mac DB|
|tbl|`0x0066bc20`|`D2Common::Drlg::DrlgRoom::DefineRoomsNear`|--|not found -- no function of this name in the Mac DB|
|pPool|`0x0066d820`|`D2Common::Drlg::DRLGROOMTILE_GetTileLibraryEntry`|--|REFUTED -- DB says `0x001614e4`, before the RoomTile.cpp anchor run (Preset.cpp territory)|
|pPool|`0x0066dde0`|`D2Common::Drlg::DRLGROOMTILE_FillTileData`|--|not found -- no function of this name in the Mac DB|
|head|`0x0067c570`|`D2Common::Drlg::DrlgGrid::GetGridFlags`|--|REFUTED -- DB says `0x00161b09`; DrlgGrid.cpp run is 0014e4bb-0014e683|
|FreeActFn|`0x006e7d1c`|`DAT_006e7d1c`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|GAME_SEED_GLOBAL|`0x00731004`|`GameSeed`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|FreeActFn|`0x00744304`|`sgptDataTable`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

### feature/headless

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|applyHeadlessRendering()|`0x00438560`|`D2Client::CharSel::DRAW_LocalCharsInSelectionScreen0`|`0x002bed2f`|TU=CharSel.cpp + 2 shared string literals|
|applyHeadlessRendering()|`0x00438d8b`|`D2Client::CharSel::SAVEFILE_ParseSaveData` (IN+2bb)|--|not found -- no function of this name in the Mac DB|
|parseSaveSkipAnimHandler()|`0x00438dac`|`D2Client::CharSel::SAVEFILE_ParseSaveData` (IN+2dc)|--|not found -- no function of this name in the Mac DB|
|parseSaveSkipAnimHandler()|`0x00438dd6`|`D2Client::CharSel::SAVEFILE_ParseSaveData` (IN+306)|--|not found -- no function of this name in the Mac DB|
|applyHeadlessRendering()|`0x00439210`|`D2Client::CharSel::CHARSEL_UpdateSelectedCharDisplay`|`0x002bdd54`|TU=CharSel.cpp + 2 shared string literals|
|applySafety()|`0x0043bf60`|`Game::Launcher::CLIENT_ConnectToBattleNet`|`0x002ba6f5`|string fingerprint 3/1; note the DB name sits on 002c5766 and is wrong|
|applyHeadlessRendering()|`0x0044c990`|`D2Client::Game::InGameDraw`|`0x0006ecc8`|TU=Game.cpp (D2Client), size 442/588|
|applyHeadlessRendering()|`0x0044f017`|`D2Client::Game::CLIENT_GameLoopFrame` (IN+77)|`0x0006f4bf`?|UNCONFIRMED -- name-only, D2Client Game.cpp neighbourhood, size 945/1899|
|applyHeadlessRendering()|`0x0044f28b`|`D2Client::Game::CLIENT_GameLoopFrame` (IN+2eb)|`0x0006f4bf`?|UNCONFIRMED -- name-only, D2Client Game.cpp neighbourhood, size 945/1899|
|applyHeadlessRendering()|`0x004565e0`|`D2Client::UI::Draw::Draw_UI_LoadGame`|--|REFUTED -- DB says `0x0013483f`, inside the D2CMP SpriteCache.cpp neighbourhood|
|applyHeadlessRendering()|`0x004f585a`|`D2Client::D2GFX::D2GFX_CreateWindow` (IN+24a)|--|Windows-only -- name-only, size 727/689; Mac creates a Carbon/AGL window, not a HWND|
|applyHeadlessRendering()|`0x004f98e0`|`D2Win::D2WinMain::RENDERER_DrawOutOfGameScene`|--|not found -- no function of this name in the Mac DB|
|applyHeadlessRendering()|`0x004fb1e0`|`D2Win::D2WinPalette::D2WINPAL_LoadPaletteFiles`|--|REFUTED -- DB says `0x0004d2a0`, which is the first D2WinTextBox.cpp anchor|
|applyHeadlessRendering()|`0x005041bc`|`D2Win::D2Comp::D2COMP_DestroyCompositeUnit` (IN+c)|`0x00040658`|TU=D2Comp.cpp|
|applyHeadlessRendering()|`0x00505550`|`D2Win::D2Comp::D2COMP_LoadAllItemPalettes`|`0x00041fb2`|TU=D2Comp.cpp + 8 shared string literals|
|applyHeadlessRendering()|`0x005066c0`|`D2Win::D2Comp::AllocCharSelectComponent`|--|REFUTED -- DB says `0x002d5e02`, inside the ComCallback.cpp TU run|
|applyHeadlessRendering()|`0x005136f0`|`D2Client::BINK_RenderVideoFrame`|--|Windows-only -- Bink video; the Mac build uses Smacker via oglSmack.cpp|
|applyHeadlessRendering()|`0x005137e0`|`D2Client::BINK_PlayVideoFile`|--|Windows-only -- Bink video; the Mac build uses Smacker via oglSmack.cpp|
|D2Client::BNGatewayAccess::Load @0x5186d0 calls GetGatewayLi|`0x005186d0`|`D2Client::BNGatewayAccess::Load`|`0x000548a0`|string fingerprint 4/3, in the BNetGW.cpp neighbourhood|
|applyHeadlessRendering()|`0x00600b80`|`D2CMP::Pallete::PALETTE_InitItemPalettes`|--|REFUTED -- DB says `0x0013204b`; the string set is shared with D2COMP_LoadAllItemPalettes|
|applySafety()|`0x00601349`|`D2CMP::CelCmp::CELCMP_FixupPointersAndPrepare` (IN+9)|`0x0012b810`|TU=CelCmp.cpp|
|applySafety()|`0x006019f0`|`D2CMP::CelCmp::IMAGE_GetFramesCount`|--|REFUTED -- DB says `0x002b55f2`, a 26-byte stub in the renderer region|
|imageGetFramesCountGuard()|`0x006019f6`|`D2CMP::CelCmp::IMAGE_GetFramesCount` (IN+6)|--|REFUTED -- DB says `0x002b55f2`, a 26-byte stub in the renderer region|
|applyHeadlessRendering()|`0x00609aa0`|`D2CMP::TileCmp::TILECMP_Generate25SubTiles`|--|not found -- no function of this name in the Mac DB|

### feature/clientdiag

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|hConnecting|`0x0044bad0`|`D2Client::ClientModeInGame::CLIENTMODE_Unused3`|--|not found -- no function of this name in the Mac DB|
|CLIENT_ConnectionRefused@0x44e380 — connection refused/timeo|`0x0044e380`|`D2Client::Game::CLIENT_ConnectionRefused`|--|not found -- no function of this name in the Mac DB|
|PacketHandle_from0xAF   @0x45c850 — connection packet dispat|`0x0045c850`|`D2Game::Game::SCmd::NET_D2GS_CLIENT_PacketHandle_from0xAF`|--|not found -- no function of this name in the Mac DB|
|Incoming0x01_GameFlags  @0x45c8b0 — client dispatched game f|`0x0045c8b0`|`D2Game::Game::SCmd::NET_D2GS_CLIENT_Incoming0x01_GameFlags`|`0x00077776`|TU=SCmd.cpp (D2Client)|
|Send_0x6B               @0x477da0 — client SENT JOINGAME (0x|`0x00477da0`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send_0x6B`|`0x00072f67`?|UNCONFIRMED -- name-only, immediately before the D2Client Msg.cpp anchor|

### feature/nocompress

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|(ThreadClientToServer @0x52ab30, gated on the phase flag tha|`0x0052ab30`|`D2Net::Client::ThreadClientToServer` (IN+30)|`0x002dcd68`|string fingerprint 4/0|
|NET_D2GS_SERVER_SendPacketToClient @0x52b330 already has a v|`0x0052b330`|`D2Game::Game::Server::NET_D2GS_SERVER_SendPacketToClient`|--|REFUTED -- DB says `0x001b4b24`, inside the D2Game Targets.cpp TU run|
|if (nMode != 2) {                                  <- 0x52b3|`0x0052b3b5`|`D2Game::Game::Server::NET_D2GS_SERVER_SendPacketToClient` (IN+85)|--|REFUTED -- DB says `0x001b4b24`, inside the D2Game Targets.cpp TU run|
|MODE_GATE_JZ|`0x0052b3b9`|`D2Game::Game::Server::NET_D2GS_SERVER_SendPacketToClient` (IN+89)|--|REFUTED -- DB says `0x001b4b24`, inside the D2Game Targets.cpp TU run|
|log|`0x0052b45f`|`D2Game::Game::Server::NET_D2GS_SERVER_SendPacketToClient` (IN+12f)|--|REFUTED -- DB says `0x001b4b24`, inside the D2Game Targets.cpp TU run|

### feature/ubers

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|DURABILITY_NOP_FROM|`0x00559009`|`D2Common::Items::Items::Drop::ITEM_CreateItemInstance` (IN+279)|`0x001c4169`|TU=Items.cpp, size 918/1584|
|DURABILITY_NOP_TO|`0x00559025`|`D2Common::Items::Items::Drop::ITEM_CreateItemInstance` (IN+295)|`0x001c4169`|TU=Items.cpp, size 918/1584|
|CUBE_KEYS_HOOK|`0x00565a90`|`D2Game::Player::PlayerTrade::CUBE_SpecialOutput_Unused2`|--|not found -- no function of this name in the Mac DB|
|CUBE_ORGANS_HOOK|`0x00565aa0`|`D2Game::Player::PlayerTrade::CUBE_SpecialOutput_Unused3`|--|not found -- no function of this name in the Mac DB|
|KILLMONSTER_ENTRY|`0x0057ccb0`|`D2Common::Unit::SUnitDmg::SERVER_KillMonster`|--|not found -- no function of this name in the Mac DB|
|KILLMONSTER_REJOIN|`0x0057ccb6`|`D2Common::Unit::SUnitDmg::SERVER_KillMonster` (IN+6)|--|not found -- no function of this name in the Mac DB|
|UBER_DIABLO_AI|`0x005e9df0`|`D2Game::Monster::AI::AI_Function1_UberDiablo`|--|not found -- no function of this name in the Mac DB (Windows stub is 3 bytes)|
|UBER_MEPH_AI|`0x005f81c0`|`D2Game::Monster::AI::AI_Function1_UberMephisto`|--|not found -- no function of this name in the Mac DB (Windows stub is 3 bytes)|
|UBER_BAAL_AI|`0x005fd200`|`D2Game::Monster::AI::Baal::AI_Function1_UberBaal`|--|not found -- no function of this name in the Mac DB (Windows stub is 3 bytes)|

### feature/arena

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|t|`0x0052c410`|`D2Game::Game::Server::BroadcastPlayerJoin`|--|not found -- no function of this name in the Mac DB|
|t|`0x0052c500`|`D2Game::Game::Server::BroadcastPlayerLeave`|--|not found -- no function of this name in the Mac DB|
|t|`0x00535ab0`|`D2Game::Player::Player::PLAYER_HandleDeathPenalties`|--|not found -- no function of this name in the Mac DB|

### feature/actpreload

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|readU32()|`0x0053ac70`|`D2Game::Game::Level::InitDrlgAct`|--|not found -- no function of this name in the Mac DB|
|The real client's CLIENT_WarpToAct @0x53acc0 self-heals (Ini|`0x0053acc0`|`D2Game::Game::Level::CLIENT_WarpToAct`|--|not found -- no function of this name in the Mac DB|
|activates the destination room and DRLGROOMTILE_SetupWarpTil|`0x0066e260`|`D2Common::Drlg::RoomTile::DRLGROOMTILE_SetupWarpTile`|--|not found -- no function of this name in the Mac DB|
|-> assert `!!pWarpCacheHead` @0x66e2ab and the GS exits ("no|`0x0066e2ab`|`D2Common::Drlg::RoomTile::DRLGROOMTILE_SetupWarpTile` (IN+4b)|--|not found -- no function of this name in the Mac DB|

### feature/omnivision

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|CANSEE_ORIGINAL|`0x004dc710`|`D2Game::Game::Wall2::DRAW_WORLD_IsUnitInLineOfSight`|--|REFUTED -- DB says `0x0019211f`, inside the D2Common Units.cpp TU run|
|2. PLAYER_CanSee call @0x4dc864 — replace the `call` with a|`0x004dc864`|`D2Game::Game::Wall2::DRAW_WORLD_Unit` (IN+b4)|--|REFUTED -- DB says `0x002b56b3`, a 26-byte stub in the renderer region|
|1. GetRoomColors @0x66bfd0 — the engine's per-room gamma/r/g|`0x0066bfd0`|`D2Common::Drlg::DrlgRoom::GetRGB_IntensityFromRoomEx`|`0x001504d1`|TU=DrlgRoom.cpp|

### feature/halt_hook

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|EXC_FILTER_ADDR|`0x00403e90`|`Fog::File::lpTopLevelExceptionFilter_00403e90`|--|Windows-only -- Win32 SetUnhandledExceptionFilter path; Mac uses StormMac::CRASH_* signal handlers|
|Hook Fog::ErrorManager::ERROR_UnrecoverableInternalError_Hal|`0x00408a60`|`Fog::ErrorManager::ERROR_UnrecoverableInternalError_Halt`|--|REFUTED -- DB says `0x002ec7c2` but that is outside the ErrorManager.cpp TU run (002ef0fe-002ef2cc)|

### feature/checkrev_patch

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|and calls BNDOWNLOAD_PerformCheckRevision @0x0051e6d0 to pro|`0x0051e6d0`|`D2Client::BnDownload::BNDOWNLOAD_PerformCheckRevision`|`0x000536d0`|TU=BnDownload.cpp|
|GET_PROGRESS|`0x0051ea70`|`D2Client::BnDownload::BNDOWNLOAD_GetProgress`|--|not found -- no function of this name in the Mac DB|

### feature/expmod

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|SERVER_CalculateExperienceForUnit calls CALC_Experience @0x5|`0x0057e3f0`|`D2Common::Unit::SUnitDmg::CALC_Experience`|--|not found -- no function of this name in the Mac DB|
|SERVER_CalculateExperienceForUnit calls CALC_Experience @0x5|`0x0057e4fa`|`D2Common::Unit::SUnitDmg::SERVER_CalculateExperienceForUnit` (IN+7a)|`0x00280d15`|TU=SUnitDmg.cpp|

### feature/gamecrashfix

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|At D2CMP.dll+0x2091E5 (= 0x006091E5 in 1.14d's statically-li|`0x006091e5`|`D2CMP::LRUCache::LRUCACHE_Unlink` (IN+65)|`0x00131eed`?|UNCONFIRMED -- name-only, just past the LRUCache.cpp anchor run|

### feature/ladderitems

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|The engine builds each TXT table via CompileTxt @0x6122f0 (a|`0x006122f0`|`D2Common::DataTbls::DataTbls::CompileTxt`|`0x0013fac2`|string fingerprint 4/2 + TU=DataTbls.cpp; the DB name on 00144de6 is wrong|
|COMPILETXT_REJOIN|`0x006122f9`|`D2Common::DataTbls::DataTbls::CompileTxt` (IN+9)|`0x0013fac2`|string fingerprint 4/2 + TU=DataTbls.cpp; the DB name on 00144de6 is wrong|

### feature/mapreveal

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|nTxtObjectsSize|`0x0096d474`|`nTxtObjectsSize`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

### feature/multiinstance

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|Multi-instance patch (d2bs's `Multi`). D2GFX_CreateWindow @0|`0x004f5610`|`D2Client::D2GFX::D2GFX_CreateWindow`|`0x002b576b`?|UNCONFIRMED -- name-only, size 727/689; Mac creates a Carbon/AGL window, not a HWND|
|FindWindowA @0x4F5623 to detect an already-running copy and,|`0x004f5623`|`D2Client::D2GFX::D2GFX_CreateWindow` (IN+13)|--|Windows-only -- name-only, size 727/689; Mac creates a Carbon/AGL window, not a HWND|

### engine/d2 (bot call table)

|purpose|windows addr|windows name|mac addr|how confirmed|
|-|-|-|-|-|
|OkDialog|`0x004331c0`|`D2Client::MainMenus::UIMENU_CreatePopupWithContentAndFooter`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x004336c0`|`D2Client::MainMenus::UIMENU_MainMenu`|--|not found -- no function of this name in the Mac DB|
|SelectedCharBnetSingleTcpIp|`0x00434a00`|`D2Client::MainMenus::SelectedCharBnetSingleTcpIp`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x00438f70`|`D2Client::CharSel::CHARSEL_EnumerateLocalSaves`|`0x002bd1f4`|TU=CharSel.cpp + shared string literal|
|castRunTo()|`0x0044dd60`|`D2Client::Game::D2CLIENT_ExitGame`|`0x000716ca`?|UNCONFIRMED -- name-only, sits just past the D2Client Game.cpp anchors|
|TxtMonStatsGetLine|`0x00451f80`|`D2Common::DataTbls::MonsterTbls::TXT_MonStats_GetLine`|--|REFUTED -- DB says `0x002b678f`, outside the MonsterTbls.cpp TU run|
|TxtMonStats2GetLine|`0x00451fe0`|`D2Common::DataTbls::MonsterTbls::TXT_MonStats_GetMonStats2`|--|REFUTED -- DB says `0x0019304d`, inside the Units.cpp TU run|
|TxtStatesGetLine|`0x00452040`|`D2Common::DataTbls::MonsterTbls::TXT_States_GetLine`|--|not found -- no function of this name in the Mac DB|
|GetUiFlag|`0x004538d0`|`D2Client::UI::UI::GetUIFlag`|--|REFUTED -- DB says `0x00135a14`; ui.cpp TU run is 000f5a08-000f9167|
|SetUIFlag|`0x00455f20`|`D2Client::UI::Draw::SetUIFlag`|--|REFUTED -- DB says `0x001296b3`, inside the UnitSnd.cpp/CUnitEvent.cpp neighbourhood|
|AddAutomapCell|`0x00457b00`|`D2Client::UI::Automap::AUTOMAP_InsertCellIntoTree`|`0x0009bc97`?|UNCONFIRMED -- name-only, just past the automap.cpp anchor run|
|NewAutomapCell|`0x00457c30`|`D2Client::UI::Automap::AUTOMAP_AllocCell`|`0x00097d3a`|TU=automap.cpp|
|ptr|`0x00458f40`|`D2Client::UI::Automap::AUTOMAP_RevealRoom`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x0045a710`|`D2Client::UI::Automap::AUTOMAP_GetMiniMapType`|--|not found -- no function of this name in the Mac DB|
|p|`0x0045a7f0`|`D2Client::UI::Automap::AUTOMAP_DrawXMarker`|`0x0009b88d`?|UNCONFIRMED -- name-only, just past the automap.cpp anchor run|
|DrawAutomap|`0x0045ad60`|`D2Client::UI::Automap::AUTOMAP_Draw`|`0x0009a888`|TU=automap.cpp|
|GetMouseYOffset|`0x0045afb0`|`D2Client::UI::Path::GetMouseYOffset`|--|not found -- no function of this name in the Mac DB|
|GetMouseXOffset|`0x0045afc0`|`D2Client::UI::Path::DRAW_GetWorldOffsetX`|--|REFUTED -- DB says `0x00165aa9`, inside the D2Common Dungeon.cpp TU run|
|TxtSkillsGetLine|`0x0045c4b0`|`D2Game::Game::SCmd::TXT_Skills_GetLine`|--|REFUTED -- DB says `0x0026ec37`, inside the D2Game Skills.cpp neighbourhood|
|TxtItemStatCostGetLine|`0x0045c4f0`|`D2Game::Game::SCmd::TXT_ItemStatCost_GetLine`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x0045c900`|`D2Game::Game::SCmd::NET_D2GS_CLIENT_IncomingReturn_0045c900`|--|not found -- no function of this name in the Mac DB|
|InteractWithObject|`0x00461890`|`D2Common::Unit::Player::PLAYER_InteractWithObject`|`0x00123eb6`?|UNCONFIRMED -- name-only, just past the D2Common Player.cpp anchor run|
|InteractWithUnit|`0x004619e0`|`D2Common::Unit::Player::PLAYER_InteractWithUnit`|--|not found -- no function of this name in the Mac DB|
|FindClientSideUnit|`0x00461fc0`|`D2Common::Unit::Player::PLAYER_InteractWithUnitByType` (IN+200)|--|not found -- no function of this name in the Mac DB|
|ClickMap|`0x00462d00`|`D2Common::Unit::Player::ClickMap`|--|not found -- no function of this name in the Mac DB|
|FindBetterNearbyRoom|`0x00463740`|`D2Common::Unit::Player::DRLGROOM_FindBetterNearbyRoom`|--|REFUTED -- DB says `0x002267e9`, a 5-byte stub inside the a2q4.cpp TU run|
|GetUnitName|`0x00464a60`|`D2Common::Unit::CUnit::GetName`|`0x001000bc`?|UNCONFIRMED -- name-only, just past the CUnit.cpp anchor run|
|ptr|`0x00478350`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send`|--|not found -- no function of this name in the Mac DB|
|len|`0x004785d0`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send_SHORT_SHORT`|--|not found -- no function of this name in the Mac DB|
|sendRunToLocation()|`0x004786a0`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send_INT_INT`|--|REFUTED -- DB says `0x000cbf8b`, inside the npcmenu.cpp/panel.cpp neighbourhood|
|ImageLoadDC6Ex|`0x004788b0`|`D2Client::Core::Archive::IMAGE_LoadDC6Ex`|`0x0005cf38`|TU=D2Client/CORE/ARCHIVE.CPP, asserts against that file (the earlier REFUTED verdict confused it with D2Hell/SRC/Archive.cpp)|
|GetMonsterOwner|`0x00479150`|`D2Game::Game::RosterPets::GetRosterOwnerGUID`|`0x00076a1a`?|UNCONFIRMED -- name-only, just past the RosterPets.cpp anchor run|
|EscMenuShowMenu|`0x0047e090`|`D2Client::UI::EscMenu::ESCMENU_ShowMenu`|`0x000a0f64`?|UNCONFIRMED -- name-only, no EscMenu TU anchor in the Mac build|
|TxtCharStatsGetLine|`0x004833e0`|`D2Common::DataTbls::INV_GetCharStatsTxtLine`|--|not found -- no function of this name in the Mac DB|
|WaypointSendClose|`0x0049c6c0`|`D2Client::UI::Waypoint::WAYPOINT_SendClosePacket`|--|not found -- no function of this name in the Mac DB|
|PrintGameString|`0x0049e3a0`|`D2Client::UI::Text::TEXT_PrintGameString`|--|REFUTED -- DB says `0x0005da4d`, an 18-byte stub; text.cpp TU run is 000eebfc-000f1365|
|ptr|`0x004b1620`|`D2Client::UI::NpcMenu::GetInteractedUnit`|--|not found -- no function of this name in the Mac DB|
|CloseNPCInteract|`0x004b3f10`|`D2Client::UI::NpcMenu::CloseNPCInteract`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x004f5160`|`D2Client::D2GFX::D2GFX_GetResolutionMode`|`0x002b4d60`?|UNCONFIRMED -- name-only; the Mac renderer is a different implementation|
|ptr|`0x004f5570`|`D2Client::D2GFX::D2GFX_GetWindowSizeByResolutionMode`|`0x002b56e7`?|UNCONFIRMED -- name-only, size 120/132|
|ptr|`0x004f59b0`|`D2Client::D2GFX::D2GFX_GetScreenSize`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x004f6250`|`D2Client::D2GFX::D2GFX_GetBackBuffer`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x004f62a0`|`D2Client::D2GFX::D2GFX_DrawRectEx`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x004f6340`|`D2Client::D2GFX::D2GFX_DrawSolidRectAlpha`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x004f6380`|`D2Client::D2GFX::D2GFX_DrawLine`|`0x002b5122`?|UNCONFIRMED -- name-only, 26-byte dispatch stub|
|ptr|`0x004f6480`|`D2Client::D2GFX::D2GFX_DrawImage`|`0x002b55d8`?|UNCONFIRMED -- name-only, 26-byte dispatch stub|
|ptr|`0x004f9190`|`D2Win::D2WinMain::D2WINMAIN_ClearMessageLoopFlag`|--|REFUTED -- DB says `0x002be8ab`; D2WinMain.cpp TU run is 0004a41f-0004b1f2|
|ptr|`0x004fa7a0`|`D2Win::D2WinMain::TakeScreenshot`|--|not found -- no function of this name in the Mac DB|
|DrawText|`0x00502320`|`D2Win::D2WinFont::DRAW_text`|`0x00048438`|TU=D2WinFont.cpp|
|GetTextSize|`0x00502520`|`D2Win::D2WinFont::TEXT_CalcTextDimensions`|`0x00048836`|TU=D2WinFont.cpp|
|SetFont|`0x00502ef0`|`D2Win::D2WinFont::SetAndReturnLastFont`|--|REFUTED -- DB says `0x0018efb5`, inside the D2Common Units.cpp TU run|
|GetLocaleString|`0x00524a30`|`D2Win::StrTable::StrTable::GetLocaleString`|--|REFUTED -- DB says `0x002ccd65`, a 17-byte stub; strtable.cpp run is 002b87a2-002b98b1|
|WarpUnitToLevel|`0x00537860`|`D2Game::Game::Clients::GetPlayerFromClient`|--|REFUTED -- DB says `0x0028c553`, inside the sunitproxy.cpp TU run|
|CheckCollisionWidth|`0x0053aec0`|`D2Game::Game::Level::InitLevel`|`0x001b012f`|TU=Level.cpp; note the Mac DB labels this address D2Common::Drlg::Drlg::InitLevel|
|FindSpawnableLocation|`0x00545340`|`D2Game::Quests::Quests::FindSpawnableLocation`|--|not found -- no function of this name in the Mac DB|
|CreateTombPortal|`0x0054f430`|`D2Game::Objects::Objects::OBJECT_CreateTombPortal`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x00553380`|`D2Common::Unit::SUnit::SetupUpdateEvent_D2MooAttachSound`|--|REFUTED -- DB says `0x001ef9ca`, inside the Objects.cpp/ObjMode.cpp neighbourhood|
|ptr|`0x00554200`|`D2Common::Unit::SUnit::UNITS_CheckIfCanAttackTarget`|--|REFUTED -- DB says `0x00268c6f`, inside the D2Game Skills.cpp TU run|
|CreateUnit|`0x00555230`|`D2Common::Unit::SUnit::CreateUnit`|`0x002788b4`|TU=SUnit.cpp|
|SpawnMonsterWithMode|`0x00555da0`|`D2Common::Items::Items::Drop::FindBestSpotToSpawnItem`|`0x001c18b7`?|UNCONFIRMED -- name-only, at the ItemMode.cpp/Items.cpp boundary|
|FindBestSpotToSpawnItem|`0x00558d90`|`D2Common::Items::Items::Drop::ITEM_CreateItemInstance`|`0x001c4169`|TU=Items.cpp, size 918/1584|
|SpawnPortal|`0x0056d130`|`D2Common::Skills::SkillsServer::SERVER_SpawnPortal`|--|not found -- no function of this name in the Mac DB|
|GetMonsterOwner|`0x005a4440`|`D2Common::Monsters::Monsters::SERVER_SpawnMonster`|`0x001e4ba3`?|UNCONFIRMED -- name-only, MonsterRegion.cpp/Objects.cpp neighbourhood, size 573/546|
|ptr|`0x005a60e0`|`D2Game::Player::PlayerScreen::PARTYSCREEN_SetHostileRelation`|--|not found -- no function of this name in the Mac DB|
|SpawnMonster|`0x005b2f20`|`D2Game::Monster::Monster::Create::SpawnMonsterAtRoomPos`|--|not found -- no function of this name in the Mac DB|
|DiabloAI|`0x005e9170`|`D2Game::Monster::AI::AI_Function1_Diablo`|`0x002a802a`|TU=AiThink4.cpp, size 1425/1801|
|MephAI|`0x005f78b0`|`D2Game::Monster::AI::AI_Function1_Mephisto`|--|not found -- no function of this name in the Mac DB|
|BaalAI|`0x005fcfe0`|`D2Game::Monster::AI::Baal::AI_Function1_BaalCrab`|`0x001a0f53`|TU=AiBaal.cpp|
|TxtExperienceGetLine|`0x00611830`|`D2Common::DataTbls::DataTbls::TXT_Experience_GetLine`|--|REFUTED -- DB says `0x0020ac18`, inside the PlrSave.cpp/PlrSave2.cpp neighbourhood|
|TxtDifficultyLevelsGetLine|`0x00611d30`|`D2Common::DataTbls::DataTbls::GetDifficultyLevels`|--|REFUTED -- DB says `0x0027b58c`, inside the SUnit.cpp/SUnitDmg.cpp neighbourhood|
|ptr|`0x0061a070`|`D2Common::Dungeon::Dungeon::AddRoomData`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x0061a0c0`|`D2Common::Dungeon::Dungeon::RemoveRoomData`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x0061db70`|`D2Common::DataTbls::LvlTbls::TXT_Levels_GetLine`|`0x0014502d`?|UNCONFIRMED -- name-only, immediately before the LvlTbls.cpp anchor run|
|GetLayer|`0x0061e470`|`D2Common::DataTbls::LvlTbls::TXT_LevelDefs_GetLine`|--|REFUTED -- DB says `0x0015a9cc`, inside the OutPlace.cpp/OutRoom.cpp neighbourhood|
|TxtLvlPrestGetLine|`0x0061f0b0`|`D2Common::DataTbls::LvlTbls::TXT_LvlPrest_GetLine`|--|REFUTED -- DB says `0x00154461`, inside the Maze.cpp/Outdoors.cpp neighbourhood|
|ptr|`0x00620870`|`D2Common::Units::Units::GetCoords`|`0x00193c28`?|UNCONFIRMED -- name-only, just past the Units.cpp anchor run|
|ptr|`0x006229f0`|`D2Common::Units::Units::TestCollisionByCoordinates`|--|REFUTED -- DB says `0x0024ce08`, inside the SkillAss.cpp TU run|
|ptr|`0x00625480`|`D2Common::Stats::StatsEx::GetStatUnsignedValue`|--|REFUTED -- DB says `0x0028660d`; StatsEx.cpp run is 00195634-00196c48|
|ptr|`0x006335f0`|`D2Common::DataTbls::ItemTbls::TXT_Items_GetLine`|--|REFUTED -- DB says `0x001c40e1`, inside the ItemMode.cpp/Items.cpp neighbourhood|
|SpawnItemWithStruct|`0x00633680`|`D2Common::DataTbls::ItemTbls::TXT_Items_ConvertItemCodeToItemClassId`|`0x00142c52`|TU=ItemTbls.cpp|
|TxtMagicAffixesGetLine|`0x00633ee0`|`D2Common::DataTbls::ItemTbls::TXT_magicaffixes_GetLine`|--|not found -- no function of this name in the Mac DB|
|TxtQualityItemsGetLine|`0x00636b20`|`D2Common::DataTbls::ItemTbls::TXT_QualityItems_GetLine`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x00639df0`|`D2Common::DataTbls::ItemStats::UNIT_GetUnitState`|--|REFUTED -- DB says `0x0027f48b`, inside the SUnitDmg.cpp TU run|
|ptr|`0x00640e90`|`D2Common::DataTbls::ObjectTbls::TXT_Objects_GetLine`|--|REFUTED -- DB says `0x001f78fb`, inside the D2Game Player.cpp TU run|
|TxtShrinesGetLine|`0x006414b0`|`D2Common::DataTbls::ObjectTbls::TXT_Shrines_GetLine`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x006424a0`|`D2Common::Drlg::Drlg::InitLevel`|--|REFUTED -- DB collides with D2Game::Game::Level::InitLevel on 001b012f|
|ptr|`0x006427f0`|`D2Common::Drlg::Drlg::GetActNoFromLevelNumber`|--|REFUTED -- DB says `0x00278859`, inside the SUnit.cpp TU run|
|GetSkill|`0x00643810`|`D2Common::Skills::Skills::GetSkill`|--|REFUTED -- DB says `0x002aa334`, inside the AiThink4.cpp TU run|
|ptr|`0x006442a0`|`D2Common::Skills::Skills::GetSkillLevel`|`0x0018608e`?|UNCONFIRMED -- name-only, immediately before the D2Common Skills.cpp anchor run|
|GetSkillLevelById|`0x006447b0`|`D2Common::Skills::Skills::GetSkillLevelById`|--|not found -- no function of this name in the Mac DB|
|ptr|`0x00645910`|`D2Common::Skills::Skills::SKILLS_HasLineOfSight`|--|not found -- no function of this name in the Mac DB|
|CheckCollisionWidth|`0x0064d9b0`|`D2Common::Collision::Collision::CheckCollision_BlockAll_Width`|--|REFUTED -- DB says `0x001d6f24`; Collisn.cpp run is 00135d4e-00136058|
|TxtSuperUniquesGetLine|`0x006556e0`|`D2Common::DataTbls::MonsterTbls::TXT_SuperUniques_GetLine`|--|not found -- no function of this name in the Mac DB|
|TxtNpcGetLine|`0x00656900`|`D2Common::DataTbls::MonsterTbls::TXT_npc_GetLine`|`0x00149afd`|TU=MonsterTbls.cpp|
|GetQuestState|`0x0065c310`|`D2Game::Quests::QuestRecord::GetQuestState`|--|REFUTED -- DB says `0x002167d6`; QuestRecord.cpp run is 00184c2a-00184cbc|
|divisor()|`0x00711254`|`nAutoMapZoomDivisor`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|screenWidth()|`0x0071146c`|`ScreenSizeX`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|screenHeight()|`0x00711470`|`ScreenSizeY`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|NPCMenuCount|`0x00725a74`|`D2Client::NPC::D2NpcMenuOptionsCount`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|NPCMenuArray|`0x00726c48`|`D2Client::NPC::D2NpcMenuOptions`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|iniDataLauncher()|`0x007795d4`|`D2IniData_launcher`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|gnSelectedCharGameState()|`0x007795e8`|`gnSelectedCharGameState`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|oogCurrentCharSelectionMode()|`0x007795ec`|`OogCurrentCharSelectionMode`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|charSelStrcFirst()|`0x00779dc0`|`gpCharSelPendingEntry`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|gameInfo()|`0x007a0438`|`D2IniData_client`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|currentGameType()|`0x007a0610`|`eD2GSGameType_007a0610`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|automapLayer()|`0x007a5164`|`D2Client::UI::Automap::sgpAutomapLayerEx`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|automapOffset()|`0x007a5198`|`nAutoMapScrollX`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|ViewportY|`0x007a5208`|`MouseYOffset`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|ViewportX|`0x007a520c`|`MouseXOffset`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|clientSideUnits()|`0x007a5270`|`ClientSideUnitHashTables`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|serverSideUnits()|`0x007a5e70`|`ServerSideUnitHashTables`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|playerUnit()|`0x007a6a70`|`pPlayerUnit`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|noPickUp()|`0x007a6a90`|`gbSuppressItemSelection`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|MouseY|`0x007a6aac`|`MouseY`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|MouseX|`0x007a6ab0`|`MouseX`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|wp_menu_open|`0x007bf06c`|`gbWaypointButtonPressed`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|wp_selected_idx|`0x007bf06d`|`ClickingDownOnWaypointEntry`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|wp_traveling|`0x007bf085`|`D2Client::Waypoint::Waypoint::bNeedAllocation`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|hInst()|`0x007c8ca8`|`hInstance`|--|Windows-only -- global data; no named counterpart anywhere in the Mac DB|
|hWnd()|`0x007c8cbc`|`hwndD2GFX_Window`|--|Windows-only -- global data; no named counterpart anywhere in the Mac DB|
|divisor()|`0x0096bc30`|`sgtDataTable`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtItemTypesGetLine()|`0x0096bcd4`|`sgtDataTable.pTxtProperties`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtMissilesGetLine()|`0x0096c794`|`sgtDataTable.pTxtMissiles`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtOverlayGetLine()|`0x0096c7a0`|`sgtDataTable.pTxtMonLvl`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtPropertiesGetLine()|`0x0096c7ec`|`sgtDataTable.pTxtOverlay`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtSetItemsGetLine()|`0x0096c824`|`sgtDataTable.pTxtItemTypesLink`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtSetItemsGetLine()|`0x0096c828`|`sgtDataTable.pTxtItemTypes`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtUniqueItemsGetLine()|`0x0096c848`|`sgtDataTable.pTxtSetItems`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtMissilesGetLine()|`0x0096c854`|`sgtDataTable.pTxtUniqueItems`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|
|txtMonLvlGetLine()|`0x0096c8a8`|`sgtDataTable.pTxtExperience`|--|unresolved -- global data; no named counterpart anywhere in the Mac DB|

## Unresolved

### Globals -- all 47, none resolvable

The Mac image has 6,060 label symbols and only 617 carry a name, almost all import/stub thunks.
Not one of the 47 data addresses (`sgtDataTable` and its `pTxt*` members, `GameSeed`,
`pGlobalPoolSystem`, `QServerClientBucketByName`, `pPlayerUnit`, the unit hash tables, the mouse
and screen globals, the CD-key buffers) has a counterpart of that name anywhere in the Mac
database. They must be relocated one by one, from a confirmed function that touches them.

### Refuted -- the Mac name exists but is wrong

|windows addr|windows name|why the Mac DB entry was rejected|
|-|-|-|
|`0x00408a60`|`Fog::ErrorManager::ERROR_UnrecoverableInternalError_Halt`|DB says `0x002ec7c2` but that is outside the ErrorManager.cpp TU run (002ef0fe-002ef2cc)|
|`0x00409ab0`|`Fog::Memory::Free`|only a bare leaf `Free` (5 candidates, none in a Fog TU)|
|`0x00409dd0`|`Fog::Memory::InitializePoolSystem`|DB says `0x002f40fb`, which lies inside the QServer.cpp TU run (002f3494-002f5370)|
|`0x0040a080`|`Fog::Memory::Alloc`|only a bare leaf `Alloc` (6 candidates), lands in the automap.cpp neighbourhood|
|`0x00413020`|`Fog::SMem::SMemAlloc`|DB says `0x002ef904`; Storm SMem lives in the StormMac region (< 0x0003ffff)|
|`0x00451bb0`|`D2Client::_Message::MessageGameLoop`|DB says `0x002f33fa`, a 5-byte stub; cannot be MessageGameLoop|
|`0x00451f80`|`D2Common::DataTbls::MonsterTbls::TXT_MonStats_GetLine`|DB says `0x002b678f`, outside the MonsterTbls.cpp TU run|
|`0x00451fe0`|`D2Common::DataTbls::MonsterTbls::TXT_MonStats_GetMonStats2`|DB says `0x0019304d`, inside the Units.cpp TU run|
|`0x004538d0`|`D2Client::UI::UI::GetUIFlag`|DB says `0x00135a14`; ui.cpp TU run is 000f5a08-000f9167|
|`0x00455f20`|`D2Client::UI::Draw::SetUIFlag`|DB says `0x001296b3`, inside the UnitSnd.cpp/CUnitEvent.cpp neighbourhood|
|`0x004565e0`|`D2Client::UI::Draw::Draw_UI_LoadGame`|DB says `0x0013483f`, inside the D2CMP SpriteCache.cpp neighbourhood|
|`0x00457300`|`D2Client::UI::Draw::CLIENT_AdjustMemoryBudget`|string fingerprint points at 0005d184, the DB name sits on 0009fd27|
|`0x0045afc0`|`D2Client::UI::Path::DRAW_GetWorldOffsetX`|DB says `0x00165aa9`, inside the D2Common Dungeon.cpp TU run|
|`0x0045c4b0`|`D2Game::Game::SCmd::TXT_Skills_GetLine`|DB says `0x0026ec37`, inside the D2Game Skills.cpp neighbourhood|
|`0x00463740`|`D2Common::Unit::Player::DRLGROOM_FindBetterNearbyRoom`|DB says `0x002267e9`, a 5-byte stub inside the a2q4.cpp TU run|
|`0x004786a0`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send_INT_INT`|DB says `0x000cbf8b`, inside the npcmenu.cpp/panel.cpp neighbourhood|
|`0x004788b0`|`D2Client::Core::Archive::IMAGE_LoadDC6Ex`|DB says `0x0005cf38`; Archive.cpp TU run is 002b6888-002b6e68|
|`0x0049e3a0`|`D2Client::UI::Text::TEXT_PrintGameString`|DB says `0x0005da4d`, an 18-byte stub; text.cpp TU run is 000eebfc-000f1365|
|`0x004dc710`|`D2Game::Game::Wall2::DRAW_WORLD_IsUnitInLineOfSight`|DB says `0x0019211f`, inside the D2Common Units.cpp TU run|
|`0x004dc7b0`|`D2Game::Game::Wall2::DRAW_WORLD_Unit`|DB says `0x002b56b3`, a 26-byte stub in the renderer region|
|`0x004f9190`|`D2Win::D2WinMain::D2WINMAIN_ClearMessageLoopFlag`|DB says `0x002be8ab`; D2WinMain.cpp TU run is 0004a41f-0004b1f2|
|`0x004fb1e0`|`D2Win::D2WinPalette::D2WINPAL_LoadPaletteFiles`|DB says `0x0004d2a0`, which is the first D2WinTextBox.cpp anchor|
|`0x00502ef0`|`D2Win::D2WinFont::SetAndReturnLastFont`|DB says `0x0018efb5`, inside the D2Common Units.cpp TU run|
|`0x005066c0`|`D2Win::D2Comp::AllocCharSelectComponent`|DB says `0x002d5e02`, inside the ComCallback.cpp TU run|
|`0x00524a30`|`D2Win::StrTable::StrTable::GetLocaleString`|DB says `0x002ccd65`, a 17-byte stub; strtable.cpp run is 002b87a2-002b98b1|
|`0x0052b330`|`D2Game::Game::Server::NET_D2GS_SERVER_SendPacketToClient`|DB says `0x001b4b24`, inside the D2Game Targets.cpp TU run|
|`0x0052c170`|`D2Game::Game::Server::QSERVER_GenerateToken`|DB says `0x001e012d`, inside the MonsterRegion.cpp/Objects.cpp neighbourhood|
|`0x0052c280`|`D2Game::Game::Server::RollSeed`|leaf-only `RollSeed`, DB pick is inside the D2Common Drlg.cpp TU run|
|`0x0052caf0`|`D2Game::Game::Server::SERVER_DisconnectClient`|DB says `0x00211eb0`, a 26-byte stub inside the PlrTrade.cpp TU run|
|`0x0052e860`|`D2Game::Game::Server::QSERVER_FindAndLockGame`|DB says `0x0013b255`, inside the AnimTbls.cpp/DataTbls.cpp neighbourhood|
|`0x0052fa50`|`D2Game::Game::Server::NET_D2GS_SERVER_SrvJoinGame`|TU=Game.cpp is right but the target is a 38-byte stub vs 448 bytes on Windows|
|`0x00530190`|`D2Game::Game::Server::NET_D2GS_SERVER_SrvJoinAct`|TU=Game.cpp is right but the target is a 68-byte stub vs 211 bytes on Windows|
|`0x00532400`|`D2Game::Player::PlayerSave::SaveGameAllGameTypes`|DB says `0x001f6a8c`, inside the PartyScreen.cpp TU run, not PlrSave.cpp|
|`0x00537810`|`D2Game::Game::Clients::SERVER_GetClientFromGmeByClientId`|DB says `0x001ad074`, inside Game.cpp; Clients.cpp run is 001a88f5-001aac62|
|`0x00537860`|`D2Game::Game::Clients::GetPlayerFromClient`|DB says `0x0028c553`, inside the sunitproxy.cpp TU run|
|`0x0053b280`|`D2Game::Game::SCmd::NET_D2GS_SERVER_SendPacket_Helper`|DB says `0x0023cfdb`, inside the a5q2.cpp/a5q3.cpp neighbourhood|
|`0x0053f100`|`D2Game::Game::CCmd::NET_D2GS_SERVER_ProcessClientMessage_GameSetup`|DB says `0x00213930`, inside the PlrTrade.cpp/a1q1.cpp neighbourhood|
|`0x0054a290`|`D2Game::Player::PlayerMsg::SCMD_0x14_OverheadMessage`|DB says `0x00269680`, inside the D2Game Skills.cpp TU run|
|`0x00553380`|`D2Common::Unit::SUnit::SetupUpdateEvent_D2MooAttachSound`|DB says `0x001ef9ca`, inside the Objects.cpp/ObjMode.cpp neighbourhood|
|`0x00554200`|`D2Common::Unit::SUnit::UNITS_CheckIfCanAttackTarget`|DB says `0x00268c6f`, inside the D2Game Skills.cpp TU run|
|`0x00600b80`|`D2CMP::Pallete::PALETTE_InitItemPalettes`|DB says `0x0013204b`; the string set is shared with D2COMP_LoadAllItemPalettes|
|`0x006019f0`|`D2CMP::CelCmp::IMAGE_GetFramesCount`|DB says `0x002b55f2`, a 26-byte stub in the renderer region|
|`0x00611830`|`D2Common::DataTbls::DataTbls::TXT_Experience_GetLine`|DB says `0x0020ac18`, inside the PlrSave.cpp/PlrSave2.cpp neighbourhood|
|`0x00611d30`|`D2Common::DataTbls::DataTbls::GetDifficultyLevels`|DB says `0x0027b58c`, inside the SUnit.cpp/SUnitDmg.cpp neighbourhood|
|`0x0061e470`|`D2Common::DataTbls::LvlTbls::TXT_LevelDefs_GetLine`|DB says `0x0015a9cc`, inside the OutPlace.cpp/OutRoom.cpp neighbourhood|
|`0x0061f0b0`|`D2Common::DataTbls::LvlTbls::TXT_LvlPrest_GetLine`|DB says `0x00154461`, inside the Maze.cpp/Outdoors.cpp neighbourhood|
|`0x006229f0`|`D2Common::Units::Units::TestCollisionByCoordinates`|DB says `0x0024ce08`, inside the SkillAss.cpp TU run|
|`0x00625480`|`D2Common::Stats::StatsEx::GetStatUnsignedValue`|DB says `0x0028660d`; StatsEx.cpp run is 00195634-00196c48|
|`0x006335f0`|`D2Common::DataTbls::ItemTbls::TXT_Items_GetLine`|DB says `0x001c40e1`, inside the ItemMode.cpp/Items.cpp neighbourhood|
|`0x00639df0`|`D2Common::DataTbls::ItemStats::UNIT_GetUnitState`|DB says `0x0027f48b`, inside the SUnitDmg.cpp TU run|
|`0x00640e90`|`D2Common::DataTbls::ObjectTbls::TXT_Objects_GetLine`|DB says `0x001f78fb`, inside the D2Game Player.cpp TU run|
|`0x006424a0`|`D2Common::Drlg::Drlg::InitLevel`|DB collides with D2Game::Game::Level::InitLevel on 001b012f|
|`0x006427f0`|`D2Common::Drlg::Drlg::GetActNoFromLevelNumber`|DB says `0x00278859`, inside the SUnit.cpp TU run|
|`0x00642bb0`|`D2Common::Drlg::Drlg::GetLevelAndAlloc`|DB says `0x001507e0`, in DrlgRoom.cpp/DrlgVer.cpp, not Drlg.cpp|
|`0x00643810`|`D2Common::Skills::Skills::GetSkill`|DB says `0x002aa334`, inside the AiThink4.cpp TU run|
|`0x0064d9b0`|`D2Common::Collision::Collision::CheckCollision_BlockAll_Width`|DB says `0x001d6f24`; Collisn.cpp run is 00135d4e-00136058|
|`0x0065c310`|`D2Game::Quests::QuestRecord::GetQuestState`|DB says `0x002167d6`; QuestRecord.cpp run is 00184c2a-00184cbc|
|`0x0066d820`|`D2Common::Drlg::DRLGROOMTILE_GetTileLibraryEntry`|DB says `0x001614e4`, before the RoomTile.cpp anchor run (Preset.cpp territory)|
|`0x0067c570`|`D2Common::Drlg::DrlgGrid::GetGridFlags`|DB says `0x00161b09`; DrlgGrid.cpp run is 0014e4bb-0014e683|

### Not found -- no function of that name in the Mac database

|windows addr|windows name|note|
|-|-|-|
|`0x00409c80`|`Fog::Memory::FreeMemoryPool`|absent, or present under a different name|
|`0x0040a1f0`|`Fog::Memory::ReAlloc`|absent, or present under a different name|
|`0x004331c0`|`D2Client::MainMenus::UIMENU_CreatePopupWithContentAndFooter`|absent, or present under a different name|
|`0x004336c0`|`D2Client::MainMenus::UIMENU_MainMenu`|absent, or present under a different name|
|`0x00434a00`|`D2Client::MainMenus::SelectedCharBnetSingleTcpIp`|absent, or present under a different name|
|`0x00438ad0`|`D2Client::CharSel::SAVEFILE_ParseSaveData`|absent, or present under a different name|
|`0x0044bad0`|`D2Client::ClientModeInGame::CLIENTMODE_Unused3`|absent, or present under a different name|
|`0x0044e380`|`D2Client::Game::CLIENT_ConnectionRefused`|absent, or present under a different name|
|`0x00451000`|`D2Client::Game::CreateGame`|absent, or present under a different name|
|`0x00452040`|`D2Common::DataTbls::MonsterTbls::TXT_States_GetLine`|absent, or present under a different name|
|`0x00456ee0`|`D2Client::UI::Draw::DRAW_UI`|absent, or present under a different name|
|`0x00458f40`|`D2Client::UI::Automap::AUTOMAP_RevealRoom`|absent, or present under a different name|
|`0x0045a710`|`D2Client::UI::Automap::AUTOMAP_GetMiniMapType`|absent, or present under a different name|
|`0x0045afb0`|`D2Client::UI::Path::GetMouseYOffset`|absent, or present under a different name|
|`0x0045c4f0`|`D2Game::Game::SCmd::TXT_ItemStatCost_GetLine`|absent, or present under a different name|
|`0x0045c850`|`D2Game::Game::SCmd::NET_D2GS_CLIENT_PacketHandle_from0xAF`|absent, or present under a different name|
|`0x0045c900`|`D2Game::Game::SCmd::NET_D2GS_CLIENT_IncomingReturn_0045c900`|absent, or present under a different name|
|`0x004619e0`|`D2Common::Unit::Player::PLAYER_InteractWithUnit`|absent, or present under a different name|
|`0x00461dc0`|`D2Common::Unit::Player::PLAYER_InteractWithUnitByType`|absent, or present under a different name|
|`0x00462d00`|`D2Common::Unit::Player::ClickMap`|absent, or present under a different name|
|`0x00478350`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send`|absent, or present under a different name|
|`0x004785d0`|`D2Game::Game::Msg::NET_D2GS_CLIENT_Send_SHORT_SHORT`|absent, or present under a different name|
|`0x004833e0`|`D2Common::DataTbls::INV_GetCharStatsTxtLine`|absent, or present under a different name|
|`0x0049c6c0`|`D2Client::UI::Waypoint::WAYPOINT_SendClosePacket`|absent, or present under a different name|
|`0x004b1620`|`D2Client::UI::NpcMenu::GetInteractedUnit`|absent, or present under a different name|
|`0x004b3f10`|`D2Client::UI::NpcMenu::CloseNPCInteract`|absent, or present under a different name|
|`0x004f59b0`|`D2Client::D2GFX::D2GFX_GetScreenSize`|absent, or present under a different name|
|`0x004f6250`|`D2Client::D2GFX::D2GFX_GetBackBuffer`|absent, or present under a different name|
|`0x004f62a0`|`D2Client::D2GFX::D2GFX_DrawRectEx`|absent, or present under a different name|
|`0x004f6340`|`D2Client::D2GFX::D2GFX_DrawSolidRectAlpha`|absent, or present under a different name|
|`0x004f98e0`|`D2Win::D2WinMain::RENDERER_DrawOutOfGameScene`|absent, or present under a different name|
|`0x004fa7a0`|`D2Win::D2WinMain::TakeScreenshot`|absent, or present under a different name|
|`0x0051ea70`|`D2Client::BnDownload::BNDOWNLOAD_GetProgress`|absent, or present under a different name|
|`0x0052b610`|`D2Game::Game::Server::QSERVER_GetClientGameToken`|absent, or present under a different name|
|`0x0052c060`|`D2Game::Game::Server::SERVER_IsTokenValid`|absent, or present under a different name|
|`0x0052c0e0`|`D2Game::Game::Server::SetupAsBnetServer`|absent, or present under a different name|
|`0x0052c110`|`D2Game::Game::Server::QSERVER_PutNewGameOnTokenList`|absent, or present under a different name|
|`0x0052c320`|`D2Game::Game::Server::GAME_SetForcedGameSeed`|absent, or present under a different name|
|`0x0052c410`|`D2Game::Game::Server::BroadcastPlayerJoin`|absent, or present under a different name|
|`0x0052c500`|`D2Game::Game::Server::BroadcastPlayerLeave`|absent, or present under a different name|
|`0x0052c5b0`|`D2Game::Game::Server::STRING_CheckIfPlayerNameDoNotContainForbidenChars`|absent, or present under a different name|
|`0x0052ca10`|`D2Game::Game::Server::SaveAllPlayers`|absent, or present under a different name|
|`0x0052da90`|`D2Game::Game::Server::Unlock`|absent, or present under a different name|
|`0x005302d0`|`D2Game::Game::Server::QSERVER_DisconnectClientByName`|absent, or present under a different name|
|`0x005306e0`|`D2Game::Game::Server::CLIENT_OnDatabaseCharacterReceived`|absent, or present under a different name|
|`0x00530930`|`D2Game::Game::Server::GAME_CreateBattleNetGame`|absent, or present under a different name|
|`0x00531eb0`|`D2Game::Player::PlayerSave::SaveToFileBnet`|absent, or present under a different name|
|`0x00535ab0`|`D2Game::Player::Player::PLAYER_HandleDeathPenalties`|absent, or present under a different name|
|`0x00536f80`|`D2Common::Unit::SUnitProxy::SUNITPROXY_InitAllNpcItemTables`|absent, or present under a different name|
|`0x00538c60`|`D2Game::Game::Clients::SERVER_IsPlayerCharacterInGame`|absent, or present under a different name|
|`0x0053ac70`|`D2Game::Game::Level::InitDrlgAct`|absent, or present under a different name|
|`0x0053acc0`|`D2Game::Game::Level::CLIENT_WarpToAct`|absent, or present under a different name|
|`0x0053ff00`|`D2Game::Game::Party::ChangeGoldForPlayer`|absent, or present under a different name|
|`0x00542b40`|`D2Common::Unit::SUnitInactive::SUNITINACTIVE_RoomInit`|absent, or present under a different name|
|`0x00545340`|`D2Game::Quests::Quests::FindSpawnableLocation`|absent, or present under a different name|
|`0x0054f430`|`D2Game::Objects::Objects::OBJECT_CreateTombPortal`|absent, or present under a different name|
|`0x005550b0`|`D2Common::Unit::SUnit::TakeStairs`|absent, or present under a different name|
|`0x00565a90`|`D2Game::Player::PlayerTrade::CUBE_SpecialOutput_Unused2`|absent, or present under a different name|
|`0x00565aa0`|`D2Game::Player::PlayerTrade::CUBE_SpecialOutput_Unused3`|absent, or present under a different name|
|`0x00569d80`|`D2Game::Player::PlayerSave2::CalculateGetFlags`|absent, or present under a different name|
|`0x0056d130`|`D2Common::Skills::SkillsServer::SERVER_SpawnPortal`|absent, or present under a different name|
|`0x00576330`|`D2Common::Unit::SUnitNpc::SUNITNPC_GenerateNpcItems`|absent, or present under a different name|
|`0x0057c6c0`|`D2Common::Unit::SUnitDmg::DAMAGE_ApplyDamageToUnit`|absent, or present under a different name|
|`0x0057ccb0`|`D2Common::Unit::SUnitDmg::SERVER_KillMonster`|absent, or present under a different name|
|`0x0057e3f0`|`D2Common::Unit::SUnitDmg::CALC_Experience`|absent, or present under a different name|
|`0x005a5be0`|`D2Game::Player::PlayerScreen::PARTYSCREEN_SendPartyInvite`|absent, or present under a different name|
|`0x005a60e0`|`D2Game::Player::PlayerScreen::PARTYSCREEN_SetHostileRelation`|absent, or present under a different name|
|`0x005b2f20`|`D2Game::Monster::Monster::Create::SpawnMonsterAtRoomPos`|absent, or present under a different name|
|`0x005e9df0`|`D2Game::Monster::AI::AI_Function1_UberDiablo`|Windows side is a 3-byte stub; Uber bosses are 1.11+ content|
|`0x005f78b0`|`D2Game::Monster::AI::AI_Function1_Mephisto`|absent, or present under a different name|
|`0x005f81c0`|`D2Game::Monster::AI::AI_Function1_UberMephisto`|Windows side is a 3-byte stub; Uber bosses are 1.11+ content|
|`0x005fd200`|`D2Game::Monster::AI::Baal::AI_Function1_UberBaal`|Windows side is a 3-byte stub; Uber bosses are 1.11+ content|
|`0x005ffd40`|`D2CMP::SpriteCache::GFX_InitCelDataCache`|absent, or present under a different name|
|`0x00609aa0`|`D2CMP::TileCmp::TILECMP_Generate25SubTiles`|absent, or present under a different name|
|`0x00619300`|`D2Common::DataTbls::DataTbls::TXT_InitTxtFiles`|absent, or present under a different name|
|`0x0061a070`|`D2Common::Dungeon::Dungeon::AddRoomData`|absent, or present under a different name|
|`0x0061a0c0`|`D2Common::Dungeon::Dungeon::RemoveRoomData`|absent, or present under a different name|
|`0x00633ee0`|`D2Common::DataTbls::ItemTbls::TXT_magicaffixes_GetLine`|absent, or present under a different name|
|`0x00636b20`|`D2Common::DataTbls::ItemTbls::TXT_QualityItems_GetLine`|absent, or present under a different name|
|`0x006414b0`|`D2Common::DataTbls::ObjectTbls::TXT_Shrines_GetLine`|absent, or present under a different name|
|`0x00642390`|`D2Common::Drlg::Drlg::DRLG_ApplyRoomExStateFlags`|absent, or present under a different name|
|`0x006447b0`|`D2Common::Skills::Skills::GetSkillLevelById`|absent, or present under a different name|
|`0x00645910`|`D2Common::Skills::Skills::SKILLS_HasLineOfSight`|absent, or present under a different name|
|`0x006556e0`|`D2Common::DataTbls::MonsterTbls::TXT_SuperUniques_GetLine`|absent, or present under a different name|
|`0x006667d0`|`D2Common::Drlg::Preset::DRLGPRESET_InitGridsFromDS1File`|absent, or present under a different name|
|`0x0066bc20`|`D2Common::Drlg::DrlgRoom::DefineRoomsNear`|absent, or present under a different name|
|`0x0066dde0`|`D2Common::Drlg::DRLGROOMTILE_FillTileData`|absent, or present under a different name|
|`0x0066e260`|`D2Common::Drlg::RoomTile::DRLGROOMTILE_SetupWarpTile`|absent, or present under a different name|

### Windows-only

|windows addr|windows name|why it has no Mac counterpart|
|-|-|-|
|`0x00403e90`|`Fog::File::lpTopLevelExceptionFilter`|Win32 `SetUnhandledExceptionFilter`; the Mac build uses `StormMac::CRASH_*` signal handlers|
|`0x004f5623`|`D2GFX_CreateWindow` (IN+13)|`call [FindWindowA]`; the multi-instance guard has no Mac equivalent|
|`0x004f585a`|`D2GFX_CreateWindow` (IN+24a)|inside the Win32 window-creation path|
|`0x004fa663`|`D2WinMain::MessagePump` (IN+d3)|Win32 `PeekMessage`/`DispatchMessage`; the Mac build pumps Carbon events|
|`0x005136f0`|`BINK_RenderVideoFrame`|Bink; the Mac build plays Smacker through `oglSmack.cpp`|
|`0x005137e0`|`BINK_PlayVideoFile`|Bink; same|
|`0x007c8ca8`|`hInstance`|`HINSTANCE`|
|`0x007c8cbc`|`hwndD2GFX_Window`|`HWND`|

## Structural risks

**A confirmed function gives you an entry point, not a patch site.** 48 of the 320 addresses are
mid-function: call sites to detour (`0x0052d011`), `jz` operands to repoint (`0x00601349`), imm32
fields to rewrite (`0x0052fe59` = the 300000 ms reap timeout, `0x0052b7bf` = the `push 0xfa0` game
port). No byte offset survives a different compiler. Even for the 62 confirmed hook-layer
addresses, every mid-function offset must be re-derived by disassembling the Mac function. That is
the bulk of `gamereap`, `gsport`, `nocompress`, `joindiag`, `headless` and `srvtrace`.

**The Windows server code maps into one Mac TU, but the join path does not survive.** The whole
`D2Game::Game::Server` cluster lands in `D2Game/Src/Game.cpp` at `0x001ab000`-`0x001af000`, and
`IsValidChecks`, `GAME_DestroyGame`, `ProcessClientMessage_System`, `HandleAnyIncomingPacket`,
`QSERVER_TickAllGames` and `QSERVER_DispatchAndCleanup` are all confirmed there. But `SrvJoinGame`
and `SrvJoinAct` land on 38-byte and 68-byte bodies against 448 and 211 on Windows. Those are
wrappers or tail-merged thunks, not the same code. The join path -- the single most important thing
d2gs hooks -- has a different shape in the Mac build.

**Fog is effectively a different library.** `Fog::Memory::{Alloc,Free,ReAlloc,FreeMemoryPool}` and
`Fog::SMem::SMemAlloc` are all unresolved or refuted, and `InitializePoolSystem`'s DB entry falls
inside `QServer.cpp`, which is impossible. `poolgrow`, `poolstat` and `memstat` -- everything that
pokes `pGlobalPoolSystem` -- start from zero. The seven-concurrent-game ceiling comes straight out
of the Fog pool-manager count, so this is not optional work.

**Everything client-side and drawing-related is a rewrite, not a port.** `D2GFX_*`, `D2WinMain`,
`RENDERER_DrawOutOfGameScene`, `BINK_*`, `IMAGE_LoadDC6Ex`: the Mac build renders through OpenGL
(`oglBlocks.cpp`, `oglSprite.cpp`, `COGLAGPTextures.cpp`, `CD2Textures.cpp`), TUs with no Windows
counterpart at all. The `headless` feature (24 addresses, all stubbing out drawing) cannot be
ported address-by-address; its Mac equivalents have to be found from scratch.

**The Mac binary is smaller.** 11,977 functions against 13,339 on Windows. Some of the 59 not-found
entries are genuinely absent rather than unnamed -- the Uber-boss AI stubs
(`AI_Function1_UberDiablo`/`UberMephisto`/`UberBaal`) are 3-byte returns on Windows and have no Mac
name at all, consistent with the Mac build predating 1.11 content.

**The Mac Ghidra database needs a cleanup pass before it can be trusted.** 35 of the 97 name
matches in the hook layer are demonstrably on the wrong function, and three more
(`CLIENT_ConnectToBattleNet`, `CLIENT_AdjustMemoryBudget`, `CompileTxt`) were caught only because
string fingerprints disagreed with the name. Roughly a third of the applied names are wrong.
Reading addresses out of that database without re-confirming them will silently hook the wrong
code.

## Corrections applied to the Mac database

Session `ce51a192` was repaired against the TU map. 39 names were changed. Nothing was renamed
without stated evidence; where the truth could not be established the name was made neutral rather
than left as a confident lie. Every changed function carries a PLATE comment recording why.

### Identified and renamed

|mac addr|was|now|evidence|
|-|-|-|-|
|`0x00034519`|`D2Common::Items::Items::ITEMS_FatalError`|`FOG_FatalError`|called by all 1,386 functions referencing the `"Unrecoverable internal error %08x line %d"` format string; body calls `MAC_DisplayFatalError` then the registered handler or `_ExitToShell`; sits in the StormMac region, not D2Common/ITEMS/Items.cpp|
|`0x002f40fb`|`Fog::Memory::InitializePoolSystem`|`QSERVER_ReleaseClientRef`|asserts `__FILE__` QServer.cpp lines 0x37b/0x3a7/0x3ae/0x940, inside the QServer.cpp core range; refcount decrement then unlink from the id hash, unlink from the per-source-IP hash, decrement the per-IP connection count, free the client|

### Neutralised (name refuted, true identity not established)

37 functions were renamed to `UNVERIFIED_<tu>_<addr>` or `UNVERIFIED_<addr>` and moved out of their
misleading namespaces. The full list is in the database; the QSERVER-path ones are:
`0x001ad04e` (was `SrvJoinGame`), `0x001adaba` (a duplicate `SrvJoinAct`), `0x001ad074` (was
`SERVER_GetClientFromGmeByClientId`), `0x00213930` (was `ProcessClientMessage_GameSetup`),
`0x001b4b24` (was `SendPacketToClient`), `0x00211eb0` (was `SERVER_DisconnectClient`),
`0x001e012d` (was `QSERVER_GenerateToken`), `0x0013b255` (was `QSERVER_FindAndLockGame`),
`0x0023cfdb` (was `SendPacket_Helper`), `0x002ec7c2` (was `ERROR_UnrecoverableInternalError_Halt`),
`0x002ef904` (was `SMemAlloc`), `0x002f33fa` (was `MessageGameLoop`).

The real handlers that these names were stolen from are, where known: `SrvJoinAct` = `0x001ac90e`,
`ProcessClientMessage_GameSetup` = `0x001a77bd` (the CCmd.cpp anchor), the assert halt =
`0x00034519`.

### Namespaces corrected

83 functions inside the `D2Client/GAME/SCmd.cpp` and `D2Client/SKILLS/Skills.cpp` core ranges were
filed under `D2Game` / `D2Common`. Their own leaf names say `NET_D2GS_CLIENT_*` and `SKILLS_Clt*`,
which corroborates the TU, so they were moved to `D2Client::Game::SCmd` and
`D2Client::Skills::Skills`. The whole client-side incoming-packet dispatch table had been reading
as server code.

### Measured error rates

|scope|decidable|wrong|rate|
|-|-|-|-|
|whole database, namespace TU vs actual TU|936|289|31%|
|QSERVER area, module vs actual TU module|63|7|11%|

The QSERVER area additionally has **15 duplicate leaf names** across 33 functions
(`EnterCriticalSection` x4, `LeaveCriticalSection` x3, `QSERVER_IsClientAllowedToJoin` x2,
`QSERVER_TickAllGames` x2, `NET_D2GS_CLIENT_ParseRecvBufferIntoPacketQueues` x2, and more).
Each duplicate guarantees at least one wrong name, so the true QSERVER-area error rate is well
above the 11% the module test can prove.

### One earlier verdict was itself wrong

`IMAGE_LoadDC6Ex` at `0x0005cf38` was listed as REFUTED because "Archive.cpp TU run is
002b6888-002b6e68". There are two Archive files: `D2Hell/SRC/Archive.cpp` (that range) and
`D2Client/CORE/ARCHIVE.CPP` (`0005cf38-0005d0c1`). The function is the first anchor of the latter
and asserts against it, so the name is correct. The row is now marked confirmed.
