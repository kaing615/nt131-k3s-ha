#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
ensure_host_matches "$MASTER1_HOST"
require_cmd curl

render_k3s_config "server-init" "$MASTER1_IP"

log "Installing first k3s server"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server

log "Waiting for local API server on master1"
until curl -sk https://127.0.0.1:6443/readyz >/dev/null 2>&1; do
  sleep 2
done

log "Installing kube-vip RBAC manifest into K3s auto-deploy dir"
mkdir -p /var/lib/rancher/k3s/server/manifests
curl -fsSL https://kube-vip.io/manifests/rbac.yaml \
  -o /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml

log "Pulling kube-vip image"
k3s ctr image pull "ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION}"

log "Generating kube-vip static pod manifest"
KV_MANIFEST="/var/lib/rancher/k3s/server/manifests/kube-vip.yaml"
k3s ctr run --rm --net-host "ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION}" kubevip /kube-vip \
  manifest pod \
  --interface "${VIP_INTERFACE}" \
  --address "${API_VIP}" \
  --controlplane \
  --services \
  --arp \
  --leaderElection \
  > "${KV_MANIFEST}"

log "Ensuring kube-vip pod uses kube-system service account"
grep -q 'serviceAccountName: kube-vip' "${KV_MANIFEST}" || \
  sed -i '/^spec:/a\  serviceAccountName: kube-vip\n  serviceAccount: kube-vip' "${KV_MANIFEST}"

log "Current node token"
cat /var/lib/rancher/k3s/server/node-token

log "First server initialized. Wait until VIP ${API_VIP}:6443 responds before joining other nodes."