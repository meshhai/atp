# A2A-Shaped Message Payloads

## Status

Accepted

## Context

ATP should let independently built agents communicate without requiring every client to learn an ATP-specific content format.

The carrier still needs a payload contract strict enough to validate, store, deliver, sign, and replay messages safely. It should not treat free-form maps as internal transport contracts.

## Decision

ATP carries an A2A `Message` subset for message sends, session messages, and ACK payloads. ATP does not implement the full A2A protocol.

The accepted payload contract is:

- `messageId`: required non-empty string
- `role`: required, either `ROLE_USER` or `ROLE_AGENT`
- `contextId`: required non-empty string when `role` is `ROLE_AGENT`
- `parts`: required non-empty list of part objects
- `metadata`: optional object
- `contextId` and `taskId`: optional non-empty strings, except for the `ROLE_AGENT` requirement above
- `extensions` and `referenceTaskIds`: optional lists of strings

Each part object must include exactly one content key:

- `text`: string
- `raw`: string
- `url`: string
- `data`: any JSON value

Each part may also include:

- `metadata`: optional object
- `filename`: optional non-empty string
- `mediaType`: optional non-empty string

The carrier validates the payload shape at ingress and stores it as untrusted JSON. ATP uses its own envelope metadata for transport concerns such as sender, recipient, trust, content type, session id, sequence, timestamps, expiry, deliveries, and ACK state.

ATP sets the carrier content type to `application/a2a+json` and currently reports A2A version `1.0` in message envelopes.

ATP does not interpret A2A payload content as trusted facts and does not execute instructions contained in payloads.

ATP does not currently provide:

- A2A agent-card discovery
- A2A task lifecycle APIs beyond carrying `taskId` fields
- RPC or tool execution
- streaming transport
- artifact or file transfer semantics beyond carrying JSON payload fields

Compatibility posture: ATP validates the subset it carries today and preserves accepted payloads as JSON. Future compatibility work should widen the validator deliberately rather than treating arbitrary maps as valid transport messages.

## Consequences

- Payload validation lives at the transport boundary.
- Message envelopes remain ATP carrier envelopes, not agent runtime objects.
- Webhooks and API responses can include A2A-shaped payloads while preserving ATP delivery metadata.
- Future clients and CLIs can build on a stable message shape without coupling to a downstream product.
- Security docs must continue to state that payloads are untrusted, even when the sender is authenticated.
