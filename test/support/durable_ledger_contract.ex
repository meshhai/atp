defmodule Atp.Support.DurableLedgerContract do
  @moduledoc """
  Reusable ExUnit contract for durable ledger adapters.

  Adapter-specific test modules `use` this contract with an `:adapter` and a
  `:harness`. The shared contract exercises carrier semantics through the
  `Atp.Transport.DurableLedger` callback shape. Adapter-specific setup,
  persistence reads, and state mutations live in the harness.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    harness = Keyword.fetch!(opts, :harness)
    case_template = Keyword.get(opts, :case_template, Atp.ConnCase)
    cases = contract_cases()

    quote do
      use unquote(case_template), async: false

      alias Atp.Support.DurableLedgerContract

      @ledger_adapter unquote(adapter)
      @ledger_harness unquote(harness)

      unquote_splicing(
        for {name, assertion, key} <- cases do
          quote do
            test unquote(name), %{conn: conn} do
              apply(DurableLedgerContract, unquote(assertion), [
                @ledger_adapter,
                @ledger_harness,
                conn,
                unquote(key)
              ])
            end
          end
        end
      )
    end
  end

  @spec contract_cases() :: [{String.t(), atom(), String.t()}]
  def contract_cases do
    [
      {"contract: one claimant receives a due delivery and active leases block duplicate work",
       :assert_single_claimant, "single-claimant"},
      {"contract: expired delivery leases can be reclaimed", :assert_lease_reclaim,
       "lease-reclaim"},
      {"contract: stale claims cannot finish or terminalize delivery",
       :assert_stale_claim_rejection, "stale-claim"},
      {"contract: attempts atomically update delivery and message state",
       :assert_attempt_recording, "attempt-recording"},
      {"contract: claimed ACKed and expired messages terminalize without attempts",
       :assert_claim_terminalization, "claimed-terminal"},
      {"contract: due ACKed and expired messages terminalize without attempts",
       :assert_due_claim_terminalization, "due-terminal"},
      {"contract: direct ACKed and expired messages terminalize without attempts",
       :assert_direct_claim_terminalization, "direct-terminal"},
      {"contract: direct message intake replays stable idempotent responses",
       :assert_direct_message_idempotent_replay, "direct-replay"},
      {"contract: concurrent direct message retries create one committed message",
       :assert_concurrent_direct_message_idempotency, "direct-concurrent"},
      {"contract: direct message intake rejects idempotency body conflicts",
       :assert_direct_message_idempotency_conflict, "direct-conflict"},
      {"contract: direct message idempotency is scoped by sender principal",
       :assert_direct_message_idempotency_principal_scope, "direct-principal-scope"},
      {"contract: invalid direct message payloads do not create carrier work",
       :assert_invalid_direct_message_payload_no_carrier_work, "direct-invalid-payload"},
      {"contract: missing direct message recipients do not create carrier work",
       :assert_missing_direct_message_recipient_no_carrier_work, "direct-missing-recipient"},
      {"contract: blocked direct message intake creates no delivery work",
       :assert_blocked_direct_message_no_delivery_work, "direct-blocked"},
      {"contract: successful direct message intake creates message state and delivery work",
       :assert_successful_direct_message_intake, "direct-success"},
      {"contract: message status reads preserve participant visibility",
       :assert_message_status_reads, "message-status-reads"},
      {"contract: session open replays stable idempotent responses",
       :assert_open_session_idempotent_replay, "session-open-replay"},
      {"contract: concurrent session open retries create one committed session",
       :assert_concurrent_open_session_idempotency, "session-open-concurrent"},
      {"contract: session open rejects idempotency body conflicts",
       :assert_open_session_idempotency_conflict, "session-open-conflict"},
      {"contract: invalid session open requests do not create carrier work",
       :assert_invalid_session_open_no_carrier_work, "session-open-invalid"},
      {"contract: blocked session open creates no delivery work",
       :assert_blocked_session_open_no_delivery_work, "session-open-blocked"},
      {"contract: successful session open creates session state and delivery work",
       :assert_successful_session_open, "session-open-success"},
      {"contract: session transcript reads preserve participant visibility and order",
       :assert_session_transcript_reads, "session-transcript-reads"},
      {"contract: session accept records ACK and opens the pending session",
       :assert_successful_session_accept, "session-accept-success"},
      {"contract: session accept replays and conflicts idempotently",
       :assert_session_accept_idempotency, "session-accept-idempotency"},
      {"contract: session accept enforces recipient authorization and ACK payload policy",
       :assert_session_accept_authorization_and_payload_checks, "session-accept-checks"},
      {"contract: session reject records ACK and terminalizes the pending session",
       :assert_successful_session_reject, "session-reject-success"},
      {"contract: session reject replays and conflicts idempotently",
       :assert_session_reject_idempotency, "session-reject-idempotency"},
      {"contract: session reject enforces recipient authorization and ACK payload policy",
       :assert_session_reject_authorization_and_payload_checks, "session-reject-checks"},
      {"contract: expired session openings cannot be accepted or rejected",
       :assert_expired_session_lifecycle, "session-lifecycle-expired"},
      {"contract: delivery ACK records polling ACKs and enforces terminal transitions",
       :assert_delivery_ack_polling_success_and_transitions, "delivery-ack-polling"},
      {"contract: delivered webhook deliveries can be ACKed",
       :assert_delivery_ack_delivered_webhook, "delivery-ack-webhook"},
      {"contract: delivery ACK validates ownership, leases, and webhook delivery state",
       :assert_delivery_ack_delivery_validation, "delivery-ack-validation"},
      {"contract: delivery ACK validates status, payload, and idempotency",
       :assert_delivery_ack_request_validation_and_idempotency, "delivery-ack-request"},
      {"contract: opening delivery ACK updates durable session state",
       :assert_delivery_ack_opening_session_side_effects, "delivery-ack-opening"},
      {"contract: opening delivery lookup returns only recipient-owned opening sessions",
       :assert_opening_session_delivery_lookup, "opening-delivery-lookup"},
      {"contract: expired opening delivery ACK fails the pending session",
       :assert_delivery_ack_expired_opening_session, "delivery-ack-expired-opening"},
      {"contract: pending opening expiry atomically fails the session and opening",
       :assert_pending_opening_expiry, "pending-opening-expiry"},
      {"contract: polling inbox claim creates a recipient-owned lease",
       :assert_polling_claim_success, "polling-claim-success"},
      {"contract: polling inbox claim returns an empty stable response",
       :assert_polling_empty_inbox, "polling-empty-inbox"},
      {"contract: polling active leases hide messages until expiry",
       :assert_polling_active_lease_reclaim, "polling-active-reclaim"},
      {"contract: active polling leases block webhook claims for the same message",
       :assert_polling_lease_blocks_webhook_claims, "polling-blocks-webhook"},
      {"contract: polling claims exclude ACKed and expired messages",
       :assert_polling_claim_visibility, "polling-claim-visibility"},
      {"contract: polling lease extension validates ownership and lease state",
       :assert_polling_lease_extension, "polling-lease-extension"},
      {"contract: polling session claims preserve message order",
       :assert_polling_session_ordering, "polling-session-order"},
      {"contract: sender policy upsert is recipient-owned and idempotent",
       :assert_sender_policy_upsert, "sender-policy-upsert"},
      {"contract: runtime session helpers expose only durable active sessions",
       :assert_runtime_session_helpers, "runtime-session-helpers"},
      {"contract: session message send replays stable idempotent responses",
       :assert_session_message_idempotent_replay, "session-send-replay"},
      {"contract: session message send rejects idempotency body conflicts",
       :assert_session_message_idempotency_conflict, "session-send-conflict"},
      {"contract: session message send requires an open participant session",
       :assert_session_message_participant_and_open_session_checks, "session-send-checks"},
      {"contract: blocked session message send creates no delivery work",
       :assert_blocked_session_message_no_delivery_work, "session-send-blocked"},
      {"contract: successful session message send creates message state and delivery work",
       :assert_successful_session_message_send, "session-send-success"},
      {"contract: concurrent session message retries create one committed message",
       :assert_concurrent_session_message_idempotency, "session-send-concurrent"},
      {"contract: session webhook delivery order is preserved", :assert_session_ordering,
       "session-order"}
    ]
  end

  import ExUnit.Assertions

  alias Atp.Identity.Idempotency
  alias Atp.Transport.{Delivery, DeliveryClaim, Message, Session, WebhookAttempt}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @direct_message_route "POST /api/messages"
  @session_open_route "POST /api/sessions"
  @polling_claim_route "POST /api/inbox/claims"

  @type harness :: module()

  @spec assert_single_claimant(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_single_claimant(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {delivery, _message, _recipient_agent} = harness.prepare_due_webhook_delivery!(conn, key)

    results =
      1..2
      |> Task.async_stream(
        fn _index -> claim_due(adapter, lease_seconds: 60) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    claims = for {:ok, %DeliveryClaim{} = claim} <- results, do: claim

    assert [%DeliveryClaim{} = claim] = claims
    assert claim.delivery.id == delivery.id
    assert Enum.count(results, &(&1 == {:ok, nil})) == 1

    assert {:error, :delivery_in_progress} =
             claim_delivery(adapter, delivery.id, lease_seconds: 60)

    :ok
  end

  @spec assert_lease_reclaim(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_lease_reclaim(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {delivery, _message, _recipient_agent} = harness.prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = first_claim} =
             claim_delivery(adapter, delivery.id, lease_seconds: 60)

    harness.expire_delivery_lease!(first_claim)

    assert {:ok, %DeliveryClaim{} = reclaimed_claim} =
             claim_due(adapter, lease_seconds: 120)

    assert reclaimed_claim.delivery.id == delivery.id
    assert reclaimed_claim.claim_token =~ "dcl_"
    assert reclaimed_claim.claim_token != first_claim.claim_token
    assert reclaimed_claim.attempt_number == first_claim.attempt_number

    persisted_delivery = harness.get_delivery!(delivery.id)

    assert persisted_delivery.status == "leased"
    assert persisted_delivery.claim_token == reclaimed_claim.claim_token
    assert persisted_delivery.leased_until == reclaimed_claim.leased_until

    :ok
  end

  @spec assert_stale_claim_rejection(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_stale_claim_rejection(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    assert_stale_finish_rejection(adapter, harness, conn, "#{key}-finish")
    assert_stale_terminalize_rejection(adapter, harness, conn, "#{key}-terminalize")

    :ok
  end

  @spec assert_attempt_recording(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_attempt_recording(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    assert_finished_claim_state(adapter, harness, conn, "#{key}-delivered", :delivered)
    assert_finished_claim_state(adapter, harness, conn, "#{key}-failed", :failed)

    :ok
  end

  @spec assert_claim_terminalization(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_claim_terminalization(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {acked_delivery, acked_message, _acked_agent} =
      harness.prepare_due_webhook_delivery!(conn, "#{key}-acked")

    assert {:ok, %DeliveryClaim{} = acked_claim} =
             claim_delivery(adapter, acked_delivery.id, lease_seconds: 90)

    harness.mark_message_acked!(acked_message)

    assert {:ok, %Message{} = terminal_acked_message} =
             terminalize_claim(adapter, acked_claim, :message_acked)

    assert terminal_acked_message.id == acked_message.id

    persisted_acked_delivery = harness.get_delivery!(acked_delivery.id)
    persisted_acked_message = harness.get_message!(acked_message.id)

    assert persisted_acked_delivery.status == "failed"
    assert persisted_acked_delivery.last_error == "message_acked"
    assert is_nil(persisted_acked_delivery.claim_token)
    assert persisted_acked_message.current_ack_status == "accepted"

    {expired_delivery, expired_message, _expired_agent} =
      harness.prepare_due_webhook_delivery!(conn, "#{key}-expired")

    assert {:ok, %DeliveryClaim{} = expired_claim} =
             claim_delivery(adapter, expired_delivery.id, lease_seconds: 90)

    harness.expire_message!(expired_message)

    assert {:ok, %Message{} = terminal_expired_message} =
             terminalize_claim(adapter, expired_claim, :message_expired)

    assert terminal_expired_message.id == expired_message.id
    assert terminal_expired_message.carrier_status == "expired"

    persisted_expired_delivery = harness.get_delivery!(expired_delivery.id)

    assert persisted_expired_delivery.status == "failed"
    assert persisted_expired_delivery.last_error == "message_expired"
    assert is_nil(persisted_expired_delivery.claim_token)
    assert harness.webhook_attempt_count() == 0

    :ok
  end

  @spec assert_due_claim_terminalization(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_due_claim_terminalization(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {acked_delivery, acked_message, _acked_agent, recipient} =
      harness.prepare_due_webhook_delivery_context!(conn, "#{key}-acked")

    harness.ack_delivery_through_polling!(recipient, "#{key}-claim-inbox", "#{key}-ack")

    assert {:ok, nil} = claim_due(adapter, lease_seconds: 90)

    persisted_acked_delivery = harness.get_delivery!(acked_delivery.id)
    persisted_acked_message = harness.get_message!(acked_message.id)

    assert persisted_acked_delivery.status == "failed"
    assert persisted_acked_delivery.last_error == "message_acked"
    assert persisted_acked_delivery.attempt_count == 0
    assert is_nil(persisted_acked_delivery.claim_token)
    assert persisted_acked_message.current_ack_status == "accepted"

    {expired_delivery, expired_message, _expired_agent} =
      harness.prepare_due_webhook_delivery!(conn, "#{key}-expired")

    harness.expire_message!(expired_message)

    assert {:ok, nil} = claim_due(adapter, lease_seconds: 90)

    persisted_expired_delivery = harness.get_delivery!(expired_delivery.id)
    persisted_expired_message = harness.get_message!(expired_message.id)

    assert persisted_expired_delivery.status == "failed"
    assert persisted_expired_delivery.last_error == "message_expired"
    assert persisted_expired_delivery.attempt_count == 0
    assert is_nil(persisted_expired_delivery.claim_token)
    assert persisted_expired_message.carrier_status == "expired"
    assert %DateTime{} = persisted_expired_message.terminal_at
    assert harness.webhook_attempt_count() == 0

    :ok
  end

  @spec assert_direct_claim_terminalization(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_direct_claim_terminalization(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {acked_delivery, acked_message, _acked_agent, recipient} =
      harness.prepare_due_webhook_delivery_context!(conn, "#{key}-acked")

    harness.ack_delivery_through_polling!(recipient, "#{key}-claim-inbox", "#{key}-ack")

    assert {:ok, %Message{} = terminal_acked_message} =
             claim_delivery(adapter, acked_delivery.id, lease_seconds: 90)

    assert terminal_acked_message.id == acked_message.id

    persisted_acked_delivery = harness.get_delivery!(acked_delivery.id)
    persisted_acked_message = harness.get_message!(acked_message.id)

    assert persisted_acked_delivery.status == "failed"
    assert persisted_acked_delivery.last_error == "message_acked"
    assert persisted_acked_delivery.attempt_count == 0
    assert is_nil(persisted_acked_delivery.claim_token)
    assert is_nil(persisted_acked_delivery.claimed_at)
    assert is_nil(persisted_acked_delivery.leased_until)
    assert persisted_acked_message.current_ack_status == "accepted"

    {expired_delivery, expired_message, _expired_agent} =
      harness.prepare_due_webhook_delivery!(conn, "#{key}-expired")

    harness.expire_message!(expired_message)

    assert {:ok, %Message{} = terminal_expired_message} =
             claim_delivery(adapter, expired_delivery.id, lease_seconds: 90)

    assert terminal_expired_message.id == expired_message.id
    assert terminal_expired_message.carrier_status == "expired"

    persisted_expired_delivery = harness.get_delivery!(expired_delivery.id)
    persisted_expired_message = harness.get_message!(expired_message.id)

    assert persisted_expired_delivery.status == "failed"
    assert persisted_expired_delivery.last_error == "message_expired"
    assert persisted_expired_delivery.attempt_count == 0
    assert is_nil(persisted_expired_delivery.claim_token)
    assert is_nil(persisted_expired_delivery.claimed_at)
    assert is_nil(persisted_expired_delivery.leased_until)
    assert persisted_expired_message.carrier_status == "expired"
    assert %DateTime{} = persisted_expired_message.terminal_at
    assert harness.webhook_attempt_count() == 0

    :ok
  end

  @spec assert_direct_message_idempotent_replay(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_direct_message_idempotent_replay(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    params = direct_message_params(recipient, "#{key}-message", "retry-safe")
    before_counts = harness.carrier_counts()

    assert {:ok, 201, first_body} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert {:ok, 201, replay_body} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert replay_body == first_body
    assert first_body["message"]["from"] == sender.address
    assert first_body["message"]["to"] == recipient.address
    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 0, messages: 1}

    :ok
  end

  @spec assert_concurrent_direct_message_idempotency(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_concurrent_direct_message_idempotency(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    params = direct_message_params(recipient, "#{key}-message", "retry-safe under concurrency")
    before_counts = harness.carrier_counts()

    results =
      1..2
      |> Task.async_stream(
        fn _index ->
          accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, 201, first_body}] =
             Enum.filter(results, &match?({:ok, 201, _body}, &1))

    assert Enum.count(results, &(&1 == {:error, :idempotency_in_progress})) == 1

    assert {:ok, 201, replay_body} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert replay_body == first_body
    assert first_body["message"]["from"] == sender.address
    assert first_body["message"]["to"] == recipient.address
    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 0, messages: 1}

    :ok
  end

  @spec assert_direct_message_idempotency_conflict(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_direct_message_idempotency_conflict(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    before_counts = harness.carrier_counts()

    assert {:ok, 201, _body} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               direct_message_params(recipient, "#{key}-original", "original"),
               "#{key}-send"
             )

    assert {:error, :idempotency_conflict} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               direct_message_params(recipient, "#{key}-changed", "changed"),
               "#{key}-send"
             )

    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 0, messages: 1}

    :ok
  end

  @spec assert_direct_message_idempotency_principal_scope(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_direct_message_idempotency_principal_scope(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {first_sender, second_sender, recipient} =
      harness.prepare_direct_message_principal_scope!(conn, key)

    params = direct_message_params(recipient, "#{key}-message", "same request body")
    before_counts = harness.carrier_counts()

    assert {:ok, 201, first_body} =
             accept_and_complete_direct_message(adapter, first_sender, params, "#{key}-send")

    assert {:ok, 201, second_body} =
             accept_and_complete_direct_message(adapter, second_sender, params, "#{key}-send")

    assert first_body["message"]["from"] == first_sender.address
    assert second_body["message"]["from"] == second_sender.address
    assert first_body["message"]["id"] != second_body["message"]["id"]
    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 0, messages: 2}

    :ok
  end

  @spec assert_invalid_direct_message_payload_no_carrier_work(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_invalid_direct_message_payload_no_carrier_work(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    before_counts = harness.carrier_counts()

    assert {:error, :invalid_a2a_message} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               %{"to" => recipient.address, "payload" => %{"text" => "not an A2A message"}},
               "#{key}-send"
             )

    assert harness.carrier_counts() == before_counts

    :ok
  end

  @spec assert_missing_direct_message_recipient_no_carrier_work(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_missing_direct_message_recipient_no_carrier_work(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    before_counts = harness.carrier_counts()

    assert {:error, :recipient_not_found} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               %{
                 "to" => "atp://agent/agt_#{key}_missing",
                 "payload" => Atp.ConnCase.a2a_user_text("#{key}-missing", "missing")
               },
               "#{key}-missing-send"
             )

    disabled_recipient = harness.disable_agent!(recipient)

    assert {:error, :recipient_not_found} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               direct_message_params(disabled_recipient, "#{key}-disabled", "disabled"),
               "#{key}-disabled-send"
             )

    assert harness.carrier_counts() == before_counts

    :ok
  end

  @spec assert_blocked_direct_message_no_delivery_work(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) ::
          :ok
  def assert_blocked_direct_message_no_delivery_work(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    harness.block_sender_agent!(sender, recipient)

    params = direct_message_params(recipient, "#{key}-message", "blocked")
    before_counts = harness.carrier_counts()

    assert {:ok, 201, body} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert body["carrier_status"] == "rejected"
    assert body["message"]["from"] == sender.address
    assert body["message"]["to"] == recipient.address
    assert body["message"]["trust"] == "untrusted"
    assert body["deliveries"] == []

    message = harness.get_message!(body["message"]["id"])

    assert message.carrier_status == "rejected"
    assert message.trust == "untrusted"
    assert %DateTime{} = message.terminal_at
    assert harness.get_deliveries_for_message!(message.id) == []
    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 0, messages: 1}

    :ok
  end

  @spec assert_successful_direct_message_intake(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_successful_direct_message_intake(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_active_webhook_direct_message_pair!(conn, key)
    params = direct_message_params(recipient, "#{key}-message", "deliver by webhook")
    before_counts = harness.carrier_counts()

    assert {:ok, 201, body, prepared} =
             accept_direct_message(adapter, sender, params, "#{key}-send")

    assert body["carrier_status"] == "queued"
    assert body["message"]["from"] == sender.address
    assert body["message"]["to"] == recipient.address
    assert body["message"]["trust"] == "trusted"
    assert body["message"]["payload"] == params["payload"]
    assert [delivery_status] = body["deliveries"]
    assert delivery_status["mode"] == "webhook"
    assert delivery_status["status"] == "retry_scheduled"
    assert delivery_status["attempt_count"] == 0
    assert is_binary(prepared.commit_value)

    message = harness.get_message!(body["message"]["id"])

    assert message.sender_agent_id == sender.id
    assert message.recipient_agent_id == recipient.id
    assert message.sender_address == sender.address
    assert message.recipient_address == recipient.address
    assert message.payload == params["payload"]
    assert message.content_type == "application/a2a+json"
    assert message.carrier_status == "queued"
    assert message.trust == "trusted"
    assert is_nil(message.current_ack_status)
    assert is_nil(message.session_id)
    assert is_nil(message.session_sequence)
    assert %DateTime{} = message.expires_at

    assert [%Delivery{} = delivery] = harness.get_deliveries_for_message!(message.id)
    assert delivery.recipient_agent_id == recipient.id
    assert delivery.mode == "webhook"
    assert delivery.status == "retry_scheduled"
    assert delivery.attempt_count == 0
    assert delivery.max_attempts >= 1
    assert prepared.commit_value == delivery.id
    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 1, messages: 1}

    assert {:ok, 201, ^body} = complete_prepared_direct_message(prepared)

    :ok
  end

  @spec assert_message_status_reads(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_message_status_reads(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    {_outsider_sender, outsider} = harness.prepare_direct_message_pair!(conn, "#{key}-outsider")
    params = direct_message_params(recipient, "#{key}-message", "read status")

    assert {:ok, 201, sent} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert {:ok, 201, claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim")

    message_id = sent["message"]["id"]

    assert claim["message"]["id"] == message_id

    assert {:ok, sender_status} = adapter.get_message_status(sender, message_id)
    assert {:ok, recipient_status} = adapter.get_message_status(recipient, message_id)

    assert sender_status["message"] == sent["message"]
    assert sender_status["carrier_status"] == "delivered"
    assert sender_status["ack_status"] == nil

    assert [%{"id" => delivery_id, "mode" => "polling", "status" => "leased"}] =
             sender_status["deliveries"]

    assert delivery_id == claim["id"]
    assert recipient_status == sender_status

    assert {:error, :not_found} = adapter.get_message_status(outsider, message_id)
    assert {:error, :not_found} = adapter.get_message_status(sender, "msg_missing_#{key}")

    :ok
  end

  @spec assert_open_session_idempotent_replay(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_open_session_idempotent_replay(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)
    params = session_open_params(recipient, "#{key}-message", "retry-safe opening")
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, first_body} =
             open_and_complete_session(adapter, initiator, params, "#{key}-open")

    assert {:ok, 201, replay_body} =
             open_and_complete_session(adapter, initiator, params, "#{key}-open")

    assert replay_body == first_body
    assert first_body["session"]["status"] == "pending"
    assert first_body["message_status"]["message"]["from"] == initiator.address
    assert first_body["message_status"]["message"]["to"] == recipient.address

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 1
           }

    :ok
  end

  @spec assert_concurrent_open_session_idempotency(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_concurrent_open_session_idempotency(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)
    params = session_open_params(recipient, "#{key}-message", "retry-safe opening concurrency")
    before_counts = harness.session_carrier_counts()

    results =
      1..2
      |> Task.async_stream(
        fn _index -> open_and_complete_session(adapter, initiator, params, "#{key}-open") end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    ok_results = Enum.filter(results, &match?({:ok, 201, _body}, &1))

    assert ok_results != []

    assert Enum.all?(results, fn result ->
             match?({:ok, 201, _body}, result) or result == {:error, :idempotency_in_progress}
           end)

    [{:ok, 201, first_body} | _rest] = ok_results

    assert Enum.all?(ok_results, fn {:ok, 201, body} -> body == first_body end)

    assert {:ok, 201, replay_body} =
             open_and_complete_session(adapter, initiator, params, "#{key}-open")

    assert replay_body == first_body
    assert first_body["session"]["status"] == "pending"
    assert first_body["message_status"]["message"]["session_sequence"] == 1

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 1
           }

    assert [1] =
             first_body["session"]["id"]
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    :ok
  end

  @spec assert_open_session_idempotency_conflict(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_open_session_idempotency_conflict(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, _body} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-original", "original opening"),
               "#{key}-open"
             )

    assert {:error, :idempotency_conflict} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-changed", "changed opening"),
               "#{key}-open"
             )

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 1
           }

    :ok
  end

  @spec assert_invalid_session_open_no_carrier_work(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_invalid_session_open_no_carrier_work(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)
    before_counts = harness.session_carrier_counts()

    assert {:error, :invalid_a2a_message} =
             open_and_complete_session(
               adapter,
               initiator,
               %{"to" => recipient.address, "payload" => %{"text" => "not an A2A message"}},
               "#{key}-invalid-payload"
             )

    assert {:error, :recipient_not_found} =
             open_and_complete_session(
               adapter,
               initiator,
               %{
                 "to" => "atp://agent/agt_#{key}_missing",
                 "payload" => Atp.ConnCase.a2a_user_text("#{key}-missing", "missing")
               },
               "#{key}-missing-recipient"
             )

    assert {:error, :invalid_session_recipient} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(initiator, "#{key}-self", "self opening"),
               "#{key}-self-recipient"
             )

    assert harness.session_carrier_counts() == before_counts

    :ok
  end

  @spec assert_blocked_session_open_no_delivery_work(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_blocked_session_open_no_delivery_work(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)
    harness.block_sender_agent!(initiator, recipient)

    params = session_open_params(recipient, "#{key}-message", "blocked opening")
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, body} =
             open_and_complete_session(adapter, initiator, params, "#{key}-open")

    assert body["session"]["status"] == "rejected"
    assert body["session"]["last_sequence"] == 1
    assert body["message_status"]["carrier_status"] == "rejected"
    assert body["message_status"]["message"]["trust"] == "untrusted"
    assert body["message_status"]["deliveries"] == []

    session = harness.get_session!(body["session"]["id"])
    message = harness.get_message!(body["message_status"]["message"]["id"])

    assert session.status == "rejected"
    assert session.opening_message_id == message.id
    assert session.last_sequence == 1
    assert %DateTime{} = session.terminal_at
    assert message.session_id == session.id
    assert message.session_sequence == 1
    assert message.carrier_status == "rejected"
    assert %DateTime{} = message.terminal_at
    assert harness.get_deliveries_for_message!(message.id) == []

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 1
           }

    :ok
  end

  @spec assert_successful_session_open(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_successful_session_open(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_active_webhook_session_pair!(conn, key)
    params = session_open_params(recipient, "#{key}-message", "deliver opening by webhook")
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, body, prepared} =
             open_session(adapter, initiator, params, "#{key}-open")

    assert body["session"]["status"] == "pending"
    assert body["session"]["last_sequence"] == 1
    assert body["session"]["opening_message_id"] == body["message_status"]["message"]["id"]
    assert body["message_status"]["carrier_status"] == "queued"
    assert body["message_status"]["message"]["from"] == initiator.address
    assert body["message_status"]["message"]["to"] == recipient.address
    assert body["message_status"]["message"]["payload"] == params["payload"]
    assert body["message_status"]["message"]["session_id"] == body["session"]["id"]
    assert body["message_status"]["message"]["session_sequence"] == 1

    assert [delivery_status] = body["message_status"]["deliveries"]
    assert delivery_status["mode"] == "webhook"
    assert delivery_status["status"] == "retry_scheduled"
    assert delivery_status["attempt_count"] == 0

    assert %{commit_value: {session_id, webhook_delivery_id}} = prepared
    assert session_id == body["session"]["id"]
    assert is_binary(webhook_delivery_id)

    session = harness.get_session!(session_id)
    message = harness.get_message!(body["message_status"]["message"]["id"])

    assert %Session{} = session
    assert session.initiator_agent_id == initiator.id
    assert session.recipient_agent_id == recipient.id
    assert session.opening_message_id == message.id
    assert session.status == "pending"
    assert session.last_sequence == 1
    assert is_nil(session.opened_at)
    assert is_nil(session.terminal_at)

    assert message.sender_agent_id == initiator.id
    assert message.recipient_agent_id == recipient.id
    assert message.session_id == session.id
    assert message.session_sequence == 1
    assert message.content_type == "application/a2a+json"
    assert message.carrier_status == "queued"
    assert message.trust == "trusted"
    assert message.payload == params["payload"]

    assert [%Delivery{} = delivery] = harness.get_deliveries_for_message!(message.id)
    assert delivery.id == webhook_delivery_id
    assert delivery.recipient_agent_id == recipient.id
    assert delivery.mode == "webhook"
    assert delivery.status == "retry_scheduled"
    assert delivery.attempt_count == 0

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 1,
             sessions: 1
           }

    assert {:ok, 201, ^body} = complete_prepared_session_open(prepared)

    :ok
  end

  @spec assert_session_transcript_reads(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_session_transcript_reads(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)
    {_outsider_sender, outsider} = harness.prepare_session_pair!(conn, "#{key}-outsider")

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "read transcript"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]

    assert {:ok, 201, opening_claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim-opening")

    assert opening_claim["message"]["id"] == opening_message_id

    assert {:ok, 201, accepted} =
             ack_delivery(
               adapter,
               recipient,
               opening_claim["id"],
               %{"status" => "accepted"},
               "#{key}-accept-opening"
             )

    assert accepted["message_status"]["ack_status"] == "accepted"
    assert harness.get_session!(session_id).status == "open"

    assert {:ok, 201, recipient_reply} =
             send_and_complete_session_message(
               adapter,
               recipient,
               session_id,
               session_message_params("#{key}-recipient", "recipient turn"),
               "#{key}-recipient-reply"
             )

    assert {:ok, 201, initiator_reply} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session_id,
               session_message_params("#{key}-initiator", "initiator turn"),
               "#{key}-initiator-reply"
             )

    assert {:ok, transcript} = adapter.get_session(initiator, session_id)
    assert {:ok, recipient_transcript} = adapter.get_session(recipient, session_id)

    assert transcript["session"]["id"] == session_id
    assert transcript["session"]["status"] == "open"

    assert Enum.map(transcript["messages"], &get_in(&1, ["message", "session_sequence"])) ==
             [1, 2, 3]

    assert Enum.map(transcript["messages"], &get_in(&1, ["message", "id"])) == [
             opening_message_id,
             recipient_reply["message_status"]["message"]["id"],
             initiator_reply["message_status"]["message"]["id"]
           ]

    assert [
             %{"ack_status" => "accepted"},
             %{"carrier_status" => "queued"},
             %{"carrier_status" => "queued"}
           ] = transcript["messages"]

    assert Enum.map(recipient_transcript["messages"], &get_in(&1, ["message", "id"])) ==
             Enum.map(transcript["messages"], &get_in(&1, ["message", "id"]))

    assert {:error, :not_found} = adapter.get_session(outsider, session_id)
    assert {:error, :not_found} = adapter.get_session(initiator, "ses_missing_#{key}")

    :ok
  end

  @spec assert_successful_session_accept(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_successful_session_accept(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "accept this session"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]
    before_counts = harness.session_carrier_counts()
    ack_payload = Atp.ConnCase.a2a_agent_text("#{key}-accepted", "accepted")

    assert {:ok, 201, accepted} =
             accept_session(
               adapter,
               recipient,
               session_id,
               %{"payload" => ack_payload},
               "#{key}-accept"
             )

    assert accepted["session"]["id"] == session_id
    assert accepted["session"]["status"] == "open"
    assert accepted["ack"]["status"] == "accepted"
    assert accepted["ack"]["payload"] == ack_payload
    assert accepted["ack"]["message_id"] == opening_message_id
    assert accepted["ack"]["delivery_id"] =~ "dlv_"
    assert accepted["message_status"]["carrier_status"] == "delivered"
    assert accepted["message_status"]["ack_status"] == "accepted"

    assert [%{"id" => delivery_id, "mode" => "polling", "status" => "delivered"}] =
             accepted["message_status"]["deliveries"]

    assert delivery_id == accepted["ack"]["delivery_id"]

    persisted_session = harness.get_session!(session_id)
    persisted_opening = harness.get_message!(opening_message_id)

    assert persisted_session.status == "open"
    assert %DateTime{} = persisted_session.opened_at
    refute persisted_session.terminal_at
    assert persisted_opening.carrier_status == "delivered"
    assert persisted_opening.current_ack_status == "accepted"
    refute persisted_opening.terminal_at

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }

    assert [ack] = harness.get_acks_for_message!(opening_message_id)
    assert ack.status == "accepted"
    assert ack.payload == ack_payload

    :ok
  end

  @spec assert_session_accept_idempotency(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_session_accept_idempotency(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "retry-safe accept"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, first_body} =
             accept_session(adapter, recipient, session_id, %{}, "#{key}-accept")

    assert {:ok, 201, replay_body} =
             accept_session(adapter, recipient, session_id, %{}, "#{key}-accept")

    assert replay_body == first_body

    assert {:error, :idempotency_conflict} =
             accept_session(
               adapter,
               recipient,
               session_id,
               %{"payload" => Atp.ConnCase.a2a_agent_text("#{key}-changed", "changed")},
               "#{key}-accept"
             )

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }

    assert [ack] = harness.get_acks_for_message!(opened["message_status"]["message"]["id"])
    assert ack.status == "accepted"

    :ok
  end

  @spec assert_session_accept_authorization_and_payload_checks(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_session_accept_authorization_and_payload_checks(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, "#{key}-participants")
    {_outsider_sender, outsider} = harness.prepare_session_pair!(conn, "#{key}-outsider")

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "recipient only"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]
    before_counts = harness.session_carrier_counts()

    assert {:error, :not_found} =
             accept_session(adapter, initiator, session_id, %{}, "#{key}-initiator-accept")

    assert {:error, :not_found} =
             accept_session(adapter, outsider, session_id, %{}, "#{key}-outsider-accept")

    assert {:error, :invalid_a2a_message} =
             accept_session(
               adapter,
               recipient,
               session_id,
               %{"payload" => %{"text" => "not A2A"}},
               "#{key}-invalid-payload"
             )

    assert harness.get_session!(session_id).status == "pending"
    assert harness.get_message!(opening_message_id).current_ack_status == nil
    assert harness.get_acks_for_message!(opening_message_id) == []

    assert {:ok, 201, accepted} =
             accept_session(adapter, recipient, session_id, %{}, "#{key}-recipient-accept")

    assert accepted["session"]["status"] == "open"

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }

    :ok
  end

  @spec assert_successful_session_reject(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_successful_session_reject(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "reject this session"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]
    before_counts = harness.session_carrier_counts()
    ack_payload = Atp.ConnCase.a2a_agent_text("#{key}-rejected", "rejected")

    assert {:ok, 201, rejected} =
             reject_session(
               adapter,
               recipient,
               session_id,
               %{"payload" => ack_payload},
               "#{key}-reject"
             )

    assert rejected["session"]["id"] == session_id
    assert rejected["session"]["status"] == "rejected"
    assert rejected["ack"]["status"] == "rejected"
    assert rejected["ack"]["payload"] == ack_payload
    assert rejected["ack"]["message_id"] == opening_message_id
    assert rejected["ack"]["delivery_id"] =~ "dlv_"
    assert rejected["message_status"]["carrier_status"] == "delivered"
    assert rejected["message_status"]["ack_status"] == "rejected"

    assert [%{"id" => delivery_id, "mode" => "polling", "status" => "delivered"}] =
             rejected["message_status"]["deliveries"]

    assert delivery_id == rejected["ack"]["delivery_id"]

    persisted_session = harness.get_session!(session_id)
    persisted_opening = harness.get_message!(opening_message_id)

    assert persisted_session.status == "rejected"
    assert %DateTime{} = persisted_session.terminal_at
    refute persisted_session.opened_at
    assert persisted_opening.carrier_status == "delivered"
    assert persisted_opening.current_ack_status == "rejected"
    assert %DateTime{} = persisted_opening.terminal_at

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }

    assert [ack] = harness.get_acks_for_message!(opening_message_id)
    assert ack.status == "rejected"
    assert ack.payload == ack_payload

    :ok
  end

  @spec assert_session_reject_idempotency(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_session_reject_idempotency(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "retry-safe reject"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, first_body} =
             reject_session(adapter, recipient, session_id, %{}, "#{key}-reject")

    assert {:ok, 201, replay_body} =
             reject_session(adapter, recipient, session_id, %{}, "#{key}-reject")

    assert replay_body == first_body

    assert {:error, :idempotency_conflict} =
             reject_session(
               adapter,
               recipient,
               session_id,
               %{"payload" => Atp.ConnCase.a2a_agent_text("#{key}-changed", "changed")},
               "#{key}-reject"
             )

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }

    assert [ack] = harness.get_acks_for_message!(opened["message_status"]["message"]["id"])
    assert ack.status == "rejected"

    :ok
  end

  @spec assert_session_reject_authorization_and_payload_checks(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_session_reject_authorization_and_payload_checks(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, "#{key}-participants")
    {_outsider_sender, outsider} = harness.prepare_session_pair!(conn, "#{key}-outsider")

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "recipient only"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]
    before_counts = harness.session_carrier_counts()

    assert {:error, :not_found} =
             reject_session(adapter, initiator, session_id, %{}, "#{key}-initiator-reject")

    assert {:error, :not_found} =
             reject_session(adapter, outsider, session_id, %{}, "#{key}-outsider-reject")

    assert {:error, :invalid_a2a_message} =
             reject_session(
               adapter,
               recipient,
               session_id,
               %{"payload" => %{"text" => "not A2A"}},
               "#{key}-invalid-payload"
             )

    assert harness.get_session!(session_id).status == "pending"
    assert harness.get_message!(opening_message_id).current_ack_status == nil
    assert harness.get_acks_for_message!(opening_message_id) == []

    assert {:ok, 201, rejected} =
             reject_session(adapter, recipient, session_id, %{}, "#{key}-recipient-reject")

    assert rejected["session"]["status"] == "rejected"

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }

    :ok
  end

  @spec assert_expired_session_lifecycle(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_expired_session_lifecycle(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    assert_expired_session_action(adapter, harness, conn, "#{key}-accept", :accept)
    assert_expired_session_action(adapter, harness, conn, "#{key}-reject", :reject)

    :ok
  end

  @spec assert_delivery_ack_polling_success_and_transitions(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_delivery_ack_polling_success_and_transitions(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {delivery, message, _sender, recipient} = harness.prepare_polling_delivery!(conn, key)
    payload = Atp.ConnCase.a2a_agent_text("#{key}-accepted", "accepted")

    assert {:ok, 201, accepted} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "accepted", "payload" => payload},
               "#{key}-accepted"
             )

    assert accepted["ack"]["delivery_id"] == delivery.id
    assert accepted["ack"]["message_id"] == message.id
    assert accepted["ack"]["status"] == "accepted"
    assert accepted["ack"]["payload"] == payload
    assert accepted["message_status"]["carrier_status"] == "delivered"
    assert accepted["message_status"]["ack_status"] == "accepted"
    refute accepted["message_status"]["terminal_at"]

    persisted_delivery = harness.get_delivery!(delivery.id)
    persisted_message = harness.get_message!(message.id)

    assert persisted_delivery.status == "delivered"
    assert %DateTime{} = persisted_delivery.delivered_at
    assert persisted_message.carrier_status == "delivered"
    assert persisted_message.current_ack_status == "accepted"
    refute persisted_message.terminal_at

    assert [accepted_ack] = harness.get_acks_for_message!(message.id)
    assert accepted_ack.status == "accepted"
    assert accepted_ack.payload == payload

    assert {:error, :invalid_ack_transition} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "rejected"},
               "#{key}-rejected-after-accepted"
             )

    assert {:ok, 201, completed} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "completed"},
               "#{key}-completed"
             )

    assert completed["ack"]["status"] == "completed"
    assert completed["message_status"]["ack_status"] == "completed"
    assert completed["message_status"]["terminal_at"]

    assert {:error, :terminal_ack_status} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "failed"},
               "#{key}-failed-after-completed"
             )

    assert ["accepted", "completed"] =
             message.id
             |> harness.get_acks_for_message!()
             |> Enum.map(& &1.status)

    :ok
  end

  @spec assert_delivery_ack_delivered_webhook(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_delivery_ack_delivered_webhook(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {delivery, message, recipient, _recipient_response} =
      harness.prepare_due_webhook_delivery_context!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_delivery(adapter, delivery.id, lease_seconds: 90)

    assert {:ok, %Message{carrier_status: "delivered"}} =
             finish_claim(
               adapter,
               claim,
               delivered_attempt_result(claim, DateTime.utc_now(:microsecond))
             )

    assert {:ok, 201, body} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "accepted"},
               "#{key}-accepted"
             )

    assert body["ack"]["delivery_id"] == delivery.id
    assert body["ack"]["message_id"] == message.id
    assert body["ack"]["status"] == "accepted"
    assert body["message_status"]["ack_status"] == "accepted"

    assert [ack] = harness.get_acks_for_message!(message.id)
    assert ack.status == "accepted"
  end

  @spec assert_delivery_ack_delivery_validation(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_delivery_ack_delivery_validation(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {delivery, message, sender, recipient} =
      harness.prepare_polling_delivery!(conn, "#{key}-wrong-recipient")

    assert {:error, :not_found} =
             ack_delivery(
               adapter,
               sender,
               delivery.id,
               %{"status" => "accepted"},
               "#{key}-wrong-recipient-ack"
             )

    assert [] = harness.get_acks_for_message!(message.id)
    refute harness.get_message!(message.id).current_ack_status

    {expired_delivery, expired_message, _sender, expired_recipient} =
      harness.prepare_polling_delivery!(conn, "#{key}-expired-lease")

    harness.expire_delivery_lease!(expired_delivery)

    assert {:error, :lease_expired} =
             ack_delivery(
               adapter,
               expired_recipient,
               expired_delivery.id,
               %{"status" => "accepted"},
               "#{key}-expired-lease-ack"
             )

    assert [] = harness.get_acks_for_message!(expired_message.id)

    {webhook_delivery, webhook_message, webhook_recipient, _recipient_response} =
      harness.prepare_due_webhook_delivery_context!(conn, "#{key}-undelivered-webhook")

    assert {:error, :delivery_not_delivered} =
             ack_delivery(
               adapter,
               webhook_recipient,
               webhook_delivery.id,
               %{"status" => "accepted"},
               "#{key}-undelivered-webhook-ack"
             )

    assert [] = harness.get_acks_for_message!(webhook_message.id)

    assert recipient.id != sender.id

    :ok
  end

  @spec assert_delivery_ack_request_validation_and_idempotency(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_delivery_ack_request_validation_and_idempotency(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {delivery, message, _sender, recipient} = harness.prepare_polling_delivery!(conn, key)

    assert {:error, :ack_status_required} =
             ack_delivery(adapter, recipient, delivery.id, %{}, "#{key}-missing-status")

    assert {:error, :invalid_ack_status} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "done"},
               "#{key}-invalid-status"
             )

    assert {:error, :invalid_a2a_message} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "accepted", "payload" => %{"text" => "not A2A"}},
               "#{key}-invalid-payload"
             )

    assert [] = harness.get_acks_for_message!(message.id)

    params = %{
      "status" => "failed",
      "payload" => Atp.ConnCase.a2a_agent_text("#{key}-failed", "failed")
    }

    assert {:ok, 201, first_body} =
             ack_delivery(adapter, recipient, delivery.id, params, "#{key}-idempotent")

    assert {:ok, 201, replay_body} =
             ack_delivery(adapter, recipient, delivery.id, params, "#{key}-idempotent")

    assert replay_body == first_body

    assert {:error, :idempotency_conflict} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{params | "payload" => Atp.ConnCase.a2a_agent_text("#{key}-changed", "changed")},
               "#{key}-idempotent"
             )

    assert [ack] = harness.get_acks_for_message!(message.id)
    assert ack.status == "failed"
    assert harness.get_message!(message.id).current_ack_status == "failed"

    :ok
  end

  @spec assert_delivery_ack_opening_session_side_effects(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_delivery_ack_opening_session_side_effects(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    for status <- ~w(accepted rejected failed) do
      {session, opening, delivery, _initiator, recipient} =
        harness.prepare_opening_polling_delivery!(conn, "#{key}-#{status}")

      assert {:ok, 201, body} =
               ack_delivery(
                 adapter,
                 recipient,
                 delivery.id,
                 %{"status" => status},
                 "#{key}-#{status}-ack"
               )

      assert body["ack"]["message_id"] == opening.id
      assert body["ack"]["delivery_id"] == delivery.id
      assert body["ack"]["status"] == status
      assert body["message_status"]["ack_status"] == status

      persisted_session = harness.get_session!(session.id)
      persisted_opening = harness.get_message!(opening.id)

      assert persisted_opening.current_ack_status == status
      assert persisted_opening.carrier_status == "delivered"

      case status do
        "accepted" ->
          assert persisted_session.status == "open"
          assert %DateTime{} = persisted_session.opened_at
          refute persisted_session.terminal_at
          refute persisted_opening.terminal_at

        terminal_status ->
          assert persisted_session.status == terminal_status
          assert %DateTime{} = persisted_session.terminal_at
          refute persisted_session.opened_at
          assert %DateTime{} = persisted_opening.terminal_at
      end
    end

    :ok
  end

  @spec assert_opening_session_delivery_lookup(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_opening_session_delivery_lookup(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {session, _opening, delivery, initiator, recipient} =
      harness.prepare_opening_polling_delivery!(conn, key)

    {_outsider_sender, outsider} = harness.prepare_session_pair!(conn, "#{key}-outsider")

    assert adapter.opening_session_id_for_delivery(recipient, delivery.id) == session.id
    assert adapter.opening_session_id_for_delivery(initiator, delivery.id) == nil
    assert adapter.opening_session_id_for_delivery(outsider, delivery.id) == nil
    assert adapter.opening_session_id_for_delivery(recipient, "dlv_missing_#{key}") == nil

    {direct_sender, direct_recipient} =
      harness.prepare_direct_message_pair!(conn, "#{key}-direct-message")

    assert {:ok, 201, sent} =
             accept_and_complete_direct_message(
               adapter,
               direct_sender,
               direct_message_params(direct_recipient, "#{key}-direct", "not an opening"),
               "#{key}-direct-send"
             )

    assert {:ok, 201, direct_claim} =
             claim_inbox(
               adapter,
               direct_recipient,
               %{"lease_seconds" => 60},
               "#{key}-direct-claim"
             )

    assert direct_claim["message"]["id"] == sent["message"]["id"]
    assert adapter.opening_session_id_for_delivery(direct_recipient, direct_claim["id"]) == nil

    :ok
  end

  @spec assert_delivery_ack_expired_opening_session(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_delivery_ack_expired_opening_session(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {session, opening, delivery, _initiator, recipient} =
      harness.prepare_opening_polling_delivery!(conn, key)

    opening
    |> harness.expire_message!()

    assert {:error, :message_expired} =
             ack_delivery(
               adapter,
               recipient,
               delivery.id,
               %{"status" => "accepted"},
               "#{key}-accepted"
             )

    persisted_session = harness.get_session!(session.id)
    persisted_opening = harness.get_message!(opening.id)

    assert persisted_session.status == "failed"
    assert %DateTime{} = persisted_session.terminal_at
    refute persisted_session.opened_at

    assert persisted_opening.carrier_status == "expired"
    assert %DateTime{} = persisted_opening.terminal_at
    refute persisted_opening.current_ack_status
    assert [] = harness.get_acks_for_message!(opening.id)

    :ok
  end

  @spec assert_pending_opening_expiry(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_pending_opening_expiry(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    assert {:error, :not_found} =
             adapter.expire_pending_opening_session(
               "ses_missing_#{key}",
               DateTime.utc_now(:microsecond)
             )

    {not_due_initiator, not_due_recipient} =
      harness.prepare_session_pair!(conn, "#{key}-not-due")

    assert {:ok, 201, not_due} =
             open_and_complete_session(
               adapter,
               not_due_initiator,
               session_open_params(
                 not_due_recipient,
                 "#{key}-not-due-opening",
                 "not due"
               ),
               "#{key}-not-due-open"
             )

    assert {:error, :opening_session_not_due} =
             adapter.expire_pending_opening_session(
               not_due["session"]["id"],
               DateTime.utc_now(:microsecond)
             )

    {_open_initiator, _open_recipient, open_session} =
      prepare_open_session!(adapter, harness, conn, "#{key}-open")

    assert {:error, :session_not_pending} =
             adapter.expire_pending_opening_session(
               open_session.id,
               DateTime.utc_now(:microsecond)
             )

    {due_initiator, due_recipient} = harness.prepare_session_pair!(conn, "#{key}-due")

    assert {:ok, 201, due} =
             open_and_complete_session(
               adapter,
               due_initiator,
               session_open_params(due_recipient, "#{key}-due-opening", "due"),
               "#{key}-due-open"
             )

    due_session_id = due["session"]["id"]
    due_opening_id = due["message_status"]["message"]["id"]

    due_opening_id
    |> harness.get_message!()
    |> harness.expire_message!()

    assert {:ok, %Session{} = expired_session} =
             adapter.expire_pending_opening_session(
               due_session_id,
               DateTime.utc_now(:microsecond)
             )

    assert expired_session.id == due_session_id
    assert expired_session.status == "failed"
    assert %DateTime{} = expired_session.terminal_at
    refute expired_session.opened_at

    persisted_session = harness.get_session!(due_session_id)
    persisted_opening = harness.get_message!(due_opening_id)

    assert persisted_session.status == "failed"
    assert %DateTime{} = persisted_session.terminal_at
    refute persisted_session.opened_at

    assert persisted_opening.carrier_status == "expired"
    assert %DateTime{} = persisted_opening.terminal_at
    refute persisted_opening.current_ack_status
    assert harness.get_acks_for_message!(due_opening_id) == []

    assert {:error, :session_not_pending} =
             adapter.expire_pending_opening_session(
               due_session_id,
               DateTime.utc_now(:microsecond)
             )

    :ok
  end

  @spec assert_polling_claim_success(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_polling_claim_success(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    params = direct_message_params(recipient, "#{key}-message", "claim by polling lease")
    before_counts = harness.carrier_counts()

    assert {:ok, 201, sent} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert sent["carrier_status"] == "queued"
    assert sent["message"]["to"] == recipient.address

    assert {:ok, 201, claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim")

    assert claim["id"] =~ "dlv_"
    assert claim["message"] == sent["message"]
    assert {:ok, _leased_until, 0} = DateTime.from_iso8601(claim["leased_until"])
    refute Map.has_key?(claim, "claim_token")
    refute Map.has_key?(claim, "claimed_at")

    delivery = harness.get_delivery!(claim["id"])
    message = harness.get_message!(sent["message"]["id"])

    assert delivery.mode == "polling"
    assert delivery.status == "leased"
    assert delivery.recipient_agent_id == recipient.id
    assert delivery.message_id == message.id
    assert is_nil(delivery.claim_token)
    assert is_nil(delivery.claimed_at)
    assert message.carrier_status == "delivered"

    assert {:ok, 201, replay} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim")

    assert replay == claim
    assert carrier_delta(before_counts, harness.carrier_counts()) == %{deliveries: 1, messages: 1}

    :ok
  end

  @spec assert_polling_empty_inbox(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_polling_empty_inbox(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {_sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    before_counts = harness.carrier_counts()

    assert {:ok, 200, empty} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim")

    assert empty == %{"delivery" => nil}

    assert {:ok, 200, replay} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim")

    assert replay == empty
    assert harness.carrier_counts() == before_counts

    :ok
  end

  @spec assert_polling_active_lease_reclaim(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_polling_active_lease_reclaim(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    params = direct_message_params(recipient, "#{key}-message", "hide until lease expiry")

    assert {:ok, 201, sent} =
             accept_and_complete_direct_message(adapter, sender, params, "#{key}-send")

    assert {:ok, 201, first_claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-first-claim")

    assert first_claim["message"]["id"] == sent["message"]["id"]

    assert {:ok, 200, %{"delivery" => nil}} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-hidden-claim")

    first_claim["id"]
    |> harness.get_delivery!()
    |> harness.expire_delivery_lease!()

    assert {:ok, 201, reclaimed} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 120}, "#{key}-reclaim")

    assert reclaimed["id"] != first_claim["id"]
    assert reclaimed["message"]["id"] == sent["message"]["id"]

    persisted_reclaim = harness.get_delivery!(reclaimed["id"])

    assert persisted_reclaim.mode == "polling"
    assert persisted_reclaim.status == "leased"
    assert persisted_reclaim.message_id == sent["message"]["id"]

    :ok
  end

  @spec assert_polling_lease_blocks_webhook_claims(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_polling_lease_blocks_webhook_claims(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {webhook_delivery, message, recipient} = harness.prepare_due_webhook_delivery!(conn, key)

    assert {:ok, 201, polling_claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-polling-claim")

    assert polling_claim["message"]["id"] == message.id

    assert {:error, :delivery_in_progress} =
             claim_delivery(adapter, webhook_delivery.id, lease_seconds: 60)

    assert {:ok, nil} = claim_due(adapter, lease_seconds: 60)

    polling_claim["id"]
    |> harness.get_delivery!()
    |> harness.expire_delivery_lease!()

    assert {:ok, %DeliveryClaim{} = webhook_claim} =
             claim_delivery(adapter, webhook_delivery.id, lease_seconds: 60)

    assert webhook_claim.delivery.id == webhook_delivery.id
    assert webhook_claim.message.id == message.id

    :ok
  end

  @spec assert_polling_claim_visibility(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_polling_claim_visibility(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)

    assert {:ok, 201, first_sent} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               direct_message_params(recipient, "#{key}-first", "will be ACKed"),
               "#{key}-send-first"
             )

    assert {:ok, 201, second_sent} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               direct_message_params(recipient, "#{key}-second", "will expire"),
               "#{key}-send-second"
             )

    message_ids = [
      first_sent["message"]["id"],
      second_sent["message"]["id"]
    ]

    assert {:ok, 201, claimed} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim-acked")

    assert claimed["message"]["id"] in message_ids

    assert {:ok, 201, _ack} =
             ack_delivery(
               adapter,
               recipient,
               claimed["id"],
               %{"status" => "accepted"},
               "#{key}-ack"
             )

    [expired_message_id] = message_ids -- [claimed["message"]["id"]]

    expired_message_id
    |> harness.get_message!()
    |> harness.expire_message!()

    assert {:ok, 200, %{"delivery" => nil}} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-empty")

    assert harness.get_message!(claimed["message"]["id"]).current_ack_status == "accepted"

    assert DateTime.compare(
             harness.get_message!(expired_message_id).expires_at,
             DateTime.utc_now()
           ) == :lt

    :ok
  end

  @spec assert_polling_lease_extension(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_polling_lease_extension(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)

    assert {:ok, 201, sent} =
             accept_and_complete_direct_message(
               adapter,
               sender,
               direct_message_params(recipient, "#{key}-message", "extend this lease"),
               "#{key}-send"
             )

    assert {:ok, 201, claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim")

    assert claim["message"]["id"] == sent["message"]["id"]

    assert {:ok, 200, extended} =
             extend_delivery(
               adapter,
               recipient,
               claim["id"],
               %{"lease_seconds" => 120},
               "#{key}-extend"
             )

    assert extended["id"] == claim["id"]
    assert extended["message"] == claim["message"]
    assert later_timestamp?(extended["leased_until"], claim["leased_until"])

    assert {:ok, 200, replay} =
             extend_delivery(
               adapter,
               recipient,
               claim["id"],
               %{"lease_seconds" => 120},
               "#{key}-extend"
             )

    assert replay == extended

    assert {:error, :idempotency_conflict} =
             extend_delivery(
               adapter,
               recipient,
               claim["id"],
               %{"lease_seconds" => 121},
               "#{key}-extend"
             )

    assert {:error, :not_found} =
             extend_delivery(
               adapter,
               sender,
               claim["id"],
               %{"lease_seconds" => 120},
               "#{key}-wrong-owner"
             )

    assert {:error, :invalid_lease} =
             extend_delivery(
               adapter,
               recipient,
               claim["id"],
               %{"lease_seconds" => -1},
               "#{key}-invalid-seconds"
             )

    claim["id"]
    |> harness.get_delivery!()
    |> harness.expire_delivery_lease!()

    assert {:error, :lease_expired} =
             extend_delivery(
               adapter,
               recipient,
               claim["id"],
               %{"lease_seconds" => 120},
               "#{key}-expired"
             )

    {webhook_delivery, _webhook_message, webhook_recipient} =
      harness.prepare_due_webhook_delivery!(conn, "#{key}-webhook")

    assert {:error, :invalid_lease} =
             extend_delivery(
               adapter,
               webhook_recipient,
               webhook_delivery.id,
               %{"lease_seconds" => 120},
               "#{key}-webhook"
             )

    :ok
  end

  @spec assert_polling_session_ordering(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_polling_session_ordering(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient} = harness.prepare_session_pair!(conn, key)

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "open polling session"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]

    assert {:ok, 201, opening_claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim-opening")

    assert opening_claim["message"]["id"] == opening_message_id

    assert {:ok, 201, _ack} =
             ack_delivery(
               adapter,
               recipient,
               opening_claim["id"],
               %{"status" => "accepted"},
               "#{key}-ack-opening"
             )

    assert harness.get_session!(session_id).status == "open"

    assert {:ok, 201, first} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session_id,
               session_message_params("#{key}-first", "first polling session message"),
               "#{key}-send-first"
             )

    assert {:ok, 201, second} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session_id,
               session_message_params("#{key}-second", "second polling session message"),
               "#{key}-send-second"
             )

    assert {:ok, 201, first_claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim-first")

    assert first_claim["message"]["id"] == first["message_status"]["message"]["id"]

    assert {:ok, 201, second_claim} =
             claim_inbox(adapter, recipient, %{"lease_seconds" => 60}, "#{key}-claim-second")

    assert second_claim["message"]["id"] == second["message_status"]["message"]["id"]

    assert [1, 2, 3] =
             session_id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    :ok
  end

  @spec assert_sender_policy_upsert(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_sender_policy_upsert(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {sender, recipient} = harness.prepare_direct_message_pair!(conn, key)
    route = sender_policy_route(recipient.id)
    before_count = harness.sender_policy_count()

    allow_params = %{
      "effect" => "allow",
      "sender_agent_id" => sender.id
    }

    assert {:ok, 200, first} =
             adapter.upsert_sender_policy(
               recipient,
               recipient.id,
               allow_params,
               "#{key}-allow",
               route
             )

    assert first["sender_policy"]["recipient_agent_id"] == recipient.id
    assert first["sender_policy"]["sender_agent_id"] == sender.id
    assert first["sender_policy"]["effect"] == "allow"

    assert {:ok, 200, replay} =
             adapter.upsert_sender_policy(
               recipient,
               recipient.id,
               allow_params,
               "#{key}-allow",
               route
             )

    assert replay == first

    assert {:error, :idempotency_conflict} =
             adapter.upsert_sender_policy(
               recipient,
               recipient.id,
               %{allow_params | "effect" => "block"},
               "#{key}-allow",
               route
             )

    assert {:error, :not_found} =
             adapter.upsert_sender_policy(
               sender,
               recipient.id,
               allow_params,
               "#{key}-wrong-owner",
               route
             )

    assert {:error, :invalid_sender_policy} =
             adapter.upsert_sender_policy(
               recipient,
               recipient.id,
               %{"effect" => "allow"},
               "#{key}-missing-target",
               route
             )

    assert {:error, :not_found} =
             adapter.upsert_sender_policy(
               recipient,
               recipient.id,
               %{"effect" => "allow", "sender_agent_id" => "agt_missing_#{key}"},
               "#{key}-missing-sender",
               route
             )

    assert {:ok, 200, updated} =
             adapter.upsert_sender_policy(
               recipient,
               recipient.id,
               %{allow_params | "effect" => "block"},
               "#{key}-block",
               route
             )

    assert updated["sender_policy"]["id"] == first["sender_policy"]["id"]
    assert updated["sender_policy"]["effect"] == "block"
    assert harness.sender_policy_count() == before_count + 1

    :ok
  end

  @spec assert_runtime_session_helpers(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_runtime_session_helpers(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {pending_initiator, pending_recipient} =
      harness.prepare_session_pair!(conn, "#{key}-pending")

    assert {:ok, 201, pending} =
             open_and_complete_session(
               adapter,
               pending_initiator,
               session_open_params(
                 pending_recipient,
                 "#{key}-pending-opening",
                 "hydrate pending"
               ),
               "#{key}-pending-open"
             )

    pending_session_id = pending["session"]["id"]
    pending_opening_id = pending["message_status"]["message"]["id"]

    assert pending_session_id in adapter.list_pending_session_ids()
    assert {:error, :session_not_open} = adapter.fetch_open_session(pending_session_id)

    assert {:ok, %Session{} = pending_runtime_session} =
             adapter.fetch_runtime_session(pending_session_id)

    assert pending_runtime_session.id == pending_session_id
    assert pending_runtime_session.status == "pending"
    assert pending_runtime_session.opening_message.id == pending_opening_id

    {_open_initiator, _open_recipient, open_session} =
      prepare_open_session!(adapter, harness, conn, "#{key}-open")

    assert {:ok, %Session{} = fetched_open_session} = adapter.fetch_open_session(open_session.id)
    assert fetched_open_session.id == open_session.id
    assert fetched_open_session.status == "open"

    assert {:ok, %Session{} = open_runtime_session} =
             adapter.fetch_runtime_session(open_session.id)

    assert open_runtime_session.id == open_session.id
    assert open_runtime_session.status == "open"
    assert open_runtime_session.opening_message.id == open_session.opening_message_id
    refute open_session.id in adapter.list_pending_session_ids()

    {terminal_initiator, terminal_recipient} =
      harness.prepare_session_pair!(conn, "#{key}-terminal")

    assert {:ok, 201, terminal} =
             open_and_complete_session(
               adapter,
               terminal_initiator,
               session_open_params(
                 terminal_recipient,
                 "#{key}-terminal-opening",
                 "terminal helper"
               ),
               "#{key}-terminal-open"
             )

    assert {:ok, 201, terminal_reject} =
             reject_session(
               adapter,
               terminal_recipient,
               terminal["session"]["id"],
               %{},
               "#{key}-reject"
             )

    assert terminal_reject["session"]["status"] == "rejected"

    assert {:error, :session_not_open} = adapter.fetch_open_session(terminal["session"]["id"])

    assert {:error, :session_not_active} =
             adapter.fetch_runtime_session(terminal["session"]["id"])

    assert {:error, :not_found} = adapter.fetch_open_session("ses_missing_#{key}")
    assert {:error, :not_found} = adapter.fetch_runtime_session("ses_missing_#{key}")

    :ok
  end

  @spec assert_session_message_idempotent_replay(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_session_message_idempotent_replay(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, _recipient, session} = prepare_open_session!(adapter, harness, conn, key)
    params = session_message_params("#{key}-message", "retry-safe session message")
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, first_body} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               params,
               "#{key}-send"
             )

    assert {:ok, 201, replay_body} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               params,
               "#{key}-send"
             )

    assert replay_body == first_body
    assert first_body["message_status"]["message"]["session_id"] == session.id
    assert first_body["message_status"]["message"]["session_sequence"] == 2

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 0
           }

    assert [1, 2] =
             session.id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    :ok
  end

  @spec assert_session_message_idempotency_conflict(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_session_message_idempotency_conflict(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, _recipient, session} = prepare_open_session!(adapter, harness, conn, key)
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, _body} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               session_message_params("#{key}-original", "original session message"),
               "#{key}-send"
             )

    assert {:error, :idempotency_conflict} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               session_message_params("#{key}-changed", "changed session message"),
               "#{key}-send"
             )

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 0
           }

    assert [1, 2] =
             session.id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    :ok
  end

  @spec assert_session_message_participant_and_open_session_checks(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_session_message_participant_and_open_session_checks(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, _recipient} = harness.prepare_session_pair!(conn, "#{key}-pending")
    {_outsider, outsider_recipient} = harness.prepare_session_pair!(conn, "#{key}-outsider")

    pending_params =
      session_open_params(
        outsider_recipient,
        "#{key}-pending-opening",
        "pending session opening"
      )

    assert {:ok, 201, pending_body} =
             open_and_complete_session(adapter, initiator, pending_params, "#{key}-open")

    pending_session_id = pending_body["session"]["id"]
    before_counts = harness.session_carrier_counts()

    assert {:error, :session_not_open} =
             send_and_complete_session_message(
               adapter,
               initiator,
               pending_session_id,
               session_message_params("#{key}-pending-send", "too early"),
               "#{key}-pending-send"
             )

    {participant, _recipient, open_session} =
      prepare_open_session!(adapter, harness, conn, "#{key}-open")

    assert {:error, :not_found} =
             send_and_complete_session_message(
               adapter,
               outsider_recipient,
               open_session.id,
               session_message_params("#{key}-outsider-send", "not a participant"),
               "#{key}-outsider-send"
             )

    {inactive_initiator, inactive_recipient, inactive_session} =
      prepare_open_session!(adapter, harness, conn, "#{key}-inactive-counterparty")

    harness.disable_agent!(inactive_recipient)

    assert {:error, :recipient_not_found} =
             send_and_complete_session_message(
               adapter,
               inactive_initiator,
               inactive_session.id,
               session_message_params("#{key}-inactive-send", "counterparty gone"),
               "#{key}-inactive-send"
             )

    assert {:ok, 201, _body} =
             send_and_complete_session_message(
               adapter,
               participant,
               open_session.id,
               session_message_params("#{key}-participant-send", "participant"),
               "#{key}-participant-send"
             )

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 3,
             sessions: 2
           }

    assert [1] =
             pending_session_id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    assert [1, 2] =
             open_session.id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    assert [1] =
             inactive_session.id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    :ok
  end

  @spec assert_blocked_session_message_no_delivery_work(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_blocked_session_message_no_delivery_work(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient, session} = prepare_open_session!(adapter, harness, conn, key)
    harness.block_sender_agent!(initiator, recipient)

    params = session_message_params("#{key}-message", "blocked session message")
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, body} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               params,
               "#{key}-send"
             )

    assert body["session"]["id"] == session.id
    assert body["session"]["last_sequence"] == 2
    assert body["message_status"]["carrier_status"] == "rejected"
    assert body["message_status"]["message"]["trust"] == "untrusted"
    assert body["message_status"]["message"]["session_sequence"] == 2
    assert body["message_status"]["deliveries"] == []

    persisted_session = harness.get_session!(session.id)
    message = harness.get_message!(body["message_status"]["message"]["id"])

    assert persisted_session.status == "open"
    assert persisted_session.last_sequence == 2
    assert message.session_id == session.id
    assert message.session_sequence == 2
    assert message.carrier_status == "rejected"
    assert message.trust == "untrusted"
    assert %DateTime{} = message.terminal_at
    assert harness.get_deliveries_for_message!(message.id) == []

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 0
           }

    :ok
  end

  @spec assert_successful_session_message_send(module(), harness(), Plug.Conn.t(), String.t()) ::
          :ok
  def assert_successful_session_message_send(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, recipient, session} =
      prepare_open_session!(adapter, harness, conn, key, active_webhook?: true)

    params = session_message_params("#{key}-message", "deliver session message by webhook")
    before_counts = harness.session_carrier_counts()

    assert {:ok, 201, body, prepared} =
             send_session_message(adapter, initiator, session.id, params, "#{key}-send")

    assert body["session"]["id"] == session.id
    assert body["session"]["status"] == "open"
    assert body["session"]["last_sequence"] == 2
    assert body["message_status"]["carrier_status"] == "queued"
    assert body["message_status"]["message"]["from"] == initiator.address
    assert body["message_status"]["message"]["to"] == recipient.address
    assert body["message_status"]["message"]["payload"] == params["payload"]
    assert body["message_status"]["message"]["session_id"] == session.id
    assert body["message_status"]["message"]["session_sequence"] == 2

    assert [delivery_status] = body["message_status"]["deliveries"]
    assert delivery_status["mode"] == "webhook"
    assert delivery_status["status"] == "retry_scheduled"
    assert delivery_status["attempt_count"] == 0

    assert %{commit_value: {session_id, webhook_delivery_id}} = prepared
    assert session_id == session.id
    assert is_binary(webhook_delivery_id)

    persisted_session = harness.get_session!(session.id)
    message = harness.get_message!(body["message_status"]["message"]["id"])

    assert persisted_session.last_sequence == 2
    assert message.sender_agent_id == initiator.id
    assert message.recipient_agent_id == recipient.id
    assert message.session_id == session.id
    assert message.session_sequence == 2
    assert message.content_type == "application/a2a+json"
    assert message.carrier_status == "queued"
    assert message.trust == "trusted"
    assert message.payload == params["payload"]

    assert [%Delivery{} = delivery] = harness.get_deliveries_for_message!(message.id)
    assert delivery.id == webhook_delivery_id
    assert delivery.recipient_agent_id == recipient.id
    assert delivery.mode == "webhook"
    assert delivery.status == "retry_scheduled"
    assert delivery.attempt_count == 0

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 1,
             sessions: 0
           }

    assert {:ok, 201, ^body} = complete_prepared_session_send(prepared)

    assert {:ok, 201, completed_body} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               session_message_params("#{key}-completed", "complete prepared session send"),
               "#{key}-completed-send"
             )

    assert completed_body["session"]["last_sequence"] == 3
    assert completed_body["message_status"]["message"]["session_sequence"] == 3

    :ok
  end

  @spec assert_concurrent_session_message_idempotency(
          module(),
          harness(),
          Plug.Conn.t(),
          String.t()
        ) :: :ok
  def assert_concurrent_session_message_idempotency(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {initiator, _recipient, session} = prepare_open_session!(adapter, harness, conn, key)
    params = session_message_params("#{key}-message", "retry-safe under concurrency")
    before_counts = harness.session_carrier_counts()

    results =
      1..2
      |> Task.async_stream(
        fn _index ->
          send_and_complete_session_message(adapter, initiator, session.id, params, "#{key}-send")
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    ok_results = Enum.filter(results, &match?({:ok, 201, _body}, &1))

    assert ok_results != []

    assert Enum.all?(results, fn result ->
             match?({:ok, 201, _body}, result) or result == {:error, :idempotency_in_progress}
           end)

    [{:ok, 201, first_body} | _rest] = ok_results

    assert {:ok, 201, replay_body} =
             send_and_complete_session_message(
               adapter,
               initiator,
               session.id,
               params,
               "#{key}-send"
             )

    assert replay_body == first_body

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 0,
             messages: 1,
             sessions: 0
           }

    assert [1, 2] =
             session.id
             |> harness.get_messages_for_session!()
             |> Enum.map(& &1.session_sequence)

    :ok
  end

  @spec assert_session_ordering(module(), harness(), Plug.Conn.t(), String.t()) :: :ok
  def assert_session_ordering(adapter, harness, conn, key)
      when is_atom(adapter) and is_atom(harness) and is_binary(key) do
    {first_delivery, second_delivery} =
      harness.prepare_ordered_session_webhook_deliveries!(conn, key)

    assert {:ok, %DeliveryClaim{} = first_claim} =
             claim_due(adapter, lease_seconds: 90)

    assert first_claim.delivery.id == first_delivery.id
    assert {:ok, nil} = claim_due(adapter, lease_seconds: 90)

    delivered_at = DateTime.utc_now(:microsecond)

    assert {:ok, %Message{}} =
             finish_claim(
               adapter,
               first_claim,
               delivered_attempt_result(first_claim, delivered_at)
             )

    assert {:ok, %DeliveryClaim{} = second_claim} =
             claim_due(adapter, lease_seconds: 90)

    assert second_claim.delivery.id == second_delivery.id

    :ok
  end

  defp assert_stale_finish_rejection(adapter, harness, conn, key) do
    {_delivery, message, _recipient_agent} = harness.prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_due(adapter, lease_seconds: 90)

    stale_claim = %{
      claim
      | claim_token: "dcl_stale",
        delivery: %{claim.delivery | claim_token: "dcl_stale"}
    }

    original_delivery = harness.get_delivery!(claim.delivery.id)
    original_message = harness.get_message!(message.id)

    assert {:error, :stale_delivery_claim} =
             finish_claim(
               adapter,
               stale_claim,
               delivered_attempt_result(stale_claim, DateTime.utc_now(:microsecond))
             )

    assert harness.webhook_attempt_count() == 0
    assert harness.get_delivery!(original_delivery.id) == original_delivery
    assert harness.get_message!(original_message.id) == original_message
  end

  defp assert_stale_terminalize_rejection(adapter, harness, conn, key) do
    {_delivery, message, _recipient_agent} = harness.prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_due(adapter, lease_seconds: 90)

    stale_claim = %{claim | delivery: %{claim.delivery | id: "dlv_missing"}}
    original_delivery = harness.get_delivery!(claim.delivery.id)
    original_message = harness.get_message!(message.id)

    assert {:error, :stale_delivery_claim} =
             terminalize_claim(adapter, stale_claim, :message_acked)

    assert harness.webhook_attempt_count() == 0
    assert harness.get_delivery!(original_delivery.id) == original_delivery
    assert harness.get_message!(original_message.id) == original_message
  end

  defp assert_finished_claim_state(adapter, harness, conn, key, result_kind) do
    {_delivery, message, recipient_agent} = harness.prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_due(adapter, lease_seconds: 90)

    result = attempt_result(result_kind, claim)

    assert {:ok, %Message{} = finished_message} =
             finish_claim(adapter, claim, result)

    assert finished_message.id == message.id
    assert finished_message.carrier_status == result.message_status

    persisted_delivery = harness.get_delivery!(claim.delivery.id)

    assert persisted_delivery.status == result.delivery_status
    assert persisted_delivery.attempt_count == claim.attempt_number
    assert persisted_delivery.delivered_at == result.delivered_at
    assert persisted_delivery.next_attempt_at == result.next_attempt_at
    assert persisted_delivery.last_error == result.error
    assert is_nil(persisted_delivery.claim_token)
    assert is_nil(persisted_delivery.claimed_at)
    assert is_nil(persisted_delivery.leased_until)

    assert %WebhookAttempt{} =
             attempt = harness.get_webhook_attempt_by_delivery!(claim.delivery.id)

    assert attempt.message_id == message.id
    assert attempt.recipient_agent_id == recipient_agent.id
    assert attempt.attempt_number == claim.attempt_number
    assert attempt.request_url == recipient_agent.webhook_url
    assert attempt.response_status == result.response_status
    assert attempt.error == result.error
    assert attempt.result == result.result
    assert attempt.next_attempt_at == result.next_attempt_at
  end

  defp delivered_attempt_result(%DeliveryClaim{} = claim, delivered_at) do
    %AttemptResult{
      attempt_number: claim.attempt_number,
      response_status: 204,
      error: nil,
      result: "delivered",
      delivery_status: "delivered",
      message_status: "delivered",
      next_attempt_at: nil,
      delivered_at: delivered_at
    }
  end

  defp failed_attempt_result(%DeliveryClaim{} = claim) do
    %AttemptResult{
      attempt_number: claim.attempt_number,
      response_status: 410,
      error: nil,
      result: "failed",
      delivery_status: "failed",
      message_status: "delivery_failed",
      next_attempt_at: nil,
      delivered_at: nil
    }
  end

  defp attempt_result(:delivered, %DeliveryClaim{} = claim) do
    delivered_attempt_result(claim, DateTime.utc_now(:microsecond))
  end

  defp attempt_result(:failed, %DeliveryClaim{} = claim), do: failed_attempt_result(claim)

  defp direct_message_params(recipient, message_id, text) do
    %{
      "to" => recipient.address,
      "payload" => Atp.ConnCase.a2a_user_text(message_id, text)
    }
  end

  defp session_open_params(recipient, message_id, text) do
    %{
      "to" => recipient.address,
      "payload" => Atp.ConnCase.a2a_user_text(message_id, text)
    }
  end

  defp session_message_params(message_id, text) do
    %{
      "payload" => Atp.ConnCase.a2a_user_text(message_id, text)
    }
  end

  defp accept_direct_message(adapter, sender, params, key),
    do: adapter.accept_direct_message(sender, params, key, @direct_message_route)

  defp accept_and_complete_direct_message(adapter, sender, params, key) do
    case accept_direct_message(adapter, sender, params, key) do
      {:ok, _status, _body, prepared} when is_map(prepared) ->
        complete_prepared_direct_message(prepared)

      {:ok, status, body, nil} ->
        {:ok, status, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_session(adapter, initiator, params, key),
    do: adapter.open_session(initiator, params, key, @session_open_route)

  defp open_and_complete_session(adapter, initiator, params, key) do
    case open_session(adapter, initiator, params, key) do
      {:ok, _status, _body, prepared} when is_map(prepared) ->
        complete_prepared_session_open(prepared)

      {:ok, status, body, nil} ->
        {:ok, status, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_session_message(adapter, sender, session_id, params, key) do
    route = "POST /api/sessions/#{session_id}/messages"
    adapter.send_session_message(sender, session_id, params, key, route)
  end

  defp accept_session(adapter, recipient, session_id, params, key) do
    route = "POST /api/sessions/#{session_id}/accept"
    adapter.accept_session(recipient, session_id, params, key, route)
  end

  defp reject_session(adapter, recipient, session_id, params, key) do
    route = "POST /api/sessions/#{session_id}/reject"
    adapter.reject_session(recipient, session_id, params, key, route)
  end

  defp ack_delivery(adapter, recipient, delivery_id, params, key) do
    route = "POST /api/deliveries/#{delivery_id}/acks"
    adapter.ack_delivery(recipient, delivery_id, params, key, route)
  end

  defp claim_inbox(adapter, recipient, params, key),
    do: adapter.claim_inbox(recipient, params, key, @polling_claim_route)

  defp extend_delivery(adapter, recipient, delivery_id, params, key) do
    route = "POST /api/deliveries/#{delivery_id}/extend"
    adapter.extend_delivery(recipient, delivery_id, params, key, route)
  end

  defp sender_policy_route(agent_id), do: "PUT /api/agents/#{agent_id}/sender_policies"

  defp later_timestamp?(later, earlier) do
    {:ok, later, 0} = DateTime.from_iso8601(later)
    {:ok, earlier, 0} = DateTime.from_iso8601(earlier)

    DateTime.compare(later, earlier) == :gt
  end

  defp assert_expired_session_action(adapter, harness, conn, key, action)
       when action in [:accept, :reject] do
    {initiator, recipient} = harness.prepare_session_pair!(conn, "#{key}-participants")

    assert {:ok, 201, opened} =
             open_and_complete_session(
               adapter,
               initiator,
               session_open_params(recipient, "#{key}-opening", "expire before lifecycle ACK"),
               "#{key}-open"
             )

    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]
    before_counts = harness.session_carrier_counts()

    opening_message_id
    |> harness.get_message!()
    |> harness.expire_message!()

    assert {:error, :message_expired} =
             expired_session_action(adapter, recipient, session_id, key, action)

    persisted_session = harness.get_session!(session_id)
    persisted_opening = harness.get_message!(opening_message_id)

    assert persisted_session.status == "failed"
    assert %DateTime{} = persisted_session.terminal_at
    refute persisted_session.opened_at

    assert persisted_opening.carrier_status == "expired"
    assert %DateTime{} = persisted_opening.terminal_at
    refute persisted_opening.current_ack_status

    assert harness.get_acks_for_message!(opening_message_id) == []

    assert session_carrier_delta(before_counts, harness.session_carrier_counts()) == %{
             deliveries: 1,
             messages: 0,
             sessions: 0
           }
  end

  defp expired_session_action(adapter, recipient, session_id, key, :accept) do
    accept_session(adapter, recipient, session_id, %{}, "#{key}-accept")
  end

  defp expired_session_action(adapter, recipient, session_id, key, :reject) do
    reject_session(adapter, recipient, session_id, %{}, "#{key}-reject")
  end

  defp send_and_complete_session_message(adapter, sender, session_id, params, key) do
    case send_session_message(adapter, sender, session_id, params, key) do
      {:ok, _status, _body, prepared} when is_map(prepared) ->
        complete_prepared_session_send(prepared)

      {:ok, status, body, nil} ->
        {:ok, status, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_prepared_direct_message(%{} = prepared) do
    Idempotency.complete_prepared_after_commit(prepared, fn status, body, _commit_value ->
      {:ok, status, body}
    end)
  end

  defp complete_prepared_session_open(%{} = prepared) do
    Idempotency.complete_prepared_after_commit(prepared, fn status, body, _commit_value ->
      {:ok, status, body}
    end)
  end

  defp complete_prepared_session_send(%{} = prepared) do
    Idempotency.complete_prepared_after_commit(prepared, fn status, body, _commit_value ->
      {:ok, status, body}
    end)
  end

  defp prepare_open_session!(adapter, harness, conn, key, opts \\ []) do
    {initiator, recipient} =
      if Keyword.get(opts, :active_webhook?, false) do
        harness.prepare_active_webhook_session_pair!(conn, key)
      else
        harness.prepare_session_pair!(conn, key)
      end

    params = session_open_params(recipient, "#{key}-opening", "open session")

    assert {:ok, 201, body} =
             open_and_complete_session(adapter, initiator, params, "#{key}-open")

    session =
      body["session"]["id"]
      |> harness.mark_session_open!()

    {initiator, recipient, session}
  end

  defp carrier_delta(before_counts, after_counts) do
    %{
      deliveries: after_counts.deliveries - before_counts.deliveries,
      messages: after_counts.messages - before_counts.messages
    }
  end

  defp session_carrier_delta(before_counts, after_counts) do
    %{
      deliveries: after_counts.deliveries - before_counts.deliveries,
      messages: after_counts.messages - before_counts.messages,
      sessions: after_counts.sessions - before_counts.sessions
    }
  end

  defp claim_due(adapter, opts), do: adapter.claim_due_webhook_delivery(opts)

  defp claim_delivery(adapter, delivery_id, opts),
    do: adapter.claim_webhook_delivery(delivery_id, opts)

  defp finish_claim(adapter, %DeliveryClaim{} = claim, %AttemptResult{} = result),
    do: adapter.finish_claimed_webhook_delivery(claim, result, [])

  defp terminalize_claim(adapter, %DeliveryClaim{} = claim, reason),
    do: adapter.terminalize_claimed_webhook_delivery(claim, reason, [])
end
