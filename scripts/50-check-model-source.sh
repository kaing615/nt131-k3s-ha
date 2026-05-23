#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd curl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

MODEL_URL="https://huggingface.co/${HF_MODEL_REPO}/resolve/main/${HF_MODEL_FILE}"
PF_PID=""
PF_LOG=""

cleanup() {
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" >/dev/null 2>&1; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  if [[ -n "$PF_LOG" && -f "$PF_LOG" ]]; then
    rm -f "$PF_LOG"
  fi
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

trap cleanup EXIT

log "Checking upstream SLM artifacts"
echo "llama.cpp image: $SLM_IMAGE"
echo "GGUF model URL : $MODEL_URL"
curl -fsSLI "$MODEL_URL" >/dev/null || fail "Cannot reach the configured GGUF model URL"

if ! kubectl -n "$NAMESPACE" get deployment "$APP_NAME" >/dev/null 2>&1; then
  log "Deployment $APP_NAME is not present in namespace $NAMESPACE"
  echo "Upstream model source is reachable."
  echo "In-cluster checks will run after you deploy the SLM stack."
  exit 0
fi

log "Waiting for deployment availability"
kubectl -n "$NAMESPACE" wait --for=condition=available deployment/"$APP_NAME" --timeout=600s >/dev/null

POD_NAME="$(kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD_NAME" ]] || fail "No running pod found for app=$APP_NAME"

log "Checking llama-server binary and model file inside pod $POD_NAME"
kubectl -n "$NAMESPACE" exec "$POD_NAME" -- sh -c "command -v llama-server >/dev/null && test -s '/models/${HF_MODEL_FILE}'" \
  || fail "Pod is missing llama-server or the model file /models/${HF_MODEL_FILE}"

log "Checking service endpoints"
ENDPOINT_COUNT="$(kubectl -n "$NAMESPACE" get endpoints "$APP_NAME" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' | awk 'NF{count++} END{print count+0}')"
[[ "$ENDPOINT_COUNT" -gt 0 ]] || fail "Service $APP_NAME has no ready endpoints"

log "Port-forwarding service/$APP_NAME for HTTP checks"
PF_LOG="$(mktemp /tmp/slm-port-forward.XXXXXX.log)"
kubectl -n "$NAMESPACE" port-forward service/"$APP_NAME" 18080:80 >"$PF_LOG" 2>&1 &
PF_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:18080/health" >/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS "http://127.0.0.1:18080/health" >/dev/null || {
  cat "$PF_LOG" >&2
  fail "Health endpoint check failed through service/$APP_NAME"
}

curl -fsS "http://127.0.0.1:18080/v1/models" >/dev/null || {
  cat "$PF_LOG" >&2
  fail "OpenAI-compatible /v1/models endpoint is not responding"
}

log "SLM model source and runtime checks passed"
