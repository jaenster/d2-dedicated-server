# `packages/realm-proto` — the contract between realmd and the game servers

The one thing both ends of the realm link compile against, so the wire format is defined
once instead of twice:

- **`protocol.zig`** — the d2cs↔d2gs control wire format: the 8-byte LE header, the message
  `Type` enum, `AddrInfo`, and the create/join payloads. Both ends import *this* enum, so a
  message added on one side does not silently mean something else on the other.
- **`guild.zig`** — the cut "Guild Halls" data model (reconstructed from the beta/1.00
  binaries). Authoritative state lives in realmd; the game server and the client read it.

Imported as the `realm_proto` module, and by both targets: it goes into the native `realmd`
binary *and* into the x86-windows `d2gs.dll`. That is what keeps it std-only — no sockets, no
allocators, no POSIX. Anything that needs those belongs in `realm-infra`, which the DLL
deliberately never sees.

The two ends it joins:

- [`apps/realmd`](../../apps/realmd/README.md) — the realm server (bnetd / d2cs / d2dbs /
  gs-link, persistence, health).
- [`apps/d2gs/realmclient`](../../apps/d2gs/realmclient/README.md) — the injected game
  server's outbound links to it.

Naming: `realmd` is the server *daemon*; `realmclient` is the GS's *link to* it; and
`apps/d2gs/engine/realm.zig` is the engine-facing realm callback table inside Game.exe — a
separate concern that happens to share the word.
