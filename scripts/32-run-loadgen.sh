#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"
LOG_DIR="${LOG_DIR:-./loadgen-logs-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$LOG_DIR"

MONITOR_PIDS=()

cleanup_monitors() {
  for pid in "${MONITOR_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}

trap cleanup_monitors EXIT INT TERM

kubectl -n "$NAMESPACE" delete job "${APP_NAME}-loadgen" --ignore-not-found
kubectl -n "$NAMESPACE" delete configmap "${APP_NAME}-k6-script" --ignore-not-found

log "Creating k6 load generator job"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-k6-script
  namespace: ${NAMESPACE}
data:
  script.js: |
    import http from 'k6/http';
    import { sleep } from 'k6';

    export const options = {
      vus: ${LOADGEN_VUS},
      duration: '${LOADGEN_DURATION}',
    };

    export default function () {
      http.post('${LOADGEN_BASE_URL}/v1/chat/completions', JSON.stringify({
        model: '${APP_NAME}',
        messages: [
          { role: 'system', content: 'You are a concise assistant.' },
          { role: 'user', content: 'Give me one short sentence about embedded systems.' }
        ],
        max_tokens: 48,
        temperature: 0.2
      }), {
        headers: { 'Content-Type': 'application/json' },
      });

      sleep(0.5);
    }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${APP_NAME}-loadgen
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: k6
        image: ${LOADGEN_IMAGE}
        command: ["k6", "run", "/scripts/script.js"]
        volumeMounts:
        - name: script
          mountPath: /scripts
      volumes:
      - name: script
        configMap:
          name: ${APP_NAME}-k6-script
EOF

log "Starting live monitors, logs will be saved to $LOG_DIR"

(
  kubectl -n "$NAMESPACE" get hpa "$APP_NAME" -w 2>&1 \
    | while IFS= read -r line; do
        echo "[HPA] $line"
      done
) | tee "$LOG_DIR/hpa-watch.log" &
MONITOR_PIDS+=("$!")

(
  kubectl -n "$NAMESPACE" get pods -w 2>&1 \
    | while IFS= read -r line; do
        echo "[PODS] $line"
      done
) | tee "$LOG_DIR/pods-watch.log" &
MONITOR_PIDS+=("$!")

(
  while true; do
    echo "[TOP-PODS] ===== $(date '+%Y-%m-%d %H:%M:%S') ====="
    kubectl top pods -n "$NAMESPACE" 2>&1 | while IFS= read -r line; do
      echo "[TOP-PODS] $line"
    done
    sleep "$MONITOR_INTERVAL"
  done
) | tee "$LOG_DIR/top-pods.log" &
MONITOR_PIDS+=("$!")

(
  while true; do
    echo "[TOP-NODES] ===== $(date '+%Y-%m-%d %H:%M:%S') ====="
    kubectl top nodes 2>&1 | while IFS= read -r line; do
      echo "[TOP-NODES] $line"
    done
    sleep "$MONITOR_INTERVAL"
  done
) | tee "$LOG_DIR/top-nodes.log" &
MONITOR_PIDS+=("$!")

log "Waiting for load generator pod to be ready"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l job-name="${APP_NAME}-loadgen" \
  --timeout=180s

log "Streaming load generator logs"
kubectl -n "$NAMESPACE" logs -f job/"${APP_NAME}-loadgen" \
  --pod-running-timeout=180s 2>&1 \
  | while IFS= read -r line; do
      echo "[K6] $line"
    done \
  | tee "$LOG_DIR/k6.log"

log "Waiting for load generator job to complete"
kubectl -n "$NAMESPACE" wait --for=condition=Complete job/"${APP_NAME}-loadgen" \
  --timeout=900s || true

log "Final status"
kubectl -n "$NAMESPACE" get deploy "$APP_NAME" | tee "$LOG_DIR/final-deploy.txt"
kubectl -n "$NAMESPACE" get hpa "$APP_NAME" | tee "$LOG_DIR/final-hpa.txt"
kubectl -n "$NAMESPACE" get pods -o wide | tee "$LOG_DIR/final-pods.txt"
kubectl top pods -n "$NAMESPACE" | tee "$LOG_DIR/final-top-pods.txt" || true
kubectl top nodes | tee "$LOG_DIR/final-top-nodes.txt" || true

log "Logs saved in $LOG_DIR"