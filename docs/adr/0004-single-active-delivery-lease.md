# Single Active Delivery Lease

## Status

Accepted

## Context

ATP is a carrier for durable agent-to-agent message delivery. A recipient can
receive a message through multiple delivery surfaces, including inbox polling
and signed webhooks.

Those surfaces are alternative ways to make the same carrier message available
to the same recipient. If ATP allows polling and webhook workers to actively own
the same message at the same time, high-throughput systems can duplicate work,
weaken backpressure, and make ACK settlement harder to reason about.

ATP does not claim exactly-once delivery. Network failures, client retries, and
lease expiry mean delivery remains at-least-once over time. The question is
whether ATP should intentionally run concurrent active delivery leases for the
same recipient/message.

## Decision

ATP allows at most one active delivery lease per recipient/message across all
delivery modes.

Polling and webhook delivery are alternative delivery surfaces for one carrier
obligation. They are not independent concurrent workers for the same message.

If a message already has an active polling lease, webhook delivery claims for
that message must be hidden or rejected as in progress. If a message already has
an active webhook lease, polling inbox claims must not return that message.

When a lease expires, another delivery mode may become eligible. When the
recipient ACKs the message, remaining delivery work for that message must stop,
terminalize, or remain invisible according to the ACK lifecycle.

## Consequences

- ATP preserves at-least-once delivery over time, not exactly-once delivery.
- ATP avoids intentional concurrent duplicate delivery work for the same
  recipient/message.
- Polling claim eligibility and webhook claim eligibility must both consider
  active leases across all delivery modes.
- Future durable ledger adapters must prove this invariant through contract
  tests.
- Future fanout-style notification behavior, if added, must be modeled as a
  separate carrier capability rather than weakening delivery lease ownership.
