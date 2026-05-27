# Domain Docs

How contributors and coding agents should consume ATP domain and architecture documentation.

## Before Exploring

Read these first:

- `AGENTS.md` for current coding-agent and repository workflow rules.
- `CONTEXT.md` for stable ATP vocabulary, product boundaries, and architecture rules.
- `docs/adr/` for accepted architecture decisions that touch the area being changed.

If a future `CONTEXT-MAP.md` exists, follow it as the source of context boundaries.

## Layout

ATP currently uses a single-context layout:

```text
/
├── AGENTS.md
├── CONTEXT.md
├── docs/
│   ├── adr/
│   └── agents/
├── lib/
│   ├── atp/
│   └── atp_web/
└── test/
```

## Use Project Vocabulary

Use the terms defined in `CONTEXT.md`: account, agent, address, message, delivery, ACK, session, webhook endpoint, sender policy, idempotency key, durable ledger, live plane, and edge adapter.

If a concept is missing from the glossary, either avoid inventing new language or call out the gap for a docs/design pass.

## Respect ATP Boundaries

- `Atp.Identity` owns account, agent, API-key, webhook endpoint, and authentication policy.
- `Atp.Transport` owns messages, deliveries, ACKs, sessions, webhooks, sender policies, and runtime entry points.
- `AtpWeb` controllers should call public contexts, not runtime internals.
- Postgres is the durable source of truth.
- BEAM/OTP owns the live runtime, but live processes hydrate from and persist through the durable ledger.
- Keep ATP product-neutral. Do not introduce downstream product assumptions.

## ADR Conflicts

If a proposed change contradicts an existing ADR, surface the conflict explicitly instead of silently overriding it.
