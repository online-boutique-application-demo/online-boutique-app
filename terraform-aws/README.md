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

### 1. Bootstrap State Backend (2-Step Process)

Because Terraform needs an S3 bucket to store remote state, but the bucket itself is created by Terraform, bootstrapping follows a 2-step pattern:

**Step 1.1: Create S3 Bucket with local state**
```bash
cd terraform-aws/global/s3-backend
terraform init
terraform apply
```
*Note the `aws_account_id` and `state_bucket_name` in the outputs.*

**Step 1.2: Migrate state to S3 with native state locking**
```bash
cp backend.tf.example backend.tf
# Replace <ACCOUNT_ID> in backend.tf with your AWS Account ID from Step 1.1
terraform init -migrate-state
```

> **Note for other modules**:
> When deploying to a new AWS account, update the bucket name (`online-boutique-tfstate-<ACCOUNT_ID>`) in `backend "s3"` blocks across modules (`global/ecr/main.tf`, `global/github-oidc/main.tf`, `environments/dev/main.tf`, `environments/staging/main.tf`) with your actual AWS Account ID.

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
