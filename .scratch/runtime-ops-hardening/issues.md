# Runtime and Operational Hardening Issues

## ISSUE-001 Establish runtime coverage baseline

Status: ready-for-agent
Type: AFK

### What to build

Run the current test and coverage gates, identify uncovered runtime and dispatcher branches, and record the concrete target list before adding tests.

### Acceptance criteria

- [ ] `mix test` passes on the branch before behavior changes.
- [ ] `mix test --cover` output is reviewed.
- [ ] Lowest runtime and dispatcher coverage modules are identified.
- [ ] Targeted gaps are listed in `.scratch/runtime-ops-hardening/progress.txt`.
- [ ] Coverage work is scoped to production-meaningful runtime, dispatcher, session, and CLI edges.

### Blocked by

None.

## ISSUE-002 Harden webhook dispatcher and attempt worker tests

Status: ready-for-agent
Type: AFK

### What to build

Add tests for dispatcher startup/configuration behavior, disabled behavior, safe wakeup behavior, attempt worker crash/catch safety, shutdown wait paths, and stale worker messages.

### Acceptance criteria

- [ ] Dispatcher disabled mode does not scan, claim, or dispatch work.
- [ ] `WebhookDispatcher.wakeup(nil)` is a safe no-op.
- [ ] Wakeup to a missing/dead dispatcher is a safe no-op.
- [ ] Invalid dispatcher options fall back to safe defaults without crashing.
- [ ] Startup with `dispatch_on_start?: true` is covered deterministically.
- [ ] Raised or caught delivery failures record sanitized task-exit attempts where practical.
- [ ] Dispatcher remains alive after covered worker failure paths.
- [ ] Shutdown and stale worker message branches are covered through observable behavior.

### Blocked by

ISSUE-001.

## ISSUE-003 Harden session runtime edge tests

Status: ready-for-agent
Type: AFK

### What to build

Add tests for session runtime branches that protect ordered webhook dispatch and pending session lifecycle behavior.

### Acceptance criteria

- [ ] Unknown or stale webhook dispatch tickets return expected error or no-op behavior.
- [ ] Releasing a dispatch turn with the wrong token does not release the active owner.
- [ ] Stale monitor messages are ignored safely.
- [ ] Pending session expiry no-op and terminal paths are covered where practical.
- [ ] Tests use public runtime/context behavior where possible and avoid private state unless already established in local tests.

### Blocked by

ISSUE-002.

## ISSUE-004 Add root-level health probe

Status: ready-for-agent
Type: AFK

### What to build

Add an unauthenticated root-level `GET /health` endpoint that returns minimal JSON when the Phoenix app can respond.

### Acceptance criteria

- [ ] `GET /health` is routed outside `/api` auth pipelines.
- [ ] Successful response is HTTP `200`.
- [ ] Response body is stable minimal JSON: `{"status":"ok"}` or equivalent map ordering.
- [ ] Endpoint does not expose config, runtime, process, or carrier state details.
- [ ] Controller/route tests cover unauthenticated access.

### Blocked by

ISSUE-003.

## ISSUE-005 Add readiness boundary with database and runtime checks

Status: ready-for-agent
Type: AFK

### What to build

Create a small readiness boundary that checks whether this single node can receive carrier work and returns coarse sanitized component statuses.

### Acceptance criteria

- [ ] Readiness logic is isolated from controller response formatting.
- [ ] Checks include database, transport runtime, and webhook dispatcher.
- [ ] Database readiness uses a cheap query and verifies migration/schema compatibility enough to catch unusable schema state.
- [ ] Enabled webhook dispatcher must be alive/available for readiness to pass.
- [ ] Disabled webhook dispatcher reports `disabled` and does not fail readiness.
- [ ] Result statuses are coarse strings such as `ok`, `error`, and `disabled`.
- [ ] Public output excludes SQL, adapter errors, migration versions, database names, URLs, PIDs, node names, exception text, IDs, queue depths, tokens, and webhook URLs.
- [ ] Tests cover success, database failure, dispatcher disabled, dispatcher enabled/missing, and sanitized output.

### Blocked by

ISSUE-004.

## ISSUE-006 Add root-level ready endpoint and HTTP semantics

Status: ready-for-agent
Type: AFK

### What to build

Expose `GET /ready` using the readiness boundary and return correct HTTP status codes.

### Acceptance criteria

- [ ] `GET /ready` is routed outside `/api` auth pipelines.
- [ ] Ready response returns HTTP `200`.
- [ ] Not-ready response returns HTTP `503`.
- [ ] Response includes top-level `status` and coarse `checks`.
- [ ] Response excludes secrets, PIDs, node names, migration versions, exception text, IDs, queue depths, and webhook URLs.
- [ ] Tests cover unauthenticated success and failure responses.

### Blocked by

ISSUE-005.

## ISSUE-007 Document single-node production operations

Status: ready-for-agent
Type: AFK

### What to build

Add public docs for ATP's single-node production contract, configuration, migration expectations, and probe semantics.

### Acceptance criteria

- [ ] Docs distinguish production deployment from local Docker Compose development.
- [ ] Docs state ATP is a carrier service, not an agent host, tool runner, workflow engine, scheduler, or memory layer.
- [ ] Docs describe the single-node assumption without implying multi-node support is complete.
- [ ] Required env vars are documented, including database URL and secret key base expectations.
- [ ] Optional env vars are documented where the app already supports them.
- [ ] Docs say migrations are run explicitly before traffic is promoted.
- [ ] `/health` and `/ready` HTTP semantics are documented.
- [ ] Docs state readiness does not check recipient webhooks, agent availability, backlog, queue emptiness, external dependencies, or downstream products.

### Blocked by

ISSUE-006.

## ISSUE-008 Document telemetry, logging, and release checklist

Status: ready-for-agent
Type: AFK

### What to build

Document current telemetry/logging signals and add an OSS-ready release checklist.

### Acceptance criteria

- [ ] Current webhook dispatcher telemetry event names are documented.
- [ ] Docs explain when each event fires.
- [ ] Docs identify safe metadata fields at a coarse level.
- [ ] Docs state what is intentionally not logged or exposed, such as tokens, webhook URLs, payload content, and delivery internals.
- [ ] `mix precommit` is documented as the canonical release gate.
- [ ] Checklist lists the commands included in `mix precommit`.
- [ ] Checklist includes migration, probe, and smoke-test considerations.
- [ ] Docs do not introduce a release process that conflicts with `docs/agents/pr-lifecycle.md`.

### Blocked by

ISSUE-007.

## ISSUE-009 Verify combined PR and keep scope production-focused

Status: ready-for-agent
Type: AFK

### What to build

Run verification and confirm the combined PR stays focused on single-node runtime and operational readiness.

### Acceptance criteria

- [ ] `mix test` passes.
- [ ] `mix test --cover` passes or remaining exclusions are explicitly justified in PR notes.
- [ ] `mix precommit` passes.
- [ ] Diff does not add metrics endpoints, admin/debug APIs, Kubernetes manifests, hosted-service assumptions, multi-node operational promises, or unrelated refactors.
- [ ] Probe responses are manually inspected for sensitive data leakage.
- [ ] `.scratch/` remains local-only and is cleaned before publishing unless explicitly requested.

### Blocked by

ISSUE-008.
