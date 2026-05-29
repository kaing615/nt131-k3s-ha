#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

log "Labeling nodes"
kubectl label node "$MASTER1_HOST" node-role.nt131/control-plane=true --overwrite
kubectl label node "$MASTER2_HOST" node-role.nt131/control-plane=true --overwrite
kubectl label node "$MASTER3_HOST" node-role.nt131/control-plane=true --overwrite
kubectl label node "$WORKER1_HOST" workload=app node-role.kubernetes.io/worker=worker --overwrite
kubectl label node "$WORKER2_HOST" workload=app node-role.kubernetes.io/worker=worker --overwrite

log "Node labels updated"
