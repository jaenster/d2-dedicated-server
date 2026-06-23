# Deploying the realm to the Hetzner k3s cluster (ArgoCD)

The realm runs from **this private repo** via ArgoCD — none of it touches the public
`hertzner-k8s` gitops repo. ArgoCD renders `deploy/` (kustomize) into the `realmd`
namespace: realmd (bnetd+d2cs+d2dbs+gs-link) + Postgres + Redis + the GS fleet.

Images are built by `.github/workflows/build.yml` → `ghcr.io/jaenster/realmd` and
`ghcr.io/jaenster/d2gs`. The packages are **public** (the realm is public anyway and the
images bake in no proprietary game data), so the cluster pulls them anonymously — no
image-pull secret. After the first CI run, flip each new package to public once in the
GitHub UI (Packages → package → Settings → Change visibility → Public).

## One out-of-band secret (NOT in git)

ArgoCD needs a credential to pull this **private** source repo — a GitHub PAT with
`repo`. Apply once, never commit:

```sh
kubectl -n argocd create secret generic repo-d2gs \
  --from-literal=type=git \
  --from-literal=url=https://github.com/jaenster/d2-dedicated-server.git \
  --from-literal=username=jaenster \
  --from-literal=password=<GITHUB_PAT>
kubectl -n argocd label secret repo-d2gs argocd.argoproj.io/secret-type=repository
```

## Register the app

```sh
kubectl apply -f deploy/argocd/application.yaml
```

## Game files (proprietary — one-time upload)

The GS pods mount the `d2-gamefiles` PVC (Longhorn RWX) read-write-many. Populate it
once with a real 1.14d data set (the minimal headless set is ~16 MB: Game.exe + the
MPQs + the bink/smack/ijl DLLs). Use a throwaway helper pod:

```sh
kubectl -n realmd apply -f deploy/argocd/upload-helper.yaml
kubectl -n realmd cp ./testgame-min/. gamefiles-upload:/game/
kubectl -n realmd delete pod gamefiles-upload
```

## Firewall

Clients reach the cluster on node public IPs. The Hetzner firewall must open the realm
ports — added in `hertzner-k8s/kube.tf` (`6112-6115` tcp + `4000` tcp, `0.0.0.0/0`).
Run `terraform apply` there after merging that change.

## Client config

Point the client's `--realm` at a node public IP (e.g. `116.202.26.229`), matching the
`REALMD_REALM_ADDR` patched in `deploy/kustomization.yaml`.
