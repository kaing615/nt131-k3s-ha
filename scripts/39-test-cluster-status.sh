#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd curl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

EXPECTED_NODES=("$MASTER1_HOST" "$MASTER2_HOST" "$MASTER3_HOST" "$WORKER1_HOST" "$WORKER2_HOST")

is_ready() {
  local node="$1"
  kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

log "Checking all expected nodes exist and are Ready"
for node in "${EXPECTED_NODES[@]}"; do
  if [[ "$(is_ready "$node")" != "True" ]]; then
    echo "Node ${node} is not Ready." >&2
    kubectl get nodes -o wide >&2 || true
    exit 1
  fi
done

log "Checking node role labels"
MASTER_READY_COUNT="$(kubectl get nodes -l node-role.nt131/control-plane=true --no-headers | wc -l | tr -d ' ')"
WORKER_READY_COUNT="$(kubectl get nodes -l node-role.nt131/worker=true,workload=app --no-headers | wc -l | tr -d ' ')"

if [[ "$MASTER_READY_COUNT" -ne 3 ]]; then
  echo "Expected 3 labeled control-plane nodes, got ${MASTER_READY_COUNT}." >&2
  kubectl get nodes --show-labels >&2
  exit 1
fi

if [[ "$WORKER_READY_COUNT" -ne 2 ]]; then
  echo "Expected 2 labeled worker nodes, got ${WORKER_READY_COUNT}." >&2
  kubectl get nodes --show-labels >&2
  exit 1
fi

log "Checking Kubernetes API through VIP ${API_VIP}"
curl -sk --max-time 10 "https://${API_VIP}:6443/version" >/dev/null

if kubectl -n "$NAMESPACE" get deploy "$APP_NAME" >/dev/null 2>&1; then
  log "Checking ${APP_NAME} pods are scheduled only on worker nodes"
  BAD_PODS="$(
    kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' |
      awk -v w1="$WORKER1_HOST" -v w2="$WORKER2_HOST" '$2 != w1 && $2 != w2 { print $0 }'
  )"

  if [[ -n "$BAD_PODS" ]]; then
    echo "Some ${APP_NAME} pods are not running on worker nodes:" >&2
    printf '%s\n' "$BAD_PODS" >&2
    exit 1
  fi
else
  log "Deployment ${NAMESPACE}/${APP_NAME} not found; skipping workload placement check"
fi

log "Cluster status test passed"
kubectl get nodes -o wide
