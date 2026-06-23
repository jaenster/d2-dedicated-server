# realmd web UI

A small Vite + React admin UI for the `realmd` realm server. It's a thin frontend
over the existing `/admin/*` JSON API (`src/realm/server/admin.zig`) — it adds **no**
new server endpoints.

![Login](img/login.png)

![Overview](img/overview.png)

![Accounts](img/accounts.png)

## How it ships

The build produces **one self-contained `dist/index.html`** (all JS/CSS inlined by
`vite-plugin-singlefile`). The realmd binary embeds that single file at build time and
serves it from the health/admin HTTP listener:

- `zig build realmd-bin -Dwebui=true` — builds this project (`npm ci && npm run build`)
  and embeds the bundle. Requires Node.
- `zig build realmd-bin` (no flag) — embeds a stub page instead, so normal Zig builds
  need no Node. The JSON API still works.

The deploy image (`deploy/Dockerfile`, `--target realmd`) builds with `-Dwebui=true`.

## Serving & auth

`realmd` serves the UI on the **health port** (`REALMD_HEALTH_PORT`, default 8080) —
the same listener as `/healthz`, `/readyz`, and `/admin/*`. Any non-probe, non-`/admin`
GET returns the SPA.

Auth reuses **`REALMD_ADMIN_TOKEN`**: the page itself is static and unauthenticated,
but every data call hits `/admin/*`, which is bearer-token gated. The UI prompts for the
token and keeps it in `sessionStorage`. If `REALMD_ADMIN_TOKEN` is empty the admin API
is disabled (403) and the UI says so.

> The health/admin port must **not** be public. Reach it via `kubectl port-forward` or
> an authenticated ingress — never expose it directly.

## Develop

```sh
npm install
npm run dev          # Vite dev server, proxies /admin to localhost:8080
```

Point the proxy elsewhere with `REALMD_HEALTH_PORT=18099 npm run dev` (matching a local
`realmd`). Run a local realmd with the API enabled:

```sh
REALMD_ADMIN_TOKEN=secret REALMD_HEALTH_PORT=18099 zig build run-realmd   # or the binary
```

## What it does

- **Overview** — sessions / games / gameservers counts, instance + store backends
- **Game Servers** — the registered GS fleet
- **Games** — active games, with a per-game *Close*
- **Accounts** — list accounts, *Create account*, *Copy character*
