#!/usr/bin/env bash
# CI adapter for the Run:ai vendor-neutral installer.
#
# Runs the exact same wrapper charts that the ArgoCD and Flux adapters use,
# via plain "helm upgrade --install". Nothing in charts/ is aware of which
# adapter invokes it; the only difference between this and the GitOps adapters
# is that the outer Helm call happens in your pipeline rather than in the cluster.
#
# Usage:
#   ./adapters/ci/install.sh [<env-name> | <env-path>]
#
# The argument is either a bare environment name (e.g. "lab-itay-26") or a
# path to an environments file relative to each chart root (e.g.
# "environments/lab-itay-26.yaml"). Both forms are equivalent. Defaults to
# the ENV_NAME environment variable if set, otherwise requires an argument.
#
# Prerequisites (same as every adapter):
#   - KUBECONFIG pointing at the target cluster
#   - runai-installer namespace exists with:
#       runai-cp-admin         (username/password for the cluster-installer Job)
#       runai-cp-secret-values (sensitive Helm values for the control plane)
#   - Registry credential Secrets in runai-backend and runai namespaces
#
# The inner Jobs that Helm waits on run the documented "helm upgrade --install"
# of the Run:ai charts. --wait here means "wait for the Job to finish", which
# means "wait for Run:ai to be installed or upgraded". Timeout is 40m to match
# the Flux and ArgoCD adapters.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Accept bare name ("lab-itay-26") or full relative path
# ("environments/lab-itay-26.yaml"). Fall back to $ENV_NAME if set.
ARG="${1:-${ENV_NAME:-}}"
if [[ -z "$ARG" ]]; then
  echo "ERROR: pass an environment name or set ENV_NAME" >&2
  echo "Usage: $0 <env-name>  (e.g. lab-itay-26)" >&2
  exit 1
fi

if [[ "$ARG" == environments/* ]] || [[ "$ARG" == *.yaml ]]; then
  ENV_PATH="$ARG"
else
  ENV_PATH="environments/${ARG}.yaml"
fi

echo "==> Environment: ${ENV_PATH}"

# helm --wait on a chart that contains a Job waits for the Job pod to be
# Running, not for the Job to Complete. We therefore wait explicitly for the
# inner Job to reach a terminal state before proceeding to the next stage.
wait_for_job() {
  local NAMESPACE="$1" LABEL_SELECTOR="$2" TIMEOUT="${3:-2400}"
  local JOB
  JOB=$(kubectl -n "$NAMESPACE" get job -l "$LABEL_SELECTOR" \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
  if [[ -z "$JOB" ]]; then
    echo "ERROR: no Job found with selector $LABEL_SELECTOR in $NAMESPACE" >&2
    return 1
  fi
  echo "    waiting for Job $JOB to complete (timeout ${TIMEOUT}s)..."
  kubectl -n "$NAMESPACE" wait "job/$JOB" \
    --for=condition=Complete --timeout="${TIMEOUT}s" 2>/dev/null && return 0
  # If Complete timed out, check if it failed
  kubectl -n "$NAMESPACE" wait "job/$JOB" \
    --for=condition=Failed --timeout=5s 2>/dev/null && {
    echo "ERROR: Job $JOB failed" >&2
    kubectl -n "$NAMESPACE" logs "job/$JOB" --tail=20 >&2
    return 1
  }
  echo "ERROR: Job $JOB did not complete within ${TIMEOUT}s" >&2
  return 1
}

echo "==> Control plane stage"
helm upgrade --install runai-installer "${REPO_ROOT}/charts/runai-installer" \
  -f "${REPO_ROOT}/charts/runai-installer/values.yaml" \
  -f "${REPO_ROOT}/charts/runai-installer/${ENV_PATH}" \
  --namespace runai-installer \
  --create-namespace \
  --timeout 40m
wait_for_job runai-installer app.kubernetes.io/name=runai-installer 2400

echo "==> Cluster stage"
helm upgrade --install runai-cluster-installer "${REPO_ROOT}/charts/runai-cluster-installer" \
  -f "${REPO_ROOT}/charts/runai-cluster-installer/values.yaml" \
  -f "${REPO_ROOT}/charts/runai-cluster-installer/${ENV_PATH}" \
  --namespace runai-installer \
  --create-namespace \
  --timeout 40m
wait_for_job runai-installer app.kubernetes.io/name=runai-cluster-installer 2400

echo "==> Done. Verify with:"
echo "    helm -n runai-backend list"
echo "    helm -n runai list"
