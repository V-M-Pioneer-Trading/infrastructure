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

    # GitHub's OIDC subject sometimes includes immutable org/repo IDs appended via "@"
    # (e.g. "repo:ORG@171620707/REPO@1301535652:ref:...") instead of the plain
    # "repo:ORG/REPO:ref:..." form - hit an AccessDenied on fleet-service's CI using only the
    # plain form, even though this same pattern worked for agent-service (confirmed via
    # CloudTrail). Pinning both exact forms per service instead of wildcarding to keep the
    # trust boundary tight. Org ID 171620707; repo IDs: navigation-service 813281107,
    # agent-service 810497500, fleet-service 1301535652, automation-service 1304148330.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:V-M-Pioneer-Trading/navigation-service:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading@171620707/navigation-service@813281107:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading/agent-service:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading@171620707/agent-service@810497500:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading/fleet-service:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading@171620707/fleet-service@1301535652:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading/automation-service:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading@171620707/automation-service@1304148330:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading/st-gateway:ref:refs/heads/main",
        "repo:V-M-Pioneer-Trading@171620707/st-gateway@1304093584:ref:refs/heads/main",
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
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/automation-service-bootstrap-*",
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

# marker-test
