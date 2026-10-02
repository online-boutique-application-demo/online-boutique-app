# 🏗️ Kiến Trúc Hệ Thống – Online Boutique on AWS

> **Ngày tạo:** 2026-10-02  
> **Phiên bản:** 1.0  
> **Dự án:** Online Boutique – DevOps End-to-End trên AWS

---

## 1. Tổng Quan

Online Boutique là ứng dụng e-commerce demo của Google Cloud gồm **12 microservices** được viết bằng nhiều ngôn ngữ khác nhau. Dự án này triển khai ứng dụng lên **AWS** với quy trình DevOps hoàn chỉnh, bao gồm Infrastructure as Code, CI/CD, Service Mesh, Monitoring và Security.

### 1.1 Kiến Trúc Tổng Thể

```mermaid
graph TB
    subgraph "Internet"
        USER[End Users]
    end

    subgraph "AWS Cloud"
        subgraph "VPC - 10.0.0.0/16"
            subgraph "Public Subnets"
                ALB[AWS Application Load Balancer]
                NAT[NAT Gateway]
            end

            subgraph "Private Subnets - EKS Worker Nodes"
                subgraph "istio-system namespace"
                    IGW[Istio Ingress Gateway]
                    KIALI[Kiali Dashboard]
                end

                subgraph "online-boutique namespace"
                    FE[Frontend]
                    CART[CartService]
                    CHECKOUT[CheckoutService]
                    PRODUCT[ProductCatalogService]
                    CURRENCY[CurrencyService]
                    PAYMENT[PaymentService]
                    SHIPPING[ShippingService]
                    EMAIL[EmailService]
                    REC[RecommendationService]
                    AD[AdService]
                end

                subgraph "monitoring namespace"
                    PROM[Prometheus]
                    GRAF[Grafana]
                    LOKI[Loki]
                    TEMPO[Tempo]
                end

                subgraph "argocd namespace"
                    ARGO[ArgoCD Server]
                end
            end

            subgraph "Database Subnets"
                REDIS[ElastiCache Redis]
            end
        end

        ECR[ECR Repositories]
        S3[S3 - Terraform State]
    end

    subgraph "GitHub"
        REPO_APP[online-boutique-app]
        REPO_CFG[online-boutique-config]
        GHA[GitHub Actions CI]
    end

    USER --> ALB --> IGW --> FE
    FE --> CHECKOUT & PRODUCT & CURRENCY & CART & REC & AD & SHIPPING
    CHECKOUT --> PAYMENT & SHIPPING & EMAIL & CART & CURRENCY & PRODUCT
    REC --> PRODUCT
    CART --> REDIS

    REPO_APP --> GHA --> ECR
    GHA --> REPO_CFG
    REPO_CFG --> ARGO
    ARGO --> FE & CART & CHECKOUT
```

---

## 2. Kiến Trúc Microservices

### 2.1 Service Map

```mermaid
graph LR
    FE["Frontend\n(Go :8080)"]
    CART["CartService\n(C# :7070)"]
    PRODUCT["ProductCatalogService\n(Go :3550)"]
    CURRENCY["CurrencyService\n(Node.js :7000)"]
    PAYMENT["PaymentService\n(Node.js :50051)"]
    SHIPPING["ShippingService\n(Go :50051)"]
    EMAIL["EmailService\n(Python :8080)"]
    CHECKOUT["CheckoutService\n(Go :5050)"]
    REC["RecommendationService\n(Python :8080)"]
    AD["AdService\n(Java :9555)"]
    ASSIST["ShoppingAssistantService\n(Python :80)"]
    REDIS[(ElastiCache Redis)]

    FE -->|gRPC| CART
    FE -->|gRPC| PRODUCT
    FE -->|gRPC| CURRENCY
    FE -->|gRPC| SHIPPING
    FE -->|gRPC| CHECKOUT
    FE -->|gRPC| REC
    FE -->|gRPC| AD
    FE -->|gRPC| ASSIST

    CHECKOUT -->|gRPC| CART
    CHECKOUT -->|gRPC| PRODUCT
    CHECKOUT -->|gRPC| CURRENCY
    CHECKOUT -->|gRPC| PAYMENT
    CHECKOUT -->|gRPC| SHIPPING
    CHECKOUT -->|gRPC| EMAIL

    REC -->|gRPC| PRODUCT

    CART -->|TCP| REDIS
```

### 2.2 Chi Tiết Từng Service

| Service | Ngôn ngữ | Port | Protocol | Mô tả | Dependencies |
|---------|----------|------|----------|--------|-------------|
| **frontend** | Go | 8080 | HTTP | Web UI cho end users | Tất cả services |
| **cartservice** | C# (.NET) | 7070 | gRPC | Quản lý giỏ hàng | ElastiCache Redis |
| **checkoutservice** | Go | 5050 | gRPC | Xử lý thanh toán & đặt hàng | cart, product, currency, payment, shipping, email |
| **productcatalogservice** | Go | 3550 | gRPC | CRUD danh mục sản phẩm | Không |
| **currencyservice** | Node.js | 7000 | gRPC | Chuyển đổi tiền tệ | Không |
| **paymentservice** | Node.js | 50051 | gRPC | Xử lý thanh toán (mock) | Không |
| **shippingservice** | Go | 50051 | gRPC | Tính phí vận chuyển | Không |
| **emailservice** | Python | 8080 | gRPC | Gửi email xác nhận | Không |
| **recommendationservice** | Python | 8080 | gRPC | Gợi ý sản phẩm | productcatalogservice |
| **adservice** | Java | 9555 | gRPC | Hiển thị quảng cáo | Không |
| **shoppingassistantservice** | Python | 80 | gRPC | Trợ lý mua sắm AI | Không |
| **loadgenerator** | Python | — | HTTP | Tạo traffic giả lập | frontend |

---

## 3. Kiến Trúc Hạ Tầng AWS

### 3.1 Networking (VPC)

```mermaid
graph TB
    subgraph "VPC: 10.0.0.0/16"
        subgraph "AZ-a"
            PUB_A["Public Subnet\n10.0.0.0/20"]
            PRIV_A["Private Subnet\n10.0.48.0/20"]
            DB_A["Database Subnet\n10.0.96.0/20"]
        end
        subgraph "AZ-b"
            PUB_B["Public Subnet\n10.0.16.0/20"]
            PRIV_B["Private Subnet\n10.0.64.0/20"]
            DB_B["Database Subnet\n10.0.112.0/20"]
        end
        subgraph "AZ-c"
            PUB_C["Public Subnet\n10.0.32.0/20"]
            PRIV_C["Private Subnet\n10.0.80.0/20"]
            DB_C["Database Subnet\n10.0.128.0/20"]
        end

        IGW[Internet Gateway]
        NAT[NAT Gateway]
    end

    INTERNET((Internet)) --> IGW --> PUB_A & PUB_B & PUB_C
    PUB_A --> NAT --> PRIV_A & PRIV_B & PRIV_C
```

| Tầng | CIDR Range | Mục đích | Internet Access |
|------|-----------|----------|-----------------|
| **Public** | `10.0.0.0/20` – `10.0.32.0/20` | ALB, NAT Gateway, Bastion | Inbound + Outbound |
| **Private** | `10.0.48.0/20` – `10.0.80.0/20` | EKS Worker Nodes | Outbound qua NAT |
| **Database** | `10.0.96.0/20` – `10.0.128.0/20` | ElastiCache Redis | Không (isolated) |

### 3.2 EKS Cluster

```mermaid
graph TB
    subgraph "EKS Cluster v1.32"
        CP[Control Plane - AWS Managed]

        subgraph "Managed Node Group - Spot"
            NODE1["t3.medium\n(Spot Instance)"]
            NODE2["t3.medium\n(Spot Instance)"]
            NODE3["t3.medium\n(Spot Instance)"]
        end

        subgraph "Add-ons"
            VPC_CNI[VPC CNI]
            COREDNS[CoreDNS]
            KUBE_PROXY[kube-proxy]
            EBS_CSI[EBS CSI Driver]
        end

        subgraph "IRSA Roles"
            LB_CTRL["AWS LB Controller\nServiceAccount"]
            AUTOSCALER["Cluster Autoscaler\nServiceAccount"]
            EBS_SA["EBS CSI\nServiceAccount"]
        end
    end

    CP --> NODE1 & NODE2 & NODE3
```

| Tham số | Giá trị |
|---------|---------|
| **Version** | 1.32 |
| **Node Type** | t3.medium (Spot) |
| **Scaling** | Min: 2, Desired: 3, Max: 5 |
| **Encryption** | KMS cho Kubernetes Secrets |
| **Logging** | API, Audit, Authenticator, Controller Manager, Scheduler |
| **IRSA** | AWS LB Controller, Cluster Autoscaler, EBS CSI Driver |

### 3.3 Data Layer

| Component | Cấu hình |
|-----------|----------|
| **ElastiCache Redis** | Engine 7.1, Multi-AZ, 2 nodes |
| **Node Type** | cache.t3.micro |
| **Encryption** | At-rest enabled |
| **Backup** | Daily snapshots, 7 days retention |

---

## 4. Kiến Trúc CI/CD

### 4.1 CI Pipeline (GitHub Actions)

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant CI as GitHub Actions
    participant ECR as AWS ECR
    participant CFG as online-boutique-config

    Dev->>GH: Push code / Create PR
    GH->>CI: Trigger workflow
    CI->>CI: Detect changed services
    
    loop Per changed service
        CI->>CI: Run unit tests
        CI->>CI: Lint & format check
        CI->>CI: SCA scan (Trivy)
        CI->>CI: SAST scan (Semgrep)
        CI->>CI: Build Docker image
        CI->>CI: Scan image (Trivy)
        CI->>CI: Sign image (Cosign)
        CI->>ECR: Push image (sha-xxx)
        CI->>CFG: Update image tag
    end
```

### 4.2 CD Pipeline (ArgoCD + GitOps)

```mermaid
sequenceDiagram
    participant CI as GitHub Actions
    participant CFG as online-boutique-config
    participant ARGO as ArgoCD
    participant K8S as EKS Cluster

    CI->>CFG: Update image tags
    CFG->>ARGO: Webhook notification
    
    alt Dev Environment
        ARGO->>K8S: Auto-sync (deploy immediately)
    else Staging Environment
        ARGO->>ARGO: Wait for manual approval
        ARGO->>K8S: Sync after approval
    end

    K8S->>K8S: Rolling update
    K8S->>ARGO: Report health status
```

### 4.3 Repository Strategy

| Repository | Mục đích | Nội dung chính |
|-----------|----------|---------------|
| **online-boutique-app** | Source code + Infrastructure | `src/`, `infra/`, `.github/workflows/`, `devops/` |
| **online-boutique-config** | GitOps Configuration | ArgoCD apps, Kustomize base/overlays, Helm values |

---

## 5. Kiến Trúc Service Mesh (Istio)

### 5.1 Traffic Flow

```mermaid
graph LR
    subgraph "Ingress"
        ALB[AWS ALB] --> IGW[Istio Ingress Gateway]
    end

    subgraph "Service Mesh - mTLS"
        IGW --> VS[VirtualService]
        VS --> FE["Frontend\n+ Envoy Sidecar"]
        FE --> |"mTLS"| SVC1["Other Services\n+ Envoy Sidecars"]
    end

    subgraph "Observability"
        FE -.->|metrics| PROM[Prometheus]
        FE -.->|traces| TEMPO[Tempo]
        FE -.->|topology| KIALI[Kiali]
    end
```

### 5.2 Security Layers

| Layer | Mechanism | Mô tả |
|-------|-----------|--------|
| **Transport** | mTLS (STRICT) | Mã hóa toàn bộ traffic service-to-service |
| **Authentication** | PeerAuthentication | Xác thực identity qua mTLS certificates |
| **Authorization** | AuthorizationPolicy | Whitelist service-to-service communication |
| **Traffic** | VirtualService + DestinationRule | Routing, retries, timeouts, circuit breaking |

---

## 6. Kiến Trúc Monitoring & Observability

### 6.1 Ba Trụ Cột

```mermaid
graph TB
    subgraph "Data Sources"
        PODS[Pods & Containers]
        ISTIO[Istio Sidecars]
        NODES[K8s Nodes]
    end

    subgraph "Collection"
        PROM[Prometheus]
        PROMTAIL[Promtail/Alloy]
        OTEL[OpenTelemetry Collector]
    end

    subgraph "Storage"
        PROM_DB["Prometheus TSDB\n(Metrics)"]
        LOKI_DB["Loki\n(Logs)"]
        TEMPO_DB["Tempo\n(Traces)"]
    end

    subgraph "Visualization"
        GRAFANA[Grafana]
        KIALI[Kiali]
        ALERT[Alertmanager]
    end

    PODS & ISTIO & NODES --> PROM --> PROM_DB --> GRAFANA
    PODS --> PROMTAIL --> LOKI_DB --> GRAFANA
    PODS & ISTIO --> OTEL --> TEMPO_DB --> GRAFANA
    PROM_DB --> KIALI
    PROM_DB --> ALERT
```

| Trụ cột | Tool | Storage | Query Language |
|---------|------|---------|---------------|
| **Metrics** | Prometheus | TSDB | PromQL |
| **Logs** | Loki + Promtail | Object Storage | LogQL |
| **Traces** | Tempo + OTel Collector | Object Storage | TraceQL |

---

## 7. Kiến Trúc Security (DevSecOps)

### 7.1 Security Pipeline

```mermaid
graph TD
    subgraph "Shift-Left Security"
        A["Pre-Commit\ngitleaks"] --> B["SCA\nTrivy FS + Dependabot"]
        B --> C["SAST\nSemgrep + CodeQL"]
        C --> D["Container Scan\nTrivy Image + Hadolint"]
        D --> E["Image Signing\nCosign"]
    end

    subgraph "Runtime Security"
        F["Policy Enforcement\nKyverno"]
        G["Network Security\nIstio mTLS + AuthZ"]
    end

    subgraph "Post-Deploy"
        H["DAST\nOWASP ZAP"]
    end

    E --> F
    E --> H
```

### 7.2 Security Controls Matrix

| Giai đoạn | Tool | Loại | Mục đích |
|-----------|------|------|----------|
| Pre-commit | gitleaks | Secret Scan | Phát hiện secrets trong code |
| Build | Trivy (fs) | SCA | Quét CVEs trong dependencies |
| Build | Dependabot | SCA | Auto-update vulnerable dependencies |
| Build | Semgrep | SAST | Phân tích mã nguồn tìm lỗ hổng |
| Build | CodeQL | SAST | Deep semantic code analysis |
| Build | Hadolint | Dockerfile Lint | Best practices cho Dockerfile |
| Build | Trivy (image) | Container Scan | Quét CVEs trong Docker images |
| Build | Cosign | Image Signing | Ký xác thực Docker images |
| Runtime | Kyverno | Policy Engine | Enforce K8s security policies |
| Runtime | Istio | Network Security | mTLS, AuthZ policies |
| Post-deploy | OWASP ZAP | DAST | Quét lỗ hổng ứng dụng đang chạy |

---

## 8. Environments

### 8.1 So Sánh Environments

| Tham số | Dev | Staging |
|---------|-----|---------|
| **Mục đích** | Development & testing | Pre-production validation |
| **ArgoCD Sync** | Auto | Manual approval |
| **EKS Nodes** | 3 Spot (t3.medium) | 3 Spot (t3.medium) |
| **Redis** | 2 nodes (Multi-AZ) | 2 nodes (Multi-AZ) |
| **DAST Scan** | Không | OWASP ZAP full scan |
| **Istio mTLS** | STRICT | STRICT |
| **Monitoring** | Full stack | Full stack |

### 8.2 Promotion Flow

```mermaid
graph LR
    DEV[Dev Environment] -->|"Manual promotion\nvia ArgoCD"| STAGING[Staging Environment]
    
    DEV ---|"Auto-sync"| AUTO[CI pushes image tag]
    STAGING ---|"Manual approval"| MANUAL[ArgoCD manual sync]
```

---

## 9. Ước Tính Chi Phí (USD/tháng)

| Tài nguyên | Dev | Staging | Tổng |
|------------|-----|---------|------|
| EKS Control Plane | $73 | $73 | $146 |
| EC2 Spot (3x t3.medium) | ~$30 | ~$30 | ~$60 |
| ElastiCache (2x cache.t3.micro) | ~$25 | ~$25 | ~$50 |
| NAT Gateway | ~$33 | ~$33 | ~$66 |
| ALB | ~$18 | ~$18 | ~$36 |
| S3 + DynamoDB (state) | < $1 | — | ~$1 |
| CloudWatch Logs | ~$5 | ~$5 | ~$10 |
| ECR | ~$2 | — | ~$2 |
| **Tổng ước tính** | **~$186** | **~$184** | **~$370** |

> [!WARNING]
> Đây là ước tính sơ bộ. Chi phí thực tế có thể thay đổi tùy thuộc vào usage, region, và Spot pricing.  
> **Tip:** Có thể tắt staging environment khi không sử dụng để tiết kiệm ~50% chi phí.

---

## 10. Quy Ước Đặt Tên

| Tài nguyên | Pattern | Ví dụ |
|------------|---------|-------|
| VPC | `{project}-{env}-vpc` | `online-boutique-dev-vpc` |
| Subnet | `{project}-{env}-{tier}-{az}` | `online-boutique-dev-private-ap-southeast-1a` |
| EKS Cluster | `{project}-{env}` | `online-boutique-dev` |
| ECR Repository | `{project}/{service}` | `online-boutique/frontend` |
| ElastiCache | `{project}-{env}` | `online-boutique-dev` |
| IAM Role | `{cluster}-{purpose}` | `online-boutique-dev-aws-lb-controller` |
| K8s Namespace | `{app-name}` | `online-boutique`, `monitoring`, `argocd` |
