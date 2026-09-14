# 11 — Deploy `agent/` to ECS behind the ALB

**Track:** D · Deploy  ·  **Blocked by:** 08, 10  ·  **Blocks:** —
**Estimate:** ~6h

## Goal

The agent serves production traffic. This is what separates "built" from "deployed".

## Changes

- **Terraform** `infra/modules/ecs_agent/` — modelled on the existing `infra/modules/ecs_api/`:
  - ECR repository (extend `infra/modules/ecr/`)
  - Task definition: 0.25 vCPU / 512 MB Fargate, port 8001
  - Service in the existing cluster, private subnets
  - Secrets from AWS Secrets Manager: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `QDRANT_URL`,
    `QDRANT_API_KEY`, `INTERNAL_TOKEN`, `LANGFUSE_*`
  - Health check on `/health`
  - CloudWatch log group
- **Networking:** the agent must **not** be publicly reachable. Options, in order of preference:
  1. Internal service discovery (Cloud Map) — api → agent over the private network, no ALB listener
  2. Internal-only ALB target group on a non-public listener

  The Java `/internal/**` routes must likewise be excluded from the public ALB listener rule
  (issue 06 security requirement).
- **`.github/workflows/deploy-agent.yml`** — mirror `deploy-api.yml`: build, `pytest`, `ruff`, push
  to ECR, update service. Path-filtered on `agent/**` so API pushes don't redeploy it.
- **Cost check:** record actual monthly delta. Budgeted ~$10–15/mo for the task; Qdrant Cloud free
  tier is $0.
- **`OTEL_SERVICE_NAME=pulse-agent`** in the task environment. Found by reading the first prod
  trace: the Python half exported as `unknown_service` while the Java half said `pulse-api`, so
  production traces could not be filtered by service. Langfuse builds its resource with
  `Resource.create()`, which merges OTel's env detector — so this is deployment config, not an
  application change.

## Rollout

1. Deploy the agent service; confirm healthy with no traffic
2. Confirm api → agent reachability from the running API task
3. Flip the API to the agent path
4. Watch error rate and p95 for 24h; the issue-08 fallback covers agent unavailability

## Acceptance criteria

- [x] `terraform plan` clean; `apply` succeeds — 84 resources on the first apply. Two follow-ups
      were needed to reach a genuinely converged plan; see *Two traps* below.
- [x] Agent task healthy; `/health` passing — `RUNNING` / `HEALTHY`, private IP `10.20.10.228`,
      **no public IP**.
- [x] Agent **not** reachable from the public internet — the agent has no ALB and no listener at
      all, so this is a property of the topology rather than of a rule. Its SG admits exactly one
      source on 8001, `sg-0ecc37d0f9fc7210a` (= `pulse-dev-api-ecs-sg`), with **zero CIDR ranges**;
      the account holds one target group (`pulse-dev-api-tg:8080`). `GET /health` on the public ALB
      returns 302 — that is the Java OAuth redirect, not the agent.
- [x] `/internal/**` on the API not reachable from the public internet — `GET
      /internal/context/profile?userId=1` returns **404 even with a valid `X-Internal-Token`**,
      which proves the block is `aws_lb_listener_rule.block_internal` at the listener and not the
      token filter behind it.
- [x] Production chat served by the agent path, end to end — one authenticated turn in the deployed
      frontend produced `POST /chat HTTP/1.1" 200 OK` in the agent log from `10.20.11.38`, the API
      task's IP in the *other* private subnet, and **no** `Agent chat call failed` in the API log.
      Both halves matter: the issue-08 fallback also returns HTTP 200 to the browser.
- [x] Langfuse receives production traces spanning both services — trace
      `bfd18dd9960f6cc888f65484489e866c`, `environment=dev`, 22 observations, one tree from
      `http post /api/personal/chat` (java) through `POST /chat` (python) to three `ChatAnthropic`
      generations. `input`/`output` are `null` on **all 22**, so the issue-10 redaction holds in
      production.
- [x] Deploy workflow green on a real push — 3/3 runs green. These were the *first* successful runs
      ever: the OIDC trust policy named `repo:NguyenVietMy/Outreachly:*`, so every prior deploy had
      failed on `sts:AssumeRoleWithWebIdentity`.
- [x] Actual cost delta recorded below

## Verify

```bash
cd infra/environments/dev && terraform plan
curl https://<public-alb>/health          # expect failure/404 for the agent
curl https://<public-alb>/internal/context/profile?userId=1   # expect 404/403
# then exercise chat in the deployed frontend
```

## Result

| Metric | Before | After |
|---|---|---|
| Chat p95 | n/a — no agent in prod | **not computable, n = 1** (one prod turn: 14.4 s) |
| Monthly infra cost | ~$69/mo | ~$79/mo (**delta ≈ +$10/mo**) |

**Chat latency.** There is exactly one production chat trace, so a p95 would be a single sample
wearing a percentile's clothes. What the numbers say instead:

| Trace | env | Latency | Cost | What it was |
|---|---|---|---|---|
| 2026-07-31T04:28 | local | 0.063 s | $0 | 302, never reached the agent |
| 2026-07-31T04:52 | local | 0.042 s | $0 | 302, never reached the agent |
| 2026-07-31T06:55 | local | 10.16 s | $0.005139 | real, agent-served (compose) |
| 2026-08-01T03:31 | local | 0.052 s | $0 | 302, never reached the agent |
| **2026-08-01T07:51** | **dev** | **14.41 s** | **$0.006771** | **real, agent-served on ECS** |

`cost = $0` is the reliable tell for a chat that never reached a model — the issue-08 fallback
returns its degraded string with no LLM call, still as an HTTP 200. Judge by cost, not status.

Prod is ~4.2 s slower than the same graph on compose. The in-agent breakdown from the trace is
`plan 3.33 s + retrieve 4.63 s + reflect 1.73 s + answer 3.13 s`; `retrieve` is the largest single
step and it egresses to Qdrant Cloud and OpenAI **through the NAT gateway**, which compose does not
do. Not chased here — one sample is not a regression.

**Cost.** Rates below are from the AWS Pricing API on 2026-08-01, us-east-1, not from memory.
Fargate x86 Linux: `$0.04048`/vCPU-hr, `$0.004445`/GB-hr. NAT gateway `$0.045`/hr. ALB `$0.0225`/hr
+ `$0.008`/LCU-hr. 730 hr/mo.

| Line item | Monthly | Note |
|---|---|---|
| NAT gateway | $32.85 | pre-existing, and the single largest item |
| ALB | $16.43 | pre-existing, + LCU |
| API task (0.25 vCPU / 512 MB) | $9.01 | pre-existing |
| Secrets Manager, 23 × $0.40 | $9.20 | pre-existing |
| Route 53 zone + logs + ECR | ~$1.50 | pre-existing |
| **Agent task (0.25 vCPU / 512 MB)** | **+$9.01** | **new** |
| **Cloud Map** (private zone $0.50 + 2 instances × $0.10) | **+$0.70** | **new** |
| **ECR agent image** (170 MB) | **+$0.02** | **new** |

**Delta ≈ +$9.75/mo**, at the bottom of the budgeted $10–15. It stayed there because the agent
added **zero** new Secrets Manager secrets — all seven it needs (`ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `QDRANT_URL`, `QDRANT_API_KEY`, `INTERNAL_TOKEN`, `LANGFUSE_PUBLIC_KEY`,
`LANGFUSE_SECRET_KEY`) already existed for the API. Seven new ones would have added $2.80/mo,
nearly a third of the task cost.

The ~$79/mo total is what motivates issue 12: **$49 of it (NAT + ALB) buys nothing a single host
with a reverse proxy would not.**

## Two traps found by applying it for real

**1. The GitHub OIDC provider is account-global, and another project federates to it.** The apply
failed with `EntityAlreadyExists`. The reflex fix — `terraform import` — would have been the
expensive mistake: `contentlens-github-actions` assumes the same provider, so importing it would
make Pulse's `./teardown.ps1` delete it and silently break an unrelated project's deploys. It is
now a `data` source. **Own what you create; read what you share.**

**2. `health_check_custom_config {}` re-created both Cloud Map services on every plan.** AWS's
`GetService` omits `HealthCheckCustomConfig` entirely once its only field (`failure_threshold`) is
unset, so the block never lands in state, every plan wants to add it back, and the block is
`ForceNew`. Left alone, *any* future `terraform apply` would have replaced both service-discovery
services, deregistering both running tasks from private DNS and breaking `api → agent` resolution
mid-apply. `Type: DNS_HTTP` on the live service confirms the config did apply — only the read-back
is lossy — so the fix is `lifecycle { ignore_changes = [health_check_custom_config] }`. A plan that
is not a no-op after a successful apply is a bug, even when it applies cleanly.

## Known gaps, deliberately not fixed here

- **The agent → API return hop is not trace-propagated.** The three `/internal/context/*` calls the
  agent makes land as three *separate* Langfuse traces, not children of the chat trace.
  `agent/clients/pulse_api.py` builds a bare `httpx.AsyncClient` and never injects `traceparent`;
  issue 10 built Java → Python propagation but not the reverse. Fixing it means touching agent
  source, which is issue 10's scope, not a deployment change.
- **`DailySuggestionService` fails to parse in prod.** `Unexpected end-of-input: was expecting
  closing quote` — a *truncated* model response (max_tokens), which is a different failure from the
  ```` ```json ```` fence that `ModelJson` already handles. Unrelated to this issue; pre-existing.
