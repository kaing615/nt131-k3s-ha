#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root

log "Installing base dependencies"
apt-get update
apt-get install -y curl ca-certificates gnupg lsb-release jq sshpass iptables iproute2 ebtables ethtool socat conntrack

log "Disabling swap"
swapoff -a || true
sed -ri 's/^\s*([^#].*\sswap\s.*)$/# \1/' /etc/fstab || true

log "Enabling cgroup memory and cpuset for Raspberry Pi"
CMDLINE_FILE=""
if [[ -f /boot/firmware/cmdline.txt ]]; then
  CMDLINE_FILE="/boot/firmware/cmdline.txt"
elif [[ -f /boot/cmdline.txt ]]; then
  CMDLINE_FILE="/boot/cmdline.txt"
fi

if [[ -n "$CMDLINE_FILE" ]]; then
  CGROUP_CHANGED=0
  for arg in cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory; do
    if ! grep -qw "$arg" "$CMDLINE_FILE"; then
      sed -i "1s/$/ $arg/" "$CMDLINE_FILE"
      CGROUP_CHANGED=1
    fi
  done
  if [[ "$CGROUP_CHANGED" -eq 1 ]]; then
    log "Updated ${CMDLINE_FILE}. Reboot this node before installing or restarting k3s."
  else
    log "Cgroup kernel arguments already present in ${CMDLINE_FILE}"
  fi
else
  log "No Raspberry Pi cmdline.txt found; skipping cgroup kernel argument update"
fi

log "Configuring kernel modules"
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system

log "Node prerequisites completed"
