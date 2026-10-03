# =============================================================================
# Staging Environment – Outputs
# =============================================================================

# VPC
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

# EKS
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA data"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

# ElastiCache
output "redis_connection_string" {
  description = "Redis connection string for CartService"
  value       = module.elasticache.redis_connection_string
}

# IRSA
output "aws_lb_controller_role_arn" {
  description = "IAM role ARN for AWS LB Controller"
  value       = module.irsa.aws_lb_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler"
  value       = module.irsa.cluster_autoscaler_role_arn
}

# Helper
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
