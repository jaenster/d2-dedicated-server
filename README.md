# d2-dedicated-server — Diablo II 1.14d as a headless dedicated game server + realm

Turns the single-binary Diablo II 1.14d `Game.exe` into a **dedicated game server**,
the way older versions do with the split DLLs — except in 1.14d the whole server
engine (`Fog::QServer` + `D2Game::Game::Server`) is statically linked inside
`Game.exe`. We don't reimplement it; we **drive the real engine** from an injected
Zig DLL. The repo also ships a clean-room **realm server** (`realmd`) that replaces
PvPGN, so the unmodified retail client can log in and play end to end.

> **Status: a real 1.14d client logs into the realm, creates/joins a game on the
> headless server, and the character spawns in-world — including two clients in
> the same game (multiplayer).** See [Status](#status).

Built for **Linux deployment**: the Windows `Game.exe` runs under wine, fully
headless — no GUI, no X, no display. Logs stream to **stdout** like a normal
daemon (`docker logs` / journald / your terminal just work). `realmd` is a native
binary (no wine).

## The pieces

```
          unmodified 1.14d client (GUI)
                     |  BNCS / MCP / BNFTP
                     v
   ┌─────────────────────────────────┐      gs-link (6115)     ┌──────────────────────┐
   │  realmd  (native Zig binary)     │ <───────────────────── │  headless Game.exe   │
   │  bnetd 6112  login + version MPQ │                        │  + d2gs.dll (injected)│
   │  d2cs  6113  realm / create-join │   char save (d2dbs)    │  drives QServer/D2Game│
   │  d2dbs 6114  character saves     │ <───────────────────── │  listens on :4000     │
   │  gslink 6115 GS dispatch         │                        └──────────────────────┘
   └─────────────────────────────────┘                                   ^
                     ^                                                    │ game traffic (:4000)
                     └────────────────── the client connects directly ───┘
```

- **realm server** (`src/realmd/`, native): one binary replacing pvpgn's
  bnetd + d2cs + d2dbs, plus a GS-link the injected server connects to. File-backed
  state survives restarts; multi-instance over a shared dir. See
  [`src/realmd/README.md`](src/realmd/README.md).
- **game server** (`src/d2gs.zig` + `src/engine/` + `src/realm/`): the injected DLL
  that boots `Game.exe` as a headless dedicated server and bridges it to realmd via
  the engine's realm callback table. See [`src/engine/README.md`](src/engine/README.md).

## How injection works

```
Game.exe --(loads)--> dbghelp.dll (our proxy) --(--loaddll)--> d2gs.dll [+ your mod DLLs]
                                                                  |
                                                DllMain spawns serverThread:
                                                  bootstrapRealmServer() + realm callbacks
                                                  loop: HandleAnyIncomingPacket
                                                        + TickAllGames + DispatchAndCleanup
```

- **Delivery:** `Game.exe` loads `dbghelp.dll` for its crash handler. Our proxy
  forwards the real exports and `LoadLibrary`s the DLLs passed via
  `--loaddll <winpath>` — that's how `d2gs.dll` gets in. No on-disk patch of `Game.exe`.
- **Headless:** `--headless` byte-patches (`src/runtime/headless.zig`) stub the
  renderers/media loaders and hide the window so the host survives with no display.
- **Server tick:** mirrors the engine's own `QSERVER_CoopThreadMain` — drain inbound
  packets, tick all games, then **flush queued outbound packets** (the
  `DispatchAndCleanup` step is what makes a joining client actually progress).

## Loading mods / server modifications

The proxy loads **any** DLL you pass with `--loaddll`, repeatable. A server mod is
just another injected DLL that hooks/patches the engine in its `DllMain`:

```
wine Game.exe ... --loaddll Z:\path\d2gs.dll --loaddll Z:\path\yourmod.dll --d2gs ...
```

Each runs in-process with full access to the engine at its fixed addresses (image
base `0x00400000`, no ASLR). `d2gs.dll` is just the first such DLL.

## Build

```
zig build     # -> zig-out/bin/{dbghelp.dll, d2gs.dll, ver-IX86-1.dll}  (x86-windows)
              #    + zig-out/bin/realmd  (native host binary)
```

## Run the full stack

```
# 1) realm server (native; data dir holds accounts/chars/games)
REALMD_DATA_DIR=./realmd-data ./zig-out/bin/realmd

# 2) headless game server (wine), registers with realmd's gs-link
wine Game.exe -w -nosound --headless --loaddll Z:\...\d2gs.dll \
    --d2gs --d2gs-boot --realm --create-games \
    --d2cs 127.0.0.1:6115 --d2dbs 127.0.0.1:6114

# 3) a real client (point its bnet gateway at realmd, then log in normally)
wine Game.exe -w -skiptobnet --loaddll Z:\...\d2gs.dll --d2gs --bypass-checkrev
```

`./run.sh` builds the DLLs and assembles a wine test dir for the injection-only
case. The full create+join flow has an end-to-end test:
[`tools/realmd-test/e2e-game.sh`](tools/realmd-test/e2e-game.sh) (boots realmd + GS,
drives two clients to create + join, asserts both characters loaded; needs wine +
a real 1.14d install via `E2E_GAME_SRC`).

## Flags (passed to Game.exe, read by our DLLs)

| flag | effect |
|-|-|
| `--loaddll <path>` | (proxy) LoadLibrary an injected DLL; repeatable |
| `--d2gs` | attach + log; install crash/halt/multi-instance guards |
| `--headless` | apply survival/no-display patches |
| `--d2gs-boot` | run the engine bootstrap + tick loop (the dedicated server) |
| `--realm` | bootstrap in realm mode (register the realm callback table) |
| `--create-games` | load data tables so the engine can create games |
| `--d2cs <ip:port>` | connect to realmd's gs-link for create/join dispatch |
| `--d2dbs <ip:port>` | fetch character saves from realmd's d2dbs |
| `--bypass-checkrev` | (client) skip the bnet version check |
| `--screenshot` | (client) take a screenshot every 3s (headed debugging) |
| `--auto-login <acct:pass>` | (client) drive login → char select → create a game |
| `--auto-join <acct:pass:game>` | (client) drive login → char select → join a game |
| `--pkttrace` | log every `:4000` client↔GS packet id (verbose) |
| `--suppress-halts` | swallow engine asserts instead of exiting (debugging) |

## Layout

```
src/
  dbghelp.zig    dbghelp.dll proxy — injection foothold (--loaddll loader)
  d2gs.zig       d2gs.dll entry — DllMain, flag parsing, server thread + tick loop
  log.zig        logger (stdout + file)
  realmd/        the realm server (bnetd + d2cs + d2dbs + gs-link)   [README]
  engine/        bindings into Game.exe's own engine + realm callback table [README]
  realm/         GS-side of the realm link (d2cs/d2dbs clients, join context) [README]
  runtime/       in-process machinery: byte-patches, hooks, fastcall, diagnostics [README]
  test/          client-driving test harnesses (auto-login/join, screenshots) [README]
  checkrev/      CheckRevision.dll producer for the version-check MPQ          [README]
tools/realmd-test/  protocol smoke tests + the full create/join e2e test
```

Each `src/*` directory has its own `README.md`. Other docs:
[`REALM.md`](REALM.md), [`VERIFY.md`](VERIFY.md), [`LEGAL.md`](LEGAL.md).

## Status

**Working** (tested under wine on the unmodified retail 1.14d `Game.exe`):
- ✅ Injection (`dbghelp` proxy → `--loaddll` → `DllMain`) + headless survival.
- ✅ Dedicated server boots, listens on `:4000`, ticks stably.
- ✅ `realmd`: real client logs in, passes the version check (BNFTP MPQ +
  CheckRevision), selects a realm, lists + loads characters.
- ✅ Create + join a game dispatched to the headless GS.
- ✅ **Character spawns in-world** (loaded from d2dbs, full life/mana, playable).
- ✅ **Multiplayer** — two real clients in one game, visible to each other.

**Rough edges / next:**
- ⏳ Verbose join diagnostics (`joindiag`) compiled in by default; `pkttrace` gated.
- ⏳ Two headed clients in one wineprefix can trip the bnet gateway-list parser on
  the second client's startup (intermittent); the e2e test retries.
- ⏳ Harden across restarts + many concurrent games; replace the fixed init delay
  with a proper engine-init hook.

## License & legal

Code: [MIT](LICENSE). No Blizzard game files are distributed here — bring your own
legit copy of Diablo II. Unofficial, not affiliated with Blizzard. See
[`LEGAL.md`](LEGAL.md).
