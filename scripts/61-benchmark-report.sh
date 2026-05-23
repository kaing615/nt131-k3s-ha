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
OUT_DIR="${RESULTS_ROOT}/${TIMESTAMP}-benchmark"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
SCENARIO_NAME="${SCENARIO_NAME:-Load test with k6 on slm-api}"
JOB_NAME="${APP_NAME}-loadgen"

mkdir -p "$OUT_DIR"

POD_COUNT_SAMPLES="${OUT_DIR}/pod-count-samples.tsv"
POD_CPU_SAMPLES="${OUT_DIR}/pod-cpu-samples.tsv"
NODE_CPU_SAMPLES="${OUT_DIR}/node-cpu-samples.tsv"
LOADGEN_RUN_LOG="${OUT_DIR}/loadgen-run.txt"
SUMMARY_MD="${OUT_DIR}/benchmark-summary.md"
SUMMARY_TXT="${OUT_DIR}/benchmark-summary.txt"

collect_sample() {
  local ts
  local pod_count
  local pod_top_tmp
  local node_top_tmp

  ts="$(date '+%FT%T')"
  pod_count="$(kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s\t%s\n' "$ts" "${pod_count:-0}" >>"$POD_COUNT_SAMPLES"

  pod_top_tmp="${OUT_DIR}/.pod-top.tmp"
  node_top_tmp="${OUT_DIR}/.node-top.tmp"

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
      END {
        printf "%s\t%.2f\t%d\n", ts, sum, count
      }
    ' "$pod_top_tmp" >>"$POD_CPU_SAMPLES"
  else
    printf '%s\t0.00\t0\n' "$ts" >>"$POD_CPU_SAMPLES"
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
    ' "$node_top_tmp" >>"$NODE_CPU_SAMPLES"
  else
    printf '%s\t0.00\t0\n' "$ts" >>"$NODE_CPU_SAMPLES"
  fi

  rm -f "$pod_top_tmp" "$node_top_tmp"
}

capture_final_state() {
  kubectl get hpa -n "$NAMESPACE" >"${OUT_DIR}/hpa.txt" 2>&1 || true
  kubectl top nodes >"${OUT_DIR}/top-nodes.txt" 2>&1 || true
  kubectl top pods -n "$NAMESPACE" >"${OUT_DIR}/top-pods.txt" 2>&1 || true
  kubectl get pods -n "$NAMESPACE" -o wide >"${OUT_DIR}/pods-wide.txt" 2>&1 || true
  kubectl logs job/"${JOB_NAME}" -n "$NAMESPACE" >"${OUT_DIR}/loadgen-logs.txt" 2>&1 || true
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
      if (NR == 0) {
        print "N/A"
      } else if (min == max) {
        print min
      } else {
        printf "%s -> %s\n", min, max
      }
    }
  ' "$file"
}

summarize_average() {
  local file="$1"
  awk '
    { sum += $2; count += 1 }
    END {
      if (count == 0) {
        print "N/A"
      } else {
        printf "%.2f\n", sum / count
      }
    }
  ' "$file"
}

extract_latency_summary() {
  local source_file="$1"
  local line
  local avg
  local p95

  line="$(tr -d '\r' <"$source_file" | grep 'http_req_duration' | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "N/A"
    return
  fi

  avg="$(printf '%s\n' "$line" | sed -n 's/.*avg=\([^ ]*\).*/\1/p')"
  p95="$(printf '%s\n' "$line" | sed -n 's/.*p(95)=\([^ ]*\).*/\1/p')"

  if [[ -n "$avg" && -n "$p95" ]]; then
    printf 'avg=%s, p95=%s\n' "$avg" "$p95"
  elif [[ -n "$avg" ]]; then
    printf 'avg=%s\n' "$avg"
  else
    echo "N/A"
  fi
}

extract_error_rate() {
  local source_file="$1"
  local line
  local rate

  line="$(tr -d '\r' <"$source_file" | grep 'http_req_failed' | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "N/A"
    return
  fi

  rate="$(printf '%s\n' "$line" | sed -n 's/.*http_req_failed[^:]*:[[:space:]]*\([^[:space:]]*\).*/\1/p')"
  if [[ -n "$rate" ]]; then
    printf '%s\n' "$rate"
  else
    echo "N/A"
  fi
}

log "Saving benchmark artifacts to ${OUT_DIR}"
log "Starting load generator in the background"
"$SCRIPT_DIR/32-run-loadgen.sh" >"$LOADGEN_RUN_LOG" 2>&1 &
LOADGEN_PID=$!

while kill -0 "$LOADGEN_PID" 2>/dev/null; do
  collect_sample
  sleep "$SAMPLE_INTERVAL"
done

LOADGEN_STATUS=0
if wait "$LOADGEN_PID"; then
  LOADGEN_STATUS=0
else
  LOADGEN_STATUS=$?
fi

collect_sample
capture_final_state

POD_RANGE="$(summarize_range "$POD_COUNT_SAMPLES")"
AVG_POD_CPU_M="$(summarize_average "$POD_CPU_SAMPLES")"
AVG_NODE_CPU_PCT="$(summarize_average "$NODE_CPU_SAMPLES")"
LATENCY_SUMMARY="$(extract_latency_summary "${OUT_DIR}/loadgen-logs.txt")"
ERROR_RATE="$(extract_error_rate "${OUT_DIR}/loadgen-logs.txt")"

NOTES="Loadgen completed."
if [[ "$LOADGEN_STATUS" -ne 0 ]]; then
  NOTES="Loadgen exited with code ${LOADGEN_STATUS}."
fi
if [[ "$POD_RANGE" == *"->"* ]]; then
  NOTES="${NOTES} HPA scaled pod count during the test."
else
  NOTES="${NOTES} No pod count change observed."
fi

cat >"$SUMMARY_MD" <<EOF
| Kịch bản thử nghiệm | Số lượng Pod | CPU trung bình | Độ trễ phản hồi | Error rate | Ghi chú |
|---|---:|---:|---|---:|---|
| ${SCENARIO_NAME} | ${POD_RANGE} | ${AVG_POD_CPU_M} mCPU (pods), ${AVG_NODE_CPU_PCT}% (nodes) | ${LATENCY_SUMMARY} | ${ERROR_RATE} | ${NOTES} |
EOF

cat >"$SUMMARY_TXT" <<EOF
Scenario: ${SCENARIO_NAME}
Pod count range: ${POD_RANGE}
Average app pod CPU: ${AVG_POD_CPU_M} mCPU
Average node CPU: ${AVG_NODE_CPU_PCT}%
Latency summary: ${LATENCY_SUMMARY}
Error rate: ${ERROR_RATE}
Notes: ${NOTES}
Output directory: ${OUT_DIR}
EOF

log "Benchmark summary"
cat "$SUMMARY_TXT"
echo
cat "$SUMMARY_MD"
