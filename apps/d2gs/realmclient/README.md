# apps/d2gs/realmclient — the game server's side of the realm

The injected game server (`d2gs.dll`) never connects to `realmd`. It meets the realm in the
shared store: it publishes itself there, takes create/join from a queue of its own, reports what
happens on it as events, and reads and writes characters directly. This directory is the **GS
side** of that (compiled into `d2gs.dll`, running under wine in `Game.exe`). The realm server is
[`apps/realmd`](../../realmd); the engine callback table that invokes these lives in
[`../engine`](../engine).

## Files

- `redis.zig` — the store transport. RESP framing comes from
  [`packages/resp`](../../../packages/resp), which is IO-free so this 32-bit Windows DLL can
  share it with the realm; only the winsock layer is local. One socket, and every command holds
  a lock over the whole request/reply cycle — two threads sharing it without that desyncs the
  connection, and the symptom is reads coming back empty while writes still appear to work.
- `d2cs.zig` — the realm conversation over that transport: publishes this server's record
  (address, capacity, load, whether it is full), drains its request queue on a thread of its own,
  and emits an event when a player enters or leaves and when a game ends.
- `joinctx.zig` — the account bridge. The engine's dedicated-server join path carries the char
  name + token but **never the account**, so the realm sends it with JOINGAME and we cache it
  here (keyed by char name / token). `fpGetDatabaseCharacter` resolves the account from this
  cache and writes it back into the client struct.

The wire format is the same 8-byte LE header `{size:u16, type:u16, seqno:u32}` the control link
used, defined once in [`packages/realm-proto`](../../../packages/realm-proto) so both ends agree
by construction. The `seqno` now does real work: it names the key a reply goes back on, which a
queue several realmds push to makes necessary and a single socket did not.

## Why this exists

In retail the realm callbacks are an opaque integration point. We implement just enough of them
to register this server, accept create/join, and load and save characters — so a real client can
enter a game served by our headless engine, with no realm server holding a connection to it.
