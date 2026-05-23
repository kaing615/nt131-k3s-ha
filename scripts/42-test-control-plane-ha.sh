#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd sshpass
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

MASTER3_SSH="${MASTER3_USER}@${MASTER3_IP}"
MASTER2_SSH="${MASTER2_USER}@${MASTER2_IP}"

cleanup() {
  ssh_cmd "$MASTER2_SSH" "sudo systemctl start k3s" >/dev/null 2>&1 || true
  ssh_cmd "$MASTER3_SSH" "sudo systemctl start k3s" >/dev/null 2>&1 || true
}

wait_for_api() {
  local timeout_secs="$1"
  local end_time
  end_time=$((SECONDS + timeout_secs))

  while (( SECONDS < end_time )); do
    if kubectl --request-timeout=10s get nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

check_api_down() {
  if kubectl --request-timeout=10s get nodes >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

trap cleanup EXIT

log "Checking API via VIP before failure"
kubectl get nodes
kubectl -n "$NAMESPACE" get pods -o wide

log "Stopping k3s on $MASTER3_HOST. Cluster should still be healthy with 2/3 control-plane nodes."
ssh_cmd "$MASTER3_SSH" "sudo systemctl stop k3s"

if wait_for_api 30; then
  log "Cluster is still reachable after $MASTER3_HOST is down"
  kubectl get nodes
  kubectl -n "$NAMESPACE" get pods -o wide
else
  echo "Cluster API did not stabilize after stopping $MASTER3_HOST" >&2
  exit 1
fi

log "Stopping k3s on $MASTER2_HOST. This should drop etcd below quorum and make the API unavailable."
ssh_cmd "$MASTER2_SSH" "sudo systemctl stop k3s"

sleep 10
if check_api_down; then
  log "API is unavailable as expected after losing 2/3 control-plane nodes"
else
  echo "Cluster API is still responding after stopping $MASTER2_HOST. Re-check your topology and VIP setup." >&2
  exit 1
fi

log "Recovering $MASTER2_HOST to restore quorum"
ssh_cmd "$MASTER2_SSH" "sudo systemctl start k3s"
if wait_for_api 120; then
  log "Cluster API recovered after restarting $MASTER2_HOST"
  kubectl get nodes
else
  echo "Cluster API did not recover after restarting $MASTER2_HOST" >&2
  exit 1
fi

log "Recovering $MASTER3_HOST"
ssh_cmd "$MASTER3_SSH" "sudo systemctl start k3s"
if wait_for_api 120; then
  log "All control-plane nodes should be returning"
  kubectl get nodes
  kubectl -n "$NAMESPACE" get pods -o wide
else
  echo "Cluster API did not stabilize after restarting $MASTER3_HOST" >&2
  exit 1
fi

trap - EXIT
