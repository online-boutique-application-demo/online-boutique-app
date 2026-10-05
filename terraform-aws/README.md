# Terraform AWS Infrastructure – Online Boutique

Terraform modules for provisioning AWS infrastructure to host the Online Boutique microservices application.

## Architecture

```
terraform-aws/
├── global/
│   ├── s3-backend/           # Terraform state backend (run first)
│   ├── ecr/                  # ECR repositories (shared across envs)
│   └── github-oidc/          # GitHub Actions OIDC + IAM roles
├── modules/
│   ├── vpc/                  # VPC with 3-tier subnets + flow logs
│   ├── eks/                  # EKS v1.36 cluster with Spot nodes
│   ├── ecr/                  # ECR repositories (11 services)
│   ├── elasticache/          # Redis for CartService (Multi-AZ)
│   └── irsa/                 # IAM Roles for Service Accounts
└── environments/
    ├── dev/                  # Dev environment config
    └── staging/              # Staging environment config
```

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Terraform >= 1.10
- An AWS account with admin or sufficient IAM permissions

## Quick Start

### 1. Bootstrap State Backend

```bash
cd terraform-aws/global/s3-backend
terraform init
terraform apply
```

This creates an S3 bucket (`online-boutique-tfstate-<ACCOUNT_ID>`) with S3 native state locking.

### 2. Create ECR Repositories

```bash
cd terraform-aws/global/ecr
terraform init && terraform apply
```

### 3. Setup GitHub OIDC (for CI/CD)

```bash
cd terraform-aws/global/github-oidc
terraform init && terraform apply
```

### 4. Deploy Dev Environment

```bash
cd terraform-aws/environments/dev
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

### 5. Configure kubectl

```bash
aws eks update-kubeconfig --region ap-southeast-1 --name online-boutique-dev
```

## Environments

| Environment | VPC CIDR | EKS Version | EKS Nodes | Capacity | Redis |
|-------------|----------|-------------|-----------|----------|-------|
| **dev** | `10.0.0.0/16` | 1.36 | 3x t3.medium | Spot | 2x cache.t3.micro (Multi-AZ) |
| **staging** | `10.1.0.0/16` | 1.36 | 3x t3.medium | Spot | 2x cache.t3.micro (Multi-AZ) |

## Cost Estimate (per environment, Standard Support)

| Resource | Estimated Cost/Month |
|----------|---------------------|
| EKS Control Plane | ~$73 |
| EC2 Spot (3x t3.medium) | ~$30 |
| ElastiCache (2x cache.t3.micro) | ~$25 |
| NAT Gateway | ~$33 |
| **Total** | **~$161** |
