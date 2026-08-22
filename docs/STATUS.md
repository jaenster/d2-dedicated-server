# Status

What a real 1.14d client does against this today, and what it still cannot do. Unless a line
says otherwise, it is tested under wine on the unmodified retail `Game.exe`.

## Working

- Injection (`dbghelp` proxy -> `--loaddll` -> `DllMain`) + headless survival.
- Dedicated server boots, listens on `:4000`, ticks stably.
- `realmd`: real client logs in, passes the version check (BNFTP file integrity +
  CheckRevision), selects a realm, lists + loads characters.
- Create + join a game dispatched to the headless GS.
- **Character spawns in-world** (loaded from the store, full life/mana, playable).
- **Multiplayer**: two real clients in one game, visible to each other.
- **A full party**: eight characters entering one game together, repeatedly, in lockstep.
  A ninth is turned away with the engine's own answer rather than silence.
- **A fleet**: two game servers registered to one realm, games routed to the least loaded,
  each client spliced to the server that owns its game.
- **The whole game lifecycle, not just the first game.** One realm login, a character
  creating a game, playing, leaving, and making or re-entering the next -- which is what a
  client actually does all evening, and what a test that spawns a process per game cannot
  reach. 450 games across 25 rounds with three characters, clean, with resident memory and
  descriptor count flat.
- **A character is in one game at a time, and the realm says so.** The seat is claimed in the
  shared store, so it holds across realmd instances, and a second client bringing the same
  character is refused with the game that has it rather than left at a loading screen.
- **A second login cannot take a live session's place.** The character is refused and the
  session already in the world keeps playing; a character whose client died re-enters
  immediately.
- **More than one realm server.** Two realmd instances against one redis, a game created
  through one and joined through the other, both players in the world together. Nothing
  connects a realm server to a game server any more: servers publish themselves into redis,
  take create/join from a queue there, and report back on an event stream any instance drains.
  Everything durable is shared too -- an account created and flagged admin on one instance,
  read back from another that shares nothing but Postgres. See [`docs/redis.md`](redis.md).
- **Every pre-1.14 engine serves a world.** A second kind of game server, `apps/d2host`, drives the
  game's own `D2Game`/`D2Common` against our `Fog.dll` and `D2Net.dll` -- no injection, no
  `Game.exe`. All seven of 1.06b, 1.07, 1.08, 1.09b, 1.09d, 1.10f and 1.13c take a real client's
  join, load its character and stream it a world. A stock 1.14d client stands in the Rogue
  Encampment on 1.10f and on 1.13c. The gate is `deploy/e2e-engines.txt` + `tools/e2e-engines.sh`,
  run in CI on every engine, so an engine that stops serving is a hard failure rather than something
  noticed weeks later. See [`docs/dll-host.md`](dll-host.md).
- **A game server with no wine at all.** 1.14d's macOS i386 build, mapped and run directly on
  i386 Linux, serving real clients through the same realm and gateway: one process in a 4.4 MB
  image, and on real amd64 hardware as fast as the wine server. It meets the realm through redis
  exactly as the wine server does, so a fleet can mix both. See
  [`native-vs-wine.md`](native-vs-wine.md).

## Rough edges / next

- Password-protected games are untested end to end.
- Verbose join diagnostics compiled in by default; `pkttrace` gated.
- Two headed clients in one wineprefix can trip the bnet gateway-list parser on the second
  client's startup (intermittent); the e2e test retries.
- A brand-new game has no players, so it is indistinguishable from an abandoned one and the
  reap countdown starts immediately. At the 5s default the client always wins that race, but
  it is why the window cannot simply be shortened to buy throughput -- the countdown needs to
  start at the first join, not at creation.
- Least-loaded routing breaks ties toward whichever server the set enumerates first, so with
  equal load one server takes the work until its count rises.
- **The native server hosts several games, but ships capped at one.** With `D2GS_MAX_GAMES`
  raised, about half of a round's games are admitted and the rest are refused cleanly -- no
  crashes, no evictions, and the games that run are correct. The shortfall is not yet
  understood, so the default keeps every game landing.
- Replace the fixed init delay with a proper engine-init hook.
- **A pre-1.14 game does not write the character back yet.** `close_game` / `leave_game` are
  reporting stubs in `apps/d2host`, so a character that played on one of those engines is not saved
  to the realm the way the 1.14d server saves it.
- 1.13c sends opcode `0xB4`, which the 1.14d client world-model does not carry, so the clientless
  parses 2 of 3 packets on that engine. A model gap on the client side, not a server one.

## Related

- [`VERIFY.md`](../VERIFY.md) -- what has been cross-checked against the engine, and what is
  still assumed.
- [`docs/PERFORMANCE.md`](PERFORMANCE.md) -- measured footprint and the hard capacity ceiling.
