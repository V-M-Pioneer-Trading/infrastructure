# Team rules

How heinzelwerk agents work in this repo (GitHub V-M-Pioneer-Trading/infrastructure). Mode rules live in the `heinzelwerk:team-modes` skill. This file holds only what is specific to this repo.

- **Autonomy**: full. Agents merge and apply on their own; breakages are learnings. Secrets are never published (name the variable, never the value), and the gate never merges its own policy.
- **Infra paths**: the seven stack dirs `agent-service/`, `auth-service/`, `automation-service/`, `caddy/`, `ci-deploy-role/`, `fleet-service/`, `navigation-service/`. Each dir is a root module and its own environment; all are production (one account, one region eu-central-1, one EC2 host)
- **Infra checks** (copied from `.github/workflows/terraform.yml`, matrix job `validate`, run in each stack dir; CI pins Terraform 1.13.0):
  - `terraform fmt -check -recursive`
  - `terraform init -backend=false -input=false`
  - `terraform validate`
- **Checks verified on main**: 71ccde2 2026-10-28
- **Infra policy**: `docs/agents/heinzelwerk/infra-policy.json`, enforced by the plugin's `tf-gate` (needs `jq` on the machine)
- **Infra apply order** (provider before consumer, from `terraform_remote_state`): personal (external, private repo) → `auth-service` → `navigation-service`, `agent-service` → `fleet-service` → `automation-service` → `caddy`. `ci-deploy-role` needs only personal
- **Infra secrets**: `agent-service`, `auth-service`, `automation-service` refresh SecureString values into the plan; `auth-service` also needs `TF_VAR_clerk_jwt_key` and the M2M machine keys, `automation-service` needs `TF_VAR_mining_ship_symbol`, every stack needs `state_bucket` and `ec2_instance_id`. Agents may plan them (full autonomy); values stay on this machine, saved plans are never committed · agent credentials (IAM user `pelmeshko`, account 543292785457) can write to: everything (production), per the owner on 2026-10-28
- **Post-merge apply**: no CI apply job; tech-lead applies through `tf-gate` in the next run, in the apply order above
- **Coding standards**: `terraform fmt`; stack patterns in `README.md` (new service = s3 backend, remote_state `personal`, SSM document `<svc>-bootstrap-<instance>` + association; then CI matrix, `dependabot.yml`, `ci-deploy-role` subs)
- **Risk areas** (validator reviews diffs touching these on Opus):
  - infra paths: always a risk area
  - Any `aws_ssm_document` change: apply re-runs the bootstrap and restarts containers with `latest`; never apply while a service CI deploy runs (`README.md:134-136,390-395`)
  - `caddy/Caddyfile.tftpl`: public routing and the `X-Origin-Verify` guard; `GET /auth/v1/token` is never routed
  - `navigation-service/main.tf` security-group ingress rule: the only network entry (443 from CloudFront)
  - `ci-deploy-role/`: which repos' main may deploy
- **Contracts** (see team-modes **Contract changes**):
  - Infra outputs: `*/outputs.tf` · provider infrastructure; read by other stacks through `terraform_remote_state`
  - SSM document names `<svc>-bootstrap-<instance>` and the `imageTag` parameter · provider infrastructure; consumed by the service repos' deploy jobs
  - Image names `ghcr.io/v-m-pioneer-trading/<svc>` · provider the service repos
