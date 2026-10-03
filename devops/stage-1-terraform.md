# Stage 1: Terraform – AWS Infrastructure

> **Trạng thái:** ✅ Hoàn thành  
> **Ngày hoàn thành:** 2026-10-03  
> **Branch:** `feature/stage-1-terraform`

---

## 1. Tổng Quan

Stage 1 thiết lập toàn bộ hạ tầng AWS bằng Terraform với cấu trúc module hóa. Hạ tầng bao gồm networking (VPC), compute (EKS), container registry (ECR), data layer (ElastiCache Redis), và IAM (IRSA).

## 2. Cấu Trúc Thư Mục

```
terraform-aws/
├── global/s3-backend/        # State backend bootstrap
├── modules/
│   ├── vpc/                  # 3-tier networking
│   ├── eks/                  # Kubernetes cluster
│   ├── ecr/                  # Container registry
│   ├── elasticache/          # Redis cache
│   └── irsa/                 # IAM for K8s service accounts
└── environments/
    ├── dev/                  # Dev config
    └── staging/              # Staging config
```

## 3. Quyết Định Thiết Kế

### 3.1 EKS v1.32 + Spot Instances
- **v1.32** được chọn vì v1.31 sẽ hết support từ 26/11/2026
- **Spot instances** giúp tiết kiệm ~60-70% chi phí so với On-Demand
- Cluster Autoscaler IRSA role đã được chuẩn bị để handle Spot interruptions

### 3.2 VPC 3-tier Subnets
- **Public**: ALB, NAT Gateway, Istio Ingress Gateway
- **Private**: EKS worker nodes (không có public IP)
- **Database**: ElastiCache Redis (isolated, không có internet access)
- Subnet tagging theo chuẩn EKS (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`)

### 3.3 Single NAT Gateway
- Dùng 1 NAT Gateway thay vì 1/AZ để tiết kiệm chi phí (~$33/tháng thay vì ~$99)
- Trade-off: nếu AZ chứa NAT Gateway gặp sự cố, private subnets ở AZ khác sẽ mất internet

### 3.4 ElastiCache Redis thay vì In-Cluster Redis
- Multi-AZ failover tự động
- Encryption at rest
- Daily snapshots với 7-day retention
- Security group chỉ cho phép EKS nodes truy cập

### 3.5 S3 Bucket Naming
- Sử dụng AWS Account ID trong tên bucket (`online-boutique-tfstate-<ACCOUNT_ID>`)
- Tránh lỗi trùng tên S3 bucket (S3 bucket names là globally unique)

### 3.6 ECR chỉ tạo ở Dev
- ECR repositories được share giữa dev và staging (cùng account)
- Staging environment không tạo lại ECR để tránh duplicate

### 3.7 VPC CIDR khác nhau
- Dev: `10.0.0.0/16`
- Staging: `10.1.0.0/16`
- Tránh conflicts nếu cần VPC peering sau này

## 4. Chi Tiết Từng Module

### 4.0 Global – S3 Backend (`global/s3-backend/`)

Module bootstrap tạo hạ tầng cho việc quản lý Terraform state từ xa. Chạy **trước tất cả** các module khác.

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_s3_bucket` | `terraform_state` | **S3 Bucket** lưu trữ Terraform state files. Tên bucket chứa AWS Account ID (ví dụ: `online-boutique-tfstate-123456789012`) để đảm bảo tính duy nhất toàn cầu. Bật `prevent_destroy` để tránh xóa nhầm. |
| `aws_s3_bucket_versioning` | `terraform_state` | Bật **versioning** cho state bucket – cho phép rollback về state cũ nếu có lỗi khi `terraform apply`. |
| `aws_s3_bucket_server_side_encryption_configuration` | `terraform_state` | Mã hóa state files bằng **AWS KMS** (Server-Side Encryption). State file chứa thông tin nhạy cảm (endpoints, ARNs), cần được bảo vệ. |
| `aws_s3_bucket_public_access_block` | `terraform_state` | **Chặn hoàn toàn public access** – block ACLs, policies, và restrict public buckets. Đảm bảo state file không bao giờ bị public. |
| `aws_dynamodb_table` | `terraform_locks` | **State locking** – ngăn 2 người chạy `terraform apply` cùng lúc. Dùng DynamoDB PAY_PER_REQUEST (không tốn phí khi không dùng). Hash key `LockID` là convention của Terraform S3 backend. |
| `data.aws_caller_identity` | `current` | Lấy **AWS Account ID** hiện tại để tạo tên S3 bucket duy nhất, không cần nhập thủ công. |

---

### 4.1 VPC Module (`modules/vpc/`)

Tạo mạng ảo riêng (Virtual Private Cloud) với kiến trúc **3 tầng subnet** trải đều trên 3 Availability Zones.

#### Resources

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_vpc` | `main` | **VPC chính** với CIDR `10.0.0.0/16` (dev) hoặc `10.1.0.0/16` (staging). Bật `enable_dns_hostnames` và `enable_dns_support` – bắt buộc cho EKS cluster hoạt động đúng. |
| `aws_internet_gateway` | `main` | **Internet Gateway** – cho phép traffic từ internet vào public subnets và ngược lại. Cần thiết cho ALB nhận traffic từ end users. |
| `aws_subnet.public` | `public[0-2]` | **3 Public Subnets** (1/AZ) – nơi đặt ALB và NAT Gateway. Bật `map_public_ip_on_launch` để tài nguyên trong subnet này có IP public. Tagged `kubernetes.io/role/elb=1` để AWS LB Controller tự động tìm subnet khi tạo internet-facing ALB. |
| `aws_subnet.private` | `private[0-2]` | **3 Private Subnets** (1/AZ) – nơi chạy **EKS worker nodes**. Không có public IP, chỉ truy cập internet qua NAT Gateway. Tagged `kubernetes.io/role/internal-elb=1` cho internal load balancer. |
| `aws_subnet.database` | `database[0-2]` | **3 Database Subnets** (1/AZ) – nơi đặt **ElastiCache Redis**. Hoàn toàn **isolated** (không có route ra internet), chỉ cho phép traffic nội bộ từ private subnets. |
| `aws_db_subnet_group` | `database` | **Subnet Group** gom 3 database subnets – ElastiCache yêu cầu subnet group để biết nên đặt Redis nodes ở AZ nào. |
| `aws_eip` | `nat[0]` | **Elastic IP** cho NAT Gateway – IP tĩnh để traffic outbound từ private subnets luôn đi qua cùng 1 IP (quan trọng cho whitelist firewall). |
| `aws_nat_gateway` | `main[0]` | **NAT Gateway** – cho phép EKS nodes trong private subnets truy cập internet (pull Docker images, gọi AWS APIs) mà không cần public IP. Dùng **single NAT** để tiết kiệm chi phí (~$33/tháng thay vì ~$99/tháng cho 3 NATs). |
| `aws_route_table.public` | `public` | **Route table cho public subnets** – route `0.0.0.0/0` đến Internet Gateway. Tất cả 3 public subnets dùng chung route table này. |
| `aws_route_table.private` | `private[0]` | **Route table cho private subnets** – route `0.0.0.0/0` đến NAT Gateway. EKS nodes dùng route này để pull images và gọi AWS APIs. |
| `aws_route_table.database` | `database` | **Route table cho database subnets** – **không có route ra internet** (isolated). Redis chỉ cần nhận kết nối từ EKS nodes trong cùng VPC. |
| `aws_route_table_association` | `public/private/database` | **Liên kết** mỗi subnet với route table tương ứng (3 associations cho mỗi tầng × 3 AZs = 9 associations). |

#### Sơ đồ mạng

```
                    Internet
                       │
                ┌──────┴──────┐
                │     IGW     │
                └──────┬──────┘
        ┌──────────────┼──────────────┐
   ┌────┴────┐   ┌────┴────┐   ┌────┴────┐
   │Public-a │   │Public-b │   │Public-c │  ← ALB, NAT
   │10.0.0/20│   │10.0.16/20│  │10.0.32/20│
   └────┬────┘   └─────────┘   └─────────┘
        │NAT GW
   ┌────┴────┐   ┌─────────┐   ┌─────────┐
   │Private-a│   │Private-b│   │Private-c│  ← EKS Nodes
   │10.0.48/20│  │10.0.64/20│  │10.0.80/20│
   └────┬────┘   └────┬────┘   └────┬────┘
        │              │              │
   ┌────┴────┐   ┌────┴────┐   ┌────┴────┐
   │  DB-a   │   │  DB-b   │   │  DB-c   │  ← Redis (isolated)
   │10.0.96/20│  │10.0.112/20│ │10.0.128/20│
   └─────────┘   └─────────┘   └─────────┘
```

---

### 4.2 EKS Module (`modules/eks/`)

Tạo Amazon EKS cluster v1.32 với Spot managed node groups. Module được chia thành 3 files:
- **`main.tf`** – Cluster và node group
- **`iam.tf`** – IAM roles và OIDC provider
- **`addons.tf`** – EKS managed add-ons

#### Resources – `main.tf`

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_kms_key` | `eks` | **KMS Key** cho mã hóa Kubernetes Secrets bên trong cluster. Bật `enable_key_rotation = true` để tự động xoay key hàng năm theo best practice. |
| `aws_kms_alias` | `eks` | **Alias** cho KMS key (ví dụ: `alias/online-boutique-dev-eks-secrets`) – dễ nhận diện trong AWS Console. |
| `aws_cloudwatch_log_group` | `cluster` | **CloudWatch Log Group** nhận logs từ EKS control plane. Retention 30 ngày. Logs bao gồm: API server, audit, authenticator, controller manager, scheduler. |
| `aws_security_group` | `cluster` | **Security Group** cho EKS control plane – kiểm soát traffic giữa control plane và worker nodes. Dùng `create_before_destroy` để tránh downtime khi recreate. |
| `aws_security_group_rule` | `cluster_egress` | Cho phép **tất cả outbound traffic** từ control plane (cần thiết để control plane giao tiếp với worker nodes và AWS APIs). |
| `aws_eks_cluster` | `main` | **EKS Cluster** chính – version 1.32, bật private + public endpoint, KMS encryption cho secrets, logging đầy đủ 5 loại. Chạy trên cả public + private subnets để đảm bảo HA. |
| `aws_eks_node_group` | `main` | **Managed Node Group** dùng **Spot instances** (t3.medium). Scaling: min 2 → desired 3 → max 5 nodes. `max_unavailable = 1` để rolling update không gây gián đoạn. `ignore_changes` cho `desired_size` vì Cluster Autoscaler sẽ tự điều chỉnh. |

#### Resources – `iam.tf`

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_iam_role.cluster` | `{cluster}-cluster-role` | **IAM Role** cho EKS cluster control plane – cho phép EKS service assume role này để quản lý cluster. |
| policy attachment | `AmazonEKSClusterPolicy` | Gắn policy cho phép EKS quản lý cluster resources (ENIs, security groups, etc.). |
| policy attachment | `AmazonEKSVPCResourceController` | Cho phép EKS quản lý VPC resources – cần thiết cho pod networking (VPC CNI). |
| `aws_iam_role.node` | `{cluster}-node-role` | **IAM Role** cho EC2 worker nodes – cho phép nodes join cluster và pull images từ ECR. |
| policy attachment | `AmazonEKSWorkerNodePolicy` | Cho phép nodes giao tiếp với EKS API server và nhận workloads. |
| policy attachment | `AmazonEKS_CNI_Policy` | Cho phép VPC CNI plugin quản lý ENIs và IP addresses cho pods. |
| policy attachment | `AmazonEC2ContainerRegistryReadOnly` | Cho phép nodes **pull Docker images** từ ECR. |
| `data.tls_certificate` | `eks` | Lấy TLS certificate từ OIDC issuer URL của EKS – cần cho xác thực OIDC provider. |
| `aws_iam_openid_connect_provider` | `eks` | **OIDC Provider** – nền tảng cho **IRSA** (IAM Roles for Service Accounts). Cho phép Kubernetes ServiceAccounts assume IAM roles mà không cần access keys. |

#### Resources – `addons.tf`

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_eks_addon` | `vpc_cni` | **Amazon VPC CNI** – plugin networking cấp IP từ VPC subnet cho mỗi pod. Mỗi pod nhận IP thực trong VPC, cho phép giao tiếp trực tiếp với các AWS services (ElastiCache, ALB). |
| `aws_eks_addon` | `coredns` | **CoreDNS** – DNS server trong cluster. Cho phép pods resolve tên service (ví dụ: `cartservice.default.svc.cluster.local` → IP). |
| `aws_eks_addon` | `kube_proxy` | **kube-proxy** – duy trì network rules trên mỗi node, cho phép traffic đến ClusterIP services được forward đến đúng pods. |
| `aws_eks_addon` | `ebs_csi_driver` | **EBS CSI Driver** – cho phép pods mount EBS volumes (PersistentVolumeClaims). Cần thiết cho stateful workloads (Prometheus, Grafana data). Dùng IRSA role riêng. |
| `aws_iam_role` | `ebs_csi` | **IRSA Role** cho EBS CSI Driver – cho phép driver tạo/xóa/attach EBS volumes mà không cần gắn permissions lên node role. |

---

### 4.3 ECR Module (`modules/ecr/`)

Tạo AWS Elastic Container Registry repositories cho **11 microservices** (không bao gồm `shoppingassistantservice`).

#### Resources

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_ecr_repository` | `services` (×11) | **ECR Repository** cho mỗi service (ví dụ: `online-boutique/frontend`, `online-boutique/cartservice`). Bật `scan_on_push = true` để AWS tự động quét CVEs khi push image. Mã hóa AES256 cho images at rest. |
| `aws_ecr_lifecycle_policy` | `services` (×11) | **Lifecycle Policy** gồm 2 rules: (1) Giữ tối đa **30 images** có tag prefix `sha-` – tự xóa images cũ; (2) Xóa **untagged images** sau 1 ngày – dọn dẹp dangling images từ failed builds. |

#### Danh sách repositories

| # | Repository | Dùng cho service |
|---|-----------|-----------------|
| 1 | `online-boutique/frontend` | Web UI (Go) |
| 2 | `online-boutique/cartservice` | Quản lý giỏ hàng (C#) |
| 3 | `online-boutique/checkoutservice` | Xử lý checkout (Go) |
| 4 | `online-boutique/productcatalogservice` | Danh mục sản phẩm (Go) |
| 5 | `online-boutique/currencyservice` | Chuyển đổi tiền tệ (Node.js) |
| 6 | `online-boutique/paymentservice` | Thanh toán (Node.js) |
| 7 | `online-boutique/shippingservice` | Vận chuyển (Go) |
| 8 | `online-boutique/emailservice` | Gửi email (Python) |
| 9 | `online-boutique/recommendationservice` | Gợi ý sản phẩm (Python) |
| 10 | `online-boutique/adservice` | Quảng cáo (Java) |
| 11 | `online-boutique/loadgenerator` | Traffic giả lập (Python) |

> ECR repositories được tạo **chỉ trong dev environment** và **share cho staging** (cùng AWS account). Staging không duplicate ECR.

---

### 4.4 ElastiCache Module (`modules/elasticache/`)

Tạo Amazon ElastiCache Redis cluster cho **CartService** – thay thế in-cluster Redis để có Multi-AZ failover, encryption, và managed backups.

#### Resources

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| `aws_elasticache_subnet_group` | `redis` | **Subnet Group** gom các database subnets (isolated) – chỉ định nơi Redis nodes sẽ được đặt. Redis cần ít nhất 2 subnets ở 2 AZs khác nhau cho Multi-AZ. |
| `aws_security_group` | `redis` | **Security Group** cho Redis – kiểm soát ai được phép kết nối đến Redis. |
| `aws_security_group_rule` | `redis_ingress` | **Ingress rule** – chỉ cho phép traffic **TCP port 6379** từ EKS node security group. Không service nào khác ngoài EKS nodes được truy cập Redis. |
| `aws_security_group_rule` | `redis_egress` | **Egress rule** – cho phép outbound traffic (cần cho Redis replication giữa các nodes). |
| `aws_elasticache_replication_group` | `redis` | **Redis Replication Group** – engine Redis 7.1, node type `cache.t3.micro`, **2 nodes** với automatic failover. Cấu hình: encryption at rest, daily snapshots (3-4 AM, giữ 7 ngày), maintenance window (Chủ Nhật 5-6 AM). CartService kết nối qua primary endpoint. |

#### Luồng kết nối

```
CartService Pod (Private Subnet) → SG Rule (TCP 6379) → Redis Primary (Database Subnet)
                                                           ↕ Replication
                                                       Redis Replica (Database Subnet, AZ khác)
```

---

### 4.5 IRSA Module (`modules/irsa/`)

Tạo **IAM Roles for Service Accounts** – cơ chế cho phép Kubernetes pods assume IAM roles thông qua OIDC, **không cần access keys**.

#### Resources

| Resource | Tên Resource | Mục đích |
|----------|-------------|----------|
| **AWS Load Balancer Controller** | | |
| `aws_iam_role` | `aws_lb_controller` | **IAM Role** cho AWS LB Controller ServiceAccount. Trust policy dùng OIDC federation, chỉ cho phép ServiceAccount `aws-load-balancer-controller` trong namespace `kube-system` assume role. |
| `aws_iam_policy` | `aws_lb_controller` | **IAM Policy** chứa quyền tạo/quản lý ALB, NLB, Target Groups, Security Groups. Policy JSON nằm trong `policies/aws-lb-controller-policy.json` (official từ AWS). |
| policy attachment | `aws_lb_controller` | Gắn policy vào role. |
| **Cluster Autoscaler** | | |
| `aws_iam_role` | `cluster_autoscaler` | **IAM Role** cho Cluster Autoscaler ServiceAccount. Đặc biệt quan trọng khi dùng **Spot instances** – Autoscaler cần quyền scale up/down node groups khi Spot bị thu hồi. |
| `aws_iam_policy` | `cluster_autoscaler` | **IAM Policy** gồm 2 statements: (1) Read-only – describe ASG, instances, tags; (2) Write – `SetDesiredCapacity` và `TerminateInstanceInAutoScalingGroup`, **chỉ cho phép** trên ASG có tag `k8s.io/cluster-autoscaler/{cluster}=owned` (scoped permission). |
| policy attachment | `cluster_autoscaler` | Gắn policy vào role. |

#### Cách IRSA hoạt động

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Pod khởi chạy với ServiceAccount "aws-load-balancer-     │
│    controller" trong namespace "kube-system"                 │
│ 2. Kubernetes inject OIDC token vào pod                      │
│ 3. AWS SDK trong pod gọi STS AssumeRoleWithWebIdentity      │
│ 4. STS kiểm tra OIDC token với OIDC Provider                │
│ 5. STS trả về temporary credentials (access key, secret,    │
│    session token)                                            │
│ 6. Pod sử dụng credentials để gọi AWS APIs                  │
└──────────────────────────────────────────────────────────────┘
```

## 5. Outputs Quan Trọng

| Output | Dùng cho |
|--------|----------|
| `cluster_name` | kubectl config, ArgoCD |
| `cluster_endpoint` | CI/CD pipeline |
| `ecr_repository_urls` | Docker push trong CI |
| `redis_connection_string` | CartService config |
| `aws_lb_controller_role_arn` | Helm install LB Controller |
| `configure_kubectl` | Quick start command |

## 6. Hướng Dẫn Sử Dụng

### Bootstrap (chạy 1 lần)
```bash
cd terraform-aws/global/s3-backend
terraform init && terraform apply
```

### Deploy environment
```bash
cd terraform-aws/environments/dev
# Sao chép file example và điều chỉnh giá trị
cp terraform.tfvars.example terraform.tfvars
# Sửa <ACCOUNT_ID> trong main.tf
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## 7. Bài Học Kinh Nghiệm

1. **`*.tfvars` pattern**: Dùng `terraform.tfvars.example` để commit mẫu config, người dùng tự copy sang `terraform.tfvars` (bị gitignore) và điền giá trị thực tế.
2. **EKS add-ons cần node group**: Add-ons như CoreDNS cần ít nhất 1 node đang chạy, nên phải `depends_on` node group.
3. **KMS key rotation**: Bật `enable_key_rotation = true` cho KMS key dùng encrypt EKS secrets.
