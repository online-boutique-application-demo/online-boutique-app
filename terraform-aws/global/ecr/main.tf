# =============================================================================
# Global ECR – Container Registry
# Shared across all environments (dev, staging)
#
# USAGE:
#   cd terraform-aws/global/ecr
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
    key            = "global/ecr/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    use_lockfile   = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Component = "ecr"
    }
  }
}

module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  environment  = "shared"
}

# =============================================================================
# Variables
# =============================================================================
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name used as ECR repository prefix"
  type        = string
  default     = "online-boutique"
}

# =============================================================================
# Outputs
# =============================================================================
output "repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = module.ecr.repository_urls
}
