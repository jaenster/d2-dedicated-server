# Web UI behind Authentik SSO (nginx-ingress forward-auth)

The realmd admin web UI is served on the **health/admin port (8080)** alongside the
`/admin/*` JSON API. realmd authenticates it two ways (see `apps/realmd/admin.zig`):

- **Account login** — a realm account listed in `REALMD_ADMINS`, by password. Always on.
- **SSO forward-auth** — when `REALMD_TRUSTED_AUTH_HEADER` is set, realmd trusts that
  request header as an already-authenticated username (which must also be in
  `REALMD_ADMINS`). This is for putting Authentik in front.

This doc wires the SSO path on the existing **nginx-ingress + cert-manager + Authentik**
stack (`*.typeguru.nl`). The manifests belong in the private deploy repo
(`hertzner-k8s/gitops/...`), not here.

> **Security — the header is trusted verbatim.** When `REALMD_TRUSTED_AUTH_HEADER` is
> set, anyone who can reach port 8080 *directly* can spoof the username. So: expose 8080
> **only** through the authenticated Ingress below (nginx overwrites the identity header
> from the auth subrequest, so it can't be spoofed *through* the proxy), and add the
> NetworkPolicy so other pods can't hit it directly. Never put 8080 on a LoadBalancer /
> NodePort. The k8s liveness/readiness probes hit the pod directly (kubelet), so they're
> unaffected by the Ingress.

## 1. Authentik: a Proxy Provider (forward auth, single application)

In Authentik, create **Provider → Proxy Provider**:
- Type: *Forward auth (single application)*
- External host: `https://realmd.typeguru.nl`
- (Optional) restrict access with a group/policy binding on the Application.

Create an **Application** bound to that provider, and assign it to the **embedded
outpost** (Outposts → authentik Embedded Outpost → add the application). The embedded
outpost is reachable in-cluster at `ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000`
(adjust the service name to your release — `kubectl -n authentik get svc | grep outpost`).

Authentik returns the logged-in user in the **`X-authentik-username`** header.

## 2. Expose realmd's admin port as a ClusterIP

The chart's `realmd` Service only publishes the game ports (6112/6113); 8080 is
container-only. Add a ClusterIP for the Ingress to target:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: realmd-admin
  namespace: d2
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/component: realmd   # match the chart's realmd selector
  ports:
    - { port: 8080, targetPort: 8080, name: admin }
```

## 3. Ingress with Authentik forward-auth

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: realmd-admin
  namespace: d2
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # Authenticate every request against the embedded outpost.
    nginx.ingress.kubernetes.io/auth-url: >-
      http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx
    nginx.ingress.kubernetes.io/auth-signin: >-
      https://realmd.typeguru.nl/outpost.goauthentik.io/start?rd=$escaped_request_uri
    # Pass the resolved identity (and the SSO session cookie) back to the backend.
    # X-authentik-username overwrites any client-supplied value → no spoofing via proxy.
    nginx.ingress.kubernetes.io/auth-response-headers: >-
      Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-uid
    nginx.ingress.kubernetes.io/auth-snippet: |
      proxy_set_header X-Forwarded-Host $http_host;
spec:
  ingressClassName: nginx
  tls:
    - hosts: [realmd.typeguru.nl]
      secretName: realmd-admin-tls
  rules:
    - host: realmd.typeguru.nl
      http:
        paths:
          # The outpost's own endpoints must NOT be auth-gated (they ARE the auth flow).
          - path: /outpost.goauthentik.io
            pathType: Prefix
            backend:
              service:
                name: ak-outpost-authentik-embedded-outpost
                port: { number: 9000 }
          - path: /
            pathType: Prefix
            backend:
              service:
                name: realmd-admin
                port: { number: 8080 }
```

(The first path rule needs the outpost Service to resolve in the `d2` namespace — if
it's in `authentik`, use an `ExternalName` Service in `d2` pointing at it, or move this
Ingress to the `authentik` namespace. `kubectl get svc -n authentik | grep outpost`.)

## 4. Lock the admin port to the Ingress only

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: realmd-admin-ingress-only
  namespace: d2
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: realmd
  policyTypes: [Ingress]
  ingress:
    # 8080 only from the ingress-nginx controller; game ports stay open as the chart sets them.
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
      ports: [{ port: 8080 }]
    - ports: [{ port: 6112 }]
```

## 5. realmd env

Set on the realmd Deployment (chart `values.yaml` → realmd env, or a patch):

```yaml
env:
  - name: REALMD_TRUSTED_AUTH_HEADER
    value: X-authentik-username
  - name: REALMD_ADMINS
    value: "alice,bob"            # Authentik usernames allowed in (SSO needs no account)
  - name: REALMD_ADMIN_SECRET     # stable HMAC key for account-login sessions
    valueFrom:
      secretKeyRef: { name: realmd-admin, key: secret }
```

- Admin-ness is primarily a **DB flag** on the account (set via `realmd create-admin`,
  `REALMD_ADMIN_BOOTSTRAP`, or the UI's promote/demote). `REALMD_ADMINS` is an additional
  static allowlist OR'd on top — use it for **SSO users who have no realm account** (the
  Authentik username just needs to be listed), and as a lockout escape hatch.
- `REALMD_ADMIN_SECRET` only matters for the password-login session cookie; with pure
  SSO you can omit it (every request is re-authenticated by nginx). Set it (and share it
  across replicas) if you also want account-login sessions to survive restarts.
- Leave `REALMD_ADMIN_TOKEN` **unset** in prod — it's a bearer bypass for scripts/CI and
  break-glass; if you set it, treat it like a root password.

To seed the first admin declaratively, add a `REALMD_ADMIN_BOOTSTRAP=name:password` env
from a Secret (idempotent on every boot), or run `kubectl exec deploy/realmd -- realmd
create-admin <name> <password>` once.

After this, hitting `https://realmd.typeguru.nl` redirects through Authentik; once logged
in, the UI loads with no second prompt (`/admin/me` returns `via: "sso"`).
