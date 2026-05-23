#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

log "Deleting one pod to verify pod self-healing"
POD_NAME="$(kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NAMESPACE" delete pod "$POD_NAME"

log "Waiting for replacement pod"
kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=180s
kubectl -n "$NAMESPACE" get pods -o wide

