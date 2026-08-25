#!/usr/bin/env bash
# Single entry point for applying Run:ai installer adapters.
#
# Usage:
#   ./adapters/apply.sh <tool> <env-name>
#
# Tools:   flux | argocd | ci
# Env:     any name matching an environments/ file in each wrapper chart
#
# Examples:
#   ./adapters/apply.sh flux    lab-itay-26
#   ./adapters/apply.sh argocd  prod-customer-a
#   ./adapters/apply.sh ci      staging-emea
#
# Adding a new environment:
#   1. Create charts/runai-installer/environments/<env-name>.yaml
#   2. Create charts/runai-cluster-installer/environments/<env-name>.yaml
#   3. Run this script with the new env name — no other files to touch.
#
# The adapter YAML files (adapters/flux/*.yaml, adapters/argocd/*.yaml) use
# ${ENV_NAME} as a placeholder. This script substitutes the placeholder before
# applying, so those files should never be applied with kubectl directly.
set -euo pipefail

TOOL="${1:?usage: apply.sh <flux|argocd|ci> <env-name>}"
ENV_NAME="${2:?usage: apply.sh <flux|argocd|ci> <env-name>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Verify the environments files exist for this env before doing anything
for CHART in runai-installer runai-cluster-installer; do
  ENV_FILE="${REPO_ROOT}/charts/${CHART}/environments/${ENV_NAME}.yaml"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: environments file not found: ${ENV_FILE}" >&2
    echo "Create it first, then re-run this script." >&2
    exit 1
  fi
done

sub() {
  # Substitute only ${ENV_NAME} — leave other ${...} patterns untouched.
  ENV_NAME="$ENV_NAME" envsubst '${ENV_NAME}' < "$1"
}

case "$TOOL" in
  flux)
    echo "==> Applying Flux source (GitRepository)"
    kubectl apply -f "${REPO_ROOT}/adapters/flux/source.yaml"

    echo "==> Applying Flux control-plane HelmRelease (env: ${ENV_NAME})"
    sub "${REPO_ROOT}/adapters/flux/control-plane.yaml" | kubectl apply -f -

    echo "==> Applying Flux cluster HelmRelease (env: ${ENV_NAME})"
    sub "${REPO_ROOT}/adapters/flux/cluster.yaml" | kubectl apply -f -
    ;;

  argocd)
    echo "==> Applying ArgoCD control-plane Application (env: ${ENV_NAME})"
    sub "${REPO_ROOT}/adapters/argocd/application-control-plane.yaml" | kubectl apply -f -

    echo "==> Applying ArgoCD cluster Application (env: ${ENV_NAME})"
    sub "${REPO_ROOT}/adapters/argocd/application-cluster.yaml" | kubectl apply -f -
    ;;

  ci)
    echo "==> Running CI install for env: ${ENV_NAME}"
    "${REPO_ROOT}/adapters/ci/install.sh" "${ENV_NAME}"
    ;;

  *)
    echo "ERROR: unknown tool '${TOOL}'. Choose: flux | argocd | ci" >&2
    exit 1
    ;;
esac

echo "==> Done (tool=${TOOL}, env=${ENV_NAME})"
