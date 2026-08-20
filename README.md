# Run:ai on ArgoCD via a Helm runner Job

Deploy and upgrade the NVIDIA Run:ai control plane from ArgoCD while still using the
**documented `helm upgrade --install` command**, instead of letting ArgoCD render the product
chart with `helm template`.

## Why

An ArgoCD Application with a Helm source does not run Helm. ArgoCD's repo-server renders the
chart with `helm template` and then applies the output. It holds no cluster credentials, so:

| | ArgoCD Helm source | This method |
| --- | --- | --- |
| What runs | `helm template` + apply | `helm upgrade --install` |
| Helm release state | none | real (`helm history`, `helm rollback`) |
| `lookup` in chart templates | always empty | works |
| Helm hooks | approximated as PreSync/PostSync | native, with weights and `--wait` |
| `.Release.IsInstall` / `IsUpgrade` | always install | correct |
| Failure handling | partial apply | `--atomic` available |

The Run:ai control-plane chart uses `lookup` for preflight guards, so under a plain ArgoCD Helm
source those guards silently never fire. This method restores them.

## How it works

ArgoCD manages a tiny wrapper chart in this repo. The wrapper renders only a ServiceAccount, a
ClusterRoleBinding, a values ConfigMap and a Job. It contains **no `lookup` and no random
functions**, so it renders identically every time and is safe to template.

The Job runs the documented command:

```sh
helm repo add runai <chart repo> --force-update
helm repo update
helm upgrade --install runai-backend runai/control-plane \
  --namespace runai-backend --create-namespace \
  --version <VERSION> \
  -f /values/values.yaml [-f /secret-values/values.yaml] \
  --wait --timeout 20m
```

Because the docs use `upgrade --install`, one code path covers the first install and every later
upgrade. Upgrading means bumping `chart.version` in the Application and committing.

The Job name embeds the chart version and a hash of the inputs. A version or values change
therefore produces a *new* Job rather than an attempted patch of an existing one, which
Kubernetes would reject because Job specs are immutable.

## Layout

```
charts/runai-installer/     wrapper chart (RBAC, values ConfigMap, Job)
argocd/                     the ArgoCD Application to apply
```

## Prerequisites

Created out of band, not by this repo:

1. The product prerequisite secrets in the target namespace, per the Run:ai install docs
   (`runai-reg-creds`, and TLS material if applicable).
2. A Secret holding sensitive Helm values, referenced by `secretValues.existingSecret`, with a
   single `values.yaml` key. This keeps credentials out of git:

```sh
kubectl -n runai-installer create secret generic runai-cp-secret-values \
  --from-file=values.yaml=./secret-values.yaml
```

## Install

```sh
kubectl apply -f argocd/application-control-plane.yaml
```

## Upgrade

Edit `chart.version` in `argocd/application-control-plane.yaml`, commit, and let ArgoCD sync.

## Verify

```sh
kubectl -n runai-installer get jobs
kubectl -n runai-installer logs job/<job-name>
helm history runai-backend -n runai-backend
```

## Design notes

**No `ttlSecondsAfterFinished` on the Job.** A TTL would delete the completed Job, ArgoCD would
see a tracked resource go missing, and `selfHeal` would recreate it, re-running Helm in a loop.

**Superseded Jobs are kept** via `Prune=false` plus `IgnoreExtraneous`, so past upgrades remain
visible as an audit trail without ArgoCD reporting them as out of sync. Clean them up manually.

**`cluster-admin` for the Job.** The Run:ai docs state the charts require Kubernetes
administrator permissions, and the chart creates cluster-scoped objects. A Job running the
documented command needs the same rights the admin would have.

**Rotating `secretValues`** does not change the rendered manifests, so it will not trigger a run.
Bump `runCounter` to force one.

## Trade-off

ArgoCD tracks the installer objects, not the Run:ai resources. You lose diff, self-heal and prune
for the product itself, and app health reflects the Job result rather than the deployment. For a
vendor-managed product that is usually the right trade, but it should be a deliberate one.
