# Archived: ECS Fargate + EFS, July 2026

The hosting design this repository *didn't* take, preserved because it is the
other half of a real decision rather than an early draft of what shipped.

**Nothing here is deployed. Nothing here is applied by CI.** The workflow under
`.github/workflows/` is inert: GitHub only reads workflows from the repository
root, so a copy nested this deep never runs. `README.original.md` and
`gitignore.original` are renamed for the same reason — at their original paths
they would have clobbered the ones this repository actually uses.

## What it was

A reusable `modules/ecs-service-with-efs` module (249 lines) consumed once per
service from `projects/<service>/`. Per service it provisioned:

- an ECS cluster and a task definition on **Fargate**, `awsvpc` networking
- an **EFS** filesystem, access point and mount target for the SQLite file
- separate execution and task IAM roles
- a CloudWatch log group
- its own security group, with ingress by CIDR or security-group id

Everything parameterised: `cpu`, `memory`, `desired_count`, VPC, subnets.

## Why it was not used

**Cost, for a hobby project.** This is one small fleet playing a browser game.
The shipped design puts every service as a `docker run` container on a single
shared EC2 instance with one encrypted EBS volume — roughly the price of one
small instance, flat, no matter how many services are added. Fargate bills per
task per second, and EFS bills per GB stored plus throughput, so the same eight
services become eight billed tasks and a network filesystem. For a project whose
entire persistent state is a few SQLite files and a MySQL database, that is a
large multiple of the cost for capability nobody is using.

**EFS is a poor fit for SQLite anyway.** SQLite expects a single writer with
working POSIX locks on a local filesystem. EFS is NFS. It can be made to work,
but "our database is a file on a network share" is a category of problem this
project has no reason to buy. An EBS volume attached to one instance gives
single-writer semantics for free, which is exactly what
`navigation-service`'s cache and `auth-service`'s credential store want.

**The capability it buys is capability this project doesn't need.** Per-service
isolation, independent scaling via `desired_count`, and compute that can be
replaced without touching storage all matter when services scale independently
or when a noisy neighbour is a real risk. Here there is one operator, one agent,
and a rate budget of roughly two requests per second shared across the whole
fleet — st-gateway exists precisely because the *upstream* limit, not compute,
is the binding constraint. Horizontal scaling would buy nothing.

## What it would still solve, and is therefore worth keeping

Two known limitations of the shipped design are things this one had already
answered, and both are recorded as accepted debt elsewhere:

- **Per-service IAM.** Today every container reads the shared EC2 instance
  profile through IMDS, so SSM parameters are effectively host-wide. Any service
  can read another's secrets. `meta/docs/design/auth-design.md` ("Deferred, and
  tracked") states plainly that fixing this properly needs **ECS task roles or
  EKS IRSA — a different hosting model, not a configuration change.** This
  module has task roles.
- **Network isolation.** Containers run with `--network host`, so they share the
  host's port space; that is why `ST_GATEWAY_URL` is `http://localhost:3002` in
  production but a service name under Compose.
  [meta#58](https://github.com/V-M-Pioneer-Trading/meta/issues/58) tracks moving
  off it. `awsvpc` mode gives each task its own interface.

So the trade was made knowingly and is the right one at this size. If the
project ever needs real per-service IAM, this is the direction it goes, and
starting from this rather than from a blank file is the reason it is archived
instead of deleted.

## Provenance

Written 2026-07-14. It never landed on a branch: the commit its Copilot worktree
pointed at (`320fa00`, "Initial commit") is **empty**, so these files existed
only in a working directory on one machine, unreferenced by any commit in this
repository, until they were archived here on 2026-09-08.
