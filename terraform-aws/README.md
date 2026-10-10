# Terraform AWS Infrastructure – Online Boutique

Terraform modules for provisioning AWS infrastructure to host the Online Boutique microservices application.

## Architecture

```
terraform-aws/
├── global/
│   └── s3-backend/           # Terraform state backend (run first)
├── modules/
│   ├── vpc/                  # VPC with 3-tier subnets
│   ├── eks/                  # EKS v1.32 cluster with Spot nodes
│   ├── ecr/                  # ECR repositories (11 services)
│   ├── elasticache/          # Redis for CartService
│   └── irsa/                 # IAM Roles for Service Accounts
└── environments/
    ├── dev/                  # Dev environment config
    └── staging/              # Staging environment config
```

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Terraform >= 1.5
- An AWS account with admin or sufficient IAM permissions

## Quick Start

### 1. Bootstrap State Backend

```bash
cd terraform-aws/global/s3-backend
terraform init
terraform apply
```

This creates an S3 bucket (`online-boutique-tfstate-<ACCOUNT_ID>`) and DynamoDB table for state locking.

### 2. Deploy Dev Environment

```bash
cd terraform-aws/environments/dev

# 1. Copy example vars and adjust values
cp terraform.tfvars.example terraform.tfvars

# 2. Replace <ACCOUNT_ID> in main.tf backend config with your AWS account ID
terraform init
terraform plan
terraform apply
```

### 3. Configure kubectl

```bash
# Use the output from terraform apply
aws eks update-kubeconfig --region ap-southeast-1 --name online-boutique-dev
```

## Environments

| Environment | VPC CIDR | EKS Nodes | Capacity | Redis |
|-------------|----------|-----------|----------|-------|
| **dev** | `10.0.0.0/16` | 3x t3.medium | Spot | 2x cache.t3.micro |
| **staging** | `10.1.0.0/16` | 3x t3.medium | Spot | 2x cache.t3.micro |

## Cost Estimate (per environment)

| Resource | Estimated Cost/Month |
|----------|---------------------|
| EKS Control Plane | ~$73 |
| EC2 Spot (3x t3.medium) | ~$30 |
| ElastiCache (2x cache.t3.micro) | ~$25 |
| NAT Gateway | ~$33 |
| **Total** | **~$161** |
