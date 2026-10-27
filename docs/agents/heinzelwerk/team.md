# Team rules

How heinzelwerk agents work in this repo. Mode rules (single repo vs workspace) live in the `heinzelwerk:team-modes` skill. This file holds only what is specific to this repo; the workspace is described in V-M-Pioneer-Trading/meta `docs/agents/heinzelwerk/workspace.md`.

- **Autonomy**: full. Agents merge and apply on their own; breakages are learnings. Secrets are never published (name the variable, never the value), and the gate never merges its own policy.
- **Role**: infra
- **Infra paths**: the stack dirs `agent-service/`, `auth-service/`, `automation-service/`, `caddy/`, `ci-deploy-role/`, `fleet-service/`, `navigation-service/`. All are production; there is no dev environment.
- **Infra checks**: in every stack dir: `terraform fmt -check -recursive`, `terraform init -backend=false -input=false`, `terraform validate` (Terraform 1.13.0, as CI)
- **Infra policy**: `docs/agents/heinzelwerk/infra-policy.json`, enforced by the plugin's `tf-gate` (needs `jq` on the machine)
- **Infra apply order** (provider before consumer, from `terraform_remote_state`): personal (mradomsky/infrastructure) → `auth-service` → `navigation-service` and `agent-service` (independent) → `fleet-service` → `automation-service` → `caddy`. `ci-deploy-role` depends only on personal. `caddy` also needs the Route53 IAM policy first (caddy/README.md:47-49).
- **Infra secrets**: every stack but `ci-deploy-role` reads secrets during plan or refresh (`auth-service`, `agent-service`, `automation-service` hold random_password and SecureString values; the others read those stacks' state). `auth-service` plans need `TF_VAR_clerk_jwt_key` and the two `TF_VAR_m2m_machine_key_*`. Agents may plan them (full autonomy); values stay on this machine and never enter a PR, ticket or note. Agent credentials can write to the full production account.
- **Infra apply timing**: never apply while a service's CI deploy is running (the bootstrap runs twice and races); an apply that changes a bootstrap document restarts its containers, databases included. No CI applies after merge: tech-lead applies through `tf-gate` in the next run.
- **Checks** (validator runs every one, in order; copied from CI): for each stack in `agent-service`, `auth-service`, `automation-service`, `caddy`, `ci-deploy-role`, `fleet-service`, `navigation-service`: `terraform -chdir=<stack> fmt -check -recursive`, `terraform -chdir=<stack> init -backend=false -input=false`, `terraform -chdir=<stack> validate`
- **Checks verified on main**: 71ccde2 2026-10-27
- **Coding standards**: `README.md` (deployment model, runbooks)
- **Risk areas** (validator reviews diffs touching these on Opus):
  - infra paths: always a risk area (every stack is production)
- **Contracts** (see team-modes **Contract changes**; validator checks every diff touching these):
  - Infra outputs: `*/outputs.tf` (read by other stacks through `terraform_remote_state`) · provider infra
