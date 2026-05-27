# ATP Context

ATP is the Agent Transport Protocol: a BEAM-native carrier for agent-to-agent communication.

This file records stable domain language and boundaries for contributors and coding agents. It is not a task tracker. Use ADRs in `docs/adr/` for durable architecture decisions and keep local planning scratch out of the repository.

## Purpose

ATP gives independently built agents a common carrier layer:

- stable agent addresses
- durable A2A-shaped messages
- delivery records
- ACK lifecycle
- inbox polling
- signed webhooks
- ordered sessions
- idempotent mutation APIs

ATP is infrastructure. It lets agents communicate; it does not become the agent.

## Product Boundary

ATP does not:

- host agents
- run tools
- execute tasks
- schedule workflows
- store long-term agent memory
- interpret message payloads as trusted facts
- depend on any downstream product domain

The carrier authenticates senders, persists transport state, and delivers messages. Agent behavior, tools, memory, and reasoning live outside ATP.

## Core Terms

**Account**: The billing or ownership container for one or more agents.

**Agent**: A registered communication principal. Each active agent has an address and an agent API key.

**Address**: Stable routing identifier for an agent, currently shaped as `atp://agent/<agent_id>`.

**Message**: Durable payload sent from one agent to another. ATP validates the payload shape and stores carrier metadata, but the payload remains untrusted agent content.

**Delivery**: Carrier attempt to make a message available to the recipient. Deliveries can be claimed by inbox polling or sent by webhook.

**ACK**: Recipient acknowledgement of a delivery. Current statuses are `accepted`, `completed`, `failed`, and `rejected`.

**Session**: Ordered communication channel between two distinct agents. Sessions begin with an opening message and become open when the recipient accepts the opening delivery.

**Webhook endpoint**: Recipient-owned HTTP endpoint for signed push delivery.

**Sender policy**: Recipient-owned allow/block/trust policy for senders.

**Idempotency key**: Client-provided key that makes mutation retries safe for the same principal, route, and request body.

**Durable ledger**: Postgres-backed source of truth for identity, messages, deliveries, ACKs, sessions, policies, and idempotency.

**Live plane**: BEAM/OTP runtime layer for active carrier operations such as session processes, per-session ordering, timers, and recovery.

**Edge adapter**: HTTP API, webhook, polling, CLI, or SDK surface that enters the carrier. Edge adapters are not the source of truth.

## Architecture Rules

- `Atp.Identity` owns account, agent, API-key, webhook endpoint, and authentication policy.
- `Atp.Transport` owns messages, deliveries, ACKs, sessions, webhooks, sender policies, and runtime entry points.
- `AtpWeb` controllers call public contexts, not runtime internals.
- Postgres remains the source of truth for external correctness.
- BEAM/OTP owns the live session runtime, but live processes hydrate from and persist through the ledger.
- Internal contracts should use schemas, typed structs, changesets, or explicit modules. Bare maps are acceptable at external request boundaries before normalization.
- Public functions should have meaningful specs where they define context contracts.
- Transport response shaping should stay outside transaction-heavy ledger logic where practical.
- ATP code and docs should stay product-neutral.

## Documentation Map

- `README.md`: quickstart, demo, local setup, and public entry point.
- `SECURITY.md`: security posture and vulnerability contact.
- `AGENTS.md`: coding-agent instructions for this repository.
- `CONTEXT.md`: stable domain vocabulary and boundaries.
- `docs/adr/`: accepted architecture decisions.
