# src/engine — bindings into Game.exe's own engine

These call the **real engine code** statically linked inside 1.14d `Game.exe` at
its fixed absolute addresses (image base `0x00400000`, no ASLR; rebased
defensively off the actual module base). Source of truth is the ghidra-mcp
reconstruction of retail `Game.exe`.

## Files

- `server.zig` — the dedicated-server bindings + bootstrap.
  - `bootstrapRealmServer(table)` — mirrors `NET_QServer_StartServer`'s host tail
    minus host-as-player-1, plus `SetupAsBnetServer`: `QSERVER_CreateAndInit(SERVER,
    BNET)` → players count → set global game-state → `QSERVER_InitializeServerState`.
  - `tick()` — one server tick: `HandleAnyIncomingPacket` (recv) →
    `QSERVER_TickAllGames` → **`QSERVER_DispatchAndCleanup`** (the per-frame
    outbound flush — without it queued packets never reach the socket and a
    joining client times out). Mirrors `QSERVER_CooperativeThreadMain`.
  - `GAME_CreateBattleNetGame`, `gameFlags()` — game creation; `eD2ArenaFlags`
    bits are exact (`ClientUpdate=0x04`, `Hardcore=0x800`, `Expansion=0x100000` —
    the expansion bit must be right or an expansion char is refused with `0x18`).
  - `BnetServerService` — the 25-slot `D2BattleNetEventCallbackTable` struct +
    `SetupAsBnetServer`, and the verified engine globals.
- `realm.zig` — the realm callback **table we register**. Slots are `__fastcall`
  (register args + callee cleanup), implemented as naked-asm shims (see
  [`../runtime/fastcall.zig`](../runtime)). Implemented so far:
  - `fpFindPlayerToken` (0x18) — validate the join token (engine `IsBadCodePtr`-checks it).
  - `fpGetDatabaseCharacter` (0x08) — resolve the account (via `joinctx`), fetch
    the `.d2s` from d2dbs, and deliver it (deferred to the tick loop via
    `pumpDelivery` → `CLIENT_OnDatabaseCharacterReceived`).
  - `fpLeaveGame` (0x04) — stack-balancing no-op (CleanUpClient halts on a null here).
  - `fpGetDatabaseFileTime` (0x54) — zeroed-filetime stub (CalculateGetFlags calls
    it unguarded; a null pointer is a call-to-zero crash).
- `command.zig` — serializes engine calls (create game, char delivery) onto the
  tick thread; calling the engine from the network thread races it.

## Gotchas

- Realm callbacks are `__fastcall`, NOT cdecl/stdcall — a wrong shim corrupts the
  stack. The engine null-guards most (but not all) slots with `IsBadCodePtr`.
- Engine-internal logging (`SRVLog`) is a compiled-out no-op in retail, so join
  tracing is done with our own hooks (see `../runtime/joindiag.zig`, `pkttrace.zig`).
