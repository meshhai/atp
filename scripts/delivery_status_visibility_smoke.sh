#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${ATP_BASE_URL:-http://localhost:4000}"
RUN_ID="${ATP_SMOKE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"

DELIVERED_URL="${ATP_WEBHOOK_DELIVERED_URL:-}"
RETRY_URL="${ATP_WEBHOOK_RETRY_URL:-}"
FAILED_URL="${ATP_WEBHOOK_FAILED_URL:-}"

usage() {
  cat <<'USAGE'
Usage:
  ATP_WEBHOOK_DELIVERED_URL=https://public.example/204 \
  ATP_WEBHOOK_RETRY_URL=https://public.example/503 \
  ATP_WEBHOOK_FAILED_URL=https://public.example/400 \
  bash scripts/delivery_status_visibility_smoke.sh

Optional:
  ATP_BASE_URL=http://localhost:4000
  ATP_SMOKE_ID=delivery-status-smoke

Webhook URLs must be public HTTP(S) URLs. ATP rejects localhost, private IPs,
and documentation-only IP ranges during webhook setup and dispatch.
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_env() {
  if [ -z "$2" ]; then
    echo "Missing required environment variable: $1" >&2
    usage >&2
    exit 1
  fi
}

request() {
  local method="$1"
  local path="$2"
  local token="${3:-}"
  local idempotency_key="${4:-}"
  local body="${5:-}"
  local args=(-fsS -X "$method" "$BASE_URL$path" -H "content-type: application/json")

  if [ -n "$token" ]; then
    args+=(-H "authorization: Bearer $token")
  fi

  if [ -n "$idempotency_key" ]; then
    args+=(-H "idempotency-key: $idempotency_key")
  fi

  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi

  curl "${args[@]}"
}

create_account() {
  request POST /api/accounts "" "" "$(jq -n --arg name "Delivery Visibility Smoke $RUN_ID" '{name: $name}')"
}

register_agent() {
  local account_token="$1"
  local idempotency_key="$2"
  local display_name="$3"

  request POST /api/agents "$account_token" "$idempotency_key" \
    "$(jq -n --arg display_name "$display_name" '{display_name: $display_name}')"
}

configure_webhook() {
  local agent_id="$1"
  local agent_token="$2"
  local idempotency_key="$3"
  local webhook_url="$4"

  request PUT "/api/agents/$agent_id/webhook_endpoint" "$agent_token" "$idempotency_key" \
    "$(jq -n --arg url "$webhook_url" '{url: $url}')"
}

send_message() {
  local sender_token="$1"
  local idempotency_key="$2"
  local recipient_address="$3"
  local client_message_id="$4"
  local text="$5"

  request POST /api/messages "$sender_token" "$idempotency_key" \
    "$(jq -n \
      --arg to "$recipient_address" \
      --arg message_id "$client_message_id" \
      --arg text "$text" \
      '{to: $to, payload: {messageId: $message_id, role: "ROLE_USER", parts: [{text: $text}]}}')"
}

ack_completed() {
  local recipient_token="$1"
  local delivery_id="$2"
  local idempotency_key="$3"

  request POST "/api/deliveries/$delivery_id/acks" "$recipient_token" "$idempotency_key" \
    "$(jq -n \
      --arg message_id "$RUN_ID-delivered-ack" \
      '{status: "completed", payload: {messageId: $message_id, role: "ROLE_AGENT", parts: [{text: "Webhook received and completed."}]}}')"
}

fetch_status() {
  local token="$1"
  local message_id="$2"

  request GET "/api/messages/$message_id" "$token"
}

wait_for_status() {
  local token="$1"
  local message_id="$2"
  local jq_filter="$3"
  local label="$4"
  local status=""

  for _ in $(seq 1 45); do
    status="$(fetch_status "$token" "$message_id")"

    if jq -e "$jq_filter" >/dev/null <<<"$status"; then
      printf '%s' "$status"
      return 0
    fi

    sleep 1
  done

  echo "Timed out waiting for $label on message $message_id" >&2
  jq . >&2 <<<"$status"
  exit 1
}

print_status_summary() {
  jq '{
    message_id: .message.id,
    carrier_status: .carrier_status,
    ack_status: .ack_status,
    deliveries: [
      .deliveries[] | {
        id: .id,
        mode: .mode,
        status: .status,
        attempt_count: .attempt_count,
        max_attempts: .max_attempts,
        claimed_at: .claimed_at,
        leased_until: .leased_until,
        next_attempt_at: .next_attempt_at,
        delivered_at: .delivered_at,
        last_error: .last_error,
        attempts: [
          .attempts[] | {
            attempt_number: .attempt_number,
            response_status: .response_status,
            result: .result,
            error: .error,
            next_attempt_at: .next_attempt_at,
            created_at: .created_at,
            request_url: .request_url
          } | with_entries(select(.value != null))
        ]
      }
    ]
  }'
}

section() {
  printf '\n== %s ==\n' "$1"
}

require_command curl
require_command jq
require_env ATP_WEBHOOK_DELIVERED_URL "$DELIVERED_URL"
require_env ATP_WEBHOOK_RETRY_URL "$RETRY_URL"
require_env ATP_WEBHOOK_FAILED_URL "$FAILED_URL"

echo "ATP delivery status visibility smoke"
echo "base_url: $BASE_URL"
echo "run_id: $RUN_ID"

section "Create account and two agents"
account="$(create_account)"
account_token="$(jq -r '.account_api_key.token' <<<"$account")"
sender="$(register_agent "$account_token" "$RUN_ID-register-sender" "Smoke Sender")"
recipient="$(register_agent "$account_token" "$RUN_ID-register-recipient" "Smoke Recipient")"

sender_token="$(jq -r '.agent_api_key.token' <<<"$sender")"
recipient_id="$(jq -r '.id' <<<"$recipient")"
recipient_token="$(jq -r '.agent_api_key.token' <<<"$recipient")"
recipient_address="$(jq -r '.address' <<<"$recipient")"

jq -n \
  --arg account_id "$(jq -r '.id' <<<"$account")" \
  --arg sender_id "$(jq -r '.id' <<<"$sender")" \
  --arg recipient_id "$recipient_id" \
  --arg recipient_address "$recipient_address" \
  '{account_id: $account_id, sender_id: $sender_id, recipient_id: $recipient_id, recipient_address: $recipient_address}'

section "Delivered webhook message"
configure_webhook "$recipient_id" "$recipient_token" "$RUN_ID-webhook-delivered" "$DELIVERED_URL" >/dev/null
delivered_sent="$(send_message "$sender_token" "$RUN_ID-send-delivered" "$recipient_address" "$RUN_ID-delivered" "Expect delivered webhook status.")"
delivered_message_id="$(jq -r '.message.id' <<<"$delivered_sent")"

echo "Intake response:"
print_status_summary <<<"$delivered_sent"

delivered_status="$(wait_for_status "$sender_token" "$delivered_message_id" '.carrier_status == "delivered" and .deliveries[0].status == "delivered" and .deliveries[0].attempt_count >= 1' "delivered status")"

echo "Sender-visible status after dispatch:"
print_status_summary <<<"$delivered_status"

delivered_delivery_id="$(jq -r '.deliveries[0].id' <<<"$delivered_status")"
ack_completed "$recipient_token" "$delivered_delivery_id" "$RUN_ID-ack-delivered" >/dev/null
acked_status="$(fetch_status "$sender_token" "$delivered_message_id")"

echo "Sender-visible status after recipient ACK:"
print_status_summary <<<"$acked_status"

recipient_delivered_status="$(fetch_status "$recipient_token" "$delivered_message_id")"

echo "Recipient-visible status includes its webhook request URL:"
print_status_summary <<<"$recipient_delivered_status"

section "Retry-scheduled webhook message"
configure_webhook "$recipient_id" "$recipient_token" "$RUN_ID-webhook-retry" "$RETRY_URL" >/dev/null
retry_sent="$(send_message "$sender_token" "$RUN_ID-send-retry" "$recipient_address" "$RUN_ID-retry" "Expect retry-scheduled webhook status.")"
retry_message_id="$(jq -r '.message.id' <<<"$retry_sent")"

echo "Intake response:"
print_status_summary <<<"$retry_sent"

retry_status="$(wait_for_status "$sender_token" "$retry_message_id" '.carrier_status == "queued" and .deliveries[0].status == "retry_scheduled" and .deliveries[0].attempt_count >= 1 and (.deliveries[0].attempts | length) >= 1' "retry-scheduled status")"

echo "Sender-visible status after first retryable attempt:"
print_status_summary <<<"$retry_status"

section "Immediate failed webhook message"
configure_webhook "$recipient_id" "$recipient_token" "$RUN_ID-webhook-failed" "$FAILED_URL" >/dev/null
failed_sent="$(send_message "$sender_token" "$RUN_ID-send-failed" "$recipient_address" "$RUN_ID-failed" "Expect failed webhook status.")"
failed_message_id="$(jq -r '.message.id' <<<"$failed_sent")"

echo "Intake response:"
print_status_summary <<<"$failed_sent"

failed_status="$(wait_for_status "$sender_token" "$failed_message_id" '.carrier_status == "delivery_failed" and .deliveries[0].status == "failed" and .deliveries[0].attempt_count >= 1' "failed status")"

echo "Sender-visible status after non-retryable failure:"
print_status_summary <<<"$failed_status"

section "Done"
echo "Smoke complete. Generated credentials were kept only in this process."
