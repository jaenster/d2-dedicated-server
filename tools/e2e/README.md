# Clientless E2E test harness for `realmd`

A pure-Zig, wire-protocol end-to-end test harness for the `realmd` realm
server. It speaks the raw BNCS / MCP / d2dbs / gs-link framings directly over
TCP — **no wine, no `Game.exe`**. Scenarios are assertion-rich and named.

## Files

- `realmclient.zig` — reusable clients:
  - `RealmClient` — full bnetd handshake (`auth`, `login`, `enterRealm`) then
    d2cs (`connectD2cs`, `startup`, `charList`, `createGame`, `joinGame`).
    `charList()` decodes each statstring into `{name, class_id, level, flags}`.
  - `d2dbsSave(acct, char, d2s)` — character-save store (SAVE_DATA 0x30).
- `fakegs.zig` — `FakeGS`: a background-thread stand-in game server that
  registers over the gs-link (AUTHREPLY + SETGSINFO + ADDRINFO) and answers
  CREATEGAME/JOINGAME with a configurable gameid; tracks `creates` / `joins`.
- `net.zig` — libc TCP client + little-endian framing helpers (mirrors
  `apps/realmd/net.zig`; the 0.16 `std.posix` socket wrappers were removed).
- `main.zig` — `minimalD2s` craft, the named scenarios, and the runner: optionally
  auto-starts its own `realmd` child, prints a summary, exits non-zero on failure.

## Run

```sh
zig build install   # build realmd first
zig build e2e       # builds AND runs the harness
```

`zig build e2e` builds the harness and runs it. If nothing is listening on the
bnet port (6112) it **auto-starts its own** `realmd` (fs store) for the run and
stops it afterward — recommended, because the FakeGS scenarios are sensitive to
*stale* GS registrations left behind by other smoke tests sharing a long-lived
realmd. If a realmd is already listening on 6112, the harness uses it.

Env (the auto-started realmd):

- `REALMD_BIN`         path to the realmd binary (default `./zig-out/bin/realmd`)
- `REALMD_DATA_DIR`    data dir (default `/tmp/e2e-realmd`)
- `REALMD_HEALTH_PORT` health port (default `18080`; non-8080 because 8080 is
  commonly taken on dev boxes)

## Scenarios

Implemented (assert against live behaviour):
- `login` — full bnet handshake, session minted.
- `char_list_statstring` — SAVE a crafted Sorceress/level-42 via d2dbs, then
  login + startup + char_list, and assert the **decoded statstring** is
  class=Sorceress, level=42.
- `create_join_game` — a FakeGS registers; create then join a game; assert both
  succeed, the join `gs_ip` is `127.0.0.1`, and the GS saw 1 create + 1 join.
- `fleet_capacity` — two FakeGS with `maxgame=1`; two creates spread one-each, a
  third create fails.

Skipped stubs (features not built yet):
- `create_account_real_auth`, `delete_char`, `lobby_chat_a_to_b`.
