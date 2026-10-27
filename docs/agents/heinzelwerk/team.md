# Team rules

How heinzelwerk agents work in this repo. Mode rules (single repo vs workspace) live in the `heinzelwerk:team-modes` skill. This file holds only what is specific to this repo.

- **Role**: infra (Terraform, AWS provider ~> 6.60). Backend services as Docker containers on one shared EC2 host
- **Infra paths**: the whole repo, one stack per directory: `agent-service/`, `auth-service/`, `automation-service/`, `caddy/`, `ci-deploy-role/`, `fleet-service/`, `navigation-service/`. Every stack is production; there is no dev environment
- **Infra checks** (validator runs every one, for every stack the diff touches; CI runs all seven):
  1. `terraform -chdir=<stack> fmt -check -recursive`
  2. `terraform -chdir=<stack> init -backend=false -input=false`
  3. `terraform -chdir=<stack> validate -no-color`
- **Infra policy**: `docs/agents/heinzelwerk/infra-policy.json`, enforced by the plugin's `tf-gate`. No auto-apply dirs: agents write and plan, Max applies by hand after merge (CI has no apply job and no AWS credentials)
- **Credentials**: open risk. The AWS profile on Max's machine can write production, and agents run on that machine. `tf-gate` refuses every apply here, but credential scope is the real boundary, and it is not set yet. Target: agents get a read-only (plan) role at most
- **Apply order** (README): auth-service before automation-service; never while a service CI deploy runs (both re-run the SSM bootstrap); a PR adding an SSM document parameter is applied before the matching service CI change
- **Security**: gitleaks pre-commit hook (`gitleaks git --pre-commit --staged` in `.git/hooks/pre-commit`, so every worktree runs it) · secrets never pass through `-var` (use `TF_VAR_*` or `read -s`); `*.tfvars` are gitignored
- **Coding standards**: `README.md`
- **Risk areas**: every infra path (validator reviews every diff here on Opus); in particular
  - `aws_ssm_parameter`, `random_password`: live secrets; replacing a `random_password` rotates a secret services hold
  - `aws_ssm_document`, `aws_ssm_association`: the deploy bootstrap every service CI runs
  - `aws_ebs_volume`, `aws_volume_attachment`, `aws_dlm_lifecycle_policy`: database data and its snapshots
  - `aws_iam_*`, `ci-deploy-role/`: what CI may do in the account
  - Clerk key rotation: a point of no return
- **Contracts**:
  - SSM document parameters ↔ each service's `.github/workflows/container.yml`: provider this repo; a new parameter is applied before the consumer's CI uses it
  - remote state `personal/terraform.tfstate` from `mradomsky/infrastructure` (host, VPC, state bucket): consumed here, owned outside the workspace
  - required check names `validate (<stack>)` for all seven stacks: branch protection depends on them
