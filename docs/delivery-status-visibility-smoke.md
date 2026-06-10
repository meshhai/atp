# Delivery Status Visibility Smoke

This smoke scenario verifies the public status path for asynchronous webhook delivery. It creates one account, registers a sender and recipient agent, sends webhook-backed messages, reads `GET /api/messages/:id` before and after delivery work, ACKs the delivered message, and shows retry and failed delivery states.

The smoke uses public HTTP API surfaces only. It does not call Transport internals, database helpers, the live runtime, or test-only webhook stubs.

## Prerequisites

Start ATP locally:

```sh
docker compose up -d postgres
mix deps.get
mix ecto.setup
mix phx.server
```

In another shell, provide three webhook URLs that you control:

- `ATP_WEBHOOK_DELIVERED_URL`: returns any 2xx status, such as `204`.
- `ATP_WEBHOOK_RETRY_URL`: returns `429` or `5xx`, such as `503`, so ATP records `retry_scheduled`.
- `ATP_WEBHOOK_FAILED_URL`: returns a non-retryable non-2xx status, such as `400`, so ATP records `failed`.

ATP intentionally rejects localhost, private IPs, and documentation-only IP ranges for webhook endpoints. For local receiver code, expose it through a public HTTPS tunnel or another public endpoint you control.

## Run

```sh
ATP_WEBHOOK_DELIVERED_URL=https://your-public-endpoint.example/delivered \
ATP_WEBHOOK_RETRY_URL=https://your-public-endpoint.example/retry \
ATP_WEBHOOK_FAILED_URL=https://your-public-endpoint.example/failed \
bash scripts/delivery_status_visibility_smoke.sh
```

Optional environment:

```sh
ATP_BASE_URL=http://localhost:4000
ATP_SMOKE_ID=delivery-status-smoke
```

## Expected Visibility

The script prints summarized message status responses. The important transitions are:

- delivered case: intake returns `carrier_status: queued`; `GET /api/messages/:id` later shows the webhook delivery as `delivered`, then `ack_status: completed` after the recipient ACK.
- retry case: intake returns `queued`; after the first retryable webhook response, message status stays `queued`, the delivery is `retry_scheduled`, `attempt_count` is at least `1`, and `next_attempt_at` is populated.
- failed case: intake returns `queued`; after a non-retryable webhook response, message status shows `carrier_status: delivery_failed` and the delivery is `failed`.
- sender-visible attempt entries include attempt number, response status, result, sanitized error, retry time, and creation time.
- recipient-visible attempt entries include the recipient's webhook `request_url`; sender-visible reads do not.

The script keeps generated account and agent credentials in process memory only and does not write token files.
