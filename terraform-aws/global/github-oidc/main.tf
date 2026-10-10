# =============================================================================
# GitHub Actions OIDC Provider + IAM Roles
# Allows GitHub Actions to authenticate to AWS without long-lived credentials
#
# USAGE:
#   cd terraform-aws/global/github-oidc
#   terraform init
#   terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "online-boutique-tfstate-798836978890"
    key            = "global/github-oidc/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    use_lockfile   = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "online-boutique"
      ManagedBy = "terraform"
      Component = "github-oidc"
    }
  }
}

data "aws_caller_identity" "current" {}

# =============================================================================
# GitHub OIDC Provider
# =============================================================================
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"] # GitHub rotates certs; AWS ignores thumbprint for OIDC providers using a trusted CA

  tags = {
    Name = "github-actions-oidc"
  }
}

# =============================================================================
# IAM Role: CI – build & push to ECR
# =============================================================================
resource "aws_iam_role" "github_ci" {
  name = "online-boutique-github-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Support both classic and immutable ID subject formats (GitHub mid-2026+)
            # Classic:   repo:ORG/REPO:ref:refs/heads/...
            # Immutable: repo:ORG@ID/REPO@ID:ref:refs/heads/...
            "token.actions.githubusercontent.com:sub" = "repo:*${var.github_repo_app}*"
          }
        }
      }
    ]
  })

  max_session_duration = 3600

  tags = {
    Name = "online-boutique-github-ci"
  }
}

resource "aws_iam_policy" "github_ci" {
  name        = "online-boutique-github-ci"
  description = "Permissions for GitHub Actions CI: ECR push, EKS describe (for deploy steps)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/online-boutique/*"
        ]
      },
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
        ]
        Resource = [
          "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/online-boutique-*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_ci" {
  role       = aws_iam_role.github_ci.name
  policy_arn = aws_iam_policy.github_ci.arn
}

# =============================================================================
# IAM Role: Terraform Plan/Apply (optional – for terraform workflows)
# =============================================================================
resource "aws_iam_role" "github_terraform" {
  name = "online-boutique-github-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # Support both classic and immutable ID subject formats (GitHub mid-2026+)
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:*${var.github_repo_app}*"
          }
        }
      }
    ]
  })

  max_session_duration = 3600

  tags = {
    Name = "online-boutique-github-terraform"
  }
}

# Terraform needs broad permissions – use AdministratorAccess for demo project.
# In production, scope this down to only the resources Terraform manages.
resource "aws_iam_role_policy_attachment" "github_terraform" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# =============================================================================
# Variables
# =============================================================================
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "github_org" {
  description = "GitHub organization or user name"
  type        = string
  default     = "online-boutique-application-demo"
}

variable "github_repo_app" {
  description = "GitHub repository name for the application"
  type        = string
  default     = "online-boutique-app"
}

# =============================================================================
# Outputs
# =============================================================================
output "github_ci_role_arn" {
  description = "IAM role ARN for GitHub Actions CI workflows"
  value       = aws_iam_role.github_ci.arn
}

output "github_terraform_role_arn" {
  description = "IAM role ARN for GitHub Actions Terraform workflows"
  value       = aws_iam_role.github_terraform.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider"
  value       = aws_iam_openid_connect_provider.github.arn
}
