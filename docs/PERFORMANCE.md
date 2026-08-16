# Resource footprint and capacity

Two different questions, and they have very different answers: *what does the realm cost to
run* (almost nothing) and *how many games fit on one game server* (seven, and it is a hard
engine limit).

## Idle footprint

The 1.14d engine's main loop busy-spins by default; d2gs frame-paces it, so an **idle game
server sits near-zero**. Measured on a real Hetzner k3s node with no players online:

| service | CPU | memory | image |
|-|-|-|-|
| `realmd` (login + realm + d2dbs + gs-link) | ~1m | ~6 MiB | scratch, static musl |
| `qqserver` (game-traffic ingress) | **~0m** | **~1 MiB** | scratch, static musl |
| `d2gs` (wine, headless `Game.exe`) | ~15m | ~300 MiB | debian + wine32 |
| `d2gs-native` (no wine, Mac i386 image) | ~0m | ~8-10 MiB | scratch, one static i386 ELF |

Postgres/Redis are optional -- `fs` persistence drops them entirely.

The two game servers are interchangeable to the realm and, on real amd64 hardware, indistinguishable
on latency -- the native one just costs an order of magnitude less to keep resident. Measured side
by side in [`native-vs-wine.md`](native-vs-wine.md).

## Under load

The pure-Zig services stay effectively free under load, not just at idle. Driving 120 games
through a two-server fleet, both sitting at ~4 MiB resident:

- **realmd: ~1.8 ms of CPU per game** -- one client's whole session, login through create and
  join.
- **qqserver: ~0.6 ms of CPU per connection.** Per *connection*, not per game: its cost is the
  route lookup and the splice setup, so a game that four players join costs four times a solo
  one. Byte copying did not register at this scale (620 KB across 119 connections, 99% of it
  the GS->client world-state push).

Measured on an M3 Max running native arm64 debug builds, so treat them as a shape rather than
a budget -- expect more per unit on an x86 vCPU, less from the ReleaseSafe builds the images
use. The `~1m` in the table above is the number to size against: real x86, real cluster. The
game server's footprint is wine plus the loaded engine, and a game costs about **2.5 MiB** on
top.

## How many games per server

**Seven concurrent games per `Game.exe`, and that is a hard engine limit.** Fog's allocator has
a fixed table of 8 pool managers (`Fog/Memory.cpp` raises `0xe0000001` on the 9th) and one is
held permanently by the global pool system. A game holds its manager until it is destroyed, and
an empty game is destroyed after an idle window (`--reap-ms`, default 5s), so a server also has
a *throughput* ceiling of roughly `7 / window` new games per second.

It is the same engine either way, so `d2gs-native` inherits the same seven -- but it ships capped
at one game (`D2GS_MAX_GAMES`), so today its capacity comes from running more of them.

That ceiling is per process, so **capacity scales by adding game servers, not by tuning one**.
Measured with eight characters running games back to back -- half of them re-entering one
shared game, half churning their own -- one server places 22 of 32 games per round and a second
takes it to 29. Every refusal is clean and says the same thing: realmd parks a full server,
tries the next, and tells the client the realm is busy rather than dropping it.

## No per-address limit at the game port

The engine has one -- eight concurrent connections from an address, then a ban past twenty in
fifteen seconds -- and it is right for a server players dial directly and wrong for this one,
because every client arrives through qqserver and the engine sees a single peer address for the
whole realm. Stock, that caps the server at eight connections and then bans its own gateway;
worse, it refuses by accepting the connection and closing it without a byte, so the client waits
at a loading screen with nothing to read. The dedicated bootstrap turns it off.

Per-address abuse control belongs at the gateway, which is the only peer that can still tell
clients apart. See [`apps/qqserver/README.md`](../apps/qqserver/README.md).
