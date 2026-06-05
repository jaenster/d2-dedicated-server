# d2-dedicated-server — Diablo II 1.14d as a headless dedicated game server

> ⚠️ **Work in progress.** The server boots and listens, but the realm callback
> layer (so a character/realm server can actually create & join games) is still
> being implemented. See [Status](#status) for what works today.

Turns the single-binary Diablo II 1.14d `Game.exe` into a dedicated game server,
the way older versions do with the split DLLs — except in 1.14d the whole server
engine (`Fog::QServer` + `D2Game::Game::Server`) is statically linked inside
`Game.exe`. We don't reimplement it; we **drive the real engine** from an injected
Zig DLL.

Built for **Linux deployment**: it runs the Windows `Game.exe` under wine,
fully headless — no GUI, no X, no display. Logs stream to **stdout** like a
normal Linux daemon (so `docker logs` / journald / your terminal just work).

## How it works

```
Game.exe  --(loads)-->  dbghelp.dll (our proxy)  --(--loaddll)-->  d2gs.dll  [+ your mod DLLs]
                                                                       |
                                                     DllMain spawns serverThread:
                                                       QSERVER_CreateAndInit(SERVER, BNET)
                                                       loop: HandleAnyIncomingPacket + TickAllGames
```

- **Delivery:** `Game.exe` loads `dbghelp.dll` for its crash handler. Our
  `dbghelp.dll` proxy forwards the real exports and `LoadLibrary`s the DLLs passed
  via `--loaddll <winpath>` — that's how `d2gs.dll` gets in. No on-disk patch of
  `Game.exe`.
- **Headless:** `--headless` applies byte-patches (`src/runtime/headless.zig`)
  that stub the renderers/media loaders and hide the window, so the host survives
  with no display and the server thread can run.
- **Game creation:** `CONNECTIONTYPE_SERVER` + `GAMETYPE_BNET` = the realm,
  token-driven path. Listens on **:4000** and speaks the classic D2GS↔D2CS/D2DBS
  protocol — the goal is to slot in behind **PvPGN** (its D2CS/D2DBS) so it
  fetches characters, validates join tokens, and players actually enter games
  (see [`REALM.md`](REALM.md)).

## Loading mods / server modifications

The proxy loads **any** DLL you pass with `--loaddll`, repeatable. So a server
mod is just another injected DLL that hooks/patches the engine in its `DllMain`:

```
wine Game.exe ... --loaddll Z:\path\d2gs.dll --loaddll Z:\path\yourmod.dll --d2gs ...
```

Each mod runs in-process with full access to the engine at its fixed addresses
(image base `0x00400000`, no ASLR). `d2gs.dll` itself is just the first such DLL.

## Build

```
zig build            # -> zig-out/bin/{dbghelp.dll, d2gs.dll}  (x86-windows-gnu)
```

## Game files

This repo ships **no game data** — you bring your own legit Diablo II 1.14d.
Either point `D2GS_GAME_SRC` at your full install, or build a slim test dir from
your own copy:

```
D2_INSTALL="/path/to/Diablo II" tools/make-minimal.sh   # -> ./testgame-min
```

`make-minimal.sh` copies the real files (`Game.exe`, `d2data.mpq`, `d2exp.mpq`,
`Patch_D2.mpq`, DLLs) from *your* install and fills the unused media archives
with empty stub MPQs. See [`LEGAL.md`](LEGAL.md).

## Run

Set `D2GS_GAME_SRC` (a D2 install with `d2data.mpq`) in your environment or a
local `.env` (see `.env.example`), then:

```
./run.sh           # inject + log (proves injection)
./run.sh --boot    # also run the engine bootstrap + tick loop (open mode)
./run.sh --realm   # bootstrap in realm mode (IsBattleNetServer=1)
```

`run.sh` builds both DLLs, assembles a test dir, and runs in the foreground
streaming logs to your terminal. `dbghelp.dll` defaults to the one we build
(`D2GS_DBGHELP` overrides it).

## Flags (passed to Game.exe, read by our DLLs)

| flag | effect |
|-|-|
| `--loaddll <path>` | (proxy) LoadLibrary an injected DLL; repeatable |
| `--d2gs` | attach + log (safe; proves injection) |
| `--headless` | apply survival/no-display patches |
| `--d2gs-boot` | run the engine bootstrap + tick loop |
| `--realm` | bootstrap in realm mode (registers the realm callback table) |

## Layout

```
src/
  dbghelp.zig          dbghelp.dll proxy — injection foothold (--loaddll loader)
  d2gs.zig             d2gs.dll entry — DllMain, flags, server thread + tick loop
  log.zig              logger (stdout + file)
  engine/              bindings into Game.exe's own code
    server.zig           QSERVER/D2Game bindings + bootstrapRealmServer()
    realm.zig            realm (D2CS/D2DBS) callback table
  runtime/             our in-process machinery
    headless.zig         headless survival byte-patches
    patch.zig            VirtualProtect byte-patch util
    fastcall.zig         naked-asm shim generator for engine __fastcall callbacks
```

Docs: [`REALM.md`](REALM.md) (realm protocol), [`VERIFY.md`](VERIFY.md) (RE log),
[`LEGAL.md`](LEGAL.md).

## Status

**Working** (tested under wine on the unmodified retail 1.14d `Game.exe`):
- ✅ Injection: `dbghelp` proxy → `--loaddll d2gs.dll` → `DllMain`.
- ✅ Headless: host survives with no display.
- ✅ Bootstrap: `bootstrapRealmServer()` → **listens on `:4000`** and ticks; stays alive.
- ✅ Realm mode (`IsBattleNetServer=1`) and stdout logging.

**In progress — goal: full PvPGN integration:**
- ⏳ Realm callback table (`fpFindPlayerToken`, `fpGetDatabaseCharacter`, …) — the
  bridge to **PvPGN** (D2CS/D2DBS) so it fetches characters, validates join
  tokens, and players actually enter games. The `__fastcall` shim plumbing is
  done; the handlers + on-wire D2CS/D2DBS framing are being filled in (`REALM.md`).
- ⏳ Replace the fixed init delay with a proper engine-init hook.

## License & legal

Code: [MIT](LICENSE). No Blizzard game files are distributed here — bring your
own legit copy of Diablo II. Unofficial, not affiliated with Blizzard. See
[`LEGAL.md`](LEGAL.md).
