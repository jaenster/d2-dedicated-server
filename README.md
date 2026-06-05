# d2gs — 1.14d as a headless dedicated game server

Turns the single-binary Diablo II 1.14d `Game.exe` into a dedicated game server,
the way older versions do with the split DLLs — except in 1.14d the whole server
engine (`Fog::QServer` + `D2Game::Game::Server`) is statically linked inside
`Game.exe`. We don't reimplement it; we **drive the real engine** from an injected
Zig DLL.

## How it works

```
Game.exe  --(loads)-->  dbghelp.dll (proxy)  --(LoadLibrary)-->  d2gs.dll
                                                                     |
                                                   DllMain spawns serverThread:
                                                     QSERVER_CreateAndInit(SERVER, BNET)
                                                     loop: HandleAnyIncomingPacket + TickAllGames
```

- **Delivery:** `Game.exe` loads `dbghelp.dll` (for crash dumps). A `dbghelp.dll`
  proxy that forwards the real exports and `LoadLibrary`s the DLLs passed via
  `-loaddll <winpath>` injects `d2gs.dll` — no on-disk patch of `Game.exe`.
- **Headless:** `--headless` applies byte-patches (`src/headless.zig`) that stub
  the renderers/media loaders and hide the window, so the host survives with no
  display and the server thread can run.
- **Game creation:** `CONNECTIONTYPE_SERVER` + `GAMETYPE_BNET` = the realm,
  token-driven path. Listens on **:4000** and lets a realm/character server feed
  create-game tokens (see `REALM.md`).

## Build

```
zig build            # -> zig-out/bin/d2gs.dll  (x86-windows-gnu)
```

## Run

Set `D2GS_GAME_SRC` (a D2 install with `d2data.mpq`) and `D2GS_DBGHELP` (a
dbghelp proxy) — in your environment or a local `.env` (see `.env.example`) — then:

```
./run.sh           # inject + log (proves injection)
./run.sh --boot    # also run the engine bootstrap + tick loop (open mode)
./run.sh --realm   # bootstrap in realm mode (IsBattleNetServer=1)
```

Under the hood: `Game.exe -w -nosound --headless -loaddll <d2gs.dll> --d2gs [...]`.

## Flags (passed to Game.exe, read by d2gs.dll)

| flag | effect |
|-|-|
| `--d2gs` | attach + log (safe; proves injection) |
| `--headless` | apply survival/no-display patches |
| `--d2gs-boot` | run the engine bootstrap + tick loop |
| `--realm` | bootstrap in realm mode (registers the realm callback table) |

## Layout

| file | role |
|-|-|
| `src/main.zig` | DllMain, flag handling, server thread + tick loop |
| `src/d2_server.zig` | typed bindings into the engine + `bootstrapRealmServer()` |
| `src/realm.zig` | realm (D2CS/D2DBS) callback table |
| `src/fastcall.zig` | naked-asm shim generator for engine-called `__fastcall` callbacks |
| `src/headless.zig` + `src/patch.zig` | headless survival byte-patches |
| `src/log.zig` | file logger |
| `REALM.md` | realm protocol notes |
| `VERIFY.md` | reverse-engineering verification log |

## Status

A working proof of concept: inject → headless → boot the built-in QServer in
dedicated mode → listen on `:4000` and tick, on the unmodified retail 1.14d
`Game.exe`. Realm mode enables the callback path; the callback table is being
filled in (see `REALM.md`).
