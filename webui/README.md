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
GET returns the SPA. The page is static; every data call hits `/admin/*`, which is gated.

There are three ways in (set any/all; the API is disabled — 403 — if none is set):

- **Account login** (`REALMD_ADMINS`) — sign in with a realm account that's in the
  comma-separated allowlist, by its password. On success realmd sets an HMAC-signed,
  `HttpOnly` session cookie (`REALMD_ADMIN_SECRET` is the signing key — set a stable one
  so sessions survive restarts / work across replicas; otherwise a per-process key is used).
- **SSO** (`REALMD_TRUSTED_AUTH_HEADER`) — behind an Authentik/oauth2-proxy forward-auth
  ingress, realmd trusts the injected identity header (e.g. `X-authentik-username`); the
  user must still be in `REALMD_ADMINS`. The UI shows no login form — `/admin/me` is
  already authenticated. See [`../deploy/AUTHENTIK-SSO.md`](../deploy/AUTHENTIK-SSO.md).
- **Bearer token** (`REALMD_ADMIN_TOKEN`) — `Authorization: Bearer <token>`, for
  scripts/CI and break-glass. Not used by the UI. Treat it like a root password.

The header shows who you are and how (`session` / `sso` / `token`).

> The health/admin port must **not** be public. Reach it via `kubectl port-forward`, or
> an authenticated ingress (the SSO setup above) — never expose port 8080 directly, since
> with SSO enabled the identity header is trusted verbatim.

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
