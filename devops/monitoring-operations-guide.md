# 📖 Hướng Dẫn Vận Hành Monitoring & Observability

> **Dành cho:** DevOps/SRE vận hành hệ thống Online Boutique trên AWS EKS
> **Prerequisite:** Stage 5 đã triển khai đầy đủ (Prometheus, Grafana, Loki, Tempo, OTel Collector)

---

## 1. Tổng Quan Hệ Thống Monitoring

### 1.1 Bản Đồ Truy Cập Nhanh

| Tool | Port-Forward | URL | Mục đích |
|------|-------------|-----|----------|
| **Grafana** | `kubectl port-forward -n monitoring svc/grafana 3000:80` | `http://localhost:3000` (admin/admin) | Dashboards, Logs, Traces |
| **Prometheus** | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` | `http://localhost:9090` | PromQL queries, targets, rules |
| **Alertmanager** | `kubectl port-forward -n monitoring svc/alertmanager 9093:9093` | `http://localhost:9093` | Alert groups, silences |
| **Kiali** | `kubectl port-forward -n istio-system svc/kiali 20001:20001` | `http://localhost:20001/kiali` | Service mesh topology |

### 1.2 Kiến Trúc Luồng Dữ Liệu

```
┌─────────────────────────────────────────────────────────────────┐
│                         DATA SOURCES                            │
│  Pods (11 services) → stdout/stderr logs                        │
│  Envoy Sidecars    → metrics (:15090) + traces (Zipkin :9411)   │
│  K8s Nodes         → node metrics (:9100)                       │
│  kube-state-metrics → cluster state (:8080)                     │
└───────┬───────────────────┬──────────────────┬──────────────────┘
        │                   │                  │
   ┌────▼────┐        ┌────▼────┐       ┌─────▼──────┐
   │Prometheus│        │Promtail │       │OTel Collect│
   │(scrape)  │        │(tail)   │       │(receive)   │
   └────┬────┘        └────┬────┘       └─────┬──────┘
        │                   │                  │
   ┌────▼────┐        ┌────▼────┐       ┌─────▼──────┐
   │Prometheus│        │  Loki   │       │   Tempo    │
   │  TSDB   │        │(index)  │       │ (store)    │
   └────┬────┘        └────┬────┘       └─────┬──────┘
        │                   │                  │
        └───────────┬───────┘──────────────────┘
               ┌────▼────┐
               │ GRAFANA │  ← Single Pane of Glass
               └─────────┘
```

---

## 2. Vận Hành Hàng Ngày

### 2.1 Kiểm Tra Sức Khỏe Buổi Sáng (Morning Health Check)

Sau khi recreate hạ tầng mỗi sáng, chạy các lệnh sau để verify:

#### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra tất cả pods monitoring đang Running
kubectl get pods -n monitoring

# 2. Kiểm tra Prometheus đã scrape được Istio metrics
kubectl run test-prom --image=curlimages/curl --restart=Never --rm -i -- \
  -s "http://prometheus-server.monitoring:80/api/v1/query?query=count(istio_requests_total)"

# 3. Kiểm tra Loki đã nhận logs
kubectl run test-loki --image=curlimages/curl --restart=Never --rm -i -- \
  -s "http://loki-stack.monitoring:3100/loki/api/v1/labels"

# 4. Kiểm tra Tempo sẵn sàng
kubectl run test-tempo --image=curlimages/curl --restart=Never --rm -i -- \
  -s "http://tempo.monitoring:3100/ready"

# 5. Kiểm tra alert rules đã load
kubectl run test-rules --image=curlimages/curl --restart=Never --rm -i -- \
  -s "http://prometheus-server.monitoring:80/api/v1/rules" | grep "online-boutique"
```

#### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra tất cả pods monitoring đang Running
kubectl get pods -n monitoring

# 2. Kiểm tra Prometheus đã scrape được Istio metrics
kubectl run test-prom --image=curlimages/curl --restart=Never --rm -i -- -s "http://prometheus-server.monitoring:80/api/v1/query?query=count(istio_requests_total)" 2>$null

# 3. Kiểm tra Loki đã nhận logs
kubectl run test-loki --image=curlimages/curl --restart=Never --rm -i -- -s "http://loki-stack.monitoring:3100/loki/api/v1/labels" 2>$null

# 4. Kiểm tra Tempo sẵn sàng
kubectl run test-tempo --image=curlimages/curl --restart=Never --rm -i -- -s "http://tempo.monitoring:3100/ready" 2>$null

# 5. Kiểm tra alert rules đã load
kubectl run test-rules --image=curlimages/curl --restart=Never --rm -i -- -s "http://prometheus-server.monitoring:80/api/v1/rules" 2>$null | Select-String "online-boutique"
```

### 2.2 Kiểm Tra Cuối Ngày Trước Khi Destroy

#### Trên Linux / macOS (Bash):
```bash
# Kiểm tra có alert đang firing không
kubectl run test-alerts --image=curlimages/curl --restart=Never --rm -i -- \
  -s "http://prometheus-server.monitoring:80/api/v1/alerts" | grep "firing"

# Nếu cần export data trước khi destroy:
# (Prometheus data sẽ mất - OK cho dev)
```

#### Trên Windows (PowerShell):
```powershell
# Kiểm tra có alert đang firing không
kubectl run test-alerts --image=curlimages/curl --restart=Never --rm -i -- -s "http://prometheus-server.monitoring:80/api/v1/alerts" 2>$null | Select-String "firing"

# Nếu cần export data trước khi destroy:
# (Prometheus data sẽ mất - OK cho dev)
```

---

## 3. Grafana: Hướng Dẫn Sử Dụng Chi Tiết

### 3.1 Truy Cập & Đăng Nhập

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```
- URL: `http://localhost:3000`
- Username: `admin` | Password: `admin`

### 3.2 Các Dashboard Có Sẵn

#### Dashboard 1: Microservices Overview (Golden Signals)

**Mục đích:** Giám sát 4 Golden Signals cho tất cả 11 microservices

| Panel | Metric | Ý nghĩa | Ngưỡng cảnh báo |
|-------|--------|---------|-----------------|
| **Request Rate** | `istio_requests_total` | Số request/giây (RPS) mỗi service | Bất thường nếu đột ngột tăng/giảm |
| **Error Rate 5xx** | `istio_requests_total{response_code=~"5.*"}` | % request trả về lỗi server | > 5% = cần điều tra |
| **P95 Latency** | `istio_request_duration_milliseconds_bucket` | 95% requests hoàn thành trong bao lâu | > 1000ms = chậm |
| **Pod Availability** | `kube_deployment_status_replicas_available` | Số pod đang chạy vs mong muốn | Thiếu replica = nguy hiểm |

**Cách đọc dashboard:**
1. Mở Grafana → Dashboards → "Online Boutique - Microservices Overview"
2. Chọn time range (15m, 1h, 6h) ở góc trên phải
3. Nếu Error Rate > 0: click vào panel → "Explore" để xem chi tiết service nào lỗi
4. Nếu Latency cao: kiểm tra xem service nào chậm, có thể do circuit breaker kick in

#### Dashboard 2: Istio Service Mesh

**Mục đích:** Giám sát Ingress Gateway và traffic giữa các services

| Panel | Ý nghĩa |
|-------|---------|
| **Ingress Gateway RPS** | Traffic từ internet vào app |
| **Inter-service Traffic** | Ma trận source → destination |
| **TCP Connections** | Số kết nối TCP đang mở |
| **Envoy Memory** | Bộ nhớ sidecar proxy |

#### Dashboard 3: Pod Resources

**Mục đích:** Giám sát tài nguyên compute (CPU/Memory)

| Panel | Ý nghĩa | Hành động |
|-------|---------|-----------|
| **CPU Usage** | CPU cores sử dụng thực tế | So sánh với limits |
| **Memory Usage** | Bytes memory sử dụng | > 85% limit → cần tăng limit hoặc scale |
| **Container Restarts** | Số lần restart | > 0 = investigate logs |
| **CPU Throttling** | % thời gian CPU bị giới hạn | > 25% = cần tăng CPU limit |

### 3.3 Truy Vấn Logs Với Loki (Grafana Explore)

**Mở:** Grafana → Explore (biểu tượng la bàn) → Chọn datasource **Loki**

#### Các query LogQL thường dùng:

```logql
# 1. Xem logs của 1 service cụ thể (ví dụ: cartservice)
{namespace="online-boutique", app="cartservice"}

# 2. Xem logs của tất cả services trong online-boutique
{namespace="online-boutique"}

# 3. Lọc logs chứa từ "error" (không phân biệt hoa thường)
{namespace="online-boutique"} |~ "(?i)error"

# 4. Lọc logs chứa "timeout" hoặc "connection refused"
{namespace="online-boutique"} |~ "timeout|connection refused"

# 5. Xem logs container istio-proxy (Envoy sidecar)
{namespace="online-boutique", container="istio-proxy"}

# 6. Xem logs monitoring stack
{namespace="monitoring"}

# 7. Đếm số dòng log error mỗi phút theo service
count_over_time({namespace="online-boutique"} |~ "(?i)error" [1m])

# 8. Xem logs của pod cụ thể
{namespace="online-boutique", pod="frontend-f989df867-tcqgn"}
```

#### Workflow điều tra lỗi bằng Loki:

1. Alert `HighErrorRate` firing cho `checkoutservice`
2. Mở Grafana → Explore → Loki
3. Query: `{namespace="online-boutique", app="checkoutservice"} |~ "(?i)error|fail|exception"`
4. Xem timestamp và nội dung lỗi
5. Nếu lỗi liên quan service khác (e.g., "connection to paymentservice failed"):
   - Query thêm: `{namespace="online-boutique", app="paymentservice"} |~ "(?i)error"`

### 3.4 Xem Distributed Traces Với Tempo (Grafana Explore)

**Mở:** Grafana → Explore → Chọn datasource **Tempo**

#### Cách tìm traces:

```
# 1. Search by service name
Service Name = frontend

# 2. Search by duration (tìm requests chậm)
Min Duration = 500ms

# 3. Search by status (tìm requests lỗi)
Status = error
```

#### Workflow phân tích latency:

1. Dashboard "Microservices Overview" cho thấy P95 latency của `checkoutservice` > 1s
2. Mở Grafana → Explore → Tempo → Search
3. Service Name = `checkoutservice`, Min Duration = 1000ms
4. Click vào 1 trace → thấy waterfall diagram:
   ```
   checkoutservice (1200ms)
   ├── cartservice.GetCart (50ms)
   ├── productcatalogservice.GetProduct (30ms)
   ├── currencyservice.Convert (20ms)
   ├── paymentservice.Charge (800ms)  ← ĐÂY LÀ BOTTLENECK
   ├── shippingservice.GetQuote (30ms)
   └── emailservice.SendConfirmation (40ms)
   ```
5. Thấy `paymentservice.Charge` chiếm 800ms → điều tra service này

---

## 4. Prometheus: PromQL Queries Thường Dùng

### 4.1 Truy Cập

```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
```
URL: `http://localhost:9090`

### 4.2 Queries Theo Tình Huống

#### Tình huống 1: Kiểm tra tổng quan traffic

```promql
# Tổng RPS vào từng service
sum by (destination_workload) (
  rate(istio_requests_total{reporter="destination",destination_workload_namespace="online-boutique"}[5m])
)

# Error rate % theo service
sum by (destination_workload) (
  rate(istio_requests_total{reporter="destination",destination_workload_namespace="online-boutique",response_code=~"5.*"}[5m])
) / sum by (destination_workload) (
  rate(istio_requests_total{reporter="destination",destination_workload_namespace="online-boutique"}[5m])
) * 100

# P95 latency theo service
histogram_quantile(0.95,
  sum by (le, destination_workload) (
    rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_workload_namespace="online-boutique"}[5m])
  )
)
```

#### Tình huống 2: Kiểm tra tài nguyên

```promql
# CPU usage theo pod (cores)
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="online-boutique",container!=""}[5m])
)

# Memory usage theo pod (MB)
sum by (pod) (
  container_memory_working_set_bytes{namespace="online-boutique",container!=""}
) / 1024 / 1024

# CPU throttling %
sum by (pod) (
  rate(container_cpu_cfs_throttled_periods_total{namespace="online-boutique"}[5m])
) / sum by (pod) (
  rate(container_cpu_cfs_periods_total{namespace="online-boutique"}[5m])
) * 100
```

#### Tình huống 3: Kiểm tra Istio mesh

```promql
# mTLS connections
sum by (destination_workload) (
  istio_tcp_connections_opened_total{destination_workload_namespace="online-boutique"}
)

# Envoy sidecar memory (MB)
sum by (pod) (
  container_memory_working_set_bytes{namespace="online-boutique",container="istio-proxy"}
) / 1024 / 1024
```

---

## 5. Alert Management

### 5.1 Danh Sách Alert Rules Hiện Tại

| Alert | Severity | Trigger | Hành động |
|-------|----------|---------|-----------|
| `OnlineBoutiquePodCrashLooping` | 🔴 Critical | Pod restart > 1 lần/15m hoặc CrashLoopBackOff | Xem logs: `kubectl logs -n online-boutique <pod> --previous` |
| `OnlineBoutiqueHighErrorRate` | 🟡 Warning | HTTP 5xx > 5% trong 3 phút | Xem Grafana dashboard → xác định service lỗi → xem logs |
| `OnlineBoutiqueHighLatency` | 🟡 Warning | P95 > 1000ms trong 5 phút | Xem traces trong Tempo → tìm bottleneck service |
| `OnlineBoutiqueContainerMemoryHigh` | 🟡 Warning | Memory > 85% limit trong 5 phút | Scale up hoặc tăng memory limit |
| `OnlineBoutiqueServiceReplicasUnavailable` | 🔴 Critical | Available < desired replicas trong 5 phút | Kiểm tra node capacity, PDB, events |
| `OnlineBoutiqueHighCPUUsage` | 🟡 Warning | CPU > 80% limit trong 5 phút | Tăng CPU limit hoặc scale replicas |
| `SpotInstanceInterruption` | 🟡 Warning | Spot instance nhận thông báo thu hồi | Monitor pod migration, xem Cluster Autoscaler đã tạo node mới chưa |

### 5.2 Xem Alerts Đang Firing

```bash
# Qua CLI
kubectl run test-alerts --image=curlimages/curl --restart=Never --rm -i -- \
  -s "http://prometheus-server.monitoring:80/api/v1/alerts" | python -m json.tool

# Qua Alertmanager UI
kubectl port-forward -n monitoring svc/alertmanager 9093:9093
# Mở http://localhost:9093
```

### 5.3 Silence Alerts (Tắt Tạm Thời)

Khi đang bảo trì và muốn tắt tạm cảnh báo:

1. Mở Alertmanager UI (`http://localhost:9093`)
2. Click **"New Silence"**
3. Nhập matchers: `alertname="OnlineBoutiqueHighErrorRate"` (hoặc alert muốn tắt)
4. Đặt thời gian silence (ví dụ: 2 giờ)
5. Ghi lý do: "Đang bảo trì service X"
6. Click **"Create"**

---

## 6. Kiali: Service Mesh Visualization

### 6.1 Truy Cập

```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
```
URL: `http://localhost:20001/kiali`

### 6.2 Các Tab Quan Trọng

#### Tab Graph (Traffic Graph)
**Cách đọc:**
1. Chọn Namespace: `online-boutique`
2. Display: chọn "Requests percentage" hoặc "Requests per second"
3. **Màu sắc đường:**
   - 🟢 Xanh lá = healthy (100% success)
   - 🟡 Vàng = có lỗi nhỏ
   - 🔴 Đỏ = error rate cao
4. **Biểu tượng ổ khóa (🔒)** = traffic mTLS encrypted
5. Hover lên đường nối = xem chi tiết RPS, error %, latency

#### Tab Workloads
- Xem trạng thái từng deployment
- **Healthy** (xanh) = tất cả pods đang chạy
- **Degraded** (đỏ) = có pod lỗi

#### Tab Istio Config
- Validate cấu hình Istio (VirtualService, DestinationRule, AuthorizationPolicy)
- **Valid** (✅) = cấu hình đúng
- **Warning/Error** (⚠️/❌) = cần kiểm tra

---

## 7. Runbook: Xử Lý Sự Cố Thường Gặp

### 7.1 Alert: `PodCrashLooping`

```bash
# Bước 1: Xác định pod nào
kubectl get pods -n online-boutique | grep -v Running

# Bước 2: Xem events
kubectl describe pod <pod-name> -n online-boutique

# Bước 3: Xem logs lần chạy cuối (trước khi crash)
kubectl logs <pod-name> -n online-boutique -c server --previous

# Bước 4: Xem logs Envoy sidecar
kubectl logs <pod-name> -n online-boutique -c istio-proxy --previous

# Bước 5: Nguyên nhân phổ biến:
# - OOMKilled → tăng memory limit
# - Connection refused → service phụ thuộc chưa sẵn sàng
# - Config error → kiểm tra env vars, configmaps
```

### 7.2 Alert: `HighErrorRate`

```bash
# Bước 1: Xác định service nào (từ Grafana dashboard hoặc PromQL)
# Grafana → Microservices Overview → Error Rate panel

# Bước 2: Xem response codes chi tiết
# PromQL:
# sum by (destination_workload, response_code) (
#   rate(istio_requests_total{reporter="destination",destination_workload_namespace="online-boutique"}[5m])
# )

# Bước 3: Xem logs service lỗi (Grafana Explore → Loki)
# Query: {namespace="online-boutique", app="<service>"} |~ "(?i)error|5[0-9]{2}"

# Bước 4: Xem traces cho requests lỗi (Grafana Explore → Tempo)
# Service Name = <service>, Status = error
```

### 7.3 Alert: `HighLatency`

```bash
# Bước 1: Xác định service chậm (Grafana → P95 Latency panel)

# Bước 2: Xem traces trong Tempo
# Grafana → Explore → Tempo → Search
# Service Name = <service>, Min Duration = 1000ms

# Bước 3: Phân tích waterfall → tìm bottleneck
# Nguyên nhân phổ biến:
# - ElastiCache Redis chậm → kiểm tra CloudWatch metrics
# - gRPC connection timeout → kiểm tra DestinationRule
# - CPU throttling → kiểm tra Pod Resources dashboard
```

### 7.4 Alert: `SpotInstanceInterruption`

```bash
# Bước 1: Xác định node nào bị interrupt
kubectl get nodes -o wide

# Bước 2: Xem pods trên node đó
kubectl get pods -A -o wide --field-selector spec.nodeName=<node-name>

# Bước 3: Cluster Autoscaler sẽ tự:
# - Drain pods khỏi node bị interrupt
# - Provision node mới (nếu cần)
# - Scheduler tự schedule pods lên node mới

# Bước 4: Verify sau 5 phút
kubectl get pods -n online-boutique
# Kỳ vọng: tất cả 11 pods Running
```

### 7.5 Prometheus Không Scrape Được Istio Metrics

```bash
# Bước 1: Kiểm tra Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Mở http://localhost:9090/targets → tìm job "envoy-stats"

# Bước 2: Nếu targets missing, kiểm tra pods có istio-proxy
kubectl get pods -n online-boutique -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'

# Bước 3: Nếu thiếu istio-proxy → sidecar injection chưa bật
kubectl get namespace online-boutique --show-labels | grep istio-injection

# Bước 4: Restart pods nếu cần
kubectl rollout restart deployment -n online-boutique
```

### 7.6 Kiali Graph Không Hiển Thị Traffic

```bash
# Bước 1: Kiểm tra Kiali logs
kubectl logs -n istio-system deployment/kiali --tail=30

# Bước 2: Kiểm tra Prometheus service alias
kubectl get svc prometheus-server -n monitoring

# Bước 3: Test kết nối Kiali → Prometheus
kubectl exec -n istio-system deployment/kiali -- curl -s http://prometheus-server.monitoring:80/api/v1/query?query=up

# Bước 4: Nếu service alias thiếu
kubectl apply -k base/monitoring
```

---

## 8. Tuỳ Chỉnh & Mở Rộng

### 8.1 Thêm Dashboard Grafana Mới

1. Tạo dashboard trong Grafana UI
2. Export JSON: Dashboard → Share → Export → Save to file
3. Tạo ConfigMap trong `base/monitoring/grafana-dashboards/`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-my-custom
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |-
    { ... paste JSON ... }
```

4. Thêm vào `base/monitoring/kustomization.yaml`
5. Commit → ArgoCD auto-sync

### 8.2 Thêm Alert Rule Mới

Thêm vào `base/monitoring/custom-alerts/online-boutique-alerts.yaml`:

```yaml
- alert: MyCustomAlert
  expr: <PromQL expression>
  for: 5m
  labels:
    severity: warning
    tier: microservices
  annotations:
    summary: "Description {{ $labels.pod }}"
    description: "Detail..."
```

Commit → ArgoCD auto-sync → Prometheus Operator tự reload rules.

### 8.3 Cấu Hình Alertmanager Gửi Slack

Sửa `prometheus-stack-values.yaml` hoặc inline values trong ArgoCD App:

```yaml
alertmanager:
  config:
    route:
      receiver: 'slack-notifications'
      group_by: ['alertname', 'namespace']
    receivers:
      - name: 'slack-notifications'
        slack_configs:
          - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
            channel: '#alerts-online-boutique'
            title: '{{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```
