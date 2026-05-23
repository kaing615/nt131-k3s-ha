#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
require_cmd curl

case "$(hostname)" in
  "$WORKER1_HOST")
    NODE_IP="$WORKER1_IP"
    ;;
  "$WORKER2_HOST")
    NODE_IP="$WORKER2_IP"
    ;;
  *)
    echo "This script must run on $WORKER1_HOST or $WORKER2_HOST" >&2
    exit 1
    ;;
esac

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
server: https://${API_VIP}:6443
token: ${K3S_TOKEN}
node-ip: ${NODE_IP}
EOF

log "Joining k3s agent"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - agent

log "Agent joined successfully"
