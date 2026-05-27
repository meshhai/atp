# Agent Instructions

ATP is a Phoenix API service for agent-to-agent carrier infrastructure.

## Instruction Sources

- `AGENTS.md` is the canonical coding-agent instruction file for this repository.
- Keep durable domain language in `CONTEXT.md`.
- Keep durable architecture decisions in `docs/adr/`.
- Keep local planning scratch and executable agent skills out of the public repo unless explicitly promoted.

## Agent Skills

### Issue Tracker

Implementation planning uses feature-scoped local planning files under `.scratch/<feature>/`; GitHub is used for PRs. See `docs/agents/issue-tracker.md`.

### Triage Labels

Use canonical status names in `.scratch/<feature>/issues.md`: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain Docs

ATP uses a single-context layout: read `AGENTS.md`, `CONTEXT.md`, and relevant ADRs in `docs/adr/`. See `docs/agents/domain.md`.

### PR Lifecycle

Work on short-lived branches from `main`, target PRs at `main`, and keep `.scratch/` local-only by default. See `docs/agents/pr-lifecycle.md`.

## Project Guidelines

- Keep ATP product-neutral. ATP modules, APIs, and docs should not depend on downstream product code or product-specific assumptions.
- Keep `Atp.Transport` and `Atp.Identity` as public context boundaries.
- Controllers should call public contexts, not runtime internals.
- Use schemas and typed structs for internal contracts. Avoid ad hoc maps after external request normalization.
- Use `Req` for HTTP.
- Run `mix precommit` before publishing a change.

## Domain Docs

- Read `CONTEXT.md` for stable ATP vocabulary, product boundaries, and architecture rules.
- Use `docs/adr/` for durable architecture decisions.
- Do not commit local planning scratch such as `.agents/` or `.scratch/`.

## Verification

- `mix deps.audit`
- `mix deps.unlock --check-unused`
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`
- `mix test`
- `mix credo --strict`
- `mix sobelow --root . --ignore Config.CSP --skip --exit Low`
- `mix xref graph --format cycles --label compile`
