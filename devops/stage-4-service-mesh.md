# 🕸️ Stage 4 – Service Mesh: Istio + Kiali

> **Ngày hoàn thành:** 2026-10-18  
> **Áp dụng cho:** `online-boutique-app` và `online-boutique-config`  
> **Tác giả:** DevOps Team  
> **Branch:** `feature/stage-4-service-mesh`

---

## 1. Tổng Quan & Mục Tiêu

Stage 4 triển khai giải pháp **Service Mesh** sử dụng **Istio** và bảng điều khiển trực quan hóa **Kiali** trên cụm AWS EKS v1.36. Sau khi hoàn thành stage này, hệ thống Online Boutique đạt được:

- **Mã hóa toàn diện (mTLS STRICT):** 100% lưu lượng giao tiếp service-to-service giữa 11 microservices được mã hóa hai chiều bằng chứng chỉ x509 tự động do `istiod` quản lý.
- **Kiểm soát truy cập đặc quyền tối thiểu (Least Privilege Access Control):** Áp dụng chính sách `AuthorizationPolicy` `deny-all` mặc định, chỉ cho phép các luồng gọi hợp lệ giữa các ServiceAccount theo ma trận phụ thuộc.
- **Quản lý lưu lượng Ingress tập trung:** Thay thế toàn bộ Service `frontend-external` (LoadBalancer độc lập cũ) bằng **Istio Ingress Gateway** kết nối với AWS Network/Application Load Balancer, định tuyến thông minh qua Istio `Gateway` và `VirtualService`.
- **Khả năng phục hồi (Resilience):** Cấu hình `DestinationRule` với connection pool và outlier detection (circuit breaking) chống sập theo tầng (cascading failures).
- **Khả năng quan sát trực quan (Observability):** Tích hợp **Kiali Dashboard** để trực quan hóa sơ đồ topology microservices, trạng thái mã hóa mTLS và lưu lượng thời gian thực.
- **Tương thích với ElastiCache Redis ngoài mesh:** Đảm bảo `cartservice` kết nối thông suốt ra cụm AWS ElastiCache Redis ngoài mesh qua giao thức TCP port 6379.

---

## 2. Kiến Trúc Lưu Lượng (Traffic Architecture)

```mermaid
graph TD
    User([Khách hàng / Internet]) -->|HTTP Port 80| AWS_NLB[AWS NLB / Ingress]
    AWS_NLB -->|TCP Port 80| IGW[Istio Ingress Gateway<br/>Namespace: istio-system]
    
    subgraph Mesh [Online Boutique Service Mesh - mTLS STRICT]
        IGW -->|mTLS| Frontend[frontend<br/>Envoy Sidecar]
        LoadGen[loadgenerator<br/>Envoy Sidecar] -->|mTLS| Frontend
        
        Frontend -->|mTLS gRPC| Cart[cartservice]
        Frontend -->|mTLS gRPC| Product[productcatalogservice]
        Frontend -->|mTLS gRPC| Currency[currencyservice]
        Frontend -->|mTLS gRPC| Shipping[shippingservice]
        Frontend -->|mTLS gRPC| Checkout[checkoutservice]
        Frontend -->|mTLS gRPC| Rec[recommendationservice]
        Frontend -->|mTLS gRPC| Ad[adservice]
        
        Checkout -->|mTLS gRPC| Cart
        Checkout -->|mTLS gRPC| Product
        Checkout -->|mTLS gRPC| Currency
        Checkout -->|mTLS gRPC| Payment[paymentservice]
        Checkout -->|mTLS gRPC| Shipping
        Checkout -->|mTLS gRPC| Email[emailservice]
        
        Rec -->|mTLS gRPC| Product
    end
    
    subgraph External [Hạ tầng ngoài Mesh - AWS VPC]
        Cart -->|TCP Port 6379 Passthrough| Redis[(AWS ElastiCache Redis 7.1)]
    end
```

### So Sánh Trước & Sau Stage 4

| Tiêu chí | Trước Stage 4 (Stage 3) | Sau Stage 4 |
| :--- | :--- | :--- |
| **Cổng vào Ingress** | Service `frontend-external` (NLB trỏ trực tiếp pod) | **Istio Ingress Gateway** + Gateway & VirtualService |
| **Bảo mật nội bộ** | Plaintext giữa các Pod | **mTLS STRICT** (Mutual TLS 100%) |
| **Quyền truy cập** | Tự do gọi qua Kubernetes DNS nội bộ | **AuthorizationPolicy Whitelist** (Deny-All mặc định) |
| **Circuit Breaker** | Không có | **DestinationRule** (Connection pool + Outlier detection) |
| **Giám sát Topology** | Chưa có | **Kiali Dashboard** quan sát real-time service graph |

---

## 3. Các Quyết Định Thiết Kế Quan Trọng

### 3.1 Thay Thế `frontend-external` Bằng Istio Ingress Gateway
- **Hiện trạng:** Ở Stage 3, `frontend-external` là một Service kiểu `LoadBalancer` riêng biệt do AWS Load Balancer Controller cấp phát NLB.
- **Giải pháp:** 
  1. Tạo patch Kustomize (`overlays/dev/patches/frontend-service.yaml`) sử dụng directive `$patch: delete` để tự động loại bỏ Service `frontend-external`.
  2. Bổ sung `Gateway` (`online-boutique-gateway`) lắng nghe trên port 80 tại namespace `istio-system` và `VirtualService` (`frontend`) tại namespace `online-boutique` định tuyến traffic vào Service ClusterIP `frontend:80`.
  3. Cấu hình annotation `service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"` trên Service `istio-ingressgateway` để AWS LB Controller tạo public NLB/ALB.
- **Lợi ích:** Tiết kiệm chi phí (chỉ duy trì 1 Load Balancer cho toàn bộ traffic bên ngoài vào mesh), chuẩn hóa mô hình Ingress Gateway của Service Mesh.

### 3.2 Cơ Chế Least Privilege Với AuthorizationPolicy
- Triển khai policy `deny-all` tại namespace `online-boutique` để chặn đứng toàn bộ traffic không được định nghĩa rõ ràng.
- Định nghĩa 10 rule ALLOW dựa trên ServiceAccount principal định danh SPIFFE:
  - Format principal: `cluster.local/ns/<namespace>/sa/<serviceaccount-name>`
  - Phù hợp chính xác với service dependency matrix của Online Boutique.
  - Phép ngoại lệ cho `loadgenerator` (gửi request kiểm thử HTTP vào `frontend`).

### 3.3 Đảm Bảo Kết Nối Ra ElastiCache Redis Ngoài Mesh
- `cartservice` kết nối với AWS ElastiCache Redis tại endpoint `online-boutique-dev.e9wc6a.ng.0001.apse1.cache.amazonaws.com:6379`.
- Istio mặc định sử dụng `meshConfig.outboundTrafficPolicy.mode = ALLOW_ANY`, cho phép Envoy sidecar pass-through trực tiếp các kết nối ra ngoài cụm.
- `DestinationRule` áp dụng scope `*.online-boutique.svc.cluster.local`, do đó không can thiệp hay ép mTLS lên endpoint ElastiCache của AWS.

---

## 4. Cấu Trúc Thư Mục Cấu Hình (Repository `online-boutique-config`)

```
online-boutique-config/
├── argocd/
│   └── apps/
│       └── dev/
│           ├── online-boutique.yaml        # ArgoCD App cho 11 microservices
│           ├── aws-lb-controller.yaml      # ArgoCD App cho AWS LB Controller
│           ├── cluster-autoscaler.yaml     # ArgoCD App cho Cluster Autoscaler
│           └── istio-config.yaml           # [MỚI] ArgoCD App đồng bộ Istio manifests
│
├── base/
│   ├── online-boutique/                    # 11 microservices base manifests
│   └── istio/                              # [MỚI] Istio Base Manifests
│       ├── kustomization.yaml              # Tập hợp các manifests Istio
│       ├── namespace.yaml                  # Định nghĩa namespace istio-system
│       ├── gateway.yaml                    # Istio Gateway trên Ingress Gateway
│       ├── virtual-service.yaml            # VirtualService định tuyến frontend
│       ├── peer-authentication.yaml        # mTLS STRICT mode cho online-boutique
│       ├── authorization-policies.yaml     # Deny-all + 10 allow policies (Least Privilege)
│       ├── destination-rules.yaml          # Connection pool + Outlier detection
│       └── kiali-values.yaml               # Helm values cấu hình Kiali Server
│
└── overlays/
    └── dev/
        ├── kustomization.yaml              # Kích hoạt patch xóa frontend-external
        └── patches/
            ├── cartservice-redis.yaml      # Patch inject ElastiCache Redis
            └── frontend-service.yaml       # [MỚI] Patch xóa frontend-external Service
```

---

## 5. Hướng Dẫn Cài Đặt Chi Tiết (Installation Guide)

Dưới đây là các bước cài đặt chi tiết Istio và Kiali trên cụm EKS (áp dụng khi triển khai mới hoặc sau mỗi lần khởi tạo lại hạ tầng):

### Bước 1: Cài Đặt Istio Với Internet-Facing Load Balancer
Cài đặt Istio profile `default` và cấu hình annotation trực tiếp cho Ingress Gateway để AWS Load Balancer Controller tự động tạo Internet-facing NLB:

**Trên Windows (PowerShell):**
> 💡 *Lưu ý trong PowerShell:* Dùng dấu backtick (`` ` ``) để ngắt dòng và bọc giá trị `--set` trong cặp nháy đơn (`'...'`) để tránh lỗi phân tích cú pháp của PowerShell:
```powershell
istioctl install --set profile=default `
  --set 'values.gateways.istio-ingressgateway.serviceAnnotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing' `
  -y
```
*(Hoặc chạy trên một dòng duy nhất)*:
```powershell
istioctl install --set profile=default --set 'values.gateways.istio-ingressgateway.serviceAnnotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing' -y
```

**Trên Linux / macOS (Bash):**
```bash
istioctl install --set profile=default \
  --set 'values.gateways.istio-ingressgateway.serviceAnnotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing' \
  -y
```

---

### Bước 2: Bật Istio Sidecar Injection & Khởi Động Lại Pods
Gắn nhãn namespace `online-boutique` để kích hoạt tự động tiêm sidecar Envoy và khởi động lại toàn bộ deployments:

**Trên cả Windows & Linux:**
```bash
kubectl label namespace online-boutique istio-injection=enabled --overwrite
kubectl rollout restart deployment -n online-boutique
```
*Kiểm tra trạng thái rollout:*
```bash
kubectl get pods -n online-boutique
# Kỳ vọng: Tất cả 11 pods đều hiển thị trạng thái 2/2 Running
```

---

### Bước 3: Áp Dụng Cấu Hình Istio Bằng ArgoCD (Hoặc Kubectl)
Sau khi repo `online-boutique-config` đã có các manifests trong thư mục `base/istio/`, áp dụng ArgoCD Application để GitOps tự động quản lý:

**Trên cả Windows & Linux:**
```bash
kubectl apply -f argocd/apps/dev/istio-config.yaml
```
*(Nếu muốn áp dụng trực tiếp qua Kustomize:* `kubectl apply -k base/istio`*)*

---

### Bước 4: Cài Đặt Kiali Dashboard Bằng Helm
Cài đặt Kiali Server vào namespace `istio-system` với chiến lược xác thực `anonymous`:

**Trên cả Windows & Linux:**
```bash
helm repo add kiali https://kiali.org/helm-charts
helm repo update
helm upgrade --install kiali-server kiali/kiali-server \
  --namespace istio-system \
  --set auth.strategy="anonymous" \
  --set server.web_fqdn="" \
  --set external_services.prometheus.url="http://prometheus-server.monitoring:80" \
  --set external_services.grafana.url="http://grafana.monitoring:80"
```

---

## 6. Hướng Dẫn Vận Hành & Kiểm Thử (Operations & Verification Guide)

### 6.1 Lấy Địa Chỉ URL Truy Cập Ứng Dụng (Istio Ingress Gateway)

Do hạ tầng ephemeral thay đổi địa chỉ Load Balancer sau mỗi lần khởi tạo, sử dụng lệnh sau để lấy URL chính xác:

**Trên Windows (PowerShell):**
```powershell
$INGRESS_HOST = (kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
Write-Host "URL Ứng Dụng (Istio Ingress): http://$INGRESS_HOST"
```

**Trên Linux / macOS (Bash):**
```bash
INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "URL Ứng Dụng (Istio Ingress): http://${INGRESS_HOST}"
```

Kiểm tra HTTP status code qua `curl`:
```bash
curl -I http://<INGRESS_HOST>
# Kết quả kỳ vọng: HTTP/1.1 200 OK (hoặc HTTP/2 200) với header server: istio-envoy
```

---

### 6.2 Kiểm Tra Trạng Thái Mã Hóa mTLS STRICT

Sử dụng công cụ `istioctl` để xác minh pod `frontend` đã kích hoạt mTLS STRICT và chịu sự điều phối của các chính sách RBAC:

**Trên Windows (PowerShell):**
```powershell
$FRONTEND_POD = (kubectl get pod -n online-boutique -l app=frontend -o jsonpath='{.items[0].metadata.name}')
istioctl experimental describe pod "$FRONTEND_POD.online-boutique"
```

**Trên Linux / macOS (Bash):**
```bash
FRONTEND_POD=$(kubectl get pod -n online-boutique -l app=frontend -o jsonpath='{.items[0].metadata.name}')
istioctl experimental describe pod "${FRONTEND_POD}.online-boutique"
```

**Kết quả kiểm tra thực tế:**
```text
Pod: frontend-xxxx.online-boutique
   Pod Revision: default
   Pod Ports: 8080 (server), 15090 (istio-proxy)
--------------------
Service: frontend.online-boutique
   Port: http 80/HTTP targets pod port 8080
DestinationRule: default-destination-rule.online-boutique for "*.online-boutique.svc.cluster.local"
   Policies: connection pool/outlier detection
RBAC policies: ns[online-boutique]-policy[allow-frontend]-rule[0], ns[online-boutique]-policy[deny-all]-rule[0]
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied PeerAuthentication:
   default.online-boutique
--------------------
Exposed on Ingress Gateway http://
VirtualService: frontend.online-boutique
   1 HTTP route(s)
```

---

### 6.3 Truy Cập Kiali Dashboard

Kiali Server được cài đặt tại namespace `istio-system` với chế độ xác thực `anonymous` (thuận tiện cho môi trường dev).

Mở dashboard tự động bằng `istioctl`:
```bash
istioctl dashboard kiali
```

Hoặc sử dụng `kubectl port-forward`:
```bash
kubectl port-forward svc/kiali 20001:20001 -n istio-system
```
Sau đó truy cập trình duyệt tại địa chỉ: [http://localhost:20001/kiali](http://localhost:20001/kiali). Tại giao diện Kiali:
- Chọn namespace `online-boutique`.
- Vào mục **Graph** -> Display: chọn **Security** (hiển thị biểu tượng ổ khóa cho mTLS traffic), **Traffic Animation**, **Request Rate**.

---

### 6.4 Kiểm Tra Lưu Lượng Tải & Kết Nối Redis

1. **Kiểm tra `loadgenerator` (0% lỗi):**
   ```bash
   kubectl logs -n online-boutique -l app=loadgenerator -c main --tail=20
   ```
   Kỳ vọng: Toàn bộ các request `GET /`, `POST /cart`, `POST /cart/checkout` đều có tỷ lệ fail là `0(0.00%)`.

2. **Kiểm tra `cartservice` kết nối AWS ElastiCache:**
   ```bash
   kubectl logs -n online-boutique -l app=cartservice -c server --tail=20
   ```
   Kỳ vọng: Các hàm `AddItemAsync`, `GetCartAsync` phản hồi bình thường, không có lỗi timeout kết nối Redis.

