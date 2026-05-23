#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd sshpass
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

WAIT_SECONDS="${NODE_FAILURE_WAIT_SECONDS:-420}"
POLL_SECONDS="${NODE_FAILURE_POLL_SECONDS:-10}"
TARGET_NODE="${NODE_FAILURE_TARGET_NODE:-$WORKER1_HOST}"
TARGET_USER="${NODE_FAILURE_TARGET_USER:-$WORKER1_USER}"
TARGET_IP="${NODE_FAILURE_TARGET_IP:-$WORKER1_IP}"
RECOVERY_NODE="${NODE_FAILURE_RECOVERY_NODE:-$WORKER2_HOST}"

cleanup() {
  log "Recovering worker ${TARGET_NODE}"
  ssh_cmd "${TARGET_USER}@${TARGET_IP}" "sudo systemctl start k3s-agent" >/dev/null 2>&1 || true
}

wait_for_ready_pod_on_recovery_node() {
  local end_time=$((SECONDS + WAIT_SECONDS))
  local ready_pods

  while (( SECONDS < end_time )); do
    ready_pods="$(
      kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' |
        awk -v node="$RECOVERY_NODE" '$2 == node && $3 == "Running" && $4 == "True" { print $1 }'
    )"

    if [[ -n "$ready_pods" ]]; then
      printf '%s\n' "$ready_pods"
      return 0
    fi

    sleep "$POLL_SECONDS"
  done

  return 1
}

log "Current pod placement"
kubectl -n "$NAMESPACE" get pods -o wide

PODS_ON_TARGET="$(
  kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' |
    awk -v node="$TARGET_NODE" '$2 == node { print $1 }'
)"

if [[ -z "$PODS_ON_TARGET" ]]; then
  echo "No ${APP_NAME} pod is currently running on ${TARGET_NODE}; this test cannot prove reschedule." >&2
  echo "Current pod placement:" >&2
  kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" -o wide >&2
  echo "Run a load/HPA scenario or scale to at least 2 replicas, then rerun this test." >&2
  exit 1
fi

trap cleanup EXIT

log "Target pods on ${TARGET_NODE}: ${PODS_ON_TARGET//$'\n'/, }"
log "Simulating worker failure on ${TARGET_NODE}"
ssh_cmd "${TARGET_USER}@${TARGET_IP}" "sudo systemctl stop k3s-agent"

log "Waiting up to ${WAIT_SECONDS}s for a ready ${APP_NAME} pod on ${RECOVERY_NODE}"
if wait_for_ready_pod_on_recovery_node >/tmp/nt131-rescheduled-pods.txt; then
  log "Observed ready ${APP_NAME} pod on ${RECOVERY_NODE}: $(tr '\n' ' ' </tmp/nt131-rescheduled-pods.txt)"
else
  echo "Timed out waiting for ${APP_NAME} pod to become Ready on ${RECOVERY_NODE}." >&2
  kubectl get nodes -o wide >&2 || true
  kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" -o wide >&2 || true
  exit 1
fi

kubectl -n "$NAMESPACE" get pods -o wide

trap - EXIT
cleanup
log "Worker failure/reschedule test passed"
