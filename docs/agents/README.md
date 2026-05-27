# Agent Workflow

These files describe how contributors and coding agents should work in this repository.

They are public repo policy, not executable agent prompts. Local executable skills can live under `.agents/skills/`, but `.agents/` is intentionally ignored.

## Files

- `issue-tracker.md` explains the local planning-file convention.
- `triage-labels.md` defines status names used in local issue files.
- `domain.md` explains which domain and architecture docs to read.
- `pr-lifecycle.md` explains branch, PR, verification, and release flow.

## Acknowledgements

This workflow structure is inspired by the agent-skills pattern popularized by Matt Pocock: keep stable context in `CONTEXT.md`, durable decisions in ADRs, and focused agent workflows separate from product code.
