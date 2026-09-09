output "role_arn" {
  description = "IAM Remote Access Role ARN used by Opsima (equivalent to the CFN stack's RoleArn output)."
  value       = aws_iam_role.opsima_remote_access.arn
}
