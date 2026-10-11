variable "aws_region" {
  description = "AWS region for the state backend"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Name of the project, used as S3 bucket prefix"
  type        = string
  default     = "online-boutique"
}

