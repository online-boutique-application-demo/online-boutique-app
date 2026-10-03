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

## 4. Modules

| Module | Files | Mô tả |
|--------|-------|--------|
| **vpc** | `main.tf`, `variables.tf`, `outputs.tf` | VPC, subnets, IGW, NAT, route tables |
| **eks** | `main.tf`, `iam.tf`, `addons.tf`, `variables.tf`, `outputs.tf` | EKS cluster, node groups, OIDC, add-ons |
| **ecr** | `main.tf`, `variables.tf`, `outputs.tf` | 11 ECR repos với lifecycle policies |
| **elasticache** | `main.tf`, `variables.tf`, `outputs.tf` | Redis replication group, SG |
| **irsa** | `main.tf`, `variables.tf`, `outputs.tf`, `policies/` | LB Controller, Autoscaler roles |

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
# Sửa <ACCOUNT_ID> trong main.tf
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## 7. Bài Học Kinh Nghiệm

1. **`*.tfvars` bị gitignore**: File `.gitignore` gốc của project có rule `*.tfvars`. Cần `git add -f` để force track vì tfvars của project này không chứa secrets.
2. **EKS add-ons cần node group**: Add-ons như CoreDNS cần ít nhất 1 node đang chạy, nên phải `depends_on` node group.
3. **KMS key rotation**: Bật `enable_key_rotation = true` cho KMS key dùng encrypt EKS secrets.
