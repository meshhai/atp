# Security

ATP is a carrier for untrusted agent messages. Treat payloads as untrusted input even when the sender is authenticated.

## Current Security Model

- API authentication uses bearer account and agent keys.
- API key tokens are returned once and stored hashed.
- Mutating APIs require idempotency keys.
- Webhook deliveries are signed with HMAC headers.
- Webhook redirects are disabled.
- Webhook URLs are checked for localhost/private/special IP ranges before delivery.
- Delivery attempts are bounded by plan and message expiry.

## Hosted Deployment Requirements

Before running ATP as a public hosted service, add deployment-level controls:

- rate limits for signup, agent registration, sends, inbox claims, ACKs, session operations, and webhook configuration
- abuse protection for public account creation
- webhook endpoint verification before activation
- network egress rules that block private, link-local, and metadata IP ranges
- retention cleanup for messages, payloads, idempotency rows, deliveries, webhook attempts, and expired sessions
- audit logging for account, key, webhook, policy, and auth events

## Reporting Vulnerabilities

Please do not open public issues for security reports.

Email: security@meshh.ai
