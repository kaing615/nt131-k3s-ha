#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd sshpass

mkdir -p "$(dirname "$KUBECONFIG_LOCAL")"

log "Fetching kubeconfig from $MASTER1_HOST"
scp_cmd "${MASTER1_USER}@${MASTER1_IP}:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_LOCAL"
sed -i.bak "s/127.0.0.1/${API_VIP}/g" "$KUBECONFIG_LOCAL"
rm -f "${KUBECONFIG_LOCAL}.bak"

log "Kubeconfig saved to $KUBECONFIG_LOCAL"
