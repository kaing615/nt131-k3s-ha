#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd awk
require_cmd sed
require_cmd grep

export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_LOCAL}"

RESULTS_ROOT="${RESULTS_ROOT:-$ROOT_DIR/results}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUT_DIR="${RESULTS_ROOT}/${TIMESTAMP}-benchmark-suite"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
COOLDOWN_INTERVAL="${COOLDOWN_INTERVAL:-15}"
PRE_SCENARIO_COOLDOWN="${PRE_SCENARIO_COOLDOWN:-60}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-60}"

WARMUP_ENABLED="${WARMUP_ENABLED:-true}"
WARMUP_VUS="${WARMUP_VUS:-2}"
WARMUP_DURATION="${WARMUP_DURATION:-30s}"
WARMUP_COOLDOWN="${WARMUP_COOLDOWN:-30}"

CPU_COOLDOWN_THRESHOLD_MCPU="${CPU_COOLDOWN_THRESHOLD_MCPU:-200}"
CPU_COOLDOWN_CONSECUTIVE="${CPU_COOLDOWN_CONSECUTIVE:-2}"

JOB_NAME="${APP_NAME}-loadgen"

mkdir -p "$OUT_DIR"

mapfile -t SCENARIOS <<'SCENARIOS_EOF'
baseline|Baseline load test — lấy số liệu nền khi tải nhẹ|5|60s
moderate|Moderate load with autoscaling — quan sát HPA scale lên|20|120s
high|High load stress test — ép hệ thống gần giới hạn|40|180s
SCENARIOS_EOF

declare -A LOADGEN_LOG

for sc in baseline moderate high; do
  sc_dir="${OUT_DIR}/scenario-${sc}"
  mkdir -p "$sc_dir"
  LOADGEN_LOG[$sc]="${sc_dir}/loadgen-logs.txt"

  : > "${sc_dir}/pod-count-samples.tsv"
  : > "${sc_dir}/pod-cpu-samples.tsv"
  : > "${sc_dir}/node-cpu-samples.tsv"
  : > "${sc_dir}/worker-node-cpu-samples.tsv"
  : > "${sc_dir}/hpa-samples.tsv"
done

# ─── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  log "Preflight check"

  kubectl get nodes -o wide | tee "${OUT_DIR}/preflight-nodes.txt"
  kubectl -n "$NAMESPACE" get deploy,hpa,pods -o wide | tee "${OUT_DIR}/preflight-slm.txt"

  if ! kubectl top pods -n "$NAMESPACE" >/dev/null 2>&1; then
    log "WARNING: kubectl top pods chưa chạy được. Metrics có thể bị thiếu."
  fi

  if ! kubectl top nodes >/dev/null 2>&1; then
    log "WARNING: kubectl top nodes chưa chạy được. Metrics node có thể bị thiếu."
  fi
}

get_pod_count() {
  kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" --no-headers 2>/dev/null \
    | wc -l | tr -d ' '
}

get_ready_pod_count() {
  kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' 2>/dev/null \
    | awk '$2 == "Running" && $0 ~ /Ready=True/ { c++ } END { print c + 0 }'
}

get_deploy_desired() {
  kubectl -n "$NAMESPACE" get deploy "$APP_NAME" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
}

get_deploy_ready() {
  kubectl -n "$NAMESPACE" get deploy "$APP_NAME" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
}

get_app_cpu_mcpu() {
  local tmp
  tmp="$(mktemp)"

  if kubectl top pods -n "$NAMESPACE" >"$tmp" 2>/dev/null; then
    awk -v app="$APP_NAME" '
      BEGIN { sum = 0 }
      NR > 1 && $1 ~ ("^" app "-") {
        cpu = $2
        gsub(/m/, "", cpu)
        if (cpu ~ /^[0-9.]+$/) sum += cpu
      }
      END { printf "%.0f\n", sum }
    ' "$tmp"
  else
    echo 0
  fi

  rm -f "$tmp"
}

get_worker_nodes() {
  local nodes
  nodes="$(kubectl get nodes -l workload=app -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"

  if [[ -z "${nodes// }" ]]; then
    nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$3 ~ /worker/ || $1 ~ /^worker/ { printf "%s ", $1 }')"
  fi

  echo "$nodes"
}

collect_sample() {
  local out_dir="$1"
  local ts
  ts="$(date '+%FT%T')"

  local pod_count
  pod_count="$(get_pod_count)"
  printf '%s\t%s\n' "$ts" "${pod_count:-0}" >>"${out_dir}/pod-count-samples.tsv"

  local pod_top_tmp="${out_dir}/.pod-top.tmp"
  local node_top_tmp="${out_dir}/.node-top.tmp"

  if kubectl top pods -n "$NAMESPACE" >"$pod_top_tmp" 2>/dev/null; then
    awk -v ts="$ts" -v app="$APP_NAME" '
      BEGIN { sum = 0; count = 0 }
      NR > 1 && $1 ~ ("^" app "-") {
        cpu = $2
        gsub(/m/, "", cpu)
        if (cpu ~ /^[0-9.]+$/) {
          sum += cpu
          count += 1
        }
      }
      END { printf "%s\t%.2f\t%d\n", ts, sum, count }
    ' "$pod_top_tmp" >>"${out_dir}/pod-cpu-samples.tsv"
  else
    printf '%s\t0.00\t0\n' "$ts" >>"${out_dir}/pod-cpu-samples.tsv"
  fi

  if kubectl top nodes >"$node_top_tmp" 2>/dev/null; then
    awk -v ts="$ts" '
      BEGIN { sum = 0; count = 0 }
      NR > 1 {
        cpu_pct = $3
        gsub(/%/, "", cpu_pct)
        if (cpu_pct ~ /^[0-9.]+$/) {
          sum += cpu_pct
          count += 1
        }
      }
      END {
        avg = (count > 0) ? (sum / count) : 0
        printf "%s\t%.2f\t%d\n", ts, avg, count
      }
    ' "$node_top_tmp" >>"${out_dir}/node-cpu-samples.tsv"

    local worker_nodes
    worker_nodes="$(get_worker_nodes)"

    awk -v ts="$ts" -v nodes="$worker_nodes" '
      BEGIN {
        sum = 0
        count = 0
        split(nodes, arr, " ")
        for (i in arr) {
          if (arr[i] != "") allowed[arr[i]] = 1
        }
      }
      NR > 1 && ($1 in allowed) {
        cpu_pct = $3
        gsub(/%/, "", cpu_pct)
        if (cpu_pct ~ /^[0-9.]+$/) {
          sum += cpu_pct
          count += 1
        }
      }
      END {
        avg = (count > 0) ? (sum / count) : 0
        printf "%s\t%.2f\t%d\n", ts, avg, count
      }
    ' "$node_top_tmp" >>"${out_dir}/worker-node-cpu-samples.tsv"
  else
    printf '%s\t0.00\t0\n' "$ts" >>"${out_dir}/node-cpu-samples.tsv"
    printf '%s\t0.00\t0\n' "$ts" >>"${out_dir}/worker-node-cpu-samples.tsv"
  fi

  local hpa_targets desired ready
  hpa_targets="$(kubectl -n "$NAMESPACE" get hpa "$APP_NAME" --no-headers 2>/dev/null | awk '{ print $3 }' || echo "N/A")"
  desired="$(get_deploy_desired)"
  ready="$(get_deploy_ready)"
  printf '%s\t%s\t%s\t%s\n' "$ts" "${hpa_targets:-N/A}" "${desired:-0}" "${ready:-0}" >>"${out_dir}/hpa-samples.tsv"

  rm -f "$pod_top_tmp" "$node_top_tmp"
}

wait_for_single_ready_replica() {
  local sc_dir="$1"
  local deadline=$((SECONDS + MAX_WAIT_SECONDS))

  log "Chờ deployment về đúng 1 replica Ready..."

  kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=300s || true

  while true; do
    local pods ready desired deploy_ready
    pods="$(get_pod_count)"
    ready="$(get_ready_pod_count)"
    desired="$(get_deploy_desired)"
    deploy_ready="$(get_deploy_ready)"

    printf '%s\t%s\n' "$(date '+%FT%T')" "${pods:-0}" >>"${sc_dir}/pod-count-samples.tsv"

    log "Current state: pods=${pods}, readyPods=${ready}, desired=${desired}, deployReady=${deploy_ready}"

    if [[ "${pods:-0}" == "1" && "${ready:-0}" == "1" && "${desired:-0}" == "1" && "${deploy_ready:-0}" == "1" ]]; then
      log "Deployment đã ổn định ở 1 Ready replica."
      break
    fi

    if (( SECONDS > deadline )); then
      log "WARNING: Timeout khi chờ deployment về 1 Ready replica."
      break
    fi

    sleep "$COOLDOWN_INTERVAL"
  done
}

wait_for_cpu_cooldown() {
  local sc_dir="$1"
  local deadline=$((SECONDS + MAX_WAIT_SECONDS))
  local ok_count=0

  log "Chờ CPU app hạ nhiệt <= ${CPU_COOLDOWN_THRESHOLD_MCPU}m trong ${CPU_COOLDOWN_CONSECUTIVE} lần liên tiếp..."

  while true; do
    collect_sample "$sc_dir"

    local cpu
    cpu="$(get_app_cpu_mcpu)"

    log "Current app CPU: ${cpu}m"

    if (( cpu <= CPU_COOLDOWN_THRESHOLD_MCPU )); then
      ok_count=$((ok_count + 1))
    else
      ok_count=0
    fi

    if (( ok_count >= CPU_COOLDOWN_CONSECUTIVE )); then
      log "CPU đã hạ nhiệt đủ điều kiện."
      break
    fi

    if (( SECONDS > deadline )); then
      log "WARNING: Timeout khi chờ CPU hạ nhiệt. Tiếp tục benchmark."
      break
    fi

    sleep "$COOLDOWN_INTERVAL"
  done
}

run_warmup() {
  if [[ "$WARMUP_ENABLED" != "true" ]]; then
    log "Bỏ qua warm-up."
    return
  fi

  log "=========================================="
  log "[WARM-UP] VUS=${WARMUP_VUS}, DURATION=${WARMUP_DURATION}"
  log "Warm-up để model/cache ổn định trước khi đo chính."
  log "=========================================="

  export LOADGEN_VUS="$WARMUP_VUS"
  export LOADGEN_DURATION="$WARMUP_DURATION"

  "$SCRIPT_DIR/32-run-loadgen.sh" >"${OUT_DIR}/warmup-loadgen.txt" 2>&1 || true

  log "Cooldown sau warm-up ${WARMUP_COOLDOWN}s..."
  sleep "$WARMUP_COOLDOWN"
}

force_single_replica() {
  local sc_dir="$1"

  log "Force HPA về min=max=1 để reset nhanh."
  kubectl -n "$NAMESPACE" patch hpa "$APP_NAME" --type merge \
    -p '{"spec":{"minReplicas":1,"maxReplicas":1}}' || true

  log "Force deployment về 1 replica."
  kubectl -n "$NAMESPACE" scale deployment/"$APP_NAME" --replicas=1

  log "Xóa bớt pod cũ để rollout/scale-down nhanh hơn."
  local pods
  pods="$(kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)"

  local count
  count="$(printf '%s\n' "$pods" | sed '/^$/d' | wc -l | tr -d ' ')"

  if (( count > 1 )); then
    printf '%s\n' "$pods" | sed '/^$/d' | awk -v n="$count" 'NR < n' | while read -r pod; do
      log "Delete extra pod: $pod"
      kubectl -n "$NAMESPACE" delete pod "$pod" --grace-period=0 --force || true
    done
  fi

  wait_for_single_ready_replica "$sc_dir"
}

restore_hpa() {
  log "Mở HPA lại: min=${HPA_MIN_REPLICAS}, max=${HPA_MAX_REPLICAS}."
  kubectl -n "$NAMESPACE" patch hpa "$APP_NAME" --type merge \
    -p "{\"spec\":{\"minReplicas\":${HPA_MIN_REPLICAS},\"maxReplicas\":${HPA_MAX_REPLICAS}}}" || true
}

run_scenario() {
  local sc_name="$1"
  local sc_desc="$2"
  local sc_vus="$3"
  local sc_duration="$4"
  local sc_dir="${OUT_DIR}/scenario-${sc_name}"

  log "=========================================="
  log "[SCENARIO] ${sc_name}  VUS=${sc_vus}  DURATION=${sc_duration}"
  log "Mục tiêu: ${sc_desc}"
  log "=========================================="

  log "Force reset về đúng 1 pod để bắt đầu công bằng."
  force_single_replica "$sc_dir"

  wait_for_cpu_cooldown "$sc_dir"

  log "Cooldown cố định trước scenario: ${PRE_SCENARIO_COOLDOWN}s"
  sleep "$PRE_SCENARIO_COOLDOWN"

  restore_hpa

  collect_sample "$sc_dir"

  export LOADGEN_VUS="$sc_vus"
  export LOADGEN_DURATION="$sc_duration"

  log "Bắt đầu loadgen (VUS=${sc_vus}, duration=${sc_duration})..."

  "$SCRIPT_DIR/32-run-loadgen.sh" >"${sc_dir}/loadgen-run.txt" 2>&1 &
  LOADGEN_PID=$!

  while kill -0 "$LOADGEN_PID" 2>/dev/null; do
    collect_sample "$sc_dir"
    sleep "$SAMPLE_INTERVAL"
  done

  LOADGEN_STATUS=0
  wait "$LOADGEN_PID" || LOADGEN_STATUS=$?

  collect_sample "$sc_dir"

  kubectl get hpa -n "$NAMESPACE" >"${sc_dir}/hpa.txt" 2>&1 || true
  kubectl top nodes >"${sc_dir}/top-nodes.txt" 2>&1 || true
  kubectl top pods -n "$NAMESPACE" >"${sc_dir}/top-pods.txt" 2>&1 || true
  kubectl get pods -n "$NAMESPACE" -o wide >"${sc_dir}/pods-wide.txt" 2>&1 || true
  kubectl logs job/"${JOB_NAME}" -n "$NAMESPACE" >"${LOADGEN_LOG[$sc_name]}" 2>&1 || true

  log "Scenario ${sc_name} hoàn tất (exit code: ${LOADGEN_STATUS})"
}

summarize_range() {
  local file="$1"
  awk '
    NR == 1 { min = $2; max = $2 }
    NR > 1 {
      if ($2 < min) min = $2
      if ($2 > max) max = $2
    }
    END {
      if (NR == 0) print "N/A"
      else if (min == max) print min
      else printf "%s -> %s\n", min, max
    }
  ' "$file"
}

summarize_avg() {
  local file="$1"
  awk '
    { sum += $2; count += 1 }
    END {
      if (count == 0) print "N/A"
      else printf "%.2f\n", sum / count
    }
  ' "$file"
}

summarize_max() {
  local file="$1"
  awk '
    NR == 1 { max = $2 }
    NR > 1 && $2 > max { max = $2 }
    END {
      if (NR == 0) print "N/A"
      else print max
    }
  ' "$file"
}

extract_latency() {
  local src="$1"
  local line
  line="$(tr -d '\r' <"$src" | grep 'http_req_duration' | tail -n 1 || true)"

  if [[ -z "$line" ]]; then
    echo "N/A"
    return
  fi

  local avg p95
  avg="$(printf '%s\n' "$line" | sed -n 's/.*avg=\([^ ]*\).*/\1/p')"
  p95="$(printf '%s\n' "$line" | sed -n 's/.*p(95)=\([^ ]*\).*/\1/p')"

  if [[ -n "$avg" && -n "$p95" ]]; then
    printf 'avg=%s, p95=%s' "$avg" "$p95"
  elif [[ -n "$avg" ]]; then
    printf 'avg=%s' "$avg"
  else
    echo "N/A"
  fi
}

extract_error_rate() {
  local src="$1"
  local line
  line="$(tr -d '\r' <"$src" | grep 'http_req_failed' | tail -n 1 || true)"

  if [[ -z "$line" ]]; then
    echo "N/A"
    return
  fi

  local rate
  rate="$(printf '%s\n' "$line" | sed -n 's/.*http_req_failed[^:]*:[[:space:]]*\([^[:space:]]*\).*/\1/p')"

  if [[ -n "$rate" ]]; then
    echo "$rate"
  else
    echo "N/A"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
log "Benchmark suite: 3 scenarios"
log "Kết quả lưu tại: ${OUT_DIR}"

preflight

log "Reset app về 1 replica trước warm-up."
kubectl -n "$NAMESPACE" scale deployment/"$APP_NAME" --replicas=1
kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=300s || true

run_warmup

for entry in "${SCENARIOS[@]}"; do
  IFS='|' read -r sc_name sc_desc sc_vus sc_duration <<<"$entry"
  run_scenario "$sc_name" "$sc_desc" "$sc_vus" "$sc_duration"
done

POD_RANGE=()
MAX_PODS=()
AVG_POD_CPU=()
MAX_POD_CPU=()
AVG_NODE_CPU=()
AVG_WORKER_NODE_CPU=()
LATENCY=()
ERR_RATE=()
SCEN_NAMES=()

for sc in baseline moderate high; do
  sc_dir="${OUT_DIR}/scenario-${sc}"

  SCEN_NAMES+=("$sc")
  POD_RANGE+=("$(summarize_range "${sc_dir}/pod-count-samples.tsv")")
  MAX_PODS+=("$(summarize_max "${sc_dir}/pod-count-samples.tsv")")
  AVG_POD_CPU+=("$(summarize_avg "${sc_dir}/pod-cpu-samples.tsv")")
  MAX_POD_CPU+=("$(summarize_max "${sc_dir}/pod-cpu-samples.tsv")")
  AVG_NODE_CPU+=("$(summarize_avg "${sc_dir}/node-cpu-samples.tsv")")
  AVG_WORKER_NODE_CPU+=("$(summarize_avg "${sc_dir}/worker-node-cpu-samples.tsv")")
  LATENCY+=("$(extract_latency "${LOADGEN_LOG[$sc]}")")
  ERR_RATE+=("$(extract_error_rate "${LOADGEN_LOG[$sc]}")")
done

cat >"${OUT_DIR}/benchmark-suite.md" <<'EOF'
# Benchmark Suite Report

Ghi chú: Script có warm-up trước benchmark, reset deployment về 1 replica trước mỗi scenario, chờ pod Ready, chờ CPU hạ nhiệt, rồi mới bắt đầu đo.

| Kịch bản | VUS | Thời lượng | Số Pod | Max Pod | Avg Pod CPU (mCPU) | Max Pod CPU (mCPU) | Avg All Nodes CPU (%) | Avg Worker CPU (%) | Độ trễ | Error rate |
|---|---:|---:|---|---:|---:|---:|---:|---:|---|---|
EOF

for i in 0 1 2; do
  sc="${SCEN_NAMES[$i]}"

  case "$sc" in
    baseline)
      label="Baseline"
      vus="5"
      duration="60s"
      ;;
    moderate)
      label="Moderate"
      vus="20"
      duration="120s"
      ;;
    high)
      label="High stress"
      vus="40"
      duration="180s"
      ;;
  esac

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$label" "$vus" "$duration" \
    "${POD_RANGE[$i]}" "${MAX_PODS[$i]}" \
    "${AVG_POD_CPU[$i]}" "${MAX_POD_CPU[$i]}" \
    "${AVG_NODE_CPU[$i]}" "${AVG_WORKER_NODE_CPU[$i]}" \
    "${LATENCY[$i]}" "${ERR_RATE[$i]}" >>"${OUT_DIR}/benchmark-suite.md"
done

cat >"${OUT_DIR}/benchmark-suite.txt" <<EOF
Benchmark Suite — $(date '+%F %T')
Output: ${OUT_DIR}

Fairness controls:
  - Warm-up enabled          : ${WARMUP_ENABLED}
  - Warm-up                  : VUS=${WARMUP_VUS}, duration=${WARMUP_DURATION}
  - Pre-scenario cooldown    : ${PRE_SCENARIO_COOLDOWN}s
  - CPU cooldown threshold   : ${CPU_COOLDOWN_THRESHOLD_MCPU}m
  - Sample interval          : ${SAMPLE_INTERVAL}s

EOF

for i in 0 1 2; do
  sc="${SCEN_NAMES[$i]}"

  case "$sc" in
    baseline) label="Baseline (VUS=5, 60s)" ;;
    moderate) label="Moderate (VUS=20, 120s)" ;;
    high) label="High stress (VUS=40, 180s)" ;;
  esac

  cat >>"${OUT_DIR}/benchmark-suite.txt" <<EOF
=== ${label} ===
  Pod count range       : ${POD_RANGE[$i]}
  Max pods              : ${MAX_PODS[$i]}
  Avg pod CPU           : ${AVG_POD_CPU[$i]} mCPU
  Max pod CPU           : ${MAX_POD_CPU[$i]} mCPU
  Avg all nodes CPU     : ${AVG_NODE_CPU[$i]}%
  Avg worker nodes CPU  : ${AVG_WORKER_NODE_CPU[$i]}%
  Latency               : ${LATENCY[$i]}
  Error rate            : ${ERR_RATE[$i]}
  Details               : ${OUT_DIR}/scenario-${sc}/

EOF
done

kubectl get nodes -o wide >"${OUT_DIR}/final-nodes.txt" 2>&1 || true
kubectl -n "$NAMESPACE" get deploy,hpa,pods -o wide >"${OUT_DIR}/final-slm.txt" 2>&1 || true
kubectl top nodes >"${OUT_DIR}/final-top-nodes.txt" 2>&1 || true
kubectl top pods -n "$NAMESPACE" >"${OUT_DIR}/final-top-pods.txt" 2>&1 || true

log "Benchmark suite hoàn tất."
echo
echo "=== benchmark-suite.txt ==="
cat "${OUT_DIR}/benchmark-suite.txt"
echo
echo "=== benchmark-suite.md ==="
cat "${OUT_DIR}/benchmark-suite.md"
echo
log "Tất cả artifacts: ${OUT_DIR}"