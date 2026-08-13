# Realm communications (D2CS / D2DBS bridge)

How the dedicated GS talks to the realm  -  identical model to the 1.13
D2GS<->D2CS<->D2DBS, just that the "host" calling into the GS is now our Zig DLL.

## The bridge: `D2BattleNetEventCallbackTable`
The GS calls back into a 25-slot vtable to reach the realm/database. We implement
the slots we need and register the table:

```
SetupAsBnetServer(&table)   // @0x0052c0e0 -> BattleNetServerService = &table; IsBattleNetServer = 1
```

Until registered, `BattleNetServerService == null` and the realm system-message
path no-ops (why the POC listened on :4000 but did nothing realm-side).

Key slots (offset -> role):
| off | slot | role |
|-|-|-|
| 0x00 | fpCloseGame | game closed -> tell realm |
| 0x04 | fpLeaveGame | player left |
| 0x08 | fpGetDatabaseCharacter | load char save from DB (-> D2DBS) |
| 0x0C | fpSaveDatabaseCharacter | persist char save |
| 0x10 | fpServerLogMessage | logging |
| 0x14 | fpEnterGame | player entered |
| 0x18 | fpFindPlayerToken | validate the game token D2CS issued, on join |
| 0x20 / 0x38 | fpUnlock/RelockDatabaseCharacter | char lock (anti-dupe across servers) |
| 0x28 | fpUpdateCharacterLadder | ladder |
| 0x2C | fpUpdateGameInformation | game list/status -> realm |
| 0x34 | fpSetGameData | game data |
| 0x3C | fpLoadComplete | char load done |
| 0x54 | fpGetDatabaseFileTime | char timestamp (save-conflict resolution) |

`fpGetDatabaseCharacter` signature (from header):
`void (*)(D2ClientStrc* client, LPCSTR charName, DWORD clientId, LPCSTR accountName)`

## On-wire system protocol (GS side)
`NET_D2GS_SERVER_ProcessClientMessage_System` @0x0052cc20 dispatches `0xFF`-prefixed
control packets by subtype `pBytes[5]`: `0x01`, `0xFD`, `0xFA`, `0xFB`, `0xFC`
(client id at `pBytes[0]`). Replies via `NET_D2GS_SERVER_SendPacketToClient(2, ...)`.
Builds `D2PacketD2GS_SC_0xFF01`. All gated on `BattleNetServerService != null`.

## Token flow (GS side)
- `QSERVER_GenerateToken()` @0x0052c170  -  next free token, range 1..0x400.
- `QSERVER_PutNewGameOnTokenList(gameServerId, token)` @0x0052c110  -  bind token->game.
- `SERVER_IsTokenValid(token)` @0x0052c060 (__fastcall)  -  look up game by token.
- `DATA_LastGameServer[token]` table guarded by crit-sec `0x00882d18`.

D2CS issues a token to a client + tells it the GS ip:4000; client connects with
the token; GS resolves it via `fpFindPlayerToken` / the token table -> join/create
game (`NET_D2GS_SERVER_SrvJoinGame` @... -> `GAME_CreateBattleNetGame` @0x00530930).

## WARNING: Calling convention  -  confirmed `__fastcall`
Disassembly of the real retail Game.exe call sites (capstone)
shows the realm callbacks are **`__fastcall`-family (register args in ECX/EDX),
NOT cdecl/stdcall**. A naive stdcall stub would corrupt the stack  -  which is why
the all-null table (engine null-guards each slot) was the correct safe state.

`BattleNetServerService` global @ **0x00883d50** (the table pointer
SetupAsBnetServer writes; distinct from gpQServerGameState @0x00883d38).

### `fpFindPlayerToken` (slot 0x18)  -  exact shape
Call site `NET_D2GS_SERVER_IsValidChecks @0x0052c787`:
```
mov eax,[0x883d50]; mov eax,[eax+0x18]   ; load fp
... 7x push ...                          ; 7 stack args (R->L)
mov edx,[ebp+0x10]                       ; EDX = arg2
mov ecx, esi                             ; ECX = arg1
call eax
```
-> **`__fastcall`, args: ECX, EDX, + 7 stack = 9 total, callee-cleanup `ret 0x1c`.**
Returns int (nonzero = token valid; 0 -> join rejected). The Ghidra/recon decompile
under-counted this as 7 args  -  trust the disasm. Implement with a fastcall shim
that pops 0x1c, returns nonzero, and fills the out-param pointers.

Method to get the rest: targeted capstone disasm of each call site (linear sweep
of .text desyncs  -  disassemble per known caller function instead).

### Shim generator  -  `apps/d2gs/runtime/fastcall.zig`
`fastcall.Callback2(n_stack, impl)` generates a `callconv(.naked)` shim that
adapts the engine's fastcall ABI (ECX, EDX + n_stack stack args) to a plain cdecl
handler `fn (ecx, edx, s1..sN) callconv(.c) T`, with correct `add esp,(N+2)*4` +
`ret N*4`. Verified at the machine-code level for N=7 (the 2-fastcall + 7-stack
case) byte-for-byte. `realm.zig` stages `findPlayerTokenImpl` + its shim, and
`populate()` calls `enableTokenValidation()` to register it before `SetupAsBnetServer`
(the engine `IsBadCodePtr`-checks the slot).

## Status
The callback table is implemented and registered: `realm.zig` populates the slots
(`fpGetDatabaseCharacter`, `fpSaveDatabaseCharacter`, `fpFindPlayerToken`, ...) and calls
`SetupAsBnetServer(&table)` during bootstrap. The realm path is live end to end -- a real
client logs in, creates/joins a game on the headless GS, and the character loads from
d2dbs and spawns in-world (see the top-level README Status).

Remaining refinement, not blockers:
- Tighten `fpFindPlayerToken` validation against D2CS (currently accepts the engine's
  token-table lookup).
- The `0xFF` control subtypes + the realmd<->GS framing are decoded enough for create/join;
  see `packages/realm-proto/` for the wire contract both ends import.
