# Issues — Agentic RAG Platform

Breakdown of `PRD-agentic.md`. One issue per unit of work; dependencies are strict.

**Starting work? Read [`HANDOFF.md`](../../HANDOFF.md) first** — prerequisites, per-issue workflow,
and the facts a cold start gets wrong.

| # | Issue | Track | Blocked by | Est. | Status |
|---|---|---|---|---|---|
| [01](01-qdrant-provision-and-schema.md) | Provision Qdrant Cloud + collection schema | A · Qdrant | — | 1h | ☑ |
| [02](02-java-qdrant-write-path.md) | Java write path → Qdrant (dual-write) | A · Qdrant | 01 | 4h | ☑ |
| [03](03-java-qdrant-read-path.md) | Java read path → Qdrant hybrid RRF + parity harness | A · Qdrant | 02 | 6h | ☑ |
| [04](04-drop-pgvector.md) | Drop pgvector column and dependency | A · Qdrant | 03 | 2h | ☑ |
| [05](05-scaffold-agent-service.md) | Scaffold `agent/` FastAPI + docker-compose | B · Agent | — | 4h | ☑ |
| [06](06-java-internal-context-api.md) | Java internal context API + auth | B · Agent | — | 3h | ☑ |
| [07](07-langgraph-stategraph.md) | LangGraph `StateGraph` | B · Agent | 03, 05, 06 | 8h | ☑ |
| [08](08-chatservice-http-client.md) | `ChatService` → HTTP client | B · Agent | 07 | 3h | ☑ |
| [09](09-langfuse-java-otel.md) | Langfuse tracing from Java | C · Obs | — | 4h | ☑ |
| [10](10-langfuse-python-trace-propagation.md) | Langfuse in Python + trace propagation | C · Obs | 07, 09 | 4h | ☑ |
| [11](11-deploy-agent-to-ecs.md) | Deploy `agent/` to ECS | D · Deploy | 08, 10 | 6h | ☑ |
| [12](12-cheap-always-on-hosting.md) | Move always-on hosting to a ~$3–5/mo single host | D · Deploy | 11 | 5h | ☐ |

**Total: ~50h.** Critical path: `01 → 02 → 03 → 07 → 08 → 10 → 11` (~34h).

Issue **12** is a follow-on, not part of the PRD: issue 11 proves the ECS deployment and records the
bill, then 12 moves the 24/7 home somewhere it costs ~$4/mo. The AWS Terraform stays in the repo,
applied once and then torn down.

Issue **06** has no blockers. Landing it early shortens the critical path.

## Suggested order

1. **01** — cheap, unblocks the whole Qdrant track
2. **05** + **06** — greenfield, no regression risk
3. **02 → 03** — the migration, gated on the parity measurement in 03
4. **09** — independent; do it while 03's parity numbers are being chased
5. **07** — the centrepiece
6. **08** — the cutover
7. **10** — the payoff trace
8. **04** — delete pgvector only after everything above is proven
9. **11** — ship it
10. **12** — then make keeping it shipped cost ~$4/mo instead of ~$75

Note 04 is deliberately late: there is no reason to drop the old column until the new path is
serving real traffic.
