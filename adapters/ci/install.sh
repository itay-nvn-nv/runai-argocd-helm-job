#!/usr/bin/env bash
# CI adapter for the Run:ai vendor-neutral installer.
#
# Runs the exact same wrapper charts that the ArgoCD and Flux adapters use,
# via plain "helm upgrade --install". Nothing in charts/ is aware of which
# adapter invokes it; the only difference between this and the GitOps adapters
# is that the outer Helm call happens in your pipeline rather than in the cluster.
#
# Usage:
#   ./adapters/ci/install.sh [<env-values-relative-path>]
#
# The optional argument is a path to an environments file, relative to the chart
# root. Defaults to environments/lab-itay-26.yaml. For a real deployment, create
# an environments/<target>.yaml file and pass it here.
#
# Prerequisites (same as every adapter):
#   - KUBECONFIG pointing at the target cluster
#   - runai-installer namespace exists with:
#       runai-cp-admin        (username/password for the cluster-installer Job)
#       runai-cp-secret-values (sensitive Helm values for the control plane)
#   - Registry credential Secrets in runai-backend and runai namespaces
#
# The inner Jobs that Helm waits on run the documented "helm upgrade --install"
# of the Run:ai charts. --wait here means "wait for the Job to finish", which
# means "wait for Run:ai to be installed or upgraded". Timeout is 40m to match
# the Flux and ArgoCD adapters.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_PATH="${1:-environments/lab-itay-26.yaml}"

echo "==> Control plane stage"
helm upgrade --install runai-installer "${REPO_ROOT}/charts/runai-installer" \
  -f "${REPO_ROOT}/charts/runai-installer/values.yaml" \
  -f "${REPO_ROOT}/charts/runai-installer/${ENV_PATH}" \
  --namespace runai-installer \
  --create-namespace \
  --wait \
  --timeout 40m

echo "==> Cluster stage"
helm upgrade --install runai-cluster-installer "${REPO_ROOT}/charts/runai-cluster-installer" \
  -f "${REPO_ROOT}/charts/runai-cluster-installer/values.yaml" \
  -f "${REPO_ROOT}/charts/runai-cluster-installer/${ENV_PATH}" \
  --namespace runai-installer \
  --create-namespace \
  --wait \
  --timeout 40m

echo "==> Done. Verify with:"
echo "    helm -n runai-backend list"
echo "    helm -n runai list"
