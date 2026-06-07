# Clientless E2E test harness for `realmd`

A pure-Python, wire-protocol end-to-end test harness for the `realmd` realm
server. It speaks the raw BNCS / MCP / d2dbs / gs-link framings directly over
TCP — **no wine, no `Game.exe`**. Scenarios are assertion-rich and named.

## Files

- `realmclient.py` — reusable clients:
  - `RealmClient` — full bnetd handshake (`auth`, `create_account`, `login`,
    `enter_realm`) then d2cs (`connect_d2cs`, `startup`, `char_list`,
    `create_game`, `join_game`). `char_list()` decodes each statstring into
    `{name, class, class_id, level, flags}`.
  - `D2dbsClient` — `save_char(acct, char, d2s_bytes)` / `get_char(acct, char)`.
  - `FakeGS` — background-thread stand-in game server that registers over the
    gs-link (AUTHREPLY + SETGSINFO + ADDRINFO) and answers CREATEGAME/JOINGAME
    with a configurable gameid; tracks `creates` / `joins`.
- `crafts.py` — `minimal_d2s(name, class_id, level)`: a minimal `.d2s` blob with
  signature `0xAA55AA55` at 0, class byte at `0x28`, level at `0x2b`.
- `scenarios.py` — named scenario functions.
- `run.py` — the runner: prints a summary, exits non-zero on any failure.

## Run

```sh
python3 tools/e2e/run.py
```

It needs a `realmd` listening on ports **6112-6115** (bnet/d2cs/d2dbs/gs-link).

- If one is already listening on 6112, the harness uses it.
- Otherwise, if `REALMD_BIN` is set, `run.py` **auto-starts its own** `realmd`
  (fs store) for the run and stops it afterward. Recommended, because the
  FakeGS scenarios are sensitive to *stale* GS registrations left behind by
  other smoke tests sharing a long-lived realmd.

```sh
zig build install
REALMD_BIN="$PWD/zig-out/bin/realmd" \
REALMD_DATA_DIR=/tmp/e2e-realmd \
REALMD_HEALTH_PORT=18080 \
python3 tools/e2e/run.py
```

`REALMD_HEALTH_PORT` is non-8080 because 8080 is commonly taken on dev boxes.

## Scenarios

Implemented (assert against live behaviour):
- `login` — full bnet handshake, session minted.
- `char_list_statstring` — SAVE a crafted Sorceress/level-42 via d2dbs, then
  login + startup + char_list, and assert the **decoded statstring** is
  class=Sorceress, level=42. This is the real test of the statslist.
- `create_join_game` — a FakeGS registers; create then join a game; assert both
  succeed, the join `gs_ip` is `127.0.0.1`, and the GS saw 1 create + 1 join.
- `fleet_capacity` — two FakeGS with `maxgame=1`; two creates spread one-each, a
  third create fails.

Skipped stubs (features not built yet, ready to fill in):
- `create_account_real_auth`, `delete_char`, `lobby_chat_a_to_b`.
