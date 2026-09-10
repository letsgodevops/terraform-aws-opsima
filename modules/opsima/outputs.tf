output "role_arn" {
  description = "IAM Remote Access Role ARN used by Opsima (equivalent to the CFN stack's RoleArn output). Paste this into Opsima's onboarding UI."
  value       = aws_iam_role.opsima_remote_access.arn
}

output "organizational_unit_id" {
  description = "ID of the Opsima OU this module created (the handshake used to send this to Opsima as OpsimaOrganizationalUnitId; now supply it during manual onboarding)."
  value       = aws_organizations_organizational_unit.opsima.id
}
