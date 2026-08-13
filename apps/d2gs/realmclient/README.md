# apps/d2gs/realmclient — the game server's side of the realm link

The injected game server (`d2gs.dll`) talks to `realmd` over two outbound links.
This directory is the **GS side** of that conversation (it is compiled into
`d2gs.dll`, runs under wine in `Game.exe`). The realm server itself lives in
[`apps/realmd`](../../realmd); the engine callback table that invokes these lives in
[`../engine`](../engine).

## Files

- `protocol.zig` — the d2cs↔d2gs / d2dbs wire types: 8-byte LE header
  `{size:u16, type:u16, seqno:u32}` + the AUTH/SETGSINFO/CREATEGAME/JOINGAME and
  GET_DATA/SAVE_DATA bodies. Shared shape with `realmd/`'s view of the same link.
- `d2cs.zig` — outbound client to realmd's **gs-link** (port 6115). Completes the
  auth handshake (AUTHREPLY + SETGSINFO), then services CREATEGAME (drives the
  engine to make a game on the tick thread) and JOINGAME. JOINGAME carries the
  account+char, which it stashes in `joinctx` so the char load can find the right
  save.
- `d2dbs.zig` — outbound client to realmd's **d2dbs** (port 6114).
  `fetchCharSave(account, char)` pulls the `.d2s` bytes the engine needs when a
  client joins; `connectTo`/`disconnect` bracket a per-fetch connection.
- `joinctx.zig` — the account bridge. The engine's dedicated-server join path
  carries the char name + token but **never the account**, so realmd sends it over
  the gs-link at JOINGAME time and we cache it here (keyed by char name / token).
  `fpGetDatabaseCharacter` resolves the account from this cache and writes it back
  into the client struct.

## Why this exists

In retail the realm callbacks are an opaque integration point. We implement just
enough of the GS↔realm protocol to: register the GS, accept create/join requests,
and fetch character saves — so a real client can actually enter a game served by
our headless engine.
