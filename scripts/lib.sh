#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${CLUSTER_ENV_FILE:-$ROOT_DIR/cluster.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

ssh_cmd() {
  require_cmd sshpass
  sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

scp_cmd() {
  require_cmd sshpass
  sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root or with sudo." >&2
    exit 1
  fi
}

ensure_host_matches() {
  local expected="$1"
  local actual
  actual="$(hostname)"
  if [[ "$actual" != "$expected" ]]; then
    echo "This script must run on $expected, current host is $actual" >&2
    exit 1
  fi
}

render_k3s_config() {
  local role="$1"
  local node_ip="$2"
  local server_url="${3:-}"

  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/config.yaml <<EOF
token: ${K3S_TOKEN}
node-ip: ${node_ip}
write-kubeconfig-mode: "0644"
tls-san:
  - ${API_VIP}
disable:
  - servicelb
EOF

  if [[ -n "$server_url" ]]; then
    cat >> /etc/rancher/k3s/config.yaml <<EOF
server: ${server_url}
EOF
  fi

  if [[ "$role" == "server-init" ]]; then
    cat >> /etc/rancher/k3s/config.yaml <<EOF
cluster-init: true
EOF
  fi
}
