# Injection and modding

How our code gets inside `Game.exe`, and how you add your own behaviour once it is there.

## How injection works

```
Game.exe --(loads)--> dbghelp.dll (our proxy) --(--loaddll)--> d2gs.dll [+ your mod DLLs]
                                                                  |
                                                DllMain spawns serverThread:
                                                  bootstrapRealmServer() + realm callbacks
                                                  loop: HandleAnyIncomingPacket
                                                        + TickAllGames + DispatchAndCleanup
```

- **Delivery:** `Game.exe` loads `dbghelp.dll` for its crash handler. Our proxy forwards the
  real exports and `LoadLibrary`s the DLLs passed via `--loaddll <winpath>` -- that's how
  `d2gs.dll` gets in. No on-disk patch of `Game.exe`.
- **Headless:** `--headless` byte-patches stub the renderers/media loaders and hide the window
  so the host survives with no display.
- **Server tick:** mirrors the engine's own `QSERVER_CoopThreadMain`: drain inbound packets,
  tick all games, then **flush queued outbound packets** (the `DispatchAndCleanup` step is what
  makes a joining client actually progress).

## The feature framework

`d2gs.dll` has a small extensibility surface (`apps/d2gs/engine/feature.zig`). A **feature is just a
Zig module** (a namespace) that opts into a hook by declaring a `pub fn` of that name -- no base
class, no vtable. Dispatch is a comptime `inline for` over a single registry table that calls a
hook only on the features that declare it. Features stay pure behaviour; all config (name,
toggle flag, default state) lives in that **one registry table**.

Hooks a feature can declare include lifecycle (`install`, `postInit`, `deinit`), client frame
loops (`gameFrame`, `oogFrame`), and the dedicated-server domain (`serverTick`, `gameCreate` /
`gameDestroy`, `roomInit`, `expAward` to transform XP, `packetIn` / `packetOut`, `playerJoin` /
`playerLeave`). Each gets a per-game context whose allocator **is the game's own memory pool**,
so anything a feature allocates dies with the game.

Copy [`apps/d2gs/runtime/feature/template.zig`](../apps/d2gs/runtime/feature/template.zig), add one line to
the registry, done.

## Shipped features

See [`apps/d2gs/runtime/feature/`](../apps/d2gs/runtime/feature/): `expmod` (XP scaling), `ubers`
(Pandemonium / Uber Tristram), `arena` (server-side PvP rounds), `ladder-items`, `guild-panel`, and
client-side maphack (`omnivision`, `mapunits`, `mapreveal`) -- the same DLL injects into a real client too. Each is
toggled by its own `--<flag>`; see [`docs/FLAGS.md`](FLAGS.md).

## Native mods of your own

For mods that need their own native code, the proxy loads **any** DLL you pass with
`--loaddll`, repeatable -- each runs in-process with full access to the engine at its fixed
addresses (image base `0x00400000`, no ASLR):

```
wine Game.exe ... --loaddll Z:\path\d2gs.dll --loaddll Z:\path\yourmod.dll --d2gs ...
```

In the **container**, drop mod DLLs in `/mods` (each `--loaddll`'d after `d2gs.dll`) or list
them in `D2GS_EXTRA_DLLS`; overlay extra **data** (mod MPQs, or a loose `data/` tree with
`D2GS_EXTRA_ARGS="-direct -txt"`) by mounting it at `/moddata`.

## Related

- [`apps/d2gs/engine/README.md`](../apps/d2gs/engine/README.md) -- bindings into the engine and the realm
  callback table.
- [`apps/d2gs/runtime/README.md`](../apps/d2gs/runtime/README.md) -- byte-patches, hooks, fastcall shims,
  drivers.
