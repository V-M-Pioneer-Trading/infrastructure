provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# Looks up the OIDC provider created once in mradomsky/infrastructure's bootstrap
# stack (AWS allows only one token.actions.githubusercontent.com provider per
# account) rather than depending on that stack's state.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_ssm_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:V-M-Pioneer-Trading/navigation-service:*",
        "repo:V-M-Pioneer-Trading/agent-service:*",
        "repo:V-M-Pioneer-Trading/fleet-service:*",
      ]
    }
  }
}

resource "aws_iam_role" "github_ssm_deploy" {
  name               = "github-actions-ssm-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_ssm_deploy_trust.json
}

# SSM document names follow the "<service>-bootstrap-<instance-id>" convention
# set by each service's own stack, so a wildcard per service avoids this role
# needing a remote-state read into every service's Terraform state just for an
# ARN it can otherwise get from a stable naming pattern.
resource "aws_iam_role_policy" "github_ssm_deploy" {
  name = "ssm-send-command"
  role = aws_iam_role.github_ssm_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/navigation-service-bootstrap-*",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/agent-service-bootstrap-*",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/fleet-service-bootstrap-*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      }
    ]
  })
}
