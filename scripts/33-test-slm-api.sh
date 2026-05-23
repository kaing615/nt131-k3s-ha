#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

SERVICE_URL="${SLM_SERVICE_URL:-http://${APP_NAME}.${NAMESPACE}.svc.cluster.local}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
TEST_POD="${APP_NAME}-api-smoke-$(date '+%s')"
CHECK_INGRESS=0

if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
  CHECK_INGRESS=1
fi

log "Checking SLM deployment rollout"
kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=900s
kubectl -n "$NAMESPACE" wait pod -l app="$APP_NAME" --for=condition=Ready --timeout=300s

log "Checking Service endpoints"
kubectl -n "$NAMESPACE" get endpoints "$APP_NAME" -o wide
ENDPOINT_COUNT="$(kubectl -n "$NAMESPACE" get endpoints "$APP_NAME" -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w | tr -d ' ')"
if [[ "${ENDPOINT_COUNT:-0}" -eq 0 ]]; then
  echo "Service ${NAMESPACE}/${APP_NAME} has no ready endpoints." >&2
  exit 1
fi

log "Running in-cluster SLM API smoke test"
kubectl -n "$NAMESPACE" run "$TEST_POD" \
  --image="$CURL_IMAGE" \
  --restart=Never \
  --rm -i \
  --quiet \
  --env="BASE_URL=$SERVICE_URL" \
  --env="APP_NAME=$APP_NAME" \
  --env="INGRESS_HOST=$INGRESS_HOST" \
  --env="CHECK_INGRESS=$CHECK_INGRESS" \
  --command -- sh -eu -c '
    payload="{\"model\":\"${APP_NAME}\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a concise assistant.\"},{\"role\":\"user\",\"content\":\"Give one short sentence about embedded systems.\"}],\"max_tokens\":32,\"temperature\":0.2}"

    echo "== Service health =="
    curl -fsS "${BASE_URL}/health"
    echo

    echo "== Service chat completion =="
    curl -fsS -X POST "${BASE_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$payload" > /tmp/chat.json
    cat /tmp/chat.json
    echo
    grep -q "\"choices\"" /tmp/chat.json

    if [ "${CHECK_INGRESS}" = "1" ]; then
      echo "== Ingress health through Traefik service =="
      curl -fsS -H "Host: ${INGRESS_HOST}" \
        "http://traefik.kube-system.svc.cluster.local/health"
      echo
    else
      echo "Traefik service not found in kube-system; skipping in-cluster Ingress check."
    fi
  '

log "SLM API smoke test passed"
