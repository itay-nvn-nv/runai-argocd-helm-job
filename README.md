# Run:ai on ArgoCD via a Helm runner Job

Deploy and upgrade the NVIDIA Run:ai control plane and its first cluster from ArgoCD while still
using the **documented `helm upgrade --install` command**, instead of letting ArgoCD render the
product chart with `helm template`. The cluster stage also removes the browser wizard from the
install path.

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

## The cluster stage

Installing the control plane is only half of it. On first visit the control plane UI opens a wizard
that asks for a cluster name and whether the cluster is on the same URL, then prints a
`helm upgrade -i runai-cluster` command to paste into a terminal. That is a manual step in the
middle of an otherwise automated install, and the command it prints cannot be written in advance
because it contains a cluster UUID and a client secret the control plane mints on the spot.

`charts/runai-cluster-installer/` closes that gap. Its Job makes the same three API calls the
wizard makes, then runs the command the control plane itself generated:

| Wizard step | API call |
| --- | --- |
| Answering the cluster name | `POST /api/v1/clusters` returns the cluster UUID |
| Rendering the install command | `GET /api/v1/clusters/{uuid}/cluster-install-info?version=&remoteClusterUrl=` returns `installationStr`, `chartRepoURL` and `clientSecret` |
| The green "connected" tick | `GET /api/v1/clusters/{uuid}` until `status.state` is `Connected` |

The Job takes the `--set` arguments **verbatim** from `installationStr` rather than reconstructing
them. So `cluster.uid`, `controlPlane.clientSecret`, both URLs and whatever else the control plane
derives from its own install (the ingress class, the FIPS mode) are exactly what the wizard would
have used. Only `--set` tokens are accepted from that string, nothing else is executed.

Re-running must not register a second cluster, so the UUID is resolved in this order:

1. `cluster.uid` from the values file, when pinned
2. `cluster.uid` recorded in an existing `runai-cluster` Helm release
3. a control plane cluster whose name matches `cluster.name`
4. a newly registered cluster

Step 2 is what makes a re-sync idempotent, and step 3 lets you adopt a cluster somebody already
created in the wizard by hand.

The Job also blocks on the control plane API before doing anything, so this Application needs no
sync-wave relative to the control plane one. Sync them in either order.

## Layout

```
charts/runai-installer/                     control plane wrapper chart
charts/runai-cluster-installer/             cluster wrapper chart (registers, installs, waits)
charts/*/environments/                      per-environment values, including the version
argocd/                                     the ArgoCD Applications to apply
```

Everything an operator changes lives in the environment values file, so the Application manifest
is applied once and never touched again.

## Prerequisites

Created out of band, not by this repo:

1. The product prerequisite secrets in each target namespace, per the Run:ai install docs
   (`runai-reg-creds`, and TLS material if applicable). The cluster chart pulls from
   `runai.jfrog.io`, so `runai-reg-creds` has to exist in the cluster namespace before the Job
   runs, and the Job's `--create-namespace` will not put it there.
2. A Secret holding sensitive Helm values, referenced by `secretValues.existingSecret`, with a
   single `values.yaml` key. This keeps credentials out of git:

```sh
kubectl -n runai-installer create secret generic runai-cp-secret-values \
  --from-file=values.yaml=./secret-values.yaml
```

3. For the cluster stage, a Secret holding the identity the Job authenticates to the control plane
   API with. Either a service account, which is preferred, or the `global.management` user:

```sh
kubectl -n runai-installer create secret generic runai-cp-admin \
  --from-literal=clientId=<service account clientId> \
  --from-literal=clientSecret=<service account clientSecret>

# or, to bootstrap before any service account exists
kubectl -n runai-installer create secret generic runai-cp-admin \
  --from-literal=username=<management user> \
  --from-literal=password=<management password>
```

A first browser login can be forced to change the management password, which then breaks the
password grant. A service account avoids that.

## Install

1. Copy the `environments/lab-itay-26.yaml` file in each chart to one for your environment and set
   the domain, ingress class, target version, cluster name and any other chart values.
2. Point `spec.source.helm.valueFiles` in the Application manifests at them.
3. Apply them once:

```sh
kubectl apply -f argocd/application-control-plane.yaml
kubectl apply -f argocd/application-cluster.yaml
```

## Upgrade

Edit `chart.version` in your environment values file, commit, push. ArgoCD renders a new Job name
and runs `helm upgrade --install` at the new version. Nothing is applied by hand. Keep the cluster
version equal to the control plane version, and upgrade the control plane first.

## Verify

```sh
kubectl -n runai-installer get jobs
kubectl -n runai-installer logs job/<job-name>
helm history runai-backend -n runai-backend
helm history runai-cluster -n runai
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

**The cluster Job needs `jq` as well as `helm`**, so it uses `dtzar/helm-kubectl` rather than
`alpine/helm`, which ships curl but not jq.

**The cluster client secret is never written to git or to a manifest.** It is fetched at run time
and passed straight to Helm, and the log lines that would contain it are redacted. It does end up
in the `runai-cluster` release's stored values, exactly as it does with the wizard.

## Trade-off

ArgoCD tracks the installer objects, not the Run:ai resources. You lose diff, self-heal and prune
for the product itself, and app health reflects the Job result rather than the deployment. For a
vendor-managed product that is usually the right trade, but it should be a deliberate one.
