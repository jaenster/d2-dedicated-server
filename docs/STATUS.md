# Status

What a real 1.14d client does against this today, and what it still cannot do. Unless a line
says otherwise, it is tested under wine on the unmodified retail `Game.exe`.

## Working

- Injection (`dbghelp` proxy -> `--loaddll` -> `DllMain`) + headless survival.
- Dedicated server boots, listens on `:4000`, ticks stably.
- `realmd`: real client logs in, passes the version check (BNFTP file integrity +
  CheckRevision), selects a realm, lists + loads characters.
- Create + join a game dispatched to the headless GS.
- **Character spawns in-world** (loaded from d2dbs, full life/mana, playable).
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
- **A second login cannot take a live session's place.** The character is refused and the
  session already in the world keeps playing; a character whose client died re-enters
  immediately.
- **A game server with no wine at all.** 1.14d's macOS i386 build, mapped and run directly on
  i386 Linux, serving real clients through the same realm and gateway: one process in a 4.4 MB
  image, and on real amd64 hardware as fast as the wine server. See
  [`native-vs-wine.md`](native-vs-wine.md).

## Rough edges / next

- **The realm-side character lock is not implemented.** The engine's callback table has
  `fpUnlockDatabaseCharacter` and `fpRelockDatabaseCharacter`; Blizzard's realm held a
  character while it was in a game and refused the second join upstream. Ours issues the
  join, and the game server then refuses it -- correctly, but through a path that answers
  nothing, so a double login sits at the loading screen until the client gives up instead of
  being told. Refusing from realmd's own roster is the wrong fix: that roster is fed by the
  game server, and one stale entry would lock a player out of their own character.
- Password-protected games are untested end to end.
- Verbose join diagnostics compiled in by default; `pkttrace` gated.
- Two headed clients in one wineprefix can trip the bnet gateway-list parser on the second
  client's startup (intermittent); the e2e test retries.
- A brand-new game has no players, so it is indistinguishable from an abandoned one and the
  reap countdown starts immediately. At the 5s default the client always wins that race, but
  it is why the window cannot simply be shortened to buy throughput -- the countdown needs to
  start at the first join, not at creation.
- Least-loaded routing breaks ties toward the first registered server, so with equal load one
  server takes the work until its count rises.
- **The native server hosts several games, but ships capped at one.** With `D2GS_MAX_GAMES`
  raised, about half of a round's games are admitted and the rest are refused cleanly -- no
  crashes, no evictions, and the games that run are correct. The shortfall is not yet
  understood, so the default keeps every game landing.
- Replace the fixed init delay with a proper engine-init hook.

## Related

- [`VERIFY.md`](../VERIFY.md) -- what has been cross-checked against the engine, and what is
  still assumed.
- [`docs/PERFORMANCE.md`](PERFORMANCE.md) -- measured footprint and the hard capacity ceiling.
