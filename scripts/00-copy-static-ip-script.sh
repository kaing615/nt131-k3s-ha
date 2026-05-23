#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd sshpass

STATIC_SCRIPT="$SCRIPT_DIR/00-configure-static-ip.sh"
if [[ ! -f "$STATIC_SCRIPT" ]]; then
  echo "Missing script: $STATIC_SCRIPT" >&2
  exit 1
fi

copy_one() {
  local role="$1"
  local host_var="${role}_HOST"
  local user_var="${role}_USER"
  local ssh_host_var="${role}_SSH_HOST"
  local host="${!host_var}"
  local user="${!user_var}"
  local ssh_host="${!ssh_host_var:-$host}"

  log "Copying static IP script to ${user}@${ssh_host}:~ for ${host}"
  scp_cmd "$STATIC_SCRIPT" "${user}@${ssh_host}:~/00-configure-static-ip.sh"
  scp_cmd "$ENV_FILE" "${user}@${ssh_host}:~/cluster.env"
  ssh_cmd "${user}@${ssh_host}" "chmod +x ~/00-configure-static-ip.sh"
}

copy_one MASTER1
copy_one MASTER2
copy_one MASTER3
copy_one WORKER1
copy_one WORKER2

log "Done. On each Pi, run: sudo ~/00-configure-static-ip.sh"
