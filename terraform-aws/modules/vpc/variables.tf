variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 3
}

variable "cluster_name" {
  description = "Name of the EKS cluster (for subnet tagging)"
  type        = string
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ (cost saving)"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch Logs"
  type        = bool
  default     = true
}
