# `realm/` — the realm link, both ends + what they share

The realm is what the D2 client logs into and what dispatches games to the headless
game servers. This package holds **both sides of that link plus the contract between
them**, so the wire format is defined once:

- **`shared/`** — the package both ends depend on (the `realm_shared` Zig module, wired
  in `build.zig`). `protocol.zig` = the d2cs↔d2gs control wire format (8-byte LE header,
  message `Type` enum, `AddrInfo`, …). Defining it here means the client and server agree
  on the wire *by construction* rather than by two hand-kept copies.
- **`client/`** — the **GS side**: the injected `d2gs.dll`'s clients of the realm —
  `d2cs.zig` (dials the gs-link, AUTHREPLY/SETGSINFO/ADDRINFO + create/join), `d2dbs.zig`
  (fetches/saves character data), `joinctx.zig` (token→account map for the engine's
  character fetch, **plus join-token validation**: a 120 001 ms TTL + consume-once +
  `validate(token)`, ported faithfully from the OG 1.00 `D2Server.dll` `PlayerToken_*`
  routines — feeds `engine/realm.zig` `fpFindPlayerToken`, currently observe-only via
  `enforce_token`). Consumed by `src/d2gs.zig` and `src/engine/realm.zig`.
- **`server/`** — the **realm server** itself (the `realmd` binary; clean-room pvpgn
  replacement): bnetd / d2cs / d2dbs / gs-link, the persistence facade + backends, health
  and graceful-shutdown. See [`server/README.md`](server/README.md).

Naming: `realmd` = the server *daemon*; `realm/client` = the GS's *link to* it;
`engine/realm.zig` = the engine-facing realm callback table (separate concern).
