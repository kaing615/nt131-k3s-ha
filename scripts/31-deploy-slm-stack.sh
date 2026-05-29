#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${SLM_IMAGE:=ghcr.io/ggml-org/llama.cpp:server}"

require_cmd kubectl
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

log "Deploying namespace, Deployment, Service, Ingress, HPA"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: workload
                operator: In
                values:
                - app
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_CACHE_HOST_PATH}
          type: DirectoryOrCreate
      initContainers:
      - name: download-model
        image: curlimages/curl:8.10.1
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
          runAsGroup: 0
        command:
        - sh
        - -c
        - |
          set -eu
          mkdir -p /models
          model_path="/models/${HF_MODEL_FILE}"
          temp_path="\${model_path}.part"
          if [ -s "\${model_path}" ]; then
            echo "Model already exists in shared node cache"
          else
            echo "Downloading GGUF model from Hugging Face"
            rm -f "\${temp_path}"
            curl -L --fail --retry 5 --retry-delay 5 \
              "https://huggingface.co/${HF_MODEL_REPO}/resolve/main/${HF_MODEL_FILE}" \
              -o "\${temp_path}"
            test -s "\${temp_path}"
            mv "\${temp_path}" "\${model_path}"
            chmod 0644 "\${model_path}"
          fi
        volumeMounts:
        - name: model-cache
          mountPath: /models
      containers:
      - name: ${APP_NAME}
        image: ${SLM_IMAGE}
        imagePullPolicy: IfNotPresent
        args:
        - "-m"
        - "/models/${HF_MODEL_FILE}"
        - "--host"
        - "0.0.0.0"
        - "--port"
        - "${SLM_PORT}"
        - "-c"
        - "${LLM_CONTEXT_SIZE}"
        - "-n"
        - "${LLM_MAX_TOKENS}"
        - "-np"
        - "${LLM_PARALLEL}"
        - "-t"
        - "${LLM_THREADS}"
        - "--metrics"
        ports:
        - containerPort: ${SLM_PORT}
        volumeMounts:
        - name: model-cache
          mountPath: /models
        resources:
          requests:
            cpu: "1000m"
            memory: "1500Mi"
          limits:
            cpu: "2000m"
            memory: "2500Mi"
        startupProbe:
          httpGet:
            path: /health
            port: ${SLM_PORT}
          failureThreshold: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: ${SLM_PORT}
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: ${SLM_PORT}
          initialDelaySeconds: 20
          periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP_NAME}
  ports:
  - name: http
    port: 80
    targetPort: ${SLM_PORT}
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  ingressClassName: traefik
  rules:
  - host: ${INGRESS_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${APP_NAME}
            port:
              number: 80
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP_NAME}
  minReplicas: ${HPA_MIN_REPLICAS}
  maxReplicas: ${HPA_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: ${HPA_CPU_PERCENT}
EOF

log "Waiting for deployment rollout"
kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=900s