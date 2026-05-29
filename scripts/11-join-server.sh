#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
require_cmd curl

case "$(hostname)" in
  "$MASTER2_HOST")
    NODE_IP="$MASTER2_IP"
    ;;
  "$MASTER3_HOST")
    NODE_IP="$MASTER3_IP"
    ;;
  *)
    echo "This script must run on $MASTER2_HOST or $MASTER3_HOST" >&2
    exit 1
    ;;
esac

render_k3s_config "server" "$NODE_IP" "https://${API_VIP}:6443"

log "Joining k3s server to HA cluster"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server

log "Server joined successfully"


