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

- **The realm-side character lock is half done.** A character is now claimed in the shared
  store by the game it enters and released when the player leaves or the game ends, so it
  cannot be in **two games** at once -- enforced across instances, and refused upfront with a
  message instead of the silent loading-screen wait.
  What it does *not* yet stop is **two clients on one character in one game**: the claim is
  owned by the game, and re-taking a character the same game already holds is allowed on
  purpose, because that is what lets a client re-enter its own game after its previous session
  died. Scoping the owner to the session would close the double login and reopen that, so the
  two need separating before this is finished. The engine still refuses the second seat, so the
  outcome is correct -- it is the *message* that is still missing in that one case.
  There is also no client result code for "that character is already in a game"; the refusal
  currently borrows "Game is Full.", which is visible but untrue.
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
- **Redis is becoming the realm's centre, and the migration is partway.** Characters live
  there with Postgres behind them (a flush worker any instance runs moves them across), game
  tokens are minted there, the fleet publishes itself there, and game names are claimed there.
  Create and join dispatch still travel each game server's control socket, which is the one
  thing that still stops realmd running as more than a single replica. See
  [`docs/redis.md`](redis.md).
- **The native server hosts several games, but ships capped at one.** With `D2GS_MAX_GAMES`
  raised, about half of a round's games are admitted and the rest are refused cleanly -- no
  crashes, no evictions, and the games that run are correct. The shortfall is not yet
  understood, so the default keeps every game landing.
- Replace the fixed init delay with a proper engine-init hook.

## Related

- [`VERIFY.md`](../VERIFY.md) -- what has been cross-checked against the engine, and what is
  still assumed.
- [`docs/PERFORMANCE.md`](PERFORMANCE.md) -- measured footprint and the hard capacity ceiling.
