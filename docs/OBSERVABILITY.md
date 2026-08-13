# Observability

Every service logs structured **JSON to stdout** (`REALMD_LOG_JSON=1`), carrying a
per-connection and per-packet trace/span context across realmd and the game servers. Shipped to
**Loki** (via Promtail/Alloy) and paired with **Prometheus** pod metrics, the whole realm is one
Grafana dashboard: [`deploy/grafana/d2-realm.json`](../deploy/grafana/d2-realm.json).

## The dashboard

Its rows cover pod CPU/memory (Prometheus), **live state** (active games + players in-game,
split per game server), **realm activity** (games created, joins, refusals, qqserver drops,
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

## Health and lifecycle

realmd exposes health/readiness on `:8080` (`/readyz` returns 200 once the configured stores are
reachable) and drains cleanly on SIGTERM, so `kubectl rollout` and Compose restarts are
uneventful. The game servers register over the gs-link and deregister on shutdown, so a rolling
GS update drains rather than dropping games on the floor.
