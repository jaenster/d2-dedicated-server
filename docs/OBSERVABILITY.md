# Observability

Every service logs structured **JSON to stdout** (`REALMD_LOG_JSON=1`), carrying a
per-connection and per-packet trace/span context across realmd and the game servers. Shipped to
**Loki** (via Promtail/Alloy) and paired with **Prometheus** pod metrics, the whole realm is one
Grafana dashboard: [`deploy/grafana/d2-realm.json`](../deploy/grafana/d2-realm.json).

## The dashboard

Its rows cover pod CPU/memory (Prometheus), **live state** (active games + players in-game,
split per game server), **realm activity** (games created, joins, refusals, d2ingress drops,
events/min), a **GS fleet** view (games + load per `gsid`), a **health** row (engine
halts/faults, pod restarts), and a live log tail -- with deploys annotated on the timelines.

It is datasource-agnostic: its `${prom}` and `${loki}` variables are datasource pickers (no
URLs, tokens, or namespaces baked in). Import it in Grafana via **Dashboards -> New -> Import**,
upload the JSON, and pick your Prometheus + Loki sources.

## Gameplay numbers without a metrics endpoint

The interesting part is that almost none of this needs a metrics endpoint in the engine: the
gameplay numbers fall out of the structured logs in Loki. For example, "games created" and
"player joins" are just `count_over_time` over the parsed `evt` field:

```logql
sum(count_over_time({namespace="realmd", app="d2gs"} | json | evt=`game_create` [$__range]))
sum(count_over_time({namespace="realmd", app="d2gs"} | json | evt=`player_join`  [$__range]))
```

## Where `evt` comes from

Those event lines are emitted by the **`srvtrace` feature**
([`apps/d2gs/runtime/feature/srvtrace.zig`](../apps/d2gs/runtime/feature/srvtrace.zig)), which is
`server_only` and **on by default** -- there is no flag to turn it on, and a game server emits
`game_create`, `game_destroy`, `player_join` and `player_leave` as they happen, each stamped
with the join `token` so a line correlates with its game.

They are bare JSON objects (`{"evt":"game_create",...}`), distinct from the ordinary log wrapper
(`{"ts","tag":"d2gs","msg",…}`) -- which is why a single `| json` parses both and why an
`evt`-filtered panel simply reports nothing during a quiet period rather than erroring. **An
empty realm-activity row means no games were created in the window, not a broken query.**

`--pkttrace` adds `pkt_in` / `pkt_out` events for every `:4000` packet; it is verbose and gated
behind its flag. See [`docs/FLAGS.md`](FLAGS.md).

## The game server's own endpoint

Logs answer "what happened"; they are a poor way to ask "what is true right now", because that
means a range query over an event stream to reconstruct a number the server already knows. So
the GS also serves its counters directly, on the port it was already using for probes
(`:8086`, `D2GS_HEALTH_PORT`), routed by path
([`apps/d2gs/runtime/feature/health.zig`](../apps/d2gs/runtime/feature/health.zig)):

| path | answers |
|-|-|
| `/healthz` | liveness — 200 only while the ENGINE tick heartbeat is advancing |
| `/readyz` | readiness — the above, AND published into the realm's shared store |
| `/stats` | the counters as JSON |
| `/metrics` | the same counters in Prometheus exposition format |
| `/` | unchanged from before there were paths, so old probes keep working |

The distinction between the first two is the one that matters: a process can be perfectly alive
with a dead engine, and that GS answers TCP, accepts connections and serves nobody. `/healthz`
is measured from the tick loop's heartbeat and from nothing else, so that state reads 503. The
chart wires liveness to `/healthz` and readiness to `/readyz`, so a GS that merely lost its
control connection leaves the Service (no new games routed to it) without being restarted out
from under the games it is still hosting.

The counters themselves live in
[`apps/d2gs/runtime/feature/stats.zig`](../apps/d2gs/runtime/feature/stats.zig), a registry
feature fed by the hook surface: uptime, ticks and tick rate, games created/destroyed/live with
each live game's token, name, client count and age, players joined/left/in-game, the Fog pool
census, and **items rolled** broken down by quality and by Items.txt code.

Item counts come from a first-class `itemRoll` hook driven by
[`apps/d2gs/runtime/itemroll.zig`](../apps/d2gs/runtime/itemroll.zig), which wraps the tail of
the engine's `ITEM_CreateItemInstance` rather than its entry — at the entry the generation
context holds only the quality that was *asked for*, and the affix roll inside still downgrades
it when no valid affix set exists, so counting there over-reports rares and uniques.

## Health and lifecycle

realmd exposes health/readiness on `:8080` (`/readyz` returns 200 once the configured stores are
reachable) and drains cleanly on SIGTERM, so `kubectl rollout` and Compose restarts are
uneventful. The game servers publish themselves into the store and let the record expire, so a rolling
GS update drains rather than dropping games on the floor.
