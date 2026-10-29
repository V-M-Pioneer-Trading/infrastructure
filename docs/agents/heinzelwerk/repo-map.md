# Repo map: V-M-Pioneer-Trading/infrastructure
Verified against 71ccde2 2026-10-29.

## Purpose
- Terraform for the SpaceTraders backend containers on ONE shared EC2 host; host, VPC, CloudFront, state bucket, OIDC provider are owned by private repo mradomsky/infrastructure. `README.md:3-11`
- No root `.tf`; 7 independent stacks, each = main/variables/outputs/versions.tf + `.terraform.lock.hcl`. `.github/workflows/terraform.yml:17-19`

## Stacks
- `navigation-service/`: container (`--network host`) with SQLite on EBS `/data`, DLM, KMS-decrypt policy, the single shared SG ingress rule. `navigation-service/main.tf:41,159,203,212,251`
- `agent-service/`: agent-service + MySQL sidecar (host net) + st-gateway (authnet bridge, `127.0.0.1`-only port), EBS, DLM, 2 random DB passwords in SSM. `agent-service/main.tf:38-58,91,130,259,306,368`
- `auth-service/`: container on authnet bridge, SQLite on EBS, DLM, 7 SecureString params (shared, introspection, clerk jwt, 2 machine keys, 2 caller secrets). `auth-service/main.tf:26-108,150,189,521`; table `README.md:89-97`
- `fleet-service/`: container (host net) + KMS-decrypt policy + SSM doc. `fleet-service/main.tf:47,143,173`
- `automation-service/`: container + Postgres sidecar, EBS, DLM, postgres password. `automation-service/main.tf:77-82,121,164,352,357`
- `caddy/`: edge proxy on authnet, `-p 443:443`, DNS-01 via Route53, image built on host with xcaddy. `caddy/main.tf:108-113,167`; `caddy/README.md:7-25`
- `ci-deploy-role/`: IAM role `github-actions-ssm-deploy` for service CI. `ci-deploy-role/main.tf:71-74`
- Every service stack = SSM Command document + association that runs the bootstrap on the host. `README.md:51-55`; e.g. `caddy/main.tf:171-198`
- authnet 172.28.0.0/24 created idempotently by whichever of auth/agent/caddy bootstraps first. `auth-service/main.tf:238,297`; `caddy/main.tf:149`; `agent-service/main.tf:263`

## Public reach (routed through CloudFront + Caddy)
- Routes are app-authenticated except health/status; agent-token and register are gated by `agent:reset` in auth-service. `../auth-service/src/controllers/operator.controller.ts:63,86`
- No 0.0.0.0/0 in any `.tf`. Only ingress: TCP 443 from CloudFront origin-facing prefix list on the shared SG. `navigation-service/main.tf:194-210`
- Prefix list = all of CloudFront, so Caddy 403s requests lacking `X-Origin-Verify`. `caddy/Caddyfile.tftpl:30,38`
- Routed: `/api/{navigation,agent,fleet,automation}/*`, `/api/st-gateway/health`, `/api/auth/v1/{status,agent-token,register}`, `/api/auth/health`; else 404; `/auth/v1/token` deliberately unrouted. `caddy/Caddyfile.tftpl:51-92`
- No SSH; SSM Session Manager; IMDSv2 required. `README.md:36-37`

## Spend
- gp3 encrypted EBS defaults: nav 10GB, agent MySQL 10GB, auth 1GB, automation 10GB. `navigation-service/variables.tf:32`, `agent-service/variables.tf:32`, `auth-service/variables.tf:40`, `automation-service/variables.tf:32`
- DLM daily 03:00, retain 7 snapshots, in all 4 data stacks. `navigation-service/main.tf:269-274`, `agent-service/main.tf:148-152`, `auth-service/main.tf:207-211`, `automation-service/main.tf:182-186`
- SSM SecureString + KMS decrypt cost (unverified). EC2/CloudFront/Route53 billed in the other repo. `README.md:5-9`

## Dependencies (`terraform_remote_state`, s3, `var.state_bucket` except ci-deploy-role)
- "personal/terraform.tfstate" (other repo) read by all 7: `agent-service/main.tf:5`, `auth-service/main.tf:5`, `automation-service/main.tf:5`, `caddy/main.tf:7`, `ci-deploy-role/main.tf:9`, `fleet-service/main.tf:5`, `navigation-service/main.tf:5`
- Personal outputs used: `ec2_role_name` `agent-service/main.tf:64`; `ec2_security_group_id` `navigation-service/main.tf:205`; `ec2_instance_ip` `agent-service/outputs.tf:8`; `ec2_instance_id` `ci-deploy-role/main.tf:98`
- navigation→auth `navigation-service/main.tf:19`; agent→auth `agent-service/main.tf:23`; fleet→agent,auth `fleet-service/main.tf:15,29`; automation→navigation,agent,fleet,auth `automation-service/main.tf:15,25,35,51`; caddy→navigation,agent,fleet,automation,auth `caddy/main.tf:19,28,37,46,64` (ports `caddy/main.tf:117-122`)
- Apply order: personal → auth-service → navigation, agent → fleet → automation → caddy; ci-deploy-role after personal only (derived from edges above; `README.md:122-126` confirms automation after auth)
- Service SSM param names flow to consumers via auth-service outputs. `auth-service/outputs.tf:11,24,55,60`

## Called by (service CI)
- Service CI assumes `github-actions-ssm-deploy` via OIDC; `ssm:SendCommand` on `document/{navigation,agent,fleet,automation,auth}-service-bootstrap-*` + the one instance ARN. `ci-deploy-role/main.tf:88-99`
- Trust: `sub` ref `main` only, for navigation, agent, fleet, automation, st-gateway, auth (plain + ID forms). `ci-deploy-role/main.tf:50-66`
- st-gateway CI runs agent-service's document. `README.md:391-393`

## Persistence
- State: S3 `radomskyi-tfstate`, versioned + encrypted, key `<stack>/terraform.tfstate`, `use_lockfile`. `auth-service/versions.tf:4-9`; `README.md:66-67`
- EBS data: nav SQLite, agent MySQL, auth SQLite, automation Postgres; no `prevent_destroy` in any `.tf` (verified 2026-10-29 @ 71ccde2: grep)

## Secrets in plan/refresh
- SecureString `aws_ssm_parameter` (refresh reads values): `agent-service/main.tf:48,54`; `auth-service/main.tf:31,51,57,69,75,93,104`; `automation-service/main.tf:82`
- `random_password` (values in state): `agent-service/main.tf:38,43`; `auth-service/main.tf:26,46,88,99`; `automation-service/main.tf:77`; `README.md:76-79`
- Sensitive vars: `auth-service/variables.tf:56,72,78`; old key values persist in versioned state. `README.md:216-217`
- auth-service plan needs TF_VARs sourced from SSM. `README.md:170-174`
- Remote-state reads download the whole auth-service state (holds secrets) in navigation/agent/fleet/automation/caddy plans (unverified)
- Out-of-band, never in TF: GHCR token `README.md:75-76`; `spacetraders-origin-verify` `caddy/README.md:35-40`; anomaly webhook URL `README.md:231-235`

## Build / run
- Validate (no creds): `terraform -chdir=<stack> fmt -check -recursive` / `init -backend=false` / `validate`. `README.md:413-415`
- Plan needs AWS creds + S3 state + git-ignored `*.tfvars`. `.gitignore:5-7` (`auth-service/versions.tf:4-9`)
- Required vars, no default: `state_bucket` + `ec2_instance_id` in all but ci-deploy-role (e.g. `auth-service/variables.tf:7,12`); `mining_ship_symbol` `automation-service/variables.tf:80`; `clerk_jwt_key`, `m2m_machine_key_automation_service`, `m2m_machine_key_ai_service` (sensitive) `auth-service/variables.tf:53-78`
- ci-deploy-role hardcodes the bucket, no required vars. `ci-deploy-role/main.tf:13`; `ci-deploy-role/variables.tf:1`
- Providers: hashicorp/aws `~> 6.60` all stacks; hashicorp/random `~> 3.6` only agent, auth, automation. `auth-service/versions.tf:11-19`; `required_version >= 1.10.0` `auth-service/versions.tf:2`

## CI / deploy
- `.github/workflows/terraform.yml`: on `pull_request` to main + `workflow_dispatch` (`:3-6`); `contents: read` (`:8-9`); job `validate`, matrix of 7 stacks, fail-fast false (`:12-30`); SHA-pinned checkout + setup-terraform 1.13.0, fmt / init -backend=false / validate (`:34-53`)
- No apply job; applies are manual. `.github/workflows/terraform.yml:11-53`
- Dependabot weekly: github-actions (`/`) + terraform per stack dir. `.github/dependabot.yml:8-46`

## Patterns
- SSM doc name `<svc>-bootstrap-<instance-id>`. `caddy/main.tf:172`; `ci-deploy-role/main.tf:76-79`
- Shared SG rule lives only in navigation-service (rules-per-SG quota). `agent-service/main.tf:86-89`
- New stack: add to CI matrix + dependabot. `.github/workflows/terraform.yml:40-43`; `.github/dependabot.yml:3-5`

## Traps
- `aws_ssm_association` has no schedule; it re-runs bootstrap whenever its document changes, so apply restarts containers/DBs. `README.md:391-395`; `README.md:326-330`
- Never apply during a service CI deploy (race on containers). `README.md:134-136`
- imageTag rollback is undone by the next deploy or doc-changing apply. `README.md:390-395`
- Apply imageTag doc changes BEFORE service CI sends it, or SSM rejects the deploy. `README.md:403-408`
- auth-service refuses to start if the two Clerk machine keys are equal. `README.md:179-180`
- `ssm:GetCommandInvocation` on `Resource "*"`. `ci-deploy-role/main.tf:100-104`
- caddy doc NOT in the SendCommand allowlist. `ci-deploy-role/main.tf:90-99`
- ai-service has no trust entry though auth-service holds its keys. `ci-deploy-role/main.tf:53-66`; `README.md:95`
- Caddy disables the :80 redirect (agent-service binds 80). `caddy/Caddyfile.tftpl:4-8`
- Stale: `ci-deploy-role/outputs.tf:2` says "three services"; agent/fleet comments say the SG rule covers 80/3001/8080 (now 443 only) `agent-service/main.tf:86-87`, `fleet-service/main.tf:63-64`; README stacks table omits auth-service `README.md:15-22`; `README.md:55` says `--network host` but auth, st-gateway, caddy use authnet
- README hardcodes instance id. `README.md:373`
- Runbooks are historical, step-ordered. `README.md:81-349`

## Reference docs
- `./README.md` "Secrets" and "auth-service secrets and machine tokens": read when adding or rotating a service secret (SSM names, writer, reader).
- `./README.md` "automation-service anomaly pages to Telegram": read when enabling or rotating the anomaly page.
- `caddy/README.md` "TLS to the origin" and "Prerequisites": read when rotating the `X-Origin-Verify` secret (`caddy/main.tf:83,152`).
- `README.md:9-11`: read when auditing account-wide security (points to mradomsky/infrastructure docs/security-model.md, outside this workspace).
