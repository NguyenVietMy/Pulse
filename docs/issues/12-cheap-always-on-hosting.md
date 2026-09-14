# 12 — Move always-on hosting off ECS to a ~$3–5/mo single host

**Track:** D · Deploy  ·  **Blocked by:** 11  ·  **Blocks:** —
**Estimate:** ~5h

## Goal

Pulse runs 24/7 on a public URL for **under ~$5/mo**, so it can be left up and shown to people
without an AWS bill that only makes sense while something is being demoed.

Issue 11 proves the ECS/Fargate deployment works. This issue makes the *permanent* home cheap and
leaves the AWS path parked.

## Non-goals — read this first

- **`infra/` is not deleted, edited, or downgraded.** The Terraform for VPC / NAT / ALB / ECS / ECR /
  Secrets Manager stays exactly as issue 11 leaves it, applied-and-verified once and then torn down
  with `./teardown.ps1`. It stays in the repo as working infrastructure-as-code that can be brought
  back with one `./spinup.ps1`. Do not "clean up" AWS resources out of the codebase to make this
  issue's diff smaller.
- **No application code changes.** If this issue needs a change inside `api/src` or `agent/src`, stop
  and re-read it — the container contract is already right.
- **`app/` stays on Vercel.** It is already free and already deploys from `main`.
- Not chasing high availability, autoscaling, or zero-downtime deploys. Explicitly accepting a
  single point of failure — see *Tradeoffs accepted*.

## Why the current bill is what it is

Measured against `infra/environments/dev/main.tf` with the stack **actually applied and running**
(issue 11). Rates below were pulled from the **AWS Pricing API on 2026-08-01**, `us-east-1`
on-demand, at 730 hr/mo — not from a pricing page or from memory. Re-check at implementation time.

| Line item | Driver | $/mo |
|---|---|---|
| NAT Gateway | `modules/network/main.tf:64` — one gateway, $0.045/hr + $0.045/GB | $32.85 |
| Application Load Balancer | `modules/ecs_api/main.tf:54` — $0.0225/hr + $0.008/LCU-hr | $16.43 |
| Fargate ×2 (0.25 vCPU / 512 MB) | api + agent, $0.04048/vCPU-hr + $0.004445/GB-hr | $18.02 |
| Secrets Manager | 23 secrets × $0.40 | $9.20 |
| Cloud Map | private DNS zone $0.50 + 2 instances × $0.10 | $0.70 |
| Route 53 zone, ECR, CloudWatch Logs, egress | small | ~$1.50 |
| **Total** | | **~$79** |

**$49.28 of that $79 — 62% — is NAT + ALB**, infrastructure whose entire job is to give two
containers a private network and one TLS endpoint. A single host gives both for free: containers
share a Docker bridge network, and Caddy terminates TLS. The two Fargate tasks are only $18 of the
bill, so the workload was never the expensive part — the AWS-shaped *plumbing around* it was.

**AWS cannot reach the target by reshaping.** Dropping the NAT (public subnets, `assign_public_ip`),
dropping the ALB (Cloudflare straight to a task IP), and moving to Fargate Spot still lands around
$14/mo, and a `t4g.micro` EC2 (1 GB) cannot hold a JVM plus a Python service plus a proxy. Note this
in the issue rather than re-deriving it.

## Options evaluated

| Option | ~$/mo | RAM | Verdict |
|---|---|---|---|
| **Hetzner CX22** (2 vCPU / 4 GB / 40 GB) | ~$4.20 + IPv4 fee | 4 GB | **Recommended.** Cheapest option with headroom for the JVM. |
| Oracle Cloud Always Free (ARM, 4 OCPU / 24 GB) | $0 | 24 GB | Tempting and genuinely free, but ARM capacity is frequently unavailable and idle accounts get reclaimed. Not a home for something you want up. |
| Fly.io, 2 × `shared-cpu-1x` 512 MB | ~$8 | 512 MB each | Best architectural fit — free TLS, Anycast, and 6PN private DNS replace ALB + Cloud Map. Double the target price, and 512 MB is tight for Spring Boot. |
| Railway Hobby | $5 credit/mo | varies | Plausible; usage-metered, so the bill is not fixed. |
| Render | $7/service | 512 MB | Two services = $14. Free tier spins down, which breaks OAuth sessions. |
| AWS, reshaped (no NAT/ALB, Spot) | ~$14 | — | Keeps the ECS work live but misses the target by 4×. |

**Decision: Hetzner CX22 + Docker Compose + Caddy.** If Hetzner signup is a problem (it sometimes
asks for ID verification), fall back to Fly.io and accept ~$8/mo.

## Changes

### 1. `docker-compose.prod.yml` (new, repo root)

Overlay on the existing `docker-compose.yml`. The service-to-service wiring is already correct —
`AGENT_URL: http://agent:8001` and `PULSE_API_URL: http://api:8080` work unchanged on a single
Docker network. What the overlay adds:

- `restart: unless-stopped` on both services (both Dockerfiles already define `HEALTHCHECK`)
- **Remove the `ports:` publish on both services.** Only Caddy binds the host. The agent must not be
  reachable from outside, and `/internal/**` on the api must not be either — same requirement issue
  11 satisfies with "no ALB target group" and `aws_lb_listener_rule.block_internal`.
- `image:` pointing at GHCR instead of `build:`
- A `caddy` service on 80/443

### 2. `Caddyfile` (new)

Replaces the ALB, the ACM certificate, and the `block_internal` listener rule:

```
api.pulse-cs.com {
    # Replaces aws_lb_listener_rule.block_internal (issue 06 security requirement):
    # /internal/** serves full resume and profile text by userId with no user session.
    handle /internal/* {
        respond `{"error":"Not found"}` 404
    }
    handle {
        reverse_proxy api:8080
    }
}
```

Caddy gets a Let's Encrypt certificate automatically. The agent gets no site block at all, so it
is unreachable from the internet structurally rather than by rule — the same property issue 11
achieves by giving it no target group.

### 3. Environment file generation

The 23 Secrets Manager entries collapse back into the two gitignored env files Compose already
reads. **The trap:** `infra/environments/dev/main.tf`'s `extra_environment` and the `ecs_api`
module's hardcoded `environment` block carry values that exist in *neither* env file:

| Variable | Source today | Consequence if missed |
|---|---|---|
| `QDRANT_ENABLED=true` | `main.tf` `extra_environment` | Defaults to `false`; since issue 04 dropped pgvector there is no fallback — chat fails outright |
| `GOOGLE_REDIRECT_URI` | `ecs_api/main.tf:185` | OAuth login breaks |
| `FRONTEND_URL`, `INTEGRATIONS_FRONTEND_URL` | `ecs_api/main.tf:186,189` | Redirects land on the wrong host |
| `SLACK_REDIRECT_URI`, `LINEAR_REDIRECT_URI` | `ecs_api/main.tf:187,188` | Integration OAuth breaks |
| `CORS_ALLOWED_ORIGINS` | `ecs_api/main.tf:190` | Browser calls blocked |
| `OBSERVABILITY_*` (10 vars) | `main.tf` `extra_environment` | Tracing/metrics silently off |
| `LANGFUSE_ENABLED=true`, `LANGFUSE_HOST` | issue 11 `extra_environment` | `langfuse.enabled` defaults to `false` — the API traces **nothing**, silently |
| `AGENT_URL`, `PULSE_API_URL` | issue 11 Cloud Map wiring | Falls back to `localhost` → degraded chat, still HTTP 200 |
| `OTEL_SERVICE_NAME=pulse-agent` | issue 11 agent `extra_environment` | Agent spans export as `unknown_service`; prod traces can't be filtered by service |

Write `scripts/render-env.ps1` (or extend the existing spinup pattern) that reads
`infra/environments/dev/secrets.json` — already the master copy of every secret value — and emits
`api/.env.prod.properties` plus `agent/.env.prod` with the derived vars above appended. Keeping the
domain `api.pulse-cs.com` means **no OAuth app reconfiguration** in the Google / Slack / Linear
consoles.

Per `HANDOFF.md`, `secrets.json` is gitignored and exists on exactly one machine; this issue makes
it load-bearing for production too, so note that in the handoff.

### 4. DNS

`cloudflare_record.api` currently lives in the AWS Terraform stack and points at
`module.ecs_api.alb_dns_name`. With that stack unapplied the record does not exist. Do **not** edit
the AWS stack to repoint it. Instead add a small standalone `infra/environments/vps/` stack that
manages only the Cloudflare A record → host IP, so DNS stays in code and the AWS stack stays
untouched and re-appliable. Start `proxied = false` so Caddy can complete the ACME HTTP challenge;
optionally flip to proxied + Full (strict) afterwards to hide the origin IP.

### 5. `.github/workflows/deploy-vps.yml` (new)

Replaces the ECR/ECS half of `deploy-api.yml` and `deploy-agent.yml`, keeping their test jobs:

1. `mvn test` (api) / `uv run pytest` + `uv run ruff check` (agent) — unchanged
2. Build both images, push to **GHCR** (free, no ECR cost)
3. SSH to the host: `docker compose -f docker-compose.yml -f docker-compose.prod.yml pull && up -d`
4. Poll `https://api.pulse-cs.com/actuator/health` until healthy, fail the job otherwise

Build in Actions, not on the host — a 2 vCPU / 4 GB box should not be running a Maven build while
serving traffic.

Keep `deploy-api.yml` / `deploy-agent.yml` in the repo but gate them behind `workflow_dispatch` only,
so the ECS path stays runnable after a `./spinup.ps1` without firing on every push to a torn-down
environment.

### 6. Host hardening (minimal)

Ubuntu LTS, `ufw` allowing 22/80/443 only, unattended-upgrades, SSH keys only, deploy user in
`docker` group. Nothing more — this is a personal project, not a compliance exercise.

## Tradeoffs accepted

- **Single point of failure.** Host down = Pulse down. No multi-AZ, no autoscaling. At $4/mo that is
  the deal, and the AWS stack is one `./spinup.ps1` from returning if that ever matters.
- **Manual OS patching**, mitigated by unattended-upgrades.
- **Deploys have a few seconds of downtime** (`compose up -d` restarts containers). No blue/green.
- **The host is disposable and needs no backups** — Postgres is Supabase, vectors are Qdrant Cloud,
  traces are Langfuse Cloud. A destroyed host is a rebuild, not a data loss. This is the single
  biggest reason a $4 box is defensible here.

## Resume framing

The ECS/Fargate/Terraform work is not wasted and should not be described as replaced. The honest and
stronger framing is a cost decision made with numbers: *"Ran the service on ECS Fargate behind an
ALB with Terraform-managed infrastructure; measured $79/mo of which $49 — 62% — was NAT gateway and
load balancer serving two containers, and moved steady-state hosting to a single $4/mo host with
Caddy and Compose — a 95% reduction with no application changes, keeping the ECS path in code for
when the traffic justifies it."*

## Acceptance criteria

- [ ] `infra/` AWS Terraform unchanged by this issue (`git diff` touches no file under
      `infra/modules/` or `infra/environments/dev/`)
- [ ] Both containers running on the host; `docker compose ps` healthy
- [ ] `https://api.pulse-cs.com/actuator/health` returns 200 over valid TLS
- [ ] `https://api.pulse-cs.com/internal/context/profile?userId=1` returns 404 from Caddy
- [ ] Agent not reachable from the internet on any port (verify with an external port scan of 8001)
- [ ] Google OAuth login works end to end from the Vercel frontend
- [ ] Chat works end to end and cites sources — proves `QDRANT_ENABLED` and `AGENT_URL` survived the
      migration off `extra_environment`
- [ ] Langfuse receives one trace per chat spanning both services (the issue-10 property still holds)
- [ ] Deploy workflow green on a real push
- [ ] AWS torn down (`terraform state list` empty) and monthly bill confirmed at ~$0
- [ ] Actual cost recorded below

## Verify

```bash
curl -I https://api.pulse-cs.com/actuator/health                      # 200, valid cert
curl -s -o /dev/null -w '%{http_code}\n' \
     https://api.pulse-cs.com/internal/context/profile?userId=1       # 404
nmap -Pn -p 8001,8080 <host-ip>                                       # closed/filtered
ssh <host> 'docker compose ps'                                        # both Up (healthy)
cd infra/environments/dev && terraform state list                     # empty
```

Then exercise login and chat in the deployed frontend and confirm the trace in Langfuse.

## Result (fill in)

| Metric | ECS (issue 11) | Single host |
|---|---|---|
| Monthly cost | $__ | $__ |
| Chat p95 | __ ms | __ ms |
| Cold deploy time | __ min | __ min |
