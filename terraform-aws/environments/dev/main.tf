# =============================================================================
# Dev Environment – Main Configuration
# Composes all Terraform modules for the dev environment
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # bucket name will be: online-boutique-tfstate-<ACCOUNT_ID>
    # Replace <ACCOUNT_ID> with your AWS account ID before running terraform init
    bucket         = "online-boutique-tfstate-<ACCOUNT_ID>"
    key            = "environments/dev/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "online-boutique-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
}

# =============================================================================
# Module: VPC
# =============================================================================
module "vpc" {
  source = "../../modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  cluster_name       = local.cluster_name
  single_nat_gateway = var.single_nat_gateway
}

# =============================================================================
# Module: EKS
# =============================================================================
module "eks" {
  source = "../../modules/eks"

  cluster_name           = local.cluster_name
  cluster_version        = var.cluster_version
  environment            = var.environment
  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  endpoint_public_access = true
  node_instance_types    = var.node_instance_types
  capacity_type          = var.capacity_type
  node_disk_size         = var.node_disk_size
  node_desired_size      = var.node_desired_size
  node_min_size          = var.node_min_size
  node_max_size          = var.node_max_size
}

# =============================================================================
# Module: ECR (shared across environments, only create once in dev)
# =============================================================================
module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  force_delete = true # Allow force delete in dev
}

# =============================================================================
# Module: ElastiCache Redis
# =============================================================================
module "elasticache" {
  source = "../../modules/elasticache"

  project_name              = var.project_name
  environment               = var.environment
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.database_subnet_ids
  allowed_security_group_id = module.eks.cluster_security_group_id
  redis_version             = var.redis_version
  node_type                 = var.redis_node_type
  num_cache_clusters        = var.redis_num_cache_clusters
  apply_immediately         = true # OK for dev
}

# =============================================================================
# Module: IRSA
# =============================================================================
module "irsa" {
  source = "../../modules/irsa"

  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
}
