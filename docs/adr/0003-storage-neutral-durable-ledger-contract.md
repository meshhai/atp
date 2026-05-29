# Storage-Neutral Durable Ledger Contract

## Status

Accepted

## Context

ATP is a BEAM/OTP-native carrier for durable agent-to-agent message delivery.

ADR 0001 established the split between the BEAM live plane and a durable ledger. That decision remains correct: carrier correctness cannot depend only on memory. ATP needs durable state for addresses, messages, deliveries, ACKs, sessions, idempotency, sender policy, webhook attempts, and recovery.

The original implementation uses Postgres/Ecto as the durable ledger. That is a production-grade first implementation, but it should not become a protocol assumption. ATP should be able to define carrier semantics independently from one storage engine.

## Decision

ATP defines the durable ledger as a storage-engine-neutral carrier contract.

The protocol requires durable ledger semantics, not Postgres specifically. A ledger implementation must preserve the same external correctness guarantees for committed carrier state, including atomic mutation, recovery after crashes, idempotent mutation behavior, delivery ownership, leases, stale-claim rejection, ordered session delivery, and observable delivery attempts.

Postgres/Ecto remains the only production ledger implementation today.

New ledger capabilities should move behind explicit context-owned boundaries incrementally. The first implementation slice is the delivery claim capability: claiming due delivery work, claiming by delivery id, validating claim leases, finishing claimed delivery, terminalizing claimed delivery, recording attempts, and preserving session-order eligibility.

## Prior Art

Messaging protocols usually specify transfer semantics, responsibility, durability, acknowledgement, settlement, and recovery without requiring one storage engine.

- SMTP defines mail transfer, relaying, queueing, and responsibility handoff while leaving server storage implementation open. See RFC 5321.
- AMQP 1.0 separates the network protocol from broker architectures and defines message responsibility transfer, acknowledgement lifecycle, safe storage, transactions, and resume behavior. See OASIS AMQP 1.0.
- Time-bounded leases are established distributed-systems prior art for safe ownership under communication and host failure. See Gray and Cheriton, "Leases: An Efficient Fault-Tolerant Mechanism for Distributed File Cache Consistency."
- Modern durable stores expose different mechanisms for equivalent correctness guarantees: Postgres row locks and transactions, distributed SQL serializable/external-consistency transactions, transactional key-value stores, and conditional/transactional writes.

These examples support ATP's design direction: define carrier semantics first, then require each durable ledger adapter to prove those semantics through contract tests.

## Consequences

- ATP keeps the durable ledger concept from ADR 0001.
- Docs and code should avoid describing Postgres as a protocol requirement.
- `Atp.Transport` remains the public transport facade.
- Store abstractions should be named around durable ledger semantics, not narrow storage tables.
- A future ledger adapter must satisfy contract tests before being considered production-capable.
- PRs should migrate real capabilities behind the boundary one at a time instead of introducing speculative callbacks for the whole ledger.
- Postgres-specific details such as row locks and `SKIP LOCKED` may remain inside the Postgres/Ecto adapter, but the exposed contract must be stated in carrier terms.
