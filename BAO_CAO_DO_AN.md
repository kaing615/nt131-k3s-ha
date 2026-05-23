# Báo Cáo Đồ Án NT131 - Hệ Thống Nhúng

## Triển khai cụm k3s HA trên 5 Raspberry Pi 4 và dịch vụ SLM inference

> Nhóm: Nhóm 10  
> Môn học: NT131 - Hệ thống nhúng Mạng không dây
> Sinh viên thực hiện: Nguyễn Đình Tâm - 23521389
> Giảng viên hướng dẫn: ThS. Đặng Lê Bảo Chương
> Ngày báo cáo: 29/5/2026

---

## Tóm tắt

Đồ án triển khai một cụm Small Compute Cluster gồm 5 Raspberry Pi 4 theo mô hình Kubernetes nhẹ bằng k3s. Cụm được tổ chức thành 3 node control plane và 2 node worker nhằm đảm bảo tính sẵn sàng cao cho API server và khả năng duy trì workload khi có lỗi node.

Trên cụm, nhóm triển khai một dịch vụ suy luận mô hình ngôn ngữ nhỏ (SLM) sử dụng `Qwen2.5-0.5B-Instruct` dạng GGUF và `llama.cpp`. Dịch vụ được đóng gói dưới dạng `Deployment`, expose qua `Service` và `Ingress`, có `startupProbe`, `readinessProbe`, `livenessProbe`, cấu hình tài nguyên, đồng thời được gắn `HorizontalPodAutoscaler` để tự động scale theo CPU.

Hệ thống cũng có các script kiểm thử nhằm chứng minh các yêu cầu chính của đồ án: truy cập Kubernetes API qua VIP, autoscaling bằng HPA, pod self-healing, reschedule khi worker lỗi, và HA control plane khi một master bị dừng.

---

## 1. Mục tiêu đồ án

Mục tiêu của đồ án là xây dựng một cụm Kubernetes nhỏ trên phần cứng nhúng, triển khai workload AI nhẹ và kiểm chứng các tính chất vận hành của hệ thống phân tán.

Các mục tiêu cụ thể:

- Triển khai cụm k3s HA gồm 5 Raspberry Pi 4.
- Tổ chức cụm theo mô hình 3 master và 2 worker.
- Cung cấp một địa chỉ VIP cho Kubernetes API server bằng `kube-vip`.
- Cài đặt và sử dụng các thành phần `Traefik`, `metrics-server`, `HPA`.
- Đóng gói SLM thành service chạy trong Kubernetes.
- Expose service qua `Ingress`.
- Tạo tải bằng `k6` để quan sát hiệu năng và autoscaling.
- Chứng minh khả năng tự phục hồi khi pod bị xóa.
- Chứng minh workload được reschedule khi worker gặp lỗi.
- Chứng minh control plane vẫn hoạt động khi mất một master.

---

## 2. Yêu cầu từ đề bài và hiện thực trong source code

| Yêu cầu | Hiện thực trong project |
|---|---|
| 5 Raspberry Pi 4, mô hình 3 master + 2 worker | Khai báo trong `cluster.env`, `cluster.env.example` với `master1`, `master2`, `master3`, `worker1`, `worker2` |
| Chuẩn bị phần cứng, hostname, static IP | `scripts/00-configure-static-ip.sh`, `scripts/01-copy-static-ip-script.sh` |
| Cài OS và chuẩn bị node | `scripts/00-node-prereqs.sh` tắt swap, bật kernel module và sysctl cho Kubernetes |
| Triển khai k3s HA | `scripts/10-init-first-server.sh`, `scripts/11-join-server.sh`, `scripts/12-join-agent.sh` |
| Endpoint HA cho API server | `kube-vip` được cài dưới dạng static pod manifest trên `master1` |
| Client/worker truy cập API qua VIP | `server: https://${API_VIP}:6443` trong config join server/agent |
| Cài add-on autoscaling và expose service | Dùng `metrics-server` và `Traefik` mặc định của k3s; HPA và Ingress được tạo trong `scripts/31-deploy-slm-stack.sh` |
| Đóng gói SLM thành service | `Deployment: slm-api`, image `ghcr.io/ggerganov/llama.cpp:full`, model GGUF tải từ Hugging Face |
| Load generator stress test SLM | `scripts/32-run-loadgen.sh` tạo `k6 Job` gọi `/v1/chat/completions` |
| HPA cho SLM service | HPA autoscaling/v2, `minReplicas=1`, `maxReplicas=4`, `targetCPU=60%` |
| Pod self-healing | `scripts/40-test-self-heal.sh` xóa pod và chờ Deployment tạo pod thay thế |
| Worker failure/reschedule | `scripts/41-test-node-failure.sh` dừng `k3s-agent` trên `worker1` và quan sát pod chuyển sang `worker2` |
| Control-plane HA | `scripts/42-test-control-plane-ha.sh` dừng một master để kiểm tra API qua VIP vẫn hoạt động; script cũng dừng thêm master thứ hai để chứng minh giới hạn quorum etcd |
| Thu thập số liệu báo cáo | `scripts/60-collect-results.sh`, `scripts/61-benchmark-report.sh` |

---

## 3. Phần cứng và mạng

### 3.1. Thiết bị sử dụng

| Thành phần | Số lượng | Vai trò |
|---|---:|---|
| Raspberry Pi 4 4GB | 5 | Chạy cụm k3s |
| microSD 32GB | 5 | Lưu OS và dữ liệu node |
| Switch mạng | 1 | Kết nối các node trong cùng LAN |
| Máy quản trị | 1 | Chạy script, `kubectl`, thu thập kết quả |

### 3.2. Sơ đồ tổng quan

![Sơ đồ cụm Raspberry Pi](../raspberry-pi-cluster-hardware.drawio.png)

### 3.3. Quy hoạch địa chỉ IP

Trong cấu hình mẫu, cụm dùng subnet `172.31.8.0/22`, gateway `172.31.8.1` và VIP `172.31.9.250`.

| Node | Vai trò | IP |
|---|---|---|
| `master1` | Control plane, khởi tạo cluster | `172.31.9.11` |
| `master2` | Control plane | `172.31.9.12` |
| `master3` | Control plane | `172.31.9.13` |
| `worker1` | Worker chạy workload | `172.31.9.21` |
| `worker2` | Worker chạy workload | `172.31.9.22` |
| `API_VIP` | Virtual IP cho Kubernetes API | `172.31.9.250` |

Các node được gán hostname tương ứng và cấu hình static IP trước khi triển khai k3s. Việc cấu hình IP được tự động hóa bằng script `00-configure-static-ip.sh`.

---

## 4. Kiến trúc hệ thống

### 4.1. Kiến trúc logic

Hệ thống gồm ba lớp chính:

| Lớp | Thành phần | Chức năng |
|---|---|---|
| Control plane | `master1`, `master2`, `master3` | Quản lý trạng thái cluster, API server, scheduler, controller, datastore etcd |
| Network/API HA | `kube-vip`, `API_VIP` | Cung cấp một endpoint ổn định cho Kubernetes API |
| Workload | `worker1`, `worker2`, `slm-api`, `k6` | Chạy dịch vụ SLM và công cụ tạo tải |

### 4.2. Control plane HA

`master1` khởi tạo cluster bằng k3s với `cluster-init: true`. Hai master còn lại join vào cluster qua `https://${API_VIP}:6443`.

`kube-vip` được cài dưới dạng static pod manifest trong thư mục auto-deploy của k3s:

- VIP: `172.31.9.250`
- Interface: `eth0`
- Chế độ: ARP + leader election
- Chức năng: cấp endpoint ổn định cho Kubernetes API server

Với 3 node control plane, cụm vẫn đạt quorum khi mất 1 master. Nếu mất 2/3 master, etcd không còn đủ quorum nên API có thể không khả dụng. Script `42-test-control-plane-ha.sh` kiểm tra cả hai trạng thái này.

### 4.3. Worker và scheduling workload

Hai worker được label:

```text
workload=app
node-role.nt131/worker=true
```

Deployment `slm-api` sử dụng `nodeAffinity` để chỉ schedule workload lên các node có label `workload=app`. Cách này giúp tách workload AI khỏi các node control plane, giảm rủi ro workload nặng ảnh hưởng đến API server và etcd.

---

## 5. Công nghệ sử dụng

| Công nghệ | Vai trò |
|---|---|
| Raspberry Pi OS Lite 64-bit | Hệ điều hành cho node |
| k3s `v1.29.6+k3s2` | Kubernetes nhẹ cho thiết bị tài nguyên hạn chế |
| kube-vip `v0.8.0` | Virtual IP cho Kubernetes API server |
| Traefik | Ingress Controller mặc định của k3s |
| metrics-server | Cung cấp metric CPU/RAM cho HPA |
| HorizontalPodAutoscaler | Tự động scale pod theo CPU |
| llama.cpp | Runtime chạy mô hình GGUF |
| Qwen2.5-0.5B-Instruct GGUF | Mô hình SLM dùng cho inference |
| k6 `0.49.0` | Công cụ tạo tải HTTP |
| Bash script | Tự động hóa triển khai và kiểm thử |

---

## 6. Cấu trúc thư mục project

```text
nt131-nhom10-k3s-ha/
├── README.md
├── cluster.env
├── cluster.env.example
└── scripts/
    ├── 00-node-prereqs.sh
    ├── 00-configure-static-ip.sh
    ├── 01-copy-static-ip-script.sh
    ├── 10-init-first-server.sh
    ├── 11-join-server.sh
    ├── 12-join-agent.sh
    ├── 20-fetch-kubeconfig.sh
    ├── 30-label-nodes.sh
    ├── 31-deploy-slm-stack.sh
    ├── 32-run-loadgen.sh
    ├── 33-test-slm-api.sh
    ├── 39-test-cluster-status.sh
    ├── 40-test-self-heal.sh
    ├── 41-test-node-failure.sh
    ├── 42-test-control-plane-ha.sh
    ├── 50-check-model-source.sh
    ├── 60-collect-results.sh
    ├── 61-benchmark-report.sh
    └── lib.sh
```

Các script được đặt tên theo thứ tự triển khai, giúp quá trình demo và tái lập hệ thống dễ theo dõi.

---

## 7. Quy trình triển khai

### 7.1. Chuẩn bị cấu hình

Tạo file cấu hình từ file mẫu:

```bash
cp cluster.env.example cluster.env
```

Các biến quan trọng:

| Biến | Ý nghĩa |
|---|---|
| `API_VIP` | VIP cho Kubernetes API |
| `VIP_INTERFACE` | Interface dùng cho kube-vip |
| `MASTER*_IP`, `WORKER*_IP` | IP tĩnh của từng node |
| `K3S_TOKEN` | Token join cluster |
| `KUBECONFIG_LOCAL` | Đường dẫn kubeconfig trên máy quản trị |
| `SLM_IMAGE` | Image chạy `llama.cpp` |
| `HF_MODEL_REPO`, `HF_MODEL_FILE` | Model GGUF được tải từ Hugging Face |
| `MODEL_CACHE_HOST_PATH` | Thư mục cache model trên worker |
| `HPA_MIN_REPLICAS`, `HPA_MAX_REPLICAS`, `HPA_CPU_PERCENT` | Cấu hình HPA |
| `LOADGEN_VUS`, `LOADGEN_DURATION` | Cấu hình tải của k6 |

### 7.2. Chuẩn bị node

Trên từng Raspberry Pi:

```bash
sudo ./scripts/00-node-prereqs.sh
```

Script này thực hiện:

- Cài các gói cần thiết như `curl`, `jq`, `ca-certificates`, `sshpass`.
- Tắt swap.
- Bật kernel module `overlay`, `br_netfilter`.
- Cấu hình sysctl cho networking của Kubernetes.

### 7.3. Khởi tạo master đầu tiên

Trên `master1`:

```bash
sudo ./scripts/10-init-first-server.sh
```

Script sẽ:

- Render `/etc/rancher/k3s/config.yaml`.
- Cài k3s server với `cluster-init: true`.
- Cài RBAC manifest cho `kube-vip`.
- Pull image `ghcr.io/kube-vip/kube-vip`.
- Tạo static pod manifest `kube-vip.yaml`.
- In node token.

Kiểm tra:

```bash
sudo kubectl get nodes
curl -k https://172.31.9.250:6443/version
```

### 7.4. Join hai master còn lại

Trên `master2` và `master3`:

```bash
sudo ./scripts/11-join-server.sh
```

Hai node này join control plane qua VIP:

```text
https://172.31.9.250:6443
```

### 7.5. Join worker

Trên `worker1` và `worker2`:

```bash
sudo ./scripts/12-join-agent.sh
```

Worker cũng sử dụng VIP làm endpoint API server, tránh phụ thuộc trực tiếp vào một master cụ thể.

### 7.6. Lấy kubeconfig về máy quản trị

Trên máy quản trị:

```bash
./scripts/20-fetch-kubeconfig.sh
export KUBECONFIG=$HOME/.kube/nt131-k3s.yaml
kubectl get nodes -o wide
```

### 7.7. Label node

```bash
./scripts/30-label-nodes.sh
kubectl get nodes --show-labels
```

Label được dùng để phân biệt node control plane và node worker chạy workload.

---

## 8. Triển khai SLM inference service

### 8.1. Model và runtime

Project sử dụng:

```text
Model repo: Qwen/Qwen2.5-0.5B-Instruct-GGUF
Model file: qwen2.5-0.5b-instruct-q4_k_m.gguf
Runtime: ghcr.io/ggerganov/llama.cpp:full
```

Lý do chọn mô hình:

- Mô hình 0.5B phù hợp với giới hạn RAM của Raspberry Pi 4.
- Định dạng GGUF hỗ trợ chạy bằng `llama.cpp`.
- Quantization `Q4_K_M` giúp giảm dung lượng model và nhu cầu bộ nhớ.
- API của `llama-server` hỗ trợ endpoint OpenAI-compatible như `/v1/chat/completions`.

### 8.2. Deployment

Script `31-deploy-slm-stack.sh` tạo namespace `slm` và Deployment `slm-api`.

Các điểm chính:

- `replicas: 1` ban đầu.
- `nodeAffinity` ép pod chạy trên worker có label `workload=app`.
- `initContainer` dùng `curlimages/curl` để tải model GGUF từ Hugging Face.
- Model được lưu trong `hostPath` cache tại `/var/lib/slm-model-cache`.
- Container chính chạy `llama-server`.
- Có cấu hình tài nguyên:
  - requests: `1000m CPU`, `1500Mi memory`
  - limits: `2000m CPU`, `2500Mi memory`
- Có `startupProbe`, `readinessProbe`, `livenessProbe` qua endpoint `/health`.

Lệnh chạy chính:

```bash
llama-server \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --host 0.0.0.0 \
  --port 8080 \
  -c 2048 \
  -n 128 \
  -np 2 \
  -t 4 \
  --metrics
```

### 8.3. Service và Ingress

`slm-api` được expose nội bộ bằng `Service` loại `ClusterIP`:

```text
Service: slm-api
Namespace: slm
Port: 80 -> 8080
```

Ingress sử dụng Traefik với host:

```text
slm.local
```

Kiểm tra API:

```bash
curl http://slm.local/health
```

Kiểm tra chat completion:

```bash
curl -X POST http://slm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"slm-api",
    "messages":[
      {"role":"system","content":"You are a concise assistant."},
      {"role":"user","content":"Gioi thieu ngan ve he thong nhung mang khong day."}
    ],
    "max_tokens":64,
    "temperature":0.2
  }'
```

---

## 9. Autoscaling bằng HPA

HPA được tạo cho Deployment `slm-api` với cấu hình:

```text
minReplicas: 1
maxReplicas: 4
targetCPUUtilization: 60%
```

Khi CPU trung bình của các pod vượt ngưỡng, HPA tăng số replica. Khi tải giảm, HPA giảm replica về mức phù hợp.

Kiểm tra:

```bash
kubectl -n slm get hpa
kubectl -n slm get hpa -w
kubectl -n slm get pods -w
kubectl top pods -n slm
kubectl top nodes
```

Lưu ý: HPA phụ thuộc vào `metrics-server`. Trong project này, `metrics-server` được dùng theo cơ chế mặc định của k3s.

---

## 10. Load generator

Script `32-run-loadgen.sh` tạo một `ConfigMap` chứa script k6 và một `Job` chạy image `grafana/k6:0.49.0`.

Mặc định:

```text
LOADGEN_VUS=20
LOADGEN_DURATION=120s
LOADGEN_BASE_URL=http://slm-api.slm.svc.cluster.local
```

Mỗi virtual user gọi:

```text
POST /v1/chat/completions
```

Payload dùng câu hỏi ngắn để tạo tải inference lên SLM service.

Chạy load test:

```bash
./scripts/32-run-loadgen.sh
```

---

## 11. Các kịch bản kiểm thử

### 11.1. Kiểm thử baseline

Mục tiêu:

- Xác nhận service hoạt động khi tải nhẹ.
- Ghi nhận CPU, RAM, latency ở trạng thái bình thường.
- Kiểm tra HPA chưa cần scale hoặc chỉ giữ 1 replica.

Gợi ý cấu hình:

```text
LOADGEN_VUS=5
LOADGEN_DURATION=60s
```

Lệnh:

```bash
SCENARIO_NAME="Baseline load test" ./scripts/61-benchmark-report.sh
```

### 11.2. Kiểm thử autoscaling

Mục tiêu:

- Tăng tải để CPU vượt ngưỡng HPA.
- Quan sát `slm-api` scale từ 1 lên 2 hoặc nhiều replica hơn.
- Ghi nhận latency và CPU khi scale.

Gợi ý cấu hình:

```text
LOADGEN_VUS=20
LOADGEN_DURATION=120s
```

Lệnh:

```bash
SCENARIO_NAME="Moderate load with autoscaling" ./scripts/61-benchmark-report.sh
```

### 11.3. Kiểm thử high load

Mục tiêu:

- Ép hệ thống tiến gần giới hạn `HPA_MAX_REPLICAS=4`.
- Quan sát tác động đến CPU, latency, error rate.

Gợi ý cấu hình:

```text
LOADGEN_VUS=40
LOADGEN_DURATION=180s
```

Lệnh:

```bash
SCENARIO_NAME="High load stress test" ./scripts/61-benchmark-report.sh
```

### 11.4. Pod self-healing

Mục tiêu:

- Xóa một pod của `slm-api`.
- Kiểm tra Deployment tự tạo pod thay thế.
- Xác nhận service phục hồi sau khi pod mới ready.

Lệnh:

```bash
./scripts/40-test-self-heal.sh
```

Kết quả mong đợi:

- Pod cũ chuyển sang trạng thái terminating.
- Pod mới được tạo.
- Deployment rollout thành công.
- Service tiếp tục phục vụ request sau khi pod mới ready.

### 11.5. Worker failure và reschedule

Mục tiêu:

- Dừng `k3s-agent` trên `worker1`.
- Quan sát node lỗi và pod được chuyển sang `worker2`.
- Khôi phục worker sau kiểm thử.

Lệnh:

```bash
./scripts/41-test-node-failure.sh
```

Kết quả mong đợi:

- `worker1` tạm thời không còn phục vụ workload.
- Pod đang chạy trên `worker1` được reschedule sang `worker2`.
- Sau khi `k3s-agent` khởi động lại, worker trở lại cluster.

### 11.6. Control-plane HA

Mục tiêu:

- Dừng một master trong lúc cluster đang chạy.
- Xác nhận `kubectl` vẫn truy cập được API qua VIP.
- Xác nhận workload vẫn chạy.
- Kiểm tra giới hạn quorum khi mất 2/3 master.

Lệnh:

```bash
./scripts/42-test-control-plane-ha.sh
```

Kết quả mong đợi:

- Khi dừng `master3`, cluster vẫn reachable.
- `kubectl get nodes` vẫn hoạt động qua VIP.
- Pod `slm-api` vẫn chạy.
- Khi dừng thêm `master2`, API mất quorum như kỳ vọng.
- Sau khi khôi phục master, API hoạt động lại.

---

## 12. Thu thập số liệu

Script thu thập nhanh:

```bash
./scripts/60-collect-results.sh
```

Các file được tạo trong `results/<timestamp>/`:

| File | Nội dung |
|---|---|
| `hpa.txt` | Trạng thái HPA |
| `top-nodes.txt` | CPU/RAM node |
| `top-pods.txt` | CPU/RAM pod trong namespace `slm` |
| `pods-wide.txt` | Vị trí pod trên node |
| `loadgen-logs.txt` | Log k6 |

Script benchmark:

```bash
SCENARIO_NAME="Tên kịch bản" ./scripts/61-benchmark-report.sh
```

Script này vừa chạy load generator vừa lấy mẫu:

- Số lượng pod theo thời gian.
- CPU pod trung bình.
- CPU node trung bình.
- Latency `avg` và `p95` từ log k6.
- Bảng Markdown `benchmark-summary.md`.

---

## 13. Kết quả thực nghiệm

> Phần này cần được cập nhật sau khi chạy thực nghiệm thật trên cụm Raspberry Pi. Project hiện chưa có thư mục `results`, vì vậy bảng dưới đây là mẫu để điền số liệu từ `scripts/61-benchmark-report.sh`.

### 13.1. Trạng thái cluster

Lệnh kiểm tra:

```bash
kubectl get nodes -o wide
kubectl -n slm get all
kubectl -n slm get ingress
kubectl -n slm get hpa
```

Kết quả cần ghi nhận:

| Nội dung | Kết quả |
|---|---|
| Số node Ready | [Điền kết quả] |
| Số master Ready | [Điền kết quả] |
| Số worker Ready | [Điền kết quả] |
| VIP API hoạt động | [Có/Không] |
| Ingress `slm.local` hoạt động | [Có/Không] |
| SLM API `/health` | [Có/Không] |

### 13.2. Bảng benchmark

| Kịch bản thử nghiệm | Số lượng Pod | CPU trung bình | Độ trễ phản hồi | Error rate | Ghi chú |
|---|---:|---:|---|---:|---|
| Baseline load test | [Điền] | [Điền] | avg=[...], p95=[...] | [Điền] | Tải nhẹ |
| Moderate load with autoscaling | [Điền] | [Điền] | avg=[...], p95=[...] | [Điền] | HPA bắt đầu scale |
| High load stress test | [Điền] | [Điền] | avg=[...], p95=[...] | [Điền] | Gần giới hạn cụm |
| Self-healing during traffic | [Điền] | [Điền] | avg=[...], p95=[...] | [Điền] | Xóa pod trong lúc có tải |
| Worker failure and reschedule | [Điền] | [Điền] | avg=[...], p95=[...] | [Điền] | `worker1` lỗi, pod chuyển sang `worker2` |
| Control-plane HA under load | [Điền] | [Điền] | avg=[...], p95=[...] | [Điền] | Dừng 1 master, API vẫn qua VIP |

### 13.3. Hình minh chứng cần đưa vào báo cáo

- Sơ đồ topology cụm.
- Kết quả `kubectl get nodes -o wide`.
- Kết quả `kubectl -n slm get all`.
- Log pod tải model và chạy `llama-server`.
- Kết quả gọi `/health` và `/v1/chat/completions`.
- HPA scale up/down khi chạy k6.
- Pod mới được tạo sau khi xóa pod cũ.
- Pod được reschedule khi `worker1` down.
- Cluster vẫn truy cập được qua VIP khi dừng một master.

---

## 14. Phân tích

### 14.1. Tính sẵn sàng cao của API server

Việc sử dụng 3 master giúp control plane có khả năng chịu lỗi tốt hơn so với mô hình một master. `kube-vip` tạo một địa chỉ API ổn định, giúp worker và máy quản trị không cần biết master nào đang giữ vai trò endpoint chính.

Khi mất 1 master, cụm vẫn còn 2/3 node control plane, etcd vẫn đạt quorum và API vẫn hoạt động. Khi mất 2 master, cụm mất quorum, đây là hành vi đúng của hệ thống etcd 3 node.

### 14.2. Tự phục hồi workload

Deployment đảm bảo số replica mong muốn luôn được duy trì. Khi một pod bị xóa hoặc lỗi, ReplicaSet tạo pod mới. Probe `/health` giúp Kubernetes chỉ route traffic tới pod đã sẵn sàng, giảm rủi ro gửi request vào container chưa load xong model.

### 14.3. Autoscaling

HPA giúp tăng số pod khi CPU tăng do request inference. Với workload SLM, thời gian scale có thể bị ảnh hưởng bởi thời gian kéo image, tải model và load model vào RAM. Project đã dùng `hostPath` cache model để giảm chi phí tải lại model trên cùng worker.

### 14.4. Giới hạn hiệu năng

Raspberry Pi 4 có CPU và RAM hạn chế, nên inference model ngôn ngữ sẽ có latency cao hơn so với server GPU hoặc máy x86 mạnh. Việc chọn mô hình 0.5B và quantization GGUF là phù hợp với mục tiêu demo trên thiết bị nhúng, nhưng hệ thống không phù hợp cho tải sản xuất lớn.

---

## 15. Hạn chế và hướng phát triển

Hạn chế hiện tại:

- Chưa triển khai MetalLB; project dùng Ingress qua Traefik và VIP cho API server.
- `sshpass` và mật khẩu trong `cluster.env` phù hợp cho lab/demo, không phù hợp môi trường production.
- SLM chạy CPU-only trên Raspberry Pi nên throughput giới hạn.
- Mỗi pod SLM cần thời gian khởi động đáng kể do phải load model.
- Chưa có dashboard quan sát dài hạn như Prometheus/Grafana.

Hướng phát triển:

- Bổ sung MetalLB nếu cần expose service kiểu `LoadBalancer`.
- Thêm Prometheus/Grafana để theo dõi CPU, RAM, latency, error rate theo thời gian.
- Dùng registry nội bộ hoặc pre-pull image để giảm thời gian rollout.
- Tối ưu model, số thread, context size và max tokens theo tài nguyên từng node.
- Bổ sung network policy và cơ chế secret an toàn hơn.
- Tự động hóa toàn bộ triển khai bằng Ansible hoặc Terraform.

---

## 16. Kết luận

Đồ án đã xây dựng được một cụm k3s HA trên 5 Raspberry Pi 4 theo mô hình 3 master và 2 worker. Hệ thống sử dụng `kube-vip` để cung cấp endpoint API ổn định qua VIP, dùng `Traefik` để expose service, dùng `metrics-server` và HPA để autoscaling, đồng thời triển khai thành công dịch vụ SLM inference bằng `llama.cpp`.

Các script trong project hỗ trợ đầy đủ quy trình từ chuẩn bị node, khởi tạo cluster, join node, deploy service, tạo tải, thu thập số liệu đến kiểm thử self-healing, worker failure và control-plane HA. Điều này giúp hệ thống có thể được tái lập, demo và đánh giá theo đúng yêu cầu đồ án.

---

## 17. Phụ lục lệnh triển khai nhanh

```bash
# Chuẩn bị cấu hình
cp cluster.env.example cluster.env
./scripts/50-check-model-source.sh

# Trên từng node
sudo ./scripts/00-node-prereqs.sh

# Trên master1
sudo ./scripts/10-init-first-server.sh

# Trên master2, master3
sudo ./scripts/11-join-server.sh

# Trên worker1, worker2
sudo ./scripts/12-join-agent.sh

# Trên máy quản trị
./scripts/20-fetch-kubeconfig.sh
export KUBECONFIG=$HOME/.kube/nt131-k3s.yaml
./scripts/30-label-nodes.sh
./scripts/39-test-cluster-status.sh
./scripts/31-deploy-slm-stack.sh
./scripts/33-test-slm-api.sh

# Kiểm tra service
kubectl get nodes -o wide
kubectl -n slm get all
kubectl -n slm get hpa
curl http://slm.local/health

# Chạy load test và thu kết quả
./scripts/32-run-loadgen.sh
./scripts/60-collect-results.sh
SCENARIO_NAME="Baseline load test" ./scripts/61-benchmark-report.sh

# Kiểm thử khả năng phục hồi
./scripts/40-test-self-heal.sh
./scripts/41-test-node-failure.sh
./scripts/42-test-control-plane-ha.sh
```

---

## 18. Tài liệu tham khảo

- k3s Documentation: https://docs.k3s.io/
- kube-vip Documentation: https://kube-vip.io/
- Kubernetes HPA: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Traefik Documentation: https://doc.traefik.io/traefik/
- llama.cpp: https://github.com/ggml-org/llama.cpp
- Qwen2.5 GGUF model repository: https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF
- k6 Documentation: https://grafana.com/docs/k6/
