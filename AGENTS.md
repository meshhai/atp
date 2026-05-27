# Agent Instructions

ATP is a Phoenix API service for agent-to-agent carrier infrastructure.

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

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix xref graph --format cycles --label compile`
