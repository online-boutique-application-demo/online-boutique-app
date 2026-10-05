# =============================================================================
# Terraform State Backend Bootstrap
# Creates S3 bucket for remote state management (using S3 native state locking)
#
# USAGE (2-step bootstrap):
#   1. Step 1: Create S3 bucket using local state:
#      cd terraform-aws/global/s3-backend
#      terraform init
#      terraform apply
#   2. Step 2: Migrate state to S3 bucket with native state locking:
#      cp backend.tf.example backend.tf
#      # Fill in your AWS Account ID in backend.tf
#      terraform init -migrate-state
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "online-boutique"
      ManagedBy = "terraform"
      Component = "state-backend"
    }
  }
}

# Use current AWS account ID for unique S3 bucket naming
data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------------------------------------
# S3 Bucket for Terraform State
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "terraform_state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

