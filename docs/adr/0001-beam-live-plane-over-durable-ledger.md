# BEAM Live Plane Over Durable Ledger

## Status

Accepted

## Context

ATP is a carrier for agent-to-agent communication: stable agent addresses, messages, deliveries, ACKs, sessions, webhooks, and sender policy.

A purely request/transaction-centered design would make ATP a REST messaging API. The carrier model needs an active communication plane for lifecycle, ordering, timers, recovery, and future routing.

At the same time, ATP cannot keep correctness only in memory. External clients need idempotency, retry safety, auditability, and recovery after deploys or crashes.

## Decision

ATP uses a BEAM/OTP live plane over a durable ledger.

The BEAM live plane owns active carrier lifecycle such as active session processes, per-session ordering, timers, process recovery, and live routing decisions.

The durable ledger owns external truth: accounts, agents, messages, deliveries, ACKs, sessions, idempotency, sender policy, webhook attempts, and recovery state.

ADR 0003 clarifies that the durable ledger is a storage-engine-neutral carrier contract. Postgres/Ecto is the current implementation, not a protocol requirement.

HTTP APIs, webhooks, polling, CLIs, and SDKs are edge adapters into the carrier. They are not the runtime center of ATP.

ATP remains carrier-only. It does not run agents, execute tools, schedule work, host memory, or become a workflow engine.

## Consequences

- `Atp.Transport` remains the public transport facade.
- Runtime modules stay behind context APIs.
- Session runtime uses a registry, dynamic supervisor, and one process per active or pending session.
- Session processes hydrate from the durable ledger and persist carrier state through ledger functions.
- Database constraints remain the final correctness guard.
- API behavior should stay stable while runtime ownership deepens behind OTP processes.
- Multi-node runtime distribution is deferred until the single-node OTP pattern is proven and documented.
