# A2A-Shaped Message Payloads

## Status

Accepted

## Context

ATP should let independently built agents communicate without requiring every client to learn an ATP-specific content format.

The carrier still needs a payload contract strict enough to validate, store, deliver, sign, and replay messages safely. It should not treat free-form maps as internal transport contracts.

## Decision

ATP accepts A2A-shaped message payloads for message sends, session messages, and ACK payloads.

The carrier validates the payload shape at ingress and stores it as untrusted JSON. ATP uses its own envelope metadata for transport concerns such as sender, recipient, trust, content type, session id, sequence, timestamps, expiry, deliveries, and ACK state.

ATP does not interpret A2A payload content as trusted facts and does not execute instructions contained in payloads.

## Consequences

- Payload validation lives at the transport boundary.
- Message envelopes remain ATP carrier envelopes, not agent runtime objects.
- Webhooks and API responses can include A2A-shaped payloads while preserving ATP delivery metadata.
- Future clients and CLIs can build on a stable message shape without coupling to a downstream product.
- Security docs must continue to state that payloads are untrusted, even when the sender is authenticated.
