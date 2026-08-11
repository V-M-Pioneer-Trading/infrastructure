# caddy — edge TLS + origin authentication

Runs a [Caddy](https://caddyserver.com/) reverse proxy on the shared EC2 host. It
is the **only** thing CloudFront talks to, and it does two jobs the plain
prefix-list security group cannot:

1. **TLS to the origin.** CloudFront connects over HTTPS on 443; Caddy terminates
   with a real Let's Encrypt certificate for `spacetraders-backend.radomskyi.com`.
   The security group admits only CloudFront (port 80 is closed to Let's Encrypt's
   validators), so the certificate is issued via the **ACME DNS-01 challenge**
   against Route53. The required Route53 permissions live on the shared instance
   role in `mradomsky/infrastructure` `shared/main.tf`; credentials come from the
   instance profile (no static keys).

2. **Origin authentication.** The CloudFront prefix list only proves a request
   came from *some* CloudFront distribution — any AWS customer could point their
   own at this host. Caddy requires every request to carry a shared secret in the
   `X-Origin-Verify` header (injected by our distribution as an origin custom
   header) and returns 403 otherwise. The secret is stored in SSM Parameter Store
   (`SecureString`, created out-of-band), read by the host at container start, and
   passed to Caddy as an environment variable — never baked into the Caddyfile.

Caddy routes each `/api/<service>/*` path prefix to the matching backend container
on `localhost`. Ports are read from each service's Terraform state so the routes
stay in sync.

## Custom image

Stock Caddy has no Route53 DNS module, so the bootstrap builds a custom image on
the host with `xcaddy` (cached after the first build). A pre-built, digest-pinned
GHCR image would be the production-grade alternative.

## Prerequisites

Create the origin-verify secret once, out of band, before applying:

```bash
aws ssm put-parameter --name spacetraders-origin-verify --type SecureString \
  --value "$(openssl rand -hex 32)"
```

The same value is read by the CloudFront stack (`projects/spacetraders` in
`mradomsky/infrastructure`) for the origin custom header.

## Apply order

This stack must be applied **after** the Route53 IAM policy exists on the instance
role and **before** CloudFront is switched to the HTTPS origin. See the rollout
runbook in the pull request.
