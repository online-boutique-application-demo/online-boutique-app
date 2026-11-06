# 🛠️ Runbook: Xử Lý Sự Cố Hệ Thống (Troubleshooting Guide)

> **Dành cho:** Kỹ sư Vận hành (SRE) / DevOps Engineer phụ trách hệ thống Online Boutique trên AWS EKS.  
> **Phạm vi áp dụng:** Cụm EKS `online-boutique-dev` (v1.36), khu vực `ap-southeast-1`, tài khoản AWS `798836978890`.  
> **Quy chuẩn xử lý:** Mọi sự cố được phân tích theo chu trình chuẩn 5 bước:  
> **Triệu chứng → Nguyên nhân → Lệnh chẩn đoán → Giải pháp → Phòng ngừa**.

---

## 📑 Bảng Tra Cứu Nhanh Sự Cố (Quick Navigation Matrix)

| Danh mục | Tên sự cố | Mức độ | Thời gian mục tiêu (MTTR) |
| :--- | :--- | :---: | :---: |
| **Pod Issues** | [1.1 Pod CrashLoopBackOff](#11-pod-crashloopbackoff) | 🔴 Critical | < 5 phút |
| | [1.2 Pod ImagePullBackOff / ErrImagePull](#12-pod-imagepullbackoff--errimagepull) | 🟠 High | < 5 phút |
| | [1.3 Pod Pending (Không schedule được)](#13-pod-pending-không-thể-schedule) | 🟠 High | < 10 phút |
| **Networking** | [2.1 Lỗi Bắt Tay mTLS (mTLS Handshake Failure)](#21-lỗi-bắt-tay-mtls-mtls-handshake-failures) | 🔴 Critical | < 10 phút |
| | [2.2 Lỗi 403 Forbidden Giữa Các Services](#22-lỗi-403-forbidden-giữa-các-services-authorizationpolicy) | 🔴 Critical | < 5 phút |
| | [2.3 Frontend Không Thể Truy Cập Từ Internet](#23-frontend-không-thể-truy-cập-từ-internet-ingress-nlb) | 🔴 Critical | < 10 phút |
| **CI/CD** | [3.1 Thất Bại Xác Thực AWS OIDC (GitHub Actions)](#31-thất-bại-xác-thực-aws-oidc-github-actions) | 🟠 High | < 15 phút |
| | [3.2 Lỗi Đẩy Image Lên ECR (ECR Push Failure)](#32-lỗi-đẩy-docker-image-lên-ecr) | 🟠 High | < 10 phút |
| | [3.3 ArgoCD Mất Đồng Bộ (Out of Sync / Degraded)](#33-argocd-mất-đồng-bộ-out-of-sync--degraded) | 🟡 Medium | < 10 phút |
| **Monitoring** | [4.1 Prometheus Targets Bị Down](#41-prometheus-targets-bị-down-mất-số-liệu-scrape) | 🟡 Medium | < 10 phút |
| | [4.2 Không Có Traces Trong Grafana Tempo](#42-không-có-traces-trong-grafana-tempo) | 🟡 Medium | < 15 phút |
| | [4.3 Kiali Không Hiển Thị Service Graph](#43-kiali-không-hiển-thị-service-mesh-graph) | 🟡 Medium | < 5 phút |
| **Terraform** | [5.1 Khóa State Terraform (Terraform State Lock)](#51-khóa-state-terraform-state-lock) | 🟠 High | < 5 phút |
| | [5.2 Tài Nguyên Mồ Côi Cản Trở Destroy / Apply](#52-tài-nguyên-mồ-côi-orphaned-resources--dependencyviolation) | 🔴 Critical | < 15 phút |
| | [5.3 CloudWatch Log Groups Bị Kẹt Sau Khi Destroy](#53-cloudwatch-log-groups-bị-kẹt-sau-khi-destroy) | 🟡 Medium | < 5 phút |

### Bảng Đối Chiếu Namespaces Chuẩn Cụm EKS

| Namespace | Mục đích | Sidecar Injection |
| :--- | :--- | :---: |
| `online-boutique` | Chứa 11 microservices ứng dụng chính | `istio-injection=enabled` |
| `istio-system` | Istio Control Plane (`istiod`), Ingress Gateway, Kiali | N/A |
| `monitoring` | Prometheus, Alertmanager, Grafana, Loki, Tempo, OTel Collector | N/A |
| `kyverno` | Policy Engine kiểm soát admission control | N/A |
| `kube-system` | AWS LB Controller, Cluster Autoscaler, CoreDNS, VPC CNI | N/A |
| `argocd` | ArgoCD Server, Application Controller, Repo Server | N/A |

---

## 1. Sự Cố Pod (Pod Issues)

### 1.1 Pod CrashLoopBackOff

#### Triệu chứng:
Pod liên tục chuyển trạng thái giữa `Running` và `CrashLoopBackOff`. Số lượng `RESTARTS` tăng dần. Prometheus kích hoạt cảnh báo `OnlineBoutiquePodCrashLooping`.

#### Nguyên nhân phổ biến:
1. **Thiếu biến môi trường bắt buộc:** Đặc biệt là dịch vụ `frontend` sử dụng Go với hàm `mustMapEnv()` sẽ tự động gọi `panic()` và tắt ngay lập tức nếu thiếu bất kỳ biến môi trường nào (ví dụ: `PRODUCT_CATALOG_SERVICE_ADDR`, `SHOPPING_ASSISTANT_SERVICE_ADDR`).
2. **Container bị OOMKilled (Exit Code 137):** Ứng dụng vượt quá ngưỡng `limits.memory` khai báo trong Deployment.
3. **Lỗi kết nối cơ sở hạ tầng nền tảng:** `cartservice` không thể kết nối tới AWS ElastiCache Redis (port 6379) do sai connection string hoặc Security Group chặn kết nối.
4. **Health Check livenessProbe thất bại:** Endpoint `/healthz` phản hồi chậm hơn `timeoutSeconds` hoặc trả về HTTP status ≥ 400.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Liệt kê các Pod đang bị lỗi trong namespace online-boutique
kubectl get pods -n online-boutique --field-selector=status.phase!=Running

# 2. Kiểm tra Exit Code và trạng thái container lần chạy trước
kubectl describe pod <pod-name> -n online-boutique | grep -A 8 "Last State:"

# 3. Đọc logs của container ứng dụng trước khi bị crash
kubectl logs <pod-name> -n online-boutique -c main --previous --tail=50

# 4. Đọc logs của Envoy sidecar nếu nghi ngờ lỗi mạng nội bộ
kubectl logs <pod-name> -n online-boutique -c istio-proxy --previous --tail=30
```

##### Trên Windows (PowerShell):
```powershell
# 1. Liệt kê các Pod đang bị lỗi trong namespace online-boutique
kubectl get pods -n online-boutique | Where-Object { $_ -notmatch "Running" }

# 2. Kiểm tra Exit Code và trạng thái container lần chạy trước
kubectl describe pod <pod-name> -n online-boutique | Select-String -Pattern "Last State:" -Context 0,8

# 3. Đọc logs của container ứng dụng trước khi bị crash
kubectl logs <pod-name> -n online-boutique -c main --previous --tail=50

# 4. Đọc logs của Envoy sidecar nếu nghi ngờ lỗi mạng nội bộ
kubectl logs <pod-name> -n online-boutique -c istio-proxy --previous --tail=30
```

#### Giải pháp:
- **Nếu Exit Code 137 (OOMKilled):** Tăng memory limit trong manifest kustomize của service đó (ví dụ từ `128Mi` lên `256Mi` hoặc `512Mi`), sau đó commit lên repo `online-boutique-config`.
- **Nếu lỗi `mustMapEnv` (Go panic):** Kiểm tra `base/online-boutique/<service>.yaml`. Đảm bảo các biến môi trường cấu hình địa chỉ gRPC đầy đủ giá trị. Lưu ý `SHOPPING_ASSISTANT_SERVICE_ADDR` phải luôn được khai báo dù service này bị tắt (`ENABLE_ASSISTANT=false`).
- **Nếu lỗi ElastiCache connection (cartservice):** Kiểm tra ConfigMap hoặc Secret chứa endpoint Redis:
  ```bash
  # Lấy connection string từ Terraform output
  cd terraform-aws/environments/dev
  terraform output redis_connection_string
  ```
  Cập nhật lại giá trị vào overlay patch `overlays/dev/patches/cartservice-redis.yaml`.

#### Phòng ngừa:
- Áp dụng Kyverno ClusterPolicy `require-resources` để bắt buộc mọi container đều có request/limit rõ ràng.
- Đặt `initialDelaySeconds` cho Liveness Probe đủ dài để ứng dụng Java/Go kịp khởi động (ví dụ: `initialDelaySeconds: 15`).

---

### 1.2 Pod ImagePullBackOff / ErrImagePull

#### Triệu chứng:
Pod ở trạng thái `ImagePullBackOff` hoặc `ErrImagePull`. Pod không thể khởi tạo container.

#### Nguyên nhân phổ biến:
1. **Tag image không tồn tại trên AWS ECR:** Pipeline CI chưa kịp hoàn tất việc push hoặc commit tag (`sha-<commit>`) bị sai khác giữa code repo và manifest GitOps repo.
2. **Quyền IAM của EKS Node Group bị thiếu:** Worker node không thể authenticate với ECR Private Registry (thiếu quyền `ecr:GetAuthorizationToken` hoặc `ecr:BatchGetImage`).
3. **Khai báo sai URI của ECR Repository:** Sai AWS Account ID (`798836978890`), sai region (`ap-southeast-1`), hoặc sai tên repository microservice.
4. **Kyverno chặn do vi phạm chữ ký Cosign:** Image chưa được ký hoặc chứng chỉ chữ ký không khớp với Root CA Sigstore/Fulcio.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Xem chi tiết lỗi ImagePull từ Kubernetes Events
kubectl describe pod <pod-name> -n online-boutique | grep -A 5 "Events:"

# 2. Lấy chính xác Image URI mà Pod đang cố tải về
kubectl get pod <pod-name> -n online-boutique -o jsonpath='{.spec.containers[*].image}'

# 3. Kiểm tra xem image tag có thực sự tồn tại trên AWS ECR không
aws ecr describe-images \
  --repository-name online-boutique/<service-name> \
  --region ap-southeast-1 \
  --query 'imageDetails[*].imageTags' \
  --output table

# 4. Kiểm tra PolicyReport của Kyverno xem có bị chặn bởi verify-image-signature không
kubectl get policyreport -n online-boutique
```

##### Trên Windows (PowerShell):
```powershell
# 1. Xem chi tiết lỗi ImagePull từ Kubernetes Events
kubectl describe pod <pod-name> -n online-boutique | Select-String -Pattern "Events:" -Context 0,5

# 2. Lấy chính xác Image URI mà Pod đang cố tải về
kubectl get pod <pod-name> -n online-boutique -o jsonpath='{.spec.containers[*].image}'

# 3. Kiểm tra xem image tag có thực sự tồn tại trên AWS ECR không
aws ecr describe-images `
  --repository-name online-boutique/<service-name> `
  --region ap-southeast-1 `
  --query 'imageDetails[*].imageTags' `
  --output table

# 4. Kiểm tra PolicyReport của Kyverno xem có bị chặn bởi verify-image-signature không
kubectl get policyreport -n online-boutique
```

#### Giải pháp:
- **Nếu tag chưa tồn tại trên ECR:** Kiểm tra tab Actions trên GitHub repository `online-boutique-app`. Chạy lại workflow `ci-main.yml` hoặc `ci-service.yml` tương ứng với service bị lỗi.
- **Nếu tag bị gõ nhầm:** Sửa trường `newTag` trong `online-boutique-config/overlays/dev/kustomization.yaml` khớp với SHA trên ECR:
  ```yaml
  images:
    - name: 798836978890.dkr.ecr.ap-southeast-1.amazonaws.com/online-boutique/frontend
      newTag: sha-a1b2c3d
  ```
- **Nếu lỗi xác thực IAM:** Kiểm tra role đính kèm vào EKS Node Group (`online-boutique-dev-eks-nodes-role`). Đảm bảo policy `AmazonEC2ContainerRegistryReadOnly` được attach.

#### Phòng ngừa:
- Quy trình CI tự động sử dụng composite action `update-manifests` commit trực tiếp image tag vừa build vào repository config, tránh chỉnh sửa thủ công.
- Áp dụng Kyverno policy `disallow-latest-tag` để ngăn chặn việc sử dụng tag `:latest`.

---

### 1.3 Pod Pending (Không Thể Schedule)

#### Triệu chứng:
Pod giữ trạng thái `Pending` trong thời gian dài (> 2 phút). Không có container nào được khởi chạy trên Node.

#### Nguyên nhân phổ biến:
1. **Cạn kiệt tài nguyên tính toán (CPU/Memory) trên Node:** Cụm khởi tạo ở mức tối thiểu 2–3 nodes `t3.medium`. Tổng yêu cầu tài nguyên (Requests) của 11 microservices + 11 Envoy proxies + Monitoring Stack vượt quá dung lượng Allocatable của các Node hiện có.
2. **Cluster Autoscaler chưa sẵn sàng hoặc bị nghẽn:** Deployment `cluster-autoscaler` trong `kube-system` gặp lỗi quyền IRSA hoặc chưa scale kịp thời.
3. **PersistentVolumeClaim (PVC) chưa được bind:** Các dịch vụ giám sát có lưu trữ (Prometheus, Loki, Tempo) không thể mount volume do lỗi AWS EBS CSI driver hoặc cạn dung lượng trong Availability Zone.
4. **Taints & Tolerations không tương thích:** Node đang chịu taint thu hồi của Spot Instance (`aws-node-termination-handler/spot-itn`).

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra lý do Pod chưa được Schedule từ Events
kubectl describe pod <pod-name> -n online-boutique | grep -A 6 "Events:"

# 2. Kiểm tra mức độ tiêu thụ tài nguyên của các Node hiện tại
kubectl top nodes

# 3. Kiểm tra chi tiết dung lượng CPU/Memory đã cam kết (Requests/Limits) trên từng node
kubectl describe nodes | grep -A 7 "Allocated resources:"

# 4. Đọc logs của Cluster Autoscaler để xem lý do không thể tăng Node
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50 | grep -i "scale"

# 5. Kiểm tra trạng thái PVC nếu pod thuộc namespace monitoring
kubectl get pvc -n monitoring
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra lý do Pod chưa được Schedule từ Events
kubectl describe pod <pod-name> -n online-boutique | Select-String -Pattern "Events:" -Context 0,6

# 2. Kiểm tra mức độ tiêu thụ tài nguyên của các Node hiện tại
kubectl top nodes

# 3. Kiểm tra chi tiết dung lượng CPU/Memory đã cam kết (Requests/Limits) trên từng node
kubectl describe nodes | Select-String -Pattern "Allocated resources:" -Context 0,7

# 4. Đọc logs của Cluster Autoscaler để xem lý do không thể tăng Node
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50 | Select-String -Pattern "scale"

# 5. Kiểm tra trạng thái PVC nếu pod thuộc namespace monitoring
kubectl get pvc -n monitoring
```

#### Giải pháp:
- **Nếu thiếu CPU/Memory do Cluster Autoscaler chưa kích hoạt:** Chờ Cluster Autoscaler thực hiện mở rộng tự động (thường mất 2–3 phút để một node EC2 Spot mới join cụm).
- **Nếu Cluster Autoscaler chạm trần node tối đa (5 nodes):** Thay đổi `node_max_size` trong Terraform (xem [Runbook Scaling](scaling.md)).
- **Nếu đang thực hiện Bootstrap buổi sáng:** Luôn tuân thủ quy tắc triển khai theo thứ tự phân kỳ: Đợi 11 microservices sẵn sàng trước khi nạp stack Monitoring để tránh nghẽn CPU tức thời.

#### Phòng ngừa:
- Thiết lập resource `requests` phản ánh đúng mức tiêu thụ thực tế của môi trường Dev (không đặt request quá lớn so với dung lượng `t3.medium`).
- Bắt buộc Cluster Autoscaler phải luôn ở trạng thái sẵn sàng trước khi deploy bất kỳ ứng dụng nào.

---

## 2. Sự Cố Mạng & Service Mesh (Networking & Istio Issues)

### 2.1 Lỗi Bắt Tay mTLS (mTLS Handshake Failures)

#### Triệu chứng:
Các cuộc gọi gRPC hoặc HTTP giữa các microservices thất bại với lỗi:
`upstream connect error or disconnect/reset before headers. reset reason: connection termination` hoặc trong log của Envoy sidecar xuất hiện `TLS_error:2048` / `PEER_CERTIFICATE_VERIFICATION_FAILED`.

#### Nguyên nhân phổ biến:
1. **Namespace `online-boutique` áp dụng `PeerAuthentication` chế độ `STRICT`:** Nhưng pod gọi hoặc pod nhận bị thiếu Envoy sidecar (`istio-proxy`), dẫn đến việc truyền tải bằng văn bản thuần (plaintext) bị từ chối ngay ở tầng transport.
2. **Desync chứng chỉ mTLS nội bộ:** Control plane `istiod` chưa đồng bộ kịp chứng chỉ bảo mật x509 mới xuống Envoy proxy của Pod vừa tạo.
3. **Các port telemetry hoặc healthcheck bị ép mTLS:** Prometheus hoặc ứng dụng bên ngoài mesh kết nối trực tiếp vào các cổng nội bộ mà không có chứng chỉ do Mesh CA cấp.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Chạy công cụ phân tích cấu hình tự động của Istio
istioctl analyze -n online-boutique

# 2. Kiểm tra trạng thái đồng bộ cấu hình giữa istiod và các proxies
istioctl proxy-status

# 3. Kiểm tra xem tất cả các Pod trong namespace online-boutique đã được tiêm sidecar chưa (cột READY phải là 2/2)
kubectl get pods -n online-boutique

# 4. Kiểm tra chính sách PeerAuthentication đang hiệu lực
kubectl get peerauthentication -A

# 5. Kiểm tra xác thực TLS giữa 2 workload cụ thể (ví dụ frontend và cartservice)
istioctl authn tls-check $(kubectl get pod -l app=frontend -n online-boutique -o jsonpath='{.items[0].metadata.name}') cartservice.online-boutique.svc.cluster.local
```

##### Trên Windows (PowerShell):
```powershell
# 1. Chạy công cụ phân tích cấu hình tự động của Istio
istioctl analyze -n online-boutique

# 2. Kiểm tra trạng thái đồng bộ cấu hình giữa istiod và các proxies
istioctl proxy-status

# 3. Kiểm tra xem tất cả các Pod trong namespace online-boutique đã được tiêm sidecar chưa (cột READY phải là 2/2)
kubectl get pods -n online-boutique

# 4. Kiểm tra chính sách PeerAuthentication đang hiệu lực
kubectl get peerauthentication -A

# 5. Kiểm tra xác thực TLS giữa 2 workload cụ thể
$FRONTEND_POD = (kubectl get pod -l app=frontend -n online-boutique -o jsonpath='{.items[0].metadata.name}')
istioctl authn tls-check $FRONTEND_POD cartservice.online-boutique.svc.cluster.local
```

#### Giải pháp:
- **Nếu Pod thiếu Envoy sidecar (READY 1/1):** Kiểm tra nhãn của namespace:
  ```bash
  kubectl label namespace online-boutique istio-injection=enabled --overwrite
  kubectl rollout restart deployment -n online-boutique
  ```
- **Nếu `istiod` bị treo đồng bộ chứng chỉ:**
  ```bash
  kubectl rollout restart deployment/istiod -n istio-system
  ```

#### Phòng ngừa:
- Đảm bảo kịch bản khởi tạo cụm luôn kiểm tra nhãn `istio-injection=enabled` trên namespace `online-boutique`.
- Sử dụng `DestinationRule` cấu hình `trafficPolicy.tls.mode: ISTIO_MUTUAL` đồng nhất trên toàn bộ mesh.

---

### 2.2 Lỗi 403 Forbidden Giữa Các Services (AuthorizationPolicy)

#### Triệu chứng:
Một microservice không thể gọi dịch vụ phụ thuộc. Client nhận mã lỗi gRPC `PERMISSION_DENIED` hoặc mã HTTP `403 Forbidden`. Trong access log của Envoy proxy xuất hiện cờ `UAEX` (Unauthorized Access Executed).

#### Nguyên nhân phổ biến:
1. **Chính sách Deny-All mặc định:** Hệ thống triển khai `default-deny-all` tại namespace `online-boutique`. Bất kỳ luồng giao tiếp mới nào không nằm trong danh sách 10 quy tắc ALLOW sẽ bị chặn hoàn toàn.
2. **Sai lệch SPIFFE Principal:** Tên ServiceAccount của workload nguồn không khớp với định danh SPIFFE được cấp quyền:
   `cluster.local/ns/online-boutique/sa/<serviceaccount-name>`.
3. **Workload chạy với ServiceAccount mặc định (`default`):** Manifest Deployment quên gán trường `serviceAccountName`.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Liệt kê toàn bộ AuthorizationPolicy trong namespace online-boutique
kubectl get authorizationpolicy -n online-boutique

# 2. Kiểm tra access log của Service đích để tìm chi tiết request bị từ chối
kubectl logs -n online-boutique -l app=cartservice -c istio-proxy --tail=50 | grep " 403 "

# 3. Kiểm tra ServiceAccount thực tế mà Pod nguồn đang sử dụng
kubectl get pod -n online-boutique -l app=frontend -o jsonpath='{.items[0].spec.serviceAccountName}'

# 4. Kiểm tra định danh SPIFFE từ chứng chỉ mTLS đang chạy trên Pod nguồn
istioctl proxy-config secret $(kubectl get pod -l app=frontend -n online-boutique -o jsonpath='{.items[0].metadata.name}') -n online-boutique -o json | jq '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' -r | base64 -d | openssl x509 -noout -text | grep "URI:spiffe"
```

##### Trên Windows (PowerShell):
```powershell
# 1. Liệt kê toàn bộ AuthorizationPolicy trong namespace online-boutique
kubectl get authorizationpolicy -n online-boutique

# 2. Kiểm tra access log của Service đích để tìm chi tiết request bị từ chối
kubectl logs -n online-boutique -l app=cartservice -c istio-proxy --tail=50 | Select-String " 403 "

# 3. Kiểm tra ServiceAccount thực tế mà Pod nguồn đang sử dụng
kubectl get pod -n online-boutique -l app=frontend -o jsonpath='{.items[0].spec.serviceAccountName}'
```

#### Giải pháp:
- Đối chiếu với Ma Trận Phụ Thuộc (Dependency Matrix):
  - `frontend` → `cartservice`, `productcatalogservice`, `currencyservice`, `shippingservice`, `checkoutservice`, `recommendationservice`, `adservice`.
  - `checkoutservice` → `cartservice`, `productcatalogservice`, `currencyservice`, `paymentservice`, `shippingservice`, `emailservice`.
  - `recommendationservice` → `productcatalogservice`.
- Mở tệp `base/istio/authorization-policies.yaml` trong repo `online-boutique-config`, bổ sung ServiceAccount còn thiếu vào quy tắc ALLOW:
  ```yaml
  apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    name: allow-frontend-to-cart
    namespace: online-boutique
  spec:
    selector:
      matchLabels:
        app: cartservice
    action: ALLOW
    rules:
      - from:
          - source:
              principals: ["cluster.local/ns/online-boutique/sa/frontend"]
  ```
- Commit và đồng bộ lại qua ArgoCD.

#### Phòng ngừa:
- Khi phát triển microservice mới, luôn đồng thời cập nhật ServiceAccount tương ứng và khai báo AuthorizationPolicy trước khi deploy code.

---

### 2.3 Frontend Không Thể Truy Cập Từ Internet (Ingress / NLB)

#### Triệu chứng:
Không thể mở trang thương mại điện tử qua trình duyệt. Lỗi `ERR_CONNECTION_TIMED_OUT`, `502 Bad Gateway`, hoặc `Could not resolve host`.

#### Nguyên nhân phổ biến:
1. **AWS Network Load Balancer (NLB) chưa sẵn sàng:** Cần từ 2–3 phút sau khi tạo để AWS cấp phát IP và cấu hình DNS.
2. **AWS Load Balancer Controller chưa hoạt động:** Pod controller trong `kube-system` bị crash hoặc thiếu quyền IAM (IRSA) để tương tác với AWS ELB API.
3. **Thiếu Annotation Public:** Service `istio-ingressgateway` thiếu annotation:
   `service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"`.
4. **Target Group Health Check thất bại:** Istio Ingress Gateway pod bị lỗi hoặc cổng `15021` (health check port của Istio) không phản hồi.
5. **Thiếu Istio Gateway hoặc VirtualService:** Chưa ánh xạ host và route traffic cổng 80 vào Service ClusterIP của `frontend`.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra trạng thái External IP của Istio Ingress Gateway
kubectl get svc istio-ingressgateway -n istio-system

# 2. Kiểm tra logs của AWS Load Balancer Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# 3. Kiểm tra Gateway và VirtualService đã được áp dụng chưa
kubectl get gateway,virtualservice -n online-boutique

# 4. Kiểm tra sức khỏe của Target Group trên AWS qua AWS CLI
TG_ARN=$(aws elbv2 describe-target-groups --region ap-southeast-1 --query "TargetGroups[?contains(TargetGroupName, 'istio')].TargetGroupArn" --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region ap-southeast-1

# 5. Kiểm tra kết nối trực tiếp vào Ingress Gateway pod từ bên trong cụm
kubectl exec -n istio-system deployment/istio-ingressgateway -- curl -s -I http://localhost:8080/
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra trạng thái External IP của Istio Ingress Gateway
kubectl get svc istio-ingressgateway -n istio-system

# 2. Kiểm tra logs của AWS Load Balancer Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# 3. Kiểm tra Gateway và VirtualService đã được áp dụng chưa
kubectl get gateway,virtualservice -n online-boutique

# 4. Kiểm tra sức khỏe của Target Group trên AWS qua AWS CLI
$TG_ARN = (aws elbv2 describe-target-groups --region ap-southeast-1 --query "TargetGroups[?contains(TargetGroupName, 'istio')].TargetGroupArn" --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region ap-southeast-1

# 5. Thử kiểm tra curl tới DNS của Ingress Gateway
$NLB_DNS = (kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl.exe -Iv "http://$NLB_DNS/"
```

#### Giải pháp:
- **Nếu thiếu External IP / Controller không nhận diện:**
  ```bash
  kubectl annotate svc istio-ingressgateway -n istio-system service.beta.kubernetes.io/aws-load-balancer-scheme="internet-facing" --overwrite
  ```
- **Nếu thiếu VirtualService:** Áp dụng lại manifest từ repo config:
  ```bash
  kubectl apply -f base/istio/gateway.yaml
  kubectl apply -f base/istio/virtual-service.yaml
  ```
- **Nếu Target Group Unhealthy:** Kiểm tra security group của EKS nodes xem cổng `15021` (health check) và cổng `80/8080` có bị chặn bởi firewall không.

#### Phòng ngừa:
- Đảm bảo các Subnet công cộng (Public Subnets) của VPC luôn có tag bắt buộc cho Kubernetes Ingress: `kubernetes.io/role/elb = 1`.

---

## 3. Sự Cố CI/CD (GitHub Actions & ArgoCD Issues)

### 3.1 Thất Bại Xác Thực AWS OIDC (GitHub Actions)

#### Triệu chứng:
GitHub Actions workflow (`ci-main.yml` hoặc `terraform-apply.yml`) thất bại ngay tại bước "Configure AWS Credentials" với lỗi:
`OpenIDConnect provider's HTTPS certificate doesn't match` hoặc `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

#### Nguyên nhân phổ biến:
1. **Lỗi định dạng Subject Claim (`sub`) bất biến (GitHub Immutable ID update mid-2026):**  
   Trước giữa năm 2026, GitHub OIDC gửi subject theo định dạng cổ điển:  
   `repo:ORG/REPO:ref:refs/heads/main`.  
   Từ giữa năm 2026, GitHub bổ sung thêm các trường ID bất biến dẫn đến subject claim có thể mang định dạng:  
   `repo:ORG@ID/REPO@ID:ref:refs/heads/main`.  
   Nếu IAM Role Trust Policy dùng `StringEquals` so khớp cứng chuỗi cũ, toàn bộ xác thực sẽ bị AWS STS từ chối ngay lập tức.
2. **Khai báo sai GitHub Organization hoặc Repository:** Biến `github_repo_app` hoặc tên repository trong trust policy bị sai lệch ký tự.
3. **Workflow chạy trên nhánh không được cấp quyền:** Trust policy chỉ cho phép nhánh `main` hoặc `ref:refs/heads/*`, nhưng PR chạy từ nhánh fork hoặc branch chưa khai báo.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra cấu hình Trust Policy của IAM Role CI
aws iam get-role --role-name online-boutique-github-ci --query 'Role.AssumeRolePolicyDocument' --output json

# 2. Kiểm tra sự tồn tại của OIDC Provider trên tài khoản AWS
aws iam list-open-id-connect-providers

# 3. Xem chi tiết thông số OpenID Connect Provider
aws iam get-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::798836978890:oidc-provider/token.actions.githubusercontent.com
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra cấu hình Trust Policy của IAM Role CI
aws iam get-role --role-name online-boutique-github-ci --query 'Role.AssumeRolePolicyDocument' --output json

# 2. Kiểm tra sự tồn tại của OIDC Provider trên tài khoản AWS
aws iam list-open-id-connect-providers

# 3. Xem chi tiết thông số OpenID Connect Provider
aws iam get-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::798836978890:oidc-provider/token.actions.githubusercontent.com
```

#### Giải pháp:
Khắc phục triệt để bằng cách cấu hình **`StringLike` kèm ký tự đại diện (wildcard `*`)** trong tệp Terraform `terraform-aws/global/github-oidc/main.tf`:

```hcl
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
  }
  StringLike = {
    # Hỗ trợ cả định dạng truyền thống và định dạng Immutable ID (mid-2026+)
    "token.actions.githubusercontent.com:sub" = "repo:*${var.github_repo_app}*"
  }
}
```

Áp dụng lại cấu hình Terraform:
```bash
cd terraform-aws/global/github-oidc
terraform init
terraform apply -auto-approve
```

#### Phòng ngừa:
- Luôn sử dụng biểu thức `StringLike` với wildcard cho claim `sub` đối với mọi OIDC IAM role tích hợp với GitHub Actions.
- Không sử dụng Access Key tĩnh dài hạn cho quy trình tự động hóa CI/CD.

---

### 3.2 Lỗi Đẩy Docker Image Lên ECR

#### Triệu chứng:
Bước `Push to ECR` trong GitHub Actions bị lỗi:
`no basic auth credentials`, `name unknown: The repository with name '...' does not exist`, hoặc `denied: Your authorization token has expired`.

#### Nguyên nhân phổ biến:
1. **Thiếu Repository trên AWS ECR:** Microservice mới chưa được định nghĩa trong Terraform module `global/ecr`.
2. **Quyền IAM bị thiếu trong Policy:** Role `online-boutique-github-ci` thiếu các quyền thực thi đẩy image: `ecr:PutImage`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`.
3. **Session Token hết hạn:** Phiên đăng nhập ECR vượt quá thời gian cho phép khi quy trình build ma trận kéo dài.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra danh sách 11 ECR repositories hiện có
aws ecr describe-repositories --region ap-southeast-1 --query 'repositories[*].repositoryName' --output table

# 2. Thử nghiệm đăng nhập ECR thủ công bằng CLI
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 798836978890.dkr.ecr.ap-southeast-1.amazonaws.com

# 3. Kiểm tra quyền IAM đính kèm vào role CI
aws iam get-policy-version --policy-arn arn:aws:iam::798836978890:policy/online-boutique-github-ci --version-id v1
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra danh sách 11 ECR repositories hiện có
aws ecr describe-repositories --region ap-southeast-1 --query 'repositories[*].repositoryName' --output table

# 2. Thử nghiệm đăng nhập ECR thủ công bằng CLI
(aws ecr get-login-password --region ap-southeast-1) | docker login --username AWS --password-stdin 798836978890.dkr.ecr.ap-southeast-1.amazonaws.com

# 3. Kiểm tra quyền IAM đính kèm vào role CI
aws iam get-policy-version --policy-arn arn:aws:iam::798836978890:policy/online-boutique-github-ci --version-id v1
```

#### Giải pháp:
- Nếu thiếu repository, di chuyển vào `terraform-aws/global/ecr`, cập nhật danh sách repository và chạy `terraform apply`.
- Đảm bảo workflow GitHub Actions luôn gọi action `aws-actions/amazon-ecr-login@v2` ngay trước bước `docker push`.

#### Phòng ngừa:
- Đảm bảo toàn bộ 11 repositories được quản lý tập trung và khai báo đầy đủ bằng Terraform trong `global/ecr`.

---

### 3.3 ArgoCD Mất Đồng Bộ (Out of Sync / Degraded)

#### Triệu chứng:
Ứng dụng trên ArgoCD Dashboard (`online-boutique-dev`) hiển thị trạng thái `OutOfSync` màu vàng hoặc `Degraded` màu đỏ. Không thể tự động đồng bộ (auto-sync).

#### Nguyên nhân phổ biến:
1. **Xung đột cấu hình (GitOps Drift):** Tài nguyên trên cụm bị chỉnh sửa trực tiếp bằng `kubectl` (ví dụ scale replicas hoặc sửa env).
2. **Kustomize build thất bại:** Tệp `kustomization.yaml` trong repo `online-boutique-config` tham chiếu sai đường dẫn tệp patch hoặc sai cú pháp YAML.
3. **Webhook Admission Controller (Kyverno) từ chối áp dụng:** Tài nguyên vi phạm ClusterPolicy bắt buộc (chế độ Enforce).
4. **Token truy cập Git repository hết hạn:** ArgoCD không thể kéo commit mới nhất từ repository cấu hình.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra tổng quan trạng thái Application trên ArgoCD CLI
argocd app get online-boutique-dev

# 2. Xem điểm sai khác cụ thể giữa Git và Cluster (Drift)
argocd app diff online-boutique-dev

# 3. Đọc logs của ArgoCD Application Controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50

# 4. Kiểm tra xem tệp Kustomize có build được ở local không
kubectl kustomize <path-to-online-boutique-config>/overlays/dev
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra tổng quan trạng thái Application trên ArgoCD CLI
argocd app get online-boutique-dev

# 2. Xem điểm sai khác cụ thể giữa Git và Cluster (Drift)
argocd app diff online-boutique-dev

# 3. Đọc logs của ArgoCD Application Controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50

# 4. Kiểm tra xem tệp Kustomize có build được ở local không
kubectl kustomize <path-to-online-boutique-config>\overlays\dev
```

#### Giải pháp:
- **Nếu lỗi do Drift:** Bấm **Sync** trên ArgoCD UI hoặc chạy:
  ```bash
  argocd app sync online-boutique-dev --prune
  ```
- **Nếu lỗi do Kustomize build:** Sửa lỗi cú pháp trong `overlays/dev/kustomization.yaml`, commit và push lại lên repo config.
- **Nếu xung đột với trường do hệ thống tự sinh (như HPA replicas):** Thêm khối `ignoreDifferences` vào Application manifest của ArgoCD:
  ```yaml
  spec:
    ignoreDifferences:
      - group: apps
        kind: Deployment
        jsonPointers:
          - /spec/replicas
  ```

#### Phòng ngừa:
- Luôn kiểm tra tính hợp lệ bằng lệnh `kubectl kustomize <path>` trước khi commit lên nhánh `main`.
- Tuyệt đối tuân thủ nguyên tắc GitOps: Không sửa trực tiếp tài nguyên trên cụm bằng `kubectl edit` hay `kubectl apply`.

---

## 4. Sự Cố Giám Sát (Monitoring & Observability Issues)

### 4.1 Prometheus Targets Bị Down (Mất Số Liệu Scrape)

#### Triệu chứng:
Trên giao diện Prometheus Web UI (`/targets`), các mục tiêu thuộc job `envoy-stats` hoặc `kubernetes-pods` hiển thị trạng thái `DOWN` màu đỏ. Grafana không vẽ được các panel Golden Signals.

#### Nguyên nhân phổ biến:
1. **Sidecar proxy chưa mở cổng 15090:** Port mặc định để Prometheus thu thập metrics từ Envoy Proxy.
2. **Sai lệch Label trên ServiceMonitor / PodMonitor:** Prometheus Operator yêu cầu các Custom Resource phải có label khớp với `serviceMonitorSelector` của Helm release (thường là `release: kube-prometheus-stack`).
3. **Mạng nội bộ bị cản trở bởi mTLS STRICT:** Prometheus nằm ngoài mesh (namespace `monitoring`) cố kết nối tới Pod trong mesh mà không thông qua cơ chế bypass port.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Mở cổng giao diện Prometheus để quan sát trực tiếp
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &

# 2. Gọi API Prometheus kiểm tra danh sách các target đang bị lỗi
curl -s "http://localhost:9090/api/v1/targets" | jq '.data.activeTargets[] | select(.health=="down") | {job: .labels.job, pod: .labels.pod, lastError: .lastError}'

# 3. Kiểm tra pod mục tiêu có đang mở cổng 15090 để xuất metric không
kubectl exec -n online-boutique $(kubectl get pod -l app=frontend -n online-boutique -o jsonpath='{.items[0].metadata.name}') -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | head -n 10
```

##### Trên Windows (PowerShell):
```powershell
# 1. Mở cổng giao diện Prometheus (chạy trên terminal riêng)
kubectl port-forward -n monitoring svc/prometheus-server 9090:80

# 2. Kiểm tra target bị lỗi qua curl nội bộ từ cụm
kubectl run test-prom-targets --image=curlimages/curl --restart=Never --rm -i -- -s "http://prometheus-server.monitoring:80/api/v1/targets" 2>$null | Select-String "down"

# 3. Kiểm tra pod mục tiêu có đang mở cổng 15090 để xuất metric không
$FRONTEND_POD = (kubectl get pod -l app=frontend -n online-boutique -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n online-boutique $FRONTEND_POD -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | Select-Object -First 10
```

#### Giải pháp:
- Kiểm tra cấu hình `additionalScrapeConfigs` trong file values `base/monitoring/prometheus-stack-values.yaml`: Đảm bảo regex cổng `15090` hoạt động chính xác cho cả 2 namespace `online-boutique` và `istio-system`.
- Port 15090 trong Istio mặc định được cấu hình bypass mTLS để Prometheus cào số liệu dạng plaintext; đảm bảo không có quy tắc `PeerAuthentication` nào đè lên port này.

#### Phòng ngừa:
- Đồng bộ hóa các nhãn ServiceMonitor qua GitOps Kustomize trong `base/monitoring`.

---

### 4.2 Không Có Traces Trong Grafana Tempo

#### Triệu chứng:
Trong Grafana Explore, khi chọn data source **Tempo** và tìm kiếm traces của các microservices, hệ thống trả về kết quả rỗng (`inspectedTraces: 0`).

#### Nguyên nhân phổ biến:
1. **Lỗi chặn mTLS từ Mesh sang Telemetry Ports (Nguyên nhân trọng yếu):**  
   Envoy sidecars trong namespace `online-boutique` (áp dụng mTLS STRICT) cố gắng gửi trace spans qua cổng Zipkin (:9411) hoặc OTLP (:4317) sang OpenTelemetry Collector đặt tại namespace `monitoring` (nằm ngoài mesh). Envoy tự động áp dụng mã hóa mTLS, nhưng OTel Collector không có sidecar để giải mã, dẫn đến kết nối bị đóng ngắt.
2. **Tỷ lệ lấy mẫu (Sampling Rate) cấu hình bằng 0:** Tài nguyên `Telemetry` của Istio chưa được áp dụng hoặc cấu hình tỷ lệ dưới 100%.
3. **OpenTelemetry Collector pod bị treo hoặc crash:** OTel pipeline gặp sự cố không thể chuyển tiếp trace sang Tempo.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra DestinationRule cấu hình ngoại lệ mTLS cho OTel Collector
kubectl get destinationrule -n istio-system | grep -i "disable-mtls"

# 2. Đọc logs của OpenTelemetry Collector để kiểm tra việc tiếp nhận traces
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=50

# 3. Đọc logs của Tempo xem có nhận được spans từ OTel Collector không
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo --tail=30

# 4. Kiểm tra cấu hình Telemetry CRD của Istio
kubectl get telemetry -n istio-system -o yaml
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra DestinationRule cấu hình ngoại lệ mTLS cho OTel Collector
kubectl get destinationrule -n istio-system | Select-String "disable-mtls"

# 2. Đọc logs của OpenTelemetry Collector để kiểm tra việc tiếp nhận traces
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=50

# 3. Đọc logs của Tempo xem có nhận được spans từ OTel Collector không
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo --tail=30

# 4. Kiểm tra cấu hình Telemetry CRD của Istio
kubectl get telemetry -n istio-system -o yaml
```

#### Giải pháp:
Bắt buộc phải có **DestinationRule vô hiệu hóa mTLS (`mode: DISABLE`)** cho các cổng telemetry khi giao tiếp xuyên namespace sang `monitoring`.

Kiểm tra tệp `base/istio/otel-collector-destination-rule.yaml` và đảm bảo đã apply:
```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: otel-collector-disable-mtls
  namespace: istio-system
spec:
  host: otel-collector.monitoring.svc.cluster.local
  exportTo:
    - "*"
  trafficPolicy:
    tls:
      mode: DISABLE
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: tempo-disable-mtls
  namespace: istio-system
spec:
  host: tempo.monitoring.svc.cluster.local
  exportTo:
    - "*"
  trafficPolicy:
    tls:
      mode: DISABLE
```

Áp dụng lại manifest:
```bash
kubectl apply -f <path-to-online-boutique-config>/base/istio/otel-collector-destination-rule.yaml
```

Đồng thời đảm bảo tài nguyên `Telemetry` cấu hình `randomSamplingPercentage: 100.00`:
```bash
kubectl apply -f <path-to-online-boutique-config>/base/istio/telemetry.yaml
```

#### Phòng ngừa:
- Mọi dịch vụ hạ tầng đặt ngoài mesh nhận traffic trực tiếp từ Envoy sidecars phải luôn đi kèm DestinationRule `tls.mode = DISABLE`.

---

### 4.3 Kiali Không Hiển Thị Service Mesh Graph

#### Triệu chứng:
Mở giao diện Kiali (`:20001/kiali`) và chọn namespace `online-boutique`, biểu đồ topology hiển thị "Empty Graph" hoặc góc trên bên phải báo lỗi: "Cannot fetch traffic metrics from Prometheus".

#### Nguyên nhân phổ biến:
1. **Thiếu Service Alias cho Prometheus:** Kiali mặc định được cấu hình trỏ vào endpoint `http://prometheus-server.monitoring:80`, trong khi Helm chart `kube-prometheus-stack` tạo service có tên dài `prometheus-kube-prometheus-stack-prometheus:9090`. Nếu thiếu Service alias `prometheus-server`, Kiali không thể truy vấn được Prometheus TSDB.
2. **Không có lưu lượng (Traffic) thực tế trong Mesh:** Cụm vừa khởi động lại hoặc pod `loadgenerator` đang dừng, dẫn đến không có metric `istio_requests_total` sinh ra trong 10 phút gần nhất.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Kiểm tra sự tồn tại của Service Alias prometheus-server trong namespace monitoring
kubectl get svc prometheus-server -n monitoring

# 2. Đọc logs của Kiali để xác nhận trạng thái kết nối Prometheus
kubectl logs -n istio-system deployment/kiali --tail=30 | grep -i "prometheus"

# 3. Kiểm tra pod loadgenerator có đang tạo lưu lượng HTTP không
kubectl get pods -n online-boutique -l app=loadgenerator
```

##### Trên Windows (PowerShell):
```powershell
# 1. Kiểm tra sự tồn tại của Service Alias prometheus-server trong namespace monitoring
kubectl get svc prometheus-server -n monitoring

# 2. Đọc logs của Kiali để xác nhận trạng thái kết nối Prometheus
kubectl logs -n istio-system deployment/kiali --tail=30 | Select-String "prometheus"

# 3. Kiểm tra pod loadgenerator có đang tạo lưu lượng HTTP không
kubectl get pods -n online-boutique -l app=loadgenerator
```

#### Giải pháp:
- **Nếu thiếu Service alias:** Áp dụng tệp `base/monitoring/prometheus-service.yaml` để tạo alias chuyển tiếp cổng 80 vào cổng 9090 của Prometheus pod:
  ```bash
  kubectl apply -f <path-to-online-boutique-config>/base/monitoring/prometheus-service.yaml
  ```
- **Nếu thiếu lưu lượng:** Kiểm tra và khởi động lại `loadgenerator`:
  ```bash
  kubectl scale deploy loadgenerator -n online-boutique --replicas=1
  ```
  Chờ khoảng 1–2 phút để Prometheus scrape đủ số liệu và refresh lại trang Kiali.

#### Phòng ngừa:
- Đưa Service alias `prometheus-server` vào Kustomize base của stack monitoring để ArgoCD tự động tạo mỗi khi dựng cụm.

---

## 5. Sự Cố Terraform (State & AWS Infrastructure Issues)

### 5.1 Khóa State Terraform (State Lock)

#### Triệu chứng:
Khi chạy `terraform plan` hoặc `terraform apply`, quá trình bị dừng với thông báo lỗi:
`Error: Error acquiring the state lock: ConditionalCheckFailedException...`  
Kèm thông tin `Lock Info: ID: <lock-id>, Path: ..., Who: ..., Created: ...`.

#### Nguyên nhân phổ biến:
1. **Tiến trình Terraform trước đó bị tắt cưỡng bức:** Developer đóng terminal đột ngột hoặc GitHub Actions workflow bị hủy ngang khi Terraform đang ghi dữ liệu vào S3 backend.
2. **Cơ chế native S3 lock (`use_lockfile = true`) chưa giải phóng:** File `.tflock` vẫn còn tồn tại trên S3 bucket `online-boutique-tfstate-798836978890`.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash) & Windows (PowerShell):
Đọc kỹ thông báo lỗi của Terraform để trích xuất chuỗi `Lock ID`. Ví dụ:
`ID: b9a7c6f0-1234-5678-90ab-cdef12345678`

Xác minh trên GitHub Actions hoặc hỏi thành viên trong đội ngũ để đảm bảo **không có ai khác** đang thực sự chạy `terraform apply`.

#### Giải pháp:

##### Trên Linux / macOS (Bash) & Windows (PowerShell):
Chạy lệnh giải phóng khóa cưỡng chế với ID thu thập được:
```bash
terraform force-unlock <lock-id>
```
Khi được hỏi xác nhận (`Do you really want to force-unlock?`), gõ `yes`.

#### Phòng ngừa:
- Tuyệt đối không dùng `Ctrl + C` nhiều lần khi Terraform đang thực thi các tác vụ sửa đổi hạ tầng.
- Đặt timeout phù hợp cho workflow CI trên GitHub Actions.

---

### 5.2 Tài Nguyên Mồ Côi (Orphaned Resources / DependencyViolation)

#### Triệu chứng:
Lệnh `terraform destroy` chạy suốt 15–20 phút rồi thất bại với mã lỗi AWS:
`Error: deleting EC2 VPC (vpc-xxx): DependencyViolation: The vpc has dependencies and cannot be deleted.`  
Hoặc báo lỗi các Network Interfaces (ENI) đang ở trạng thái `in-use`.

#### Nguyên nhân phổ biến:
Chạy `terraform destroy` khi EKS cluster vẫn còn sống nhưng chưa dọn dẹp các tài nguyên do Kubernetes Controllers tạo ra tự động (Out-of-band):
1. **Network Load Balancer (NLB)** của Istio Ingress Gateway.
2. **Classic ELB** của ArgoCD Server.
3. Các **Security Groups** tiền tố `k8s-traffic-...` hoặc `k8s-elb-...` gắn với các Elastic Network Interfaces (ENI) trong Subnet.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
# 1. Liệt kê các NLB/ALB còn sót lại trên AWS
aws elbv2 describe-load-balancers --region ap-southeast-1 --query 'LoadBalancers[*].[LoadBalancerName,LoadBalancerArn]' --output table

# 2. Liệt kê các Classic ELB còn sót lại
aws elb describe-load-balancers --region ap-southeast-1 --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output table

# 3. Liệt kê các Security Groups do Kubernetes tự sinh gắn với VPC
VPC_ID=$(aws ec2 describe-vpcs --region ap-southeast-1 --filters "Name=tag:Project,Values=online-boutique" --query "Vpcs[0].VpcId" --output text)
aws ec2 describe-security-groups --region ap-southeast-1 --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" --query 'SecurityGroups[*].[GroupId,GroupName]' --output table
```

##### Trên Windows (PowerShell):
```powershell
# 1. Liệt kê các NLB/ALB còn sót lại trên AWS
aws elbv2 describe-load-balancers --region ap-southeast-1 --query 'LoadBalancers[*].[LoadBalancerName,LoadBalancerArn]' --output table

# 2. Liệt kê các Classic ELB còn sót lại
aws elb describe-load-balancers --region ap-southeast-1 --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output table

# 3. Liệt kê các Security Groups do Kubernetes tự sinh gắn với VPC
$VPC_ID = (aws ec2 describe-vpcs --region ap-southeast-1 --filters "Name=tag:Project,Values=online-boutique" --query "Vpcs[0].VpcId" --output text)
aws ec2 describe-security-groups --region ap-southeast-1 --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" --query 'SecurityGroups[*].[GroupId,GroupName]' --output table
```

#### Giải pháp:
Chạy script Python dọn dẹp khẩn cấp để xóa cưỡng bức toàn bộ tài nguyên mồ côi:

##### Trên Windows (PowerShell) & Linux / macOS (Bash):
```bash
python -c "
import subprocess, json

region = 'ap-southeast-1'

# 1. Xoa NLB/ALB
try:
    cmd = ['aws', 'elbv2', 'describe-load-balancers', '--region', region, '--query', 'LoadBalancers[*].LoadBalancerArn', '--output', 'json']
    arns = json.loads(subprocess.check_output(cmd))
    for arn in arns:
        print(f'Deleting ELBv2: {arn}')
        subprocess.call(['aws', 'elbv2', 'delete-load-balancer', '--load-balancer-arn', arn, '--region', region])
except Exception as e:
    print('ELBv2 check error:', e)

# 2. Xoa Classic ELB
try:
    cmd = ['aws', 'elb', 'describe-load-balancers', '--region', region, '--query', 'LoadBalancerDescriptions[*].LoadBalancerName', '--output', 'json']
    names = json.loads(subprocess.check_output(cmd))
    for name in names:
        print(f'Deleting Classic ELB: {name}')
        subprocess.call(['aws', 'elb', 'delete-load-balancer', '--load-balancer-name', name, '--region', region])
except Exception as e:
    print('Classic ELB check error:', e)

# 3. Xoa Target Groups k8s
try:
    cmd = ['aws', 'elbv2', 'describe-target-groups', '--region', region, '--query', 'TargetGroups[*].[TargetGroupName,TargetGroupArn]', '--output', 'json']
    tgs = json.loads(subprocess.check_output(cmd))
    for name, arn in tgs:
        if 'k8s-' in name:
            print(f'Deleting TG: {name}')
            subprocess.call(['aws', 'elbv2', 'delete-target-group', '--target-group-arn', arn, '--region', region])
except Exception as e:
    print('TG check error:', e)

# 4. Xoa Security Groups k8s
try:
    cmd = ['aws', 'ec2', 'describe-security-groups', '--region', region, '--filters', 'Name=group-name,Values=k8s-*', '--query', 'SecurityGroups[*].GroupId', '--output', 'json']
    sgs = json.loads(subprocess.check_output(cmd))
    for sg in sgs:
        print(f'Deleting SG: {sg}')
        subprocess.call(['aws', 'ec2', 'delete-security-group', '--group-id', sg, '--region', region])
except Exception as e:
    print('SG check error:', e)

print('Dọn dẹp tài nguyên mồ côi hoàn tất!')
"
```

Sau khi chạy xong, thực hiện lại lệnh `terraform destroy -auto-approve`.

#### Phòng ngừa:
- Luôn tuân thủ quy trình chuẩn SOP 2 bước trong [`devops/destroy-guide.md`](../destroy-guide.md): Gỡ cài đặt Helm releases và xóa Service LoadBalancer **trước khi** chạy `terraform destroy`.

---

### 5.3 CloudWatch Log Groups Bị Kẹt Sau Khi Destroy

#### Triệu chứng:
Khi khởi tạo lại hạ tầng buổi sáng bằng `terraform apply`, tiến trình thất bại với lỗi:
`ResourceAlreadyExistsException: The specified log group already exists: /aws/eks/online-boutique-dev/cluster`.

#### Nguyên nhân phổ biến:
Khi EKS cluster kích hoạt tính năng Control Plane Logging (API Server, Audit, Authenticator...), AWS tự động tạo CloudWatch Log Group tương ứng. Mặc định khi EKS cluster bị xóa, AWS giữ lại log group này để bảo toàn dữ liệu nhật ký kiểm toán (Audit Trail) và không tự động xóa theo cluster.

#### Lệnh chẩn đoán:

##### Trên Linux / macOS (Bash):
```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/eks/online-boutique-dev \
  --region ap-southeast-1 \
  --query 'logGroups[*].[logGroupName,storedBytes]' \
  --output table
```

##### Trên Windows (PowerShell):
```powershell
aws logs describe-log-groups `
  --log-group-name-prefix /aws/eks/online-boutique-dev `
  --region ap-southeast-1 `
  --query 'logGroups[*].[logGroupName,storedBytes]' `
  --output table
```

#### Giải pháp:
Xóa Log Group bị kẹt trực tiếp bằng AWS CLI trước khi chạy lại `terraform apply`:

##### Trên Linux / macOS (Bash) & Windows (PowerShell):
```bash
aws logs delete-log-group \
  --log-group-name /aws/eks/online-boutique-dev/cluster \
  --region ap-southeast-1
```

Sau khi xóa, chạy lại:
```bash
terraform apply -auto-approve
```

#### Phòng ngừa:
- Thêm bước xóa CloudWatch Log Group vào script tiêu hủy cuối ngày.
- Thiết lập thời gian lưu trữ ngắn (retention: 1–3 ngày) cho môi trường Dev để tránh phát sinh chi phí lưu trữ không cần thiết.

---

## 6. Danh Mục Tài Liệu Tham Chiếu (References)

- [Quy trình Triển Khai & Vận Hành Hàng Ngày](deploy.md)
- [Quy trình Hoàn Nguyên Ứng Dụng & Hạ Tầng](rollback.md)
- [Hướng Dẫn Co Giãn Tài Nguyên (Scaling)](scaling.md)
- [Hướng Dẫn Tiêu Hủy & Dựng Lại Hạ Tầng An Toàn](../destroy-guide.md)
- [Tài Liệu Nghiệm Thu Giám Sát Stage 5](../stage-5-monitoring.md)
