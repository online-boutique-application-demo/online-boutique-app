# 🛑 Hướng Dẫn Destroy & Re-create Hạ Tầng AWS (Online Boutique)

> **Mục tiêu:** Hướng dẫn quy trình tiêu hủy (destroy) hạ tầng vào cuối ngày làm việc nhằm tiết kiệm chi phí tối đa (~65–70% ngân sách Cloud), đồng thời cung cấp quy trình từng bước để tái tạo (re-deploy) nhanh chóng vào sáng hôm sau từ **Stage 1 (Terraform)** đến **Stage 5 (Monitoring & Observability)** mà không gặp lỗi phụ thuộc (`DependencyViolation`).

---

## 1. Tại Sao Không Thể Chạy `terraform destroy` Ngay Lập Tức?

Trong kiến trúc Kubernetes hiện đại trên AWS (EKS), có 2 nhóm tài nguyên:
1. **Tài nguyên do Terraform quản lý:** VPC, Subnets, Internet/NAT Gateway, Route Tables, EKS Cluster, Node Groups, ElastiCache Redis, IAM Roles.
2. **Tài nguyên do Kubernetes Controller tạo động ngoài tầm Terraform (Out-of-band):**
   - Service `istio-ingressgateway` (`type: LoadBalancer`) → AWS Load Balancer Controller cấp phát **Network Load Balancer (NLB)** public internet-facing (từ Stage 4).
   - Service `argocd-server` (`type: LoadBalancer`) → Tạo **Classic ELB** (từ Stage 3).
   - Các Target Groups, Security Groups (`k8s-traffic-...`, `k8s-elb-...`) và các **Elastic Network Interfaces (ENIs)** gắn động vào subnets.
   - Các **Persistent Volume Claims (PVC)** của Prometheus, Loki và Tempo (Stage 5) gắn vào các ổ đĩa **AWS EBS Volumes (gp2)**.

> [!WARNING]
> **Quy tắc vàng:** Nếu chạy `terraform destroy` ngay lập tức, Terraform sẽ xóa cụm EKS trước. Khi EKS biến mất:
> 1. Không còn Controller để gửi lệnh xóa các Load Balancers (NLB/ELB) và Target Groups trên AWS.
> 2. Các ENI gắn với Load Balancer và các EBS Volume bị **"mồ côi" (orphaned)** kẹt trong Subnet.
> 
> Hậu quả: AWS sẽ từ chối xóa Subnet và VPC với mã lỗi `DependencyViolation`, khiến tiến trình destroy bị treo suốt 20–30 phút và cuối cùng thất bại.

---

## 2. Quy Trình Chuẩn (SOP) Destroy Cuối Ngày (Chỉ mất 5–7 phút)

Thực hiện đúng thứ tự **2 bước** sau:

### Bước 1: Dọn dẹp Load Balancers và Volumes trên Kubernetes (khi EKS còn sống)

Mở PowerShell (hoặc Bash) tại thư mục `online-boutique-config` và chạy:

#### Trên Windows (PowerShell):
```powershell
Set-Location -Path "d:\online-boutique\online-boutique-config"

# 1. Dọn dẹp Monitoring Stack (Stage 5) - Xóa Helm releases & giải phóng EBS Volumes
helm uninstall kube-prometheus-stack loki-stack tempo otel-collector -n monitoring 2>$null
kubectl delete pvc --all -n monitoring --timeout=60s
kubectl delete namespace monitoring --timeout=60s

# 2. Dọn dẹp Service Mesh Istio & Ứng dụng (Stage 4) - Thu hồi Ingress Gateway NLB
helm uninstall kiali-server -n istio-system 2>$null
kubectl delete application online-boutique-dev istio-config -n argocd --timeout=60s 2>$null
kubectl delete namespace online-boutique --timeout=90s

# Gỡ bỏ Istio để AWS thu hồi hoàn toàn Network Load Balancer (NLB)
istioctl uninstall --purge -y
kubectl delete namespace istio-system --timeout=60s

# 3. Dọn dẹp ArgoCD & Core Controllers (Stage 3) - Thu hồi Classic ELB
kubectl delete application aws-lb-controller cluster-autoscaler -n argocd --timeout=60s 2>$null
helm uninstall argocd -n argocd 2>$null
kubectl delete namespace argocd --timeout=60s
```

#### Trên Linux / macOS (Bash):
```bash
cd /path/to/online-boutique-config

# 1. Dọn dẹp Monitoring Stack (Stage 5)
helm uninstall kube-prometheus-stack loki-stack tempo otel-collector -n monitoring 2>/dev/null || true
kubectl delete pvc --all -n monitoring --timeout=60s || true
kubectl delete namespace monitoring --timeout=60s || true

# 2. Dọn dẹp Service Mesh Istio & Ứng dụng (Stage 4)
helm uninstall kiali-server -n istio-system 2>/dev/null || true
kubectl delete application online-boutique-dev istio-config -n argocd --timeout=60s 2>/dev/null || true
kubectl delete namespace online-boutique --timeout=90s || true

istioctl uninstall --purge -y || true
kubectl delete namespace istio-system --timeout=60s || true

# 3. Dọn dẹp ArgoCD (Stage 3)
kubectl delete application aws-lb-controller cluster-autoscaler -n argocd --timeout=60s 2>/dev/null || true
helm uninstall argocd -n argocd 2>/dev/null || true
kubectl delete namespace argocd --timeout=60s || true
```

---

#### Kiểm tra xác nhận các Load Balancer đã được thu hồi sạch sẽ:
```powershell
aws elbv2 describe-load-balancers --region ap-southeast-1 --query "LoadBalancers[*].LoadBalancerName"
aws elb describe-load-balancers --region ap-southeast-1 --query "LoadBalancerDescriptions[*].LoadBalancerName"
```
*(Cả 2 lệnh trên trả về `[]` nghĩa là các ELB/NLB và ENI đã được AWS giải phóng hoàn toàn).*

---

### Bước 2: Chạy Terraform Destroy

Chuyển vào thư mục môi trường dev và chạy lệnh destroy:

```powershell
cd d:\online-boutique\online-boutique-app\terraform-aws\environments\dev
terraform destroy -auto-approve
```

Terraform sẽ xóa toàn bộ EKS Cluster, Spot Node Groups, ElastiCache Redis, NAT Gateway, EIP và VPC trơn tru 100% trong ~10-12 phút mà không gặp bất kỳ lỗi phụ thuộc nào.

---

## 3. Script Dọn Dẹp Khẩn Cấp (Khi Đã Lỡ Bị Kẹt Do Xóa EKS Trước)

Nếu bạn đã lỡ bấm `terraform destroy` trước khi dọn dẹp K8s Services khiến EKS đã mất mà VPC bị kẹt không thể xóa, hãy chạy script Python sau để cưỡng chế xóa sạch toàn bộ tài nguyên mồ côi:

```powershell
python -c "
import subprocess, json

region = 'ap-southeast-1'

# 1. Xóa tất cả NLB/ALB còn sót
try:
    cmd = ['aws', 'elbv2', 'describe-load-balancers', '--region', region, '--query', 'LoadBalancers[*].LoadBalancerArn', '--output', 'json']
    arns = json.loads(subprocess.check_output(cmd))
    for arn in arns:
        print(f'Deleting ELBv2: {arn}')
        subprocess.call(['aws', 'elbv2', 'delete-load-balancer', '--load-balancer-arn', arn, '--region', region])
except Exception as e:
    print('ELBv2 check:', e)

# 2. Xóa Classic ELB còn sót
try:
    cmd = ['aws', 'elb', 'describe-load-balancers', '--region', region, '--query', 'LoadBalancerDescriptions[*].LoadBalancerName', '--output', 'json']
    names = json.loads(subprocess.check_output(cmd))
    for name in names:
        print(f'Deleting Classic ELB: {name}')
        subprocess.call(['aws', 'elb', 'delete-load-balancer', '--load-balancer-name', name, '--region', region])
except Exception as e:
    print('Classic ELB check:', e)

# 3. Xóa Target Groups k8s
try:
    cmd = ['aws', 'elbv2', 'describe-target-groups', '--region', region, '--query', 'TargetGroups[*].[TargetGroupName,TargetGroupArn]', '--output', 'json']
    tgs = json.loads(subprocess.check_output(cmd))
    for name, arn in tgs:
        if 'k8s-' in name:
            print(f'Deleting TG: {name}')
            subprocess.call(['aws', 'elbv2', 'delete-target-group', '--target-group-arn', arn, '--region', region])
except Exception as e:
    print('TG check:', e)

# 4. Xóa Security Groups k8s
try:
    cmd = ['aws', 'ec2', 'describe-security-groups', '--region', region, '--filters', 'Name=group-name,Values=k8s-*', '--query', 'SecurityGroups[*].GroupId', '--output', 'json']
    sgs = json.loads(subprocess.check_output(cmd))
    for sg in sgs:
        print(f'Deleting SG: {sg}')
        subprocess.call(['aws', 'ec2', 'delete-security-group', '--group-id', sg, '--region', region])
except Exception as e:
    print('SG check:', e)

print('Clean up completed! Now you can re-run terraform destroy.')
"
```

Sau khi script chạy xong, bạn chỉ cần gõ lại `terraform destroy -auto-approve` là VPC sẽ được giải phóng hoàn tất.

---

## 4. Quy Trình Bật Lại Hạ Tầng (Re-Deploy Toàn Diện Sáng Hôm Sau: Stage 1 → 5)

Vào đầu ngày mới khi bắt đầu làm việc, thực hiện tuần tự các bước dưới đây để khôi phục toàn bộ hệ thống từ Stage 1 đến Stage 5:

### 4.1 Khởi Tạo Nền Tảng Hạ Tầng AWS & EKS (Stage 1 & 2)

```powershell
# 1. Chạy Terraform Apply
cd d:\online-boutique\online-boutique-app\terraform-aws\environments\dev
terraform apply -auto-approve

# 2. Cập nhật Kubeconfig để kubectl kết nối tới EKS Cluster mới
aws eks update-kubeconfig --region ap-southeast-1 --name online-boutique-dev
```
*(Quá trình mất khoảng 10–12 phút để dựng mới VPC, EKS Spot Nodes và ElastiCache Redis).*

---

### 4.2 Cài Đặt ArgoCD & Core Controllers (Stage 3)

```powershell
cd d:\online-boutique\online-boutique-config

# 1. Cài đặt ArgoCD Controller
helm install argocd argo/argo-cd `
  --namespace argocd --create-namespace `
  -f argocd/install/values.yaml

# 2. Chờ ArgoCD pods sẵn sàng
kubectl wait --for=condition=available deployment -l app.kubernetes.io/part-of=argocd -n argocd --timeout=120s

# 3. Áp dụng các controller nền tảng
kubectl apply -f argocd/apps/dev/aws-lb-controller.yaml
kubectl apply -f argocd/apps/dev/cluster-autoscaler.yaml

# 4. ⏳ QUAN TRỌNG: Chờ Cluster Autoscaler sẵn sàng trước khi tiếp tục
#    (Nếu bỏ qua bước này, cluster chỉ có 3 nodes t3.medium không đủ chạy toàn bộ workloads)
kubectl wait --for=condition=available deployment/cluster-autoscaler-aws-cluster-autoscaler -n kube-system --timeout=180s
```

> [!WARNING]
> **Không được bỏ qua bước chờ Cluster Autoscaler!** Cluster khởi tạo chỉ có 3 nodes `t3.medium` (~5790m CPU allocatable). Tổng resource requests của toàn bộ workloads (Istio + 11 microservices + 11 Envoy sidecars + Monitoring) là **~5855m CPU** — vượt quá capacity 3 nodes. Cluster Autoscaler phải hoạt động để tự động scale lên 4-5 nodes khi cần.

---

### 4.3 Khởi Tạo Istio Service Mesh & Kiali (Stage 4)

```powershell
cd d:\online-boutique\online-boutique-config

# 1. Cài đặt Istio core control plane và Ingress Gateway
istioctl install --set profile=default -y

# 2. Gắn annotation để AWS LB Controller tạo Public Internet-Facing NLB cho Ingress Gateway
kubectl annotate svc istio-ingressgateway -n istio-system service.beta.kubernetes.io/aws-load-balancer-scheme="internet-facing" --overwrite

# 3. Tạo namespace online-boutique và kích hoạt tự động tiêm Envoy sidecar
kubectl create namespace online-boutique 2>$null
kubectl label namespace online-boutique istio-injection=enabled --overwrite

# 4. Áp dụng toàn bộ cấu hình Service Mesh (Gateway, VirtualService, mTLS STRICT, AuthPolicies) qua ArgoCD
kubectl apply -f argocd/apps/dev/istio-config.yaml

# 5. Triển khai 11 microservices của Online Boutique qua ArgoCD
kubectl apply -f argocd/apps/dev/online-boutique.yaml

# 6. Cài đặt Kiali Server (Service Mesh Topology Dashboard)
helm repo add kiali https://kiali.org/helm-charts 2>$null
helm repo update
helm upgrade --install kiali-server kiali/kiali-server -n istio-system -f base/istio/kiali-values.yaml

# 7. ⏳ Chờ 11 microservices sẵn sàng trước khi deploy monitoring
#    (Đảm bảo Cluster Autoscaler đã scale đủ nodes cho workloads hiện tại)
kubectl wait --for=condition=available deployment --all -n online-boutique --timeout=300s
```

---

### 4.4 Khởi Tạo Monitoring & Observability Stack (Stage 5)

> [!NOTE]
> Chỉ triển khai monitoring **sau khi** 11 microservices đã Running ở bước 4.3 để đảm bảo Cluster Autoscaler đã scale đủ nodes. Nếu deploy đồng thời, cluster 3 nodes `t3.medium` sẽ bị cạn kiệt CPU (~5855m requests > ~5790m allocatable) khiến pods Pending.

Có 2 phương án để triển khai lại stack giám sát:

#### Phương Án A: Tự Động Hoàn Toàn Bằng ArgoCD GitOps (Khuyên Dùng)

```powershell
cd d:\online-boutique\online-boutique-config

# Áp dụng toàn bộ ArgoCD Applications (các app đã tồn tại từ Stage 3, 4 sẽ báo unchanged)
kubectl apply -f argocd/apps/dev/
```

> [!TIP]
> Lệnh trên sẽ apply tất cả 9 file YAML trong thư mục, bao gồm cả các app đã tạo ở bước 4.2 và 4.3. ArgoCD sẽ bỏ qua những app đã tồn tại (`unchanged`) và chỉ tạo mới 5 app monitoring: `monitoring-stack`, `kube-prometheus-stack`, `loki`, `tempo`, `otel-collector`.

#### Phương Án B: Cài Đặt Trực Tiếp Bằng Helm CLI (Khi Cần Dựng Nhanh)

```powershell
cd d:\online-boutique\online-boutique-config

# 1. Cập nhật Helm repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# 2. Tạo namespace monitoring, Service Aliases, Custom Alerts và Dashboards
kubectl apply -k base/monitoring

# 3. Cài đặt các thành phần giám sát
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring -f base/monitoring/prometheus-stack-values.yaml
helm upgrade --install loki-stack grafana/loki-stack --namespace monitoring -f base/monitoring/loki-values.yaml
helm upgrade --install tempo grafana/tempo --namespace monitoring -f base/monitoring/tempo-values.yaml
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --namespace monitoring -f base/monitoring/otel-collector-values.yaml
```

---

### 4.5 Kích Hoạt Distributed Tracing (Khởi Động Lại Workloads)

> [!NOTE]
> Cấu hình tracing (`istio-mesh-configmap.yaml`, `telemetry.yaml`, `otel-collector-destination-rule.yaml`) đã nằm trong `base/istio/kustomization.yaml` và được ArgoCD app `istio-config` tự động đồng bộ ở bước 4.3. Tuy nhiên, các Envoy sidecar cần được khởi động lại **sau khi monitoring services đã sẵn sàng** để nạp cấu hình tracing mới và kết nối thành công tới OTel Collector.

```powershell
# Chờ monitoring pods sẵn sàng (~60-90s) rồi khởi động lại workloads để nạp cấu hình tracing
kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout restart deployment -n online-boutique
kubectl rollout restart deployment/istio-ingressgateway -n istio-system
```

---

### 4.6 Kiểm Tra Sức Khỏe Nhanh (Morning Health Verification)

Sau khi triển khai xong, chạy các lệnh kiểm tra nhanh để đảm bảo 100% hệ thống đã sẵn sàng:

```powershell
# 1. Kiểm tra trạng thái Pods (Kỳ vọng: 11 pods online-boutique 2/2 Running, monitoring pods Running)
kubectl get pods -n online-boutique
kubectl get pods -n monitoring

# 2. Kiểm tra Prometheus thu thập số liệu Istio Mesh (> 0 series)
kubectl run test-prom --image=curlimages/curl --restart=Never --rm -i -- -s "http://prometheus-server.monitoring:80/api/v1/query?query=count(istio_requests_total)" 2>$null

# 3. Kiểm tra Loki thu thập Logs
kubectl run test-loki --image=curlimages/curl --restart=Never --rm -i -- -s "http://loki-stack.monitoring:3100/loki/api/v1/labels" 2>$null

# 4. Kiểm tra Tempo Distributed Tracing
kubectl run test-tempo --image=curlimages/curl --restart=Never --rm -i -- -s "http://tempo.monitoring:3100/ready" 2>$null

# 5. Kiểm tra truy vấn Traces trên Tempo
kubectl run test-tempo-traces --image=curlimages/curl --restart=Never --rm -i -- -s "http://tempo.monitoring:3100/api/search?limit=5" 2>$null
```

---

### 4.7 Mở Các Bảng Điều Khiển Sẵn Sàng Làm Việc

Mở các terminal riêng biệt để truy cập các dashboard quản trị:

| Dịch vụ | Lệnh Port-Forward | URL Truy Cập | Tài Khoản / Lưu Ý |
| :--- | :--- | :--- | :--- |
| **Ứng dụng Web** | *(Qua NLB Public Ingress)* | `http://<NLB-DNS-Name>` | Xem DNS: `kubectl get svc istio-ingressgateway -n istio-system` |
| **Grafana** | `kubectl port-forward -n monitoring svc/grafana 3000:80` | `http://localhost:3000` | `admin` / `admin` (Dashboards, Logs, Traces) |
| **Kiali** | `kubectl port-forward -n istio-system svc/kiali 20001:20001` | `http://localhost:20001/kiali` | Đăng nhập ẩn danh (Service Mesh Topology) |
| **Prometheus** | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` | `http://localhost:9090` | PromQL queries, targets |
| **Alertmanager** | `kubectl port-forward -n monitoring svc/alertmanager 9093:9093` | `http://localhost:9093` | Quản lý cảnh báo & Silences |
| **ArgoCD UI** | `kubectl port-forward -n argocd svc/argocd-server 8080:443` | `https://localhost:8080` | `admin` / lấy password từ secret `argocd-initial-admin-secret` |

---

## 5. Bảng Dự Toán Tiết Kiệm Chi Phí Khi Destroy Cuối Ngày

| Tài nguyên | Bật 24/7 (USD/tháng) | Bật 8h/ngày làm việc (USD/tháng) | Tiết kiệm (%) |
| :--- | :--- | :--- | :--- |
| **EKS Control Plane** ($0.10/h) | ~$73 | ~$24 | **~67%** |
| **3x EC2 t3.medium Spot** | ~$30 | ~$10 | **~67%** |
| **ElastiCache Redis Multi-AZ** | ~$25 | ~$8 | **~68%** |
| **NAT Gateway** ($0.059/h + Data) | ~$43 | ~$14 | **~67%** |
| **Istio Ingress Gateway NLB** | ~$18 | ~$6 | **~67%** |
| **ArgoCD Server Classic ELB** | ~$18 | ~$6 | **~67%** |
| **AWS EBS gp2 Storage** (Prometheus, Loki, Tempo) | ~$10 | ~$3 | **~70%** |
| **TỔNG CỘNG** | **~$217 / tháng** | **~$71 / tháng** | **Tiết kiệm ~$146 / tháng (~67%)** |
