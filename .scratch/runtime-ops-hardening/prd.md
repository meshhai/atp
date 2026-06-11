# Runtime and Operational Hardening PRD

## Problem Statement

ATP now has the core single-node carrier loop in place: identity, direct messages, inbox polling, webhooks, ACKs, sessions, message status reads, CLI workflows, and a supervised webhook dispatcher. The normal test suite passes, but production readiness still needs two things in one coherent pass:

- stronger confidence in runtime and dispatcher edge behavior
- basic OSS-ready operational surface and docs for single-node deployment

The current coverage gap is concentrated in runtime and dispatcher edge paths. Those paths matter during crashes, restarts, retries, disabled components, malformed configuration, shutdown, and stale worker recovery.

The app also lacks root-level service probes and a clear single-node production operations contract. Operators need to know whether the process is alive, whether the node should receive traffic, how to configure production, how migrations are handled, and what telemetry/logging signals are available.

## Solution

Implement one production-readiness PR that hardens the current runtime and adds minimal single-node operational readiness:

1. Add production-meaningful runtime and dispatcher edge tests.
2. Preserve the configured coverage goal unless any remaining defensive branch is explicitly justified.
3. Add unauthenticated root-level `GET /health` and `GET /ready` endpoints.
4. Make readiness answer whether this single node is safe to receive ATP carrier work.
5. Document the single-node production contract, required configuration, migration expectations, probe semantics, telemetry/logging signals, and release checklist.

## User Stories

1. As an ATP maintainer, I want runtime crash/restart/retry paths covered, so that production behavior is proven instead of assumed.
2. As an ATP operator, I want dispatcher and session runtime edge behavior tested, so that a single-node service can recover predictably from worker exits and restarts.
3. As an OSS deployer, I want `/health`, so that a process manager or load balancer can tell whether the service is alive.
4. As an OSS deployer, I want `/ready`, so that traffic is sent only to an instance that can safely receive carrier work.
5. As an ATP operator, I want probe responses to avoid sensitive internals, so that public probes do not leak carrier data, secrets, or runtime implementation details.
6. As an ATP operator, I want clear production docs, so that I can deploy and verify ATP without reverse-engineering local development instructions.
7. As a release manager, I want a release checklist, so that changes are verified consistently before publishing.

## Implementation Decisions

- Target single-node production first: one Phoenix service instance, one Postgres durable ledger, and local OTP runtime processes.
- Keep ATP product-neutral and carrier-scoped.
- Do not add agent hosting, tool execution, workflow scheduling, long-term memory, or payload interpretation.
- Add root-level probe paths, not `/api` paths:
  - `GET /health`
  - `GET /ready`
- Probe endpoints are unauthenticated and return JSON.
- `/health` returns `200` with minimal JSON when Phoenix can respond.
- `/ready` returns `200` when the node is safe to receive carrier traffic and `503` when it is not.
- `/ready` checks database usability, transport runtime supervision, and webhook dispatcher availability when the dispatcher is enabled.
- If the webhook dispatcher is intentionally disabled by config, readiness reports it as `disabled` and can still return `200`.
- Readiness must not check recipient webhooks, agent availability, queue emptiness, backlog, downstream products, or multi-node health.
- Public probe responses must not expose DB URLs, env vars, PIDs, node names, migration versions, exception text, delivery IDs, message IDs, webhook URLs, tokens, queue depths, or agent data.
- Docs should target generic VM/container deployment first, not Kubernetes-specific manifests.
- Docker Compose remains local development guidance, not the production deployment story.
- `mix precommit` is the canonical release gate and docs should list what it runs.

## Testing Decisions

- Prioritize tests for `Atp.Transport.WebhookDispatcher`, `Atp.Transport.WebhookDispatcher.AttemptWorker`, `Atp.Transport.Runtime.SessionServer`, `Atp.Transport.SessionIntake`, `Atp.Transport.Runtime`, and CLI behavior only where gaps represent real production behavior.
- Prefer public API, supervised process behavior, telemetry, or durable database state assertions over private implementation assertions.
- Add controller/route tests for `/health` and `/ready`.
- Test readiness success, database failure, dispatcher disabled, dispatcher enabled but unavailable, and sanitized failure responses.
- Run focused tests while iterating.
- Run `mix test`.
- Run `mix test --cover`.
- Run `mix precommit` before the PR is ready for review.

## Acceptance Criteria

- Runtime and dispatcher hardening tests cover real crash, restart, retry, disabled, malformed config, shutdown, or stale-message behavior.
- `GET /health` exists at the root path and returns `200` with minimal JSON.
- `GET /ready` exists at the root path and returns `200` when database and required runtime components are ready.
- `GET /ready` returns `503` when a required readiness check fails.
- Dispatcher disabled by operator config does not fail readiness.
- Probe responses are stable, coarse, and non-sensitive.
- Docs define the single-node production contract.
- Docs list required production env vars and important optional env vars.
- Docs explain database migration expectations.
- Docs explain `/health` and `/ready` semantics.
- Docs document current telemetry/logging events useful to operators.
- Docs include a release checklist centered on `mix precommit`.
- `mix test` passes.
- `mix test --cover` passes, or any remaining uncovered defensive branch is explicitly justified.
- `mix precommit` passes.

## Out of Scope

- `/metrics`.
- Admin/debug endpoints.
- Kubernetes manifests.
- Helm charts.
- Terraform or cloud-provider deployment guides.
- Multi-node runtime operations.
- Queue depth or backlog reporting.
- External recipient webhook checks.
- Hosted ATP service documentation.
- SDK documentation.
- Public protocol shape changes unrelated to probes.

## Further Notes

This PR is intentionally larger than the ideal review slice because the requested workflow is one Ralph run for one PR. Keep the internal order strict: harden existing runtime behavior first, then add probes, then document the final implemented operational contract.
