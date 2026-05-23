# NT131 Nhóm 10 - Triển khai k3s HA trên 5 Raspberry Pi 4

Bộ script này dùng để triển khai và demo đồ án NT131 theo mô hình:

- 5 Raspberry Pi 4.
- 3 master/control plane và 2 worker.
- Cụm Kubernetes nhẹ bằng `k3s` ở chế độ HA.
- `kube-vip` tạo VIP cho Kubernetes API server.
- `Traefik` và `metrics-server` dùng theo thành phần mặc định của k3s.
- Dịch vụ SLM inference chạy `Qwen2.5-0.5B-Instruct-GGUF` bằng `llama.cpp`.
- `slm-api` được triển khai bằng `Deployment + Service + Ingress + HPA`.
- `k6` dùng để tạo tải và benchmark.
- Các script kiểm thử `cluster status`, `SLM API`, `HPA`, `pod self-healing`, `worker failure/reschedule`, `control-plane HA`.

README này đóng vai trò runbook triển khai, kiểm thử và demo.

---

## 1. Mục tiêu hệ thống

Hệ thống cần chứng minh được các điểm sau:

- Cụm k3s HA có 3 node control plane.
- Worker và máy quản trị truy cập Kubernetes API thông qua VIP, không phụ thuộc vào một master cụ thể.
- Dịch vụ SLM inference chạy được trên worker.
- Dịch vụ có `startupProbe`, `readinessProbe`, `livenessProbe`.
- HPA có thể scale `slm-api` từ `1` đến `4` replica khi CPU tăng.
- Có load generator bằng `k6` để quan sát tải, latency, error rate và scale up/down.
- Deployment tự tạo pod mới khi pod bị xóa.
- Pod được reschedule khi một worker bị lỗi.
- Control plane vẫn truy cập được khi mất một master.

---

## 2. Kiến trúc logic

| Thành phần | Vai trò |
|---|---|
| `master1` | Khởi tạo cụm k3s, tạo static manifest cho `kube-vip` |
| `master2`, `master3` | Join vào control plane HA |
| `worker1`, `worker2` | Chạy workload `slm-api` và pod ứng dụng |
| `kube-vip` | Cung cấp `API_VIP` cho Kubernetes API server |
| `Traefik` | Ingress Controller để expose `slm-api` |
| `metrics-server` | Cung cấp metric CPU/RAM cho HPA |
| `slm-api` | Service suy luận mô hình SLM bằng `llama.cpp` |
| `k6 Job` | Tạo tải HTTP để benchmark SLM service |

---

## 3. Cấu trúc thư mục

```text
nt131-nhom10-k3s-ha/
├── README.md
├── BAO_CAO_DO_AN.md
├── cluster.env.example
├── cluster.env
└── scripts/
    ├── 00-configure-static-ip.sh
    ├── 00-node-prereqs.sh
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

Ý nghĩa các script chính:

| Script | Chức năng |
|---|---|
| `00-configure-static-ip.sh` | Cấu hình IP tĩnh cho từng Pi theo hostname hoặc `--host` |
| `00-node-prereqs.sh` | Chuẩn bị OS: package, swap, cgroup, kernel module, sysctl |
| `01-copy-static-ip-script.sh` | Copy script IP tĩnh và `cluster.env` lên các Pi |
| `10-init-first-server.sh` | Khởi tạo `master1` với k3s HA và cài `kube-vip` |
| `11-join-server.sh` | Join `master2`, `master3` vào control plane |
| `12-join-agent.sh` | Join `worker1`, `worker2` vào cluster |
| `20-fetch-kubeconfig.sh` | Lấy kubeconfig từ `master1` về máy quản trị |
| `30-label-nodes.sh` | Gán label cho master và worker |
| `31-deploy-slm-stack.sh` | Deploy namespace, Deployment, Service, Ingress, HPA |
| `32-run-loadgen.sh` | Tạo `k6 Job` để stress test |
| `33-test-slm-api.sh` | Kiểm thử SLM Service, endpoint, `/health`, chat completion và Ingress |
| `39-test-cluster-status.sh` | Kiểm thử 5 node Ready, role label, VIP API, workload placement |
| `40-test-self-heal.sh` | Xóa pod để kiểm tra self-healing |
| `41-test-node-failure.sh` | Dừng `k3s-agent` trên worker để kiểm tra reschedule |
| `42-test-control-plane-ha.sh` | Dừng master để kiểm tra HA và giới hạn quorum |
| `50-check-model-source.sh` | Kiểm tra model Hugging Face và image public |
| `60-collect-results.sh` | Thu thập nhanh output phục vụ báo cáo |
| `61-benchmark-report.sh` | Chạy loadgen, lấy mẫu CPU/pod/latency/error rate, xuất Markdown |

---

## 4. Chuẩn bị phần cứng và mạng

Giả định phần cứng:

- 5 Raspberry Pi 4 4GB đã cài Raspberry Pi OS Lite 64-bit.
- 5 thẻ microSD 32GB.
- 1 switch mạng.
- Máy quản trị cùng mạng với các Pi.
- Các node có thể SSH được.
- Username trên mỗi Pi trùng hostname, ví dụ `master1`, `worker1`.

Quy hoạch IP mẫu:

| Node | Vai trò | IP |
|---|---|---|
| `master1` | Control plane đầu tiên | `172.31.9.11` |
| `master2` | Control plane | `172.31.9.12` |
| `master3` | Control plane | `172.31.9.13` |
| `worker1` | Worker | `172.31.9.21` |
| `worker2` | Worker | `172.31.9.22` |
| `API_VIP` | VIP Kubernetes API | `172.31.9.250` |
| Gateway | Router | `172.31.8.1` |
| Prefix | Subnet prefix | `/22` |

Kiểm tra cơ bản trên từng Pi:

```bash
hostname
ip -4 addr
ip route
ping -c 3 172.31.8.1
```

---

## 5. Chuẩn bị file cấu hình

**Chạy trên máy quản trị**:

```bash
cd /Users/dtam.21/Study/NT131\ -\ Hệ\ thống\ nhúng/nt131-nhom10-k3s-ha
cp cluster.env.example cluster.env
```

Chỉnh các biến trong `cluster.env` cho đúng mạng thực tế:

```env
API_VIP=172.31.9.250
VIP_INTERFACE=eth0
NODE_INTERFACE=eth0
NODE_PREFIX=22
NODE_GATEWAY=172.31.8.1

MASTER1_HOST=master1
MASTER1_IP=172.31.9.11
MASTER2_HOST=master2
MASTER2_IP=172.31.9.12
MASTER3_HOST=master3
MASTER3_IP=172.31.9.13

WORKER1_HOST=worker1
WORKER1_IP=172.31.9.21
WORKER2_HOST=worker2
WORKER2_IP=172.31.9.22
```

Nếu hostname chưa resolve được qua mạng, thêm biến SSH tạm thời vào `cluster.env`, ví dụ:

```env
MASTER1_SSH_HOST=172.31.9.17
WORKER1_SSH_HOST=172.31.9.18
```

Kiểm tra nhanh model và image public.

**Chạy trên máy quản trị**:

```bash
./scripts/50-check-model-source.sh
```

---

## 6. Đặt hostname và IP tĩnh

Script `00-configure-static-ip.sh` không tự đổi hostname. Nó đọc hostname hiện tại hoặc giá trị `--host`, rồi map sang IP trong `cluster.env`.

Nếu hostname chưa đúng, đặt hostname trước.

**Chạy trên từng Pi tương ứng**:

```bash
sudo hostnamectl set-hostname master1
sudo reboot
```

Lặp lại tương ứng cho:

```text
master1
master2
master3
worker1
worker2
```

Copy script cấu hình IP tĩnh lên các Pi.

**Chạy trên máy quản trị**:

```bash
./scripts/01-copy-static-ip-script.sh
```

Sau đó cấu hình IP tĩnh.

**Chạy trên từng Pi**:

```bash
sudo ~/00-configure-static-ip.sh --dry-run
sudo ~/00-configure-static-ip.sh
sudo reboot
```

Nếu muốn ép role vì hostname chưa đúng, thay `master1` bằng role của Pi hiện tại.

**Chạy trên Pi cần cấu hình**:

```bash
sudo ~/00-configure-static-ip.sh --host master1 --dry-run
sudo ~/00-configure-static-ip.sh --host master1
sudo reboot
```

Sau khi reboot, kiểm tra lại IP.

**Chạy trên từng Pi**:

```bash
hostname
ip -4 addr show eth0
ip route
```

---

## 7. Chuẩn bị OS cho k3s

**Chạy trên cả 5 Pi**:

```bash
sudo ./scripts/00-node-prereqs.sh
sudo reboot
```

Script này thực hiện:

- Cài package nền: `curl`, `jq`, `ca-certificates`, `sshpass`, `iptables`, `conntrack`, `socat`, ...
- Tắt swap.
- Bật cgroup cho Raspberry Pi bằng cách thêm vào `cmdline.txt`:

```text
cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory
```

- Bật kernel modules:

```text
overlay
br_netfilter
```

- Cấu hình sysctl cho Kubernetes networking:

```text
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
```

Cần reboot sau bước này để kernel args cgroup có hiệu lực.

---

## 8. Khởi tạo k3s HA

### 8.1. Khởi tạo `master1`

**Chạy trên `master1`**:

```bash
sudo ./scripts/10-init-first-server.sh
```

Script sẽ:

- Tạo `/etc/rancher/k3s/config.yaml`.
- Cài k3s server với `cluster-init: true`.
- Cài RBAC manifest cho `kube-vip`.
- Tạo static pod manifest `kube-vip.yaml`.
- In ra node token.

Kiểm tra trạng thái sau khi init.

**Chạy trên `master1`**:

```bash
sudo systemctl status k3s
sudo kubectl get nodes -o wide
curl -k https://172.31.9.250:6443/version
```

### 8.2. Join `master2`, `master3`

**Chạy trên `master2` và `master3`**:

```bash
sudo ./scripts/11-join-server.sh
```

Kiểm tra sau khi join master.

**Chạy trên `master1`**:

```bash
sudo kubectl get nodes -o wide
```

Kết quả mong đợi: 3 master ở trạng thái `Ready`.

### 8.3. Join `worker1`, `worker2`

**Chạy trên `worker1` và `worker2`**:

```bash
sudo ./scripts/12-join-agent.sh
```

Kết quả mong đợi: 5 node `Ready`, gồm 3 control plane và 2 worker.

---

## 9. Cấu hình máy quản trị

Sau khi máy quản trị kết nối được tới `API_VIP`, lấy kubeconfig từ `master1`.

**Chạy trên máy quản trị**:

```bash
./scripts/20-fetch-kubeconfig.sh
export KUBECONFIG=$HOME/.kube/nt131-k3s.yaml
kubectl get nodes -o wide
```

Điều kiện để chạy các lệnh `kubectl` từ máy quản trị là máy quản trị truy cập được Kubernetes API qua VIP:

```bash
curl -k https://172.31.9.250:6443/version
```

Nếu máy quản trị chưa truy cập được VIP, có thể chạy tạm các lệnh deploy/test trên `master1` bằng `sudo kubectl` hoặc kubeconfig mặc định `/etc/rancher/k3s/k3s.yaml`. Tuy nhiên, các bài test HA, đặc biệt `42-test-control-plane-ha.sh`, nên chạy từ máy quản trị để không bị ảnh hưởng khi dừng master.

Gán label cho node.

**Chạy trên máy quản trị**:

```bash
./scripts/30-label-nodes.sh
kubectl get nodes --show-labels
```

Label được gán:

- Master: `node-role.nt131/control-plane=true`
- Worker: `workload=app`, `node-role.nt131/worker=true`

Kiểm thử trạng thái cụm.

**Chạy trên máy quản trị**:

```bash
./scripts/39-test-cluster-status.sh
```

Script này kiểm tra:

- 5 node đều `Ready`.
- Có đúng 3 master và 2 worker theo label.
- API server truy cập được qua `API_VIP`.
- Nếu `slm-api` đã deploy, pod chỉ chạy trên worker.

---

## 10. Deploy SLM inference service

Model sử dụng:

```text
Repo: Qwen/Qwen2.5-0.5B-Instruct-GGUF
File: qwen2.5-0.5b-instruct-q4_k_m.gguf
Runtime image: ghcr.io/ggerganov/llama.cpp:full
```

Deploy stack.

**Chạy trên máy quản trị**:

```bash
./scripts/31-deploy-slm-stack.sh
```

Script tạo:

- `Namespace: slm`
- `Deployment: slm-api`
- `Service: slm-api`
- `Ingress: slm-api`
- `HPA: slm-api`

Các điểm chính trong Deployment:

- `initContainer` tải file GGUF từ Hugging Face.
- Model được cache trên worker bằng `hostPath` tại `MODEL_CACHE_HOST_PATH`.
- Container chính chạy `llama-server`.
- Pod có `startupProbe`, `readinessProbe`, `livenessProbe` qua `/health`.
- `nodeAffinity` chỉ cho pod chạy trên worker có label `workload=app`.

Kiểm tra tài nguyên.

**Chạy trên máy quản trị**:

```bash
kubectl -n slm get all
kubectl -n slm get ingress
kubectl -n slm get hpa
kubectl -n slm describe deploy slm-api
kubectl -n slm logs deploy/slm-api -c slm-api
```

Kiểm thử API tự động.

**Chạy trên máy quản trị**:

```bash
./scripts/33-test-slm-api.sh
```

Script này kiểm tra:

- Deployment rollout thành công.
- Pod đạt trạng thái `Ready`.
- Service có endpoint hợp lệ.
- Gọi được `/health`.
- Gọi được `/v1/chat/completions`.
- Nếu Traefik service tồn tại, kiểm tra Ingress bằng header `Host: slm.local`.

Nếu muốn gọi API từ bên ngoài bằng hostname `slm.local`, thêm tạm vào `/etc/hosts` trên máy test:

```text
<ingress-ip> slm.local
```

Sau đó test từ máy có thể truy cập Ingress.

**Chạy trên máy quản trị hoặc máy test cùng mạng**:

```bash
curl http://slm.local/health
curl -X POST http://slm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"slm-api",
    "messages":[
      {"role":"system","content":"You are a concise assistant."},
      {"role":"user","content":"Giới thiệu ngắn về hệ thống nhúng mạng không dây."}
    ],
    "max_tokens":64,
    "temperature":0.2
  }'
```

---

## 11. Kiểm thử HPA và benchmark

Chạy load generator đơn giản.

**Chạy trên máy quản trị**:

```bash
./scripts/32-run-loadgen.sh
```

Quan sát ở terminal khác.

**Chạy trên máy quản trị**:

```bash
kubectl -n slm get hpa -w
kubectl -n slm get pods -w
kubectl top pods -n slm
kubectl top nodes
```

Chạy benchmark có thu thập số liệu.

**Chạy trên máy quản trị**:

```bash
SCENARIO_NAME="Moderate load with autoscaling" ./scripts/61-benchmark-report.sh
```

Script benchmark sẽ:

- Chạy `32-run-loadgen.sh` ở nền.
- Lấy mẫu số lượng pod của `slm-api`.
- Lấy mẫu CPU pod và CPU node.
- Trích latency `avg`, `p95` từ `http_req_duration`.
- Trích `Error rate` từ `http_req_failed`.
- Xuất `benchmark-summary.md` và `benchmark-summary.txt` trong `results/<timestamp>-benchmark/`.

Có thể đổi chu kỳ lấy mẫu.

**Chạy trên máy quản trị**:

```bash
SAMPLE_INTERVAL=5 SCENARIO_NAME="High load stress test" ./scripts/61-benchmark-report.sh
```

### Các kịch bản benchmark đề xuất

| Kịch bản | Cấu hình gợi ý | Mục tiêu |
|---|---|---|
| Baseline load test | `LOADGEN_VUS=5`, `LOADGEN_DURATION=60s` | Lấy số liệu nền khi tải nhẹ |
| Moderate load with autoscaling | `LOADGEN_VUS=20`, `LOADGEN_DURATION=120s` | Quan sát HPA scale lên |
| High load stress test | `LOADGEN_VUS=40`, `LOADGEN_DURATION=180s` | Ép hệ thống gần giới hạn |
| Self-healing during traffic | Chạy benchmark, terminal khác chạy `40-test-self-heal.sh` | Xóa pod khi có tải |
| Worker failure and reschedule | Chạy benchmark, terminal khác chạy `41-test-node-failure.sh` | Dừng worker khi có tải |
| Control-plane HA under load | Chạy benchmark, terminal khác chạy `42-test-control-plane-ha.sh` | Dừng master khi có tải |

Mẫu bảng kết quả cho báo cáo:

| Kịch bản thử nghiệm | Số lượng Pod | CPU trung bình | Độ trễ phản hồi | Error rate | Ghi chú |
|---|---:|---:|---|---:|---|
| Baseline load test | 1 | xx mCPU, yy% node CPU | avg=..., p95=... | ... | Tải nhẹ |
| Moderate load with autoscaling | 1 -> 2 | xx mCPU, yy% node CPU | avg=..., p95=... | ... | HPA bắt đầu scale |
| High load stress test | 1 -> 3 hoặc 4 | xx mCPU, yy% node CPU | avg=..., p95=... | ... | Gần ngưỡng tải |
| Self-healing during traffic | 1 -> n | xx mCPU, yy% node CPU | avg=..., p95=... | ... | Xóa pod khi có tải |
| Worker failure and reschedule | 1 -> n | xx mCPU, yy% node CPU | avg=..., p95=... | ... | Pod chuyển sang worker còn lại |
| Control-plane HA under load | 1 -> n | xx mCPU, yy% node CPU | avg=..., p95=... | ... | Dừng một master, API vẫn qua VIP |

---

## 12. Kiểm thử self-healing, worker failure và control-plane HA

### 12.1. Pod self-healing

**Chạy trên máy quản trị**:

```bash
./scripts/40-test-self-heal.sh
```

Kết quả mong đợi:

- Một pod `slm-api` bị xóa.
- Deployment tạo pod mới.
- Pod mới đạt `Ready`.
- Service tiếp tục phục vụ request.

### 12.2. Worker failure và reschedule

**Chạy trên máy quản trị**:

```bash
./scripts/41-test-node-failure.sh
```

Script sẽ:

- Kiểm tra có pod `slm-api` đang chạy trên `worker1`.
- Dừng `k3s-agent` trên `worker1`.
- Đợi pod `slm-api` Ready trên `worker2`.
- Khởi động lại `k3s-agent` trên `worker1`.

Lưu ý: nếu không có pod nào đang nằm trên `worker1`, script sẽ dừng và báo không thể chứng minh reschedule. Khi đó có thể chạy tải để HPA tạo thêm replica, hoặc scale tạm thời Deployment trước khi test.

### 12.3. Control-plane HA

**Chạy trên máy quản trị**:

```bash
./scripts/42-test-control-plane-ha.sh
```

Script sẽ:

- Kiểm tra API qua VIP trước khi lỗi.
- Dừng `k3s` trên một master.
- Xác nhận cluster vẫn reachable với 2/3 control plane.
- Dừng thêm master thứ hai để chứng minh giới hạn quorum etcd.
- Khôi phục các master.

Kết quả mong đợi:

- Mất 1 master: API vẫn truy cập được qua VIP.
- Mất 2/3 master: API có thể mất quorum như dự kiến.
- Sau khi khôi phục master: cluster hoạt động lại.

---

## 13. Thu thập kết quả cho báo cáo

Thu thập nhanh.

**Chạy trên máy quản trị**:

```bash
./scripts/60-collect-results.sh
```

Script tạo thư mục `results/<timestamp>/` gồm:

| File | Nội dung |
|---|---|
| `hpa.txt` | Trạng thái HPA |
| `top-nodes.txt` | CPU/RAM node |
| `top-pods.txt` | CPU/RAM pod trong namespace `slm` |
| `pods-wide.txt` | Vị trí pod trên node |
| `loadgen-logs.txt` | Log k6 |

Các ảnh/chứng cứ nên chụp:

- Sơ đồ topology node và VIP.
- `kubectl get nodes -o wide`.
- `kubectl -n slm get all`.
- Log tải model và startup `llama-server`.
- Kết quả gọi `/health` và `/v1/chat/completions`.
- HPA trước, trong và sau load test.
- Pod được tạo lại sau khi xóa.
- Pod reschedule khi worker down.
- API vẫn truy cập qua VIP khi dừng một master.

---

## 14. Trình tự demo ngắn

Thứ tự demo gợi ý. Các lệnh dưới đây **chạy trên máy quản trị** sau khi đã có kubeconfig:

1. `kubectl get nodes -o wide`
2. `./scripts/39-test-cluster-status.sh`
3. `kubectl -n slm get all`
4. `./scripts/33-test-slm-api.sh`
5. `SCENARIO_NAME="Moderate load with autoscaling" ./scripts/61-benchmark-report.sh`
6. `kubectl -n slm get hpa -w`
7. `./scripts/40-test-self-heal.sh`
8. `./scripts/41-test-node-failure.sh`
9. `./scripts/42-test-control-plane-ha.sh`

---

## 15. Lệnh tổng hợp nhanh

```bash
# Trên máy quản trị
cp cluster.env.example cluster.env
./scripts/50-check-model-source.sh

# Nếu cần cấu hình IP tĩnh tự động
./scripts/01-copy-static-ip-script.sh

# Trên từng Pi nếu chưa cấu hình IP tĩnh
sudo ~/00-configure-static-ip.sh --dry-run
sudo ~/00-configure-static-ip.sh
sudo reboot

# Sau khi Pi lên lại, trên từng Pi
sudo ./scripts/00-node-prereqs.sh
sudo reboot

# Trên master1
sudo ./scripts/10-init-first-server.sh

# Trên master2 và master3
sudo ./scripts/11-join-server.sh

# Trên worker1 và worker2
sudo ./scripts/12-join-agent.sh

# Trên máy quản trị
./scripts/20-fetch-kubeconfig.sh
export KUBECONFIG=$HOME/.kube/nt131-k3s.yaml
./scripts/30-label-nodes.sh
./scripts/39-test-cluster-status.sh
./scripts/31-deploy-slm-stack.sh
./scripts/33-test-slm-api.sh
SCENARIO_NAME="Moderate load with autoscaling" ./scripts/61-benchmark-report.sh
./scripts/40-test-self-heal.sh
./scripts/41-test-node-failure.sh
./scripts/42-test-control-plane-ha.sh
./scripts/60-collect-results.sh
```

---

## 16. Lưu ý và giới hạn

- `00-configure-static-ip.sh` không đổi hostname; cần đặt hostname trước bằng `hostnamectl` nếu chưa đúng.
- `00-node-prereqs.sh` có chỉnh kernel args cgroup, nên cần reboot sau khi chạy.
- `sshpass` và mật khẩu trong `cluster.env` chỉ phù hợp cho lab/demo, không phù hợp production.
- `Traefik` và `metrics-server` dùng theo mặc định của k3s, không cài lại bằng Helm.
- Chưa triển khai MetalLB vì trong yêu cầu là optional.
- `slm-api` chạy CPU-only trên Raspberry Pi 4 nên latency sẽ cao hơn máy x86/GPU.
- Khi HPA tạo replica mới, pod có thể mất thời gian vì cần pull image và load model.
- Nếu test tải lớn, có thể tăng `LOADGEN_VUS`, `LOADGEN_DURATION`, hoặc giảm `LLM_MAX_TOKENS`.
