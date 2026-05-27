# PR Lifecycle

How contributors and coding agents should plan, publish, and verify ATP work.

## Branches

- Work in a short-lived feature or fix branch.
- Branch from `main` unless the user explicitly asks for another base.
- Target PRs at `main` unless the user explicitly says otherwise.
- Do not commit directly to `main` unless the user explicitly asks for that exact action.
- Do not amend pushed commits unless the user explicitly asks.
- Push only when the user asks.

## Local Planning

- Use `.scratch/<feature>/prd.md`, `.scratch/<feature>/issues.md`, and `.scratch/<feature>/progress.txt` for local agent-driven planning.
- Keep `.scratch/` and `.agents/` out of public commits by default.
- Promote durable domain language to `CONTEXT.md`.
- Promote durable architecture decisions to `docs/adr/`.
- Promote public workflow policy to `docs/agents/`.

## Implementation PRs

- Keep PRs narrow and independently reviewable.
- Prefer vertical slices that are demoable or verifiable on their own.
- Reference relevant ADRs or planning summaries in the PR body when useful.
- Do not invent new domain language silently. Update `CONTEXT.md` or call out the vocabulary gap.

## Verification

Run the narrow relevant check first, then broaden.

Recommended full local gate:

```sh
mix deps.audit
mix deps.unlock --check-unused
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix sobelow --root . --ignore Config.CSP --skip --exit Low
mix xref graph --format cycles --label compile
```

Run `mix precommit` when available and appropriate. If verification cannot run because dependencies, Postgres, credentials, network access for advisories, or services are unavailable, state the exact command attempted and the blocker.

## Releases

- Cut release tags only from integrated `main`.
- Do not tag feature-branch commits for public releases.
- Before tagging, verify the target commit contains the expected release ancestry.
