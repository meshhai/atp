#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_url="${ATP_BASE_URL:-http://localhost:4000}"
run_id="${ATP_SMOKE_ID:-$(date -u +%Y%m%d%H%M%S)-$RANDOM}"
sender_alias="smoke-sender-$run_id"
recipient_alias="smoke-recipient-$run_id"
created_smoke_home=0

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/cli_two_agent_smoke.sh

Optional:
  ATP_BASE_URL=http://localhost:4000
  ATP_CLI_BIN=/path/to/atp
  ATP_SMOKE_HOME=/tmp/atp-cli-smoke
  ATP_SMOKE_ID=cli-smoke
  ATP_SMOKE_KEEP_HOME=1

The smoke uses public CLI commands against a running ATP HTTP server. It creates
an isolated ATP_HOME for generated local credentials and does not print tokens.
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_cli() {
  if [ -n "${ATP_CLI_BIN:-}" ]; then
    if [ ! -x "$ATP_CLI_BIN" ]; then
      echo "ATP_CLI_BIN is not executable: $ATP_CLI_BIN" >&2
      exit 1
    fi

    printf '%s\n' "$ATP_CLI_BIN"
    return
  fi

  if [ -x "$repo_root/atp" ]; then
    printf '%s\n' "$repo_root/atp"
    return
  fi

  if command -v atp >/dev/null 2>&1; then
    command -v atp
    return
  fi

  cat >&2 <<'ERROR'
Missing ATP CLI executable.

Build the local CLI first:
  mix escript.build

Or pass a specific binary:
  ATP_CLI_BIN=/path/to/atp bash scripts/cli_two_agent_smoke.sh
ERROR
  exit 1
}

cleanup() {
  if [ "$created_smoke_home" -eq 1 ] && [ "${ATP_SMOKE_KEEP_HOME:-0}" != "1" ]; then
    rm -rf "$ATP_HOME"
  fi
}

section() {
  printf '\n== %s ==\n' "$1"
}

run_atp() {
  ATP_HOME="$ATP_HOME" "$atp_cli" "$@"
}

extract_field() {
  local label="$1"
  awk -v label="$label" -F': ' '$1 == label {print $2; exit}'
}

require_field() {
  local label="$1"
  local output="$2"
  local value

  value="$(printf '%s\n' "$output" | extract_field "$label")"

  if [ -z "$value" ] || [ "$value" = "none" ]; then
    echo "Could not find required field '$label' in CLI output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  printf '%s\n' "$value"
}

require_output() {
  local output="$1"
  local expected="$2"
  local label="$3"

  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Expected $label to include: $expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_no_secrets() {
  local output="$1"
  local label="$2"

  if grep -Eiq '(Bearer |authorization|account_token|agent_token|ak_[A-Za-z0-9]|agk_[A-Za-z0-9]|whsec_|signature)' <<<"$output"; then
    echo "Refusing to print secret-like output from $label" >&2
    exit 1
  fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

require_command awk
require_command grep

atp_cli="$(resolve_cli)"

if [ -n "${ATP_SMOKE_HOME:-}" ]; then
  mkdir -p "$ATP_SMOKE_HOME"
  ATP_HOME="$ATP_SMOKE_HOME"
else
  created_smoke_home=1
  ATP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/atp-cli-smoke.XXXXXX")"
fi

export ATP_HOME
trap cleanup EXIT

echo "ATP CLI two-agent smoke"
echo "base_url: $base_url"
echo "atp_cli: $atp_cli"
echo "atp_home: $ATP_HOME"
echo "run_id: $run_id"

section "Initialize isolated CLI state"
init_output="$(run_atp init --server "$base_url")"
assert_no_secrets "$init_output" "init"
require_output "$init_output" "ATP account initialized." "init output"
require_output "$init_output" "No default agent was created." "init output"

section "Register two local aliases"
sender_output="$(run_atp agent create "$sender_alias")"
recipient_output="$(run_atp agent create "$recipient_alias")"
assert_no_secrets "$sender_output" "sender registration"
assert_no_secrets "$recipient_output" "recipient registration"
sender_address="$(require_field "Address" "$sender_output")"
recipient_address="$(require_field "Address" "$recipient_output")"
printf 'sender: %s (%s)\n' "$sender_alias" "$sender_address"
printf 'recipient: %s (%s)\n' "$recipient_alias" "$recipient_address"

section "Send, claim, ACK, and inspect a direct message"
send_output="$(run_atp send "$recipient_alias" "direct smoke message from $sender_alias" --as "$sender_alias")"
assert_no_secrets "$send_output" "message send"
message_id="$(require_field "Message" "$send_output")"
printf '%s\n' "$send_output"

status_before_ack="$(run_atp message status "$message_id" --as "$sender_alias")"
assert_no_secrets "$status_before_ack" "message status before ACK"
require_output "$status_before_ack" "Message: $message_id" "message status before ACK"
require_output "$status_before_ack" "Carrier status: queued" "message status before ACK"
printf '%s\n' "$status_before_ack"

inbox_output="$(run_atp inbox --as "$recipient_alias")"
assert_no_secrets "$inbox_output" "inbox claim"
delivery_id="$(require_field "Delivery" "$inbox_output")"
require_output "$inbox_output" "Message: $message_id" "inbox claim"
printf '%s\n' "$inbox_output"

ack_output="$(run_atp ack "$delivery_id" --completed "direct smoke message completed" --as "$recipient_alias")"
assert_no_secrets "$ack_output" "ACK"
require_output "$ack_output" "ACK completed." "ACK output"
require_output "$ack_output" "Message: $message_id" "ACK output"
printf '%s\n' "$ack_output"

status_after_ack="$(run_atp message status "$message_id" --as "$sender_alias")"
assert_no_secrets "$status_after_ack" "message status after ACK"
require_output "$status_after_ack" "Carrier status: delivered" "message status after ACK"
require_output "$status_after_ack" "ACK status: completed" "message status after ACK"
printf '%s\n' "$status_after_ack"

section "Open, accept, exchange turns, and show an ordered session"
open_output="$(run_atp session open "$recipient_alias" "open smoke session" --as "$sender_alias")"
assert_no_secrets "$open_output" "session open"
session_id="$(require_field "Session" "$open_output")"
printf '%s\n' "$open_output"

accept_output="$(run_atp session accept "$session_id" --as "$recipient_alias")"
assert_no_secrets "$accept_output" "session accept"
require_output "$accept_output" "Session accepted." "session accept"
printf '%s\n' "$accept_output"

recipient_reply_output="$(
  run_atp session send "$session_id" \
    "recipient smoke reply" \
    --as "$recipient_alias"
)"
assert_no_secrets "$recipient_reply_output" "recipient session reply"
require_output "$recipient_reply_output" "Session message sent." "recipient session reply"
printf '%s\n' "$recipient_reply_output"

sender_reply_output="$(
  run_atp session send "$session_id" \
    "sender smoke follow-up" \
    --as "$sender_alias"
)"
assert_no_secrets "$sender_reply_output" "sender session reply"
require_output "$sender_reply_output" "Session message sent." "sender session reply"
printf '%s\n' "$sender_reply_output"

show_output="$(run_atp session show "$session_id" --as "$sender_alias")"
assert_no_secrets "$show_output" "session show"
require_output "$show_output" "Session: $session_id" "session show"
require_output "$show_output" "Delivery" "session show"
require_output "$show_output" "ACK" "session show"
require_output "$show_output" "open smoke session" "session show"
require_output "$show_output" "recipient smoke reply" "session show"
require_output "$show_output" "sender smoke follow-up" "session show"
printf '%s\n' "$show_output"

section "Smoke complete"
echo "direct_message: $message_id"
echo "session: $session_id"

if [ "$created_smoke_home" -eq 1 ] && [ "${ATP_SMOKE_KEEP_HOME:-0}" = "1" ]; then
  echo "kept_atp_home: $ATP_HOME"
fi
