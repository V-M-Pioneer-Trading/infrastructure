# Repo map: V-M-Pioneer-Trading_infrastructure (GitHub: V-M-Pioneer-Trading/infrastructure)

Terraform for the backend services, which run as Docker containers on one shared EC2 host. Account primitives (VPC, host, CloudFront, state bucket, OIDC) live outside this workspace in `mradomsky/infrastructure`; each stack reads them from remote state `personal/terraform.tfstate`.

| Stack dir | Holds |
|---|---|
| `agent-service/` | SSM bootstrap document + association (also runs st-gateway), MySQL passwords (`random_password` → SSM), MySQL EBS volume + DLM snapshots |
| `auth-service/` | bootstrap, every auth secret in SSM (shared secret, introspection secret, Clerk JWT key, M2M machine keys and caller secrets), SQLite EBS volume + snapshots |
| `automation-service/` | bootstrap, Postgres password, Postgres EBS volume + snapshots |
| `navigation-service/` | bootstrap, SQLite EBS volume + snapshots, the ingress rule letting CloudFront reach Caddy on 443 only |
| `fleet-service/` | bootstrap only (stateless) |
| `caddy/` | edge proxy CloudFront reaches: TLS on 443, routes `/api/<service>/*`, enforces `X-Origin-Verify` |
| `ci-deploy-role/` | IAM role `github-actions-ssm-deploy` that service CI assumes for the SSM redeploy |

- Backend: S3 bucket `radomskyi-tfstate`, eu-central-1, one key per stack, `use_lockfile = true`. Provider `hashicorp/aws ~> 6.60`, `hashicorp/random`; lockfiles committed.
- Resource types in use: `aws_ssm_document`, `aws_ssm_association`, `aws_ssm_parameter`, `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_role_policy_attachment`, `aws_ebs_volume`, `aws_volume_attachment`, `aws_dlm_lifecycle_policy`, `aws_vpc_security_group_ingress_rule`, `random_password`.
- CI `terraform.yml`: on PR to main, matrix `validate (<stack>)` × 7: fmt, `init -backend=false`, validate. No apply, no AWS credentials.
- Local, gitignored: `*.tfvars` (e.g. `prod.tfvars`), `tfplan*`.
- Rollback by `imageTag` is not sticky: the next apply that changes the document reverts it.

## Reference docs

- `README.md`: read before any plan or apply (apply order, secrets, rolling back a service image, the -var revert trap).
- `caddy/README.md`: read when changing the edge proxy, its image, or TLS.
