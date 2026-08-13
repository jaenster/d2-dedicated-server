# apps/d2gs/test — client-driving test harnesses

Compiled into `d2gs.dll` and activated by flags; these drive a **real** 1.14d
client through its menus so the realm/GS flow can be exercised without a human at
the GUI. Not unit tests — they automate the live client under wine.

## Files

- `autologin.zig` — drives the bnet login form and lobby. Reads/writes the engine's
  UI control list (`D2WIN_FirstControl`), sets edit-box text via
  `D2WIN_SetControlText`, and clicks buttons by posting mouse messages to the game
  window (same approach as d2bs). Two modes:
  - `--auto-login <acct:pass>` → login → char select → **create** a game.
  - `--auto-join <acct:pass:game>` → login → char select → open the lobby JOIN tab
    → type the game name → **join** it.
  Runs on its own poll thread (it never patches the game loops, which would break
  the version-check flow). Includes a control-rect dump used to map screen coords.
- `autoenter.zig` — fiber/gameloop-driven harness that drives the client into a
  **single-player** game with a character and verifies it loads (the SP analogue of
  the realm join; `--test-enter`).
- `screenshot.zig` — `--screenshot`: a thread calling the engine's
  `D2WIN_TakeScreenshot` every 3s (writes `Screenshot###.jpg` in the game CWD).
  The main headless-debugging window into what the client is doing.

## Full create+join e2e

The orchestrated two-client test (realmd + GS + client A creates + client B joins,
with assertions) lives in [`../../tools/realmd-test/e2e-game.sh`](../../../tools/realmd-test),
which launches clients with `--auto-login` / `--auto-join` from here.
