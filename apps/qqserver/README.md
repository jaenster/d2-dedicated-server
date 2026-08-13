# apps/qqserver — the ingress for game traffic

`qqserver` is a **pure-Zig, stateless ingress** for game traffic: one public address in front,
the whole game-server fleet behind it, routed per connection. It is an ingress controller for
the D2 game protocol.

## Why it exists

The client gives you nothing to route on. The realm can tell it *which host* to dial, but the
game port is fixed at `:4000`, so without a gateway every game server needs its own
client-routable address and the fleet can never outgrow the IPs you own.

An HTTP ingress reads the `Host` header to choose a backend. qqserver does the same job one
layer down, on the game's own protocol.

## How a connection is routed

1. realmd mints a realm-globally-unique **token** per create/join and records
   `token -> {gs address, real engine game id}` in redis.
2. The client dials `qqserver:4000` and sends `GAMELOGON` (`0x68`), which carries that token.
3. qqserver reads it, looks up the route, **rewrites the token in the packet** to the game id
   the backend engine actually knows, dials that GS, replays the rewritten packet, and
   **splices**.

That is the entire extent of the protocol it understands: one field in the first packet, plus
the engine's `0xAF` greeting frame, which it strips. Everything after is opaque bytes in both
directions -- so gameplay changes cannot break it, and it never needs to keep up with the
engine.

## Why it needs no state of its own

Because the token is realm-global, **any** gateway pod resolves **any** token: no session
affinity, no shared state of its own, no warm-up. Scale it to whatever you like and put a plain
round-robin LoadBalancer in front.

It is NAT-proof too -- two clients behind one public IP never collide, because the route key is
the token, not the source address. That property is also what forces the engine's per-address
connection limit off on the game server: the engine sees a single peer address for the whole
realm. See [How many games per server](../../docs/PERFORMANCE.md#no-per-address-limit-at-the-game-port).

## Implementation

The implementation matches the job: **one thread, one `poll()` loop, zero heap, no globals**,
all state in a single value on `main()`'s stack. Even the redis lookup is non-blocking and
pipelined on a persistent connection in the same poll set, so one connection waiting on its
route never stalls the others. Idle it sits in `poll(-1)` at 0% CPU.

Measured cost is ~0.6 ms of CPU per connection and ~1 MiB resident; see
[`docs/PERFORMANCE.md`](../../docs/PERFORMANCE.md).

## When you don't need it

In the lightweight single-binary path, realmd can splice in-process and you don't run qqserver
at all. That is the **DIRECT** mode described in [`docs/DEPLOY.md`](../../docs/DEPLOY.md):
the GS keeps a client-routable address and clients dial it themselves. Fine for one server on
one host; it is exactly what stops working once the fleet is bigger than the addresses you own.
