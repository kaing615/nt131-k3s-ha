#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

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

log "Streaming load generator logs"
kubectl -n "$NAMESPACE" logs -f job/"${APP_NAME}-loadgen"
