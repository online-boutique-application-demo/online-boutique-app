output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.arn
}


output "aws_account_id" {
  description = "AWS Account ID (used in S3 bucket naming)"
  value       = data.aws_caller_identity.current.account_id
}
