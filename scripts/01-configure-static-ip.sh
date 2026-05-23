#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CLUSTER_ENV_FILE:-$SCRIPT_DIR/cluster.env}"

if [[ ! -f "$ENV_FILE" && -f "$SCRIPT_DIR/../cluster.env" ]]; then
  ENV_FILE="$SCRIPT_DIR/../cluster.env"
fi

if [[ ! -f "$ENV_FILE" && -f "$HOME/cluster.env" ]]; then
  ENV_FILE="$HOME/cluster.env"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing cluster.env. Put cluster.env next to this script or at ~/cluster.env." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

DRY_RUN=0
HOST_OVERRIDE=""

usage() {
  cat <<EOF
Usage: sudo ./00-configure-static-ip.sh [--host master1] [--dry-run]

The script maps the current hostname to *_IP variables in cluster.env and
configures NODE_INTERFACE with NODE_PREFIX, NODE_GATEWAY, and NODE_DNS_SERVERS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST_OVERRIDE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
  echo "Please run as root: sudo ./00-configure-static-ip.sh" >&2
  exit 1
fi

NODE_INTERFACE="${NODE_INTERFACE:-${VIP_INTERFACE:-eth0}}"
NODE_PREFIX="${NODE_PREFIX:-22}"
NODE_GATEWAY="${NODE_GATEWAY:-172.31.8.1}"
NODE_DNS_SERVERS="${NODE_DNS_SERVERS:-$NODE_GATEWAY 1.1.1.1 8.8.8.8}"

NODE_HOST="$(hostname -s)"
if [[ -n "$HOST_OVERRIDE" ]]; then
  NODE_HOST="$HOST_OVERRIDE"
fi

NODE_IP=""
case "$NODE_HOST" in
  "$MASTER1_HOST") NODE_IP="$MASTER1_IP" ;;
  "$MASTER2_HOST") NODE_IP="$MASTER2_IP" ;;
  "$MASTER3_HOST") NODE_IP="$MASTER3_IP" ;;
  "$WORKER1_HOST") NODE_IP="$WORKER1_IP" ;;
  "$WORKER2_HOST") NODE_IP="$WORKER2_IP" ;;
  *)
    echo "Hostname '$NODE_HOST' does not match any host in cluster.env." >&2
    echo "Use --host master1|master2|master3|worker1|worker2 if needed." >&2
    exit 1
    ;;
esac

if [[ -z "$NODE_IP" ]]; then
  echo "Could not resolve static IP for host '$NODE_HOST'." >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" && "$DRY_RUN" -eq 0 ]]; then
    cp -a "$file" "${file}.bak.$(date '+%Y%m%d%H%M%S')"
  fi
}

configure_networkmanager() {
  local con_name
  con_name="$(nmcli -g GENERAL.CONNECTION device show "$NODE_INTERFACE" 2>/dev/null | head -n 1 || true)"

  if [[ -z "$con_name" || "$con_name" == "--" ]]; then
    con_name="nt131-${NODE_INTERFACE}"
    run nmcli connection add type ethernet ifname "$NODE_INTERFACE" con-name "$con_name"
  fi

  log "Configuring NetworkManager connection '$con_name'"
  run nmcli connection modify "$con_name" \
    ipv4.method manual \
    ipv4.addresses "${NODE_IP}/${NODE_PREFIX}" \
    ipv4.gateway "$NODE_GATEWAY" \
    ipv4.dns "$NODE_DNS_SERVERS" \
    ipv6.method ignore \
    connection.autoconnect yes
  run nmcli connection up "$con_name"
}

configure_dhcpcd() {
  local conf="/etc/dhcpcd.conf"
  local tmp
  tmp="$(mktemp)"

  log "Configuring dhcpcd in $conf"
  backup_file "$conf"

  if [[ -f "$conf" ]]; then
    awk '
      /^# BEGIN nt131-static$/ { skip=1; next }
      /^# END nt131-static$/ { skip=0; next }
      !skip { print }
    ' "$conf" > "$tmp"
  fi

  cat >> "$tmp" <<EOF
# BEGIN nt131-static
interface ${NODE_INTERFACE}
static ip_address=${NODE_IP}/${NODE_PREFIX}
static routers=${NODE_GATEWAY}
static domain_name_servers=${NODE_DNS_SERVERS}
# END nt131-static
EOF

  if [[ "$DRY_RUN" -eq 1 ]]; then
    sed -n '/# BEGIN nt131-static/,$p' "$tmp"
    rm -f "$tmp"
  else
    install -m 0644 "$tmp" "$conf"
    rm -f "$tmp"
    systemctl restart dhcpcd
  fi
}

configure_netplan() {
  local conf="/etc/netplan/99-nt131-static.yaml"

  log "Configuring netplan in $conf"
  backup_file "$conf"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
network:
  version: 2
  ethernets:
    ${NODE_INTERFACE}:
      dhcp4: false
      addresses:
        - ${NODE_IP}/${NODE_PREFIX}
      routes:
        - to: default
          via: ${NODE_GATEWAY}
      nameservers:
        addresses: [${NODE_DNS_SERVERS// /, }]
EOF
  else
    cat > "$conf" <<EOF
network:
  version: 2
  ethernets:
    ${NODE_INTERFACE}:
      dhcp4: false
      addresses:
        - ${NODE_IP}/${NODE_PREFIX}
      routes:
        - to: default
          via: ${NODE_GATEWAY}
      nameservers:
        addresses: [${NODE_DNS_SERVERS// /, }]
EOF
    netplan apply
  fi
}

configure_systemd_networkd() {
  local conf="/etc/systemd/network/10-nt131-${NODE_INTERFACE}.network"

  log "Configuring systemd-networkd in $conf"
  backup_file "$conf"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
[Match]
Name=${NODE_INTERFACE}

[Network]
Address=${NODE_IP}/${NODE_PREFIX}
Gateway=${NODE_GATEWAY}
DNS=${NODE_DNS_SERVERS}
EOF
  else
    cat > "$conf" <<EOF
[Match]
Name=${NODE_INTERFACE}

[Network]
Address=${NODE_IP}/${NODE_PREFIX}
Gateway=${NODE_GATEWAY}
DNS=${NODE_DNS_SERVERS}
EOF
    systemctl enable --now systemd-networkd
    systemctl restart systemd-networkd
  fi
}

log "Host: $NODE_HOST"
log "Interface: $NODE_INTERFACE"
log "Static IP: ${NODE_IP}/${NODE_PREFIX}"
log "Gateway: $NODE_GATEWAY"
log "DNS: $NODE_DNS_SERVERS"

if command -v nmcli >/dev/null 2>&1; then
  configure_networkmanager
elif systemctl list-unit-files dhcpcd.service >/dev/null 2>&1; then
  configure_dhcpcd
elif command -v netplan >/dev/null 2>&1; then
  configure_netplan
else
  configure_systemd_networkd
fi

log "Resulting IPv4 address on $NODE_INTERFACE"
run ip -4 addr show dev "$NODE_INTERFACE"
log "Default routes"
run ip route show default
log "Static IP configuration completed. SSH may reconnect on ${NODE_IP}."
