#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

RESULTS_ROOT="${RESULTS_ROOT:-$ROOT_DIR/results}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUT_DIR="${RESULTS_ROOT}/${TIMESTAMP}"

mkdir -p "$OUT_DIR"

run_and_capture() {
  local name="$1"
  shift

  log "Collecting ${name}"
  "$@" >"${OUT_DIR}/${name}.txt" 2>&1
  cat "${OUT_DIR}/${name}.txt"
}

log "Saving cluster results to ${OUT_DIR}"

run_and_capture hpa kubectl get hpa -n "$NAMESPACE"
run_and_capture top-nodes kubectl top nodes
run_and_capture top-pods kubectl top pods -n "$NAMESPACE"
run_and_capture pods-wide kubectl get pods -n "$NAMESPACE" -o wide
run_and_capture loadgen-logs kubectl logs job/"${APP_NAME}-loadgen" -n "$NAMESPACE"

log "Results collected successfully"
log "Files created:"
ls -1 "$OUT_DIR"
