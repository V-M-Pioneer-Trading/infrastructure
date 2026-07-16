output "github_ssm_deploy_role_arn" {
  description = "IAM role ARN the three services' CI workflows assume to trigger their SSM bootstrap document."
  value       = aws_iam_role.github_ssm_deploy.arn
}
