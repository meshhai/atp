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
      {"contract: session open replays stable idempotent responses",
       :assert_open_session_idempotent_replay, "session-open-replay"},
      {"contract: session open rejects idempotency body conflicts",
       :assert_open_session_idempotency_conflict, "session-open-conflict"},
      {"contract: invalid session open requests do not create carrier work",
       :assert_invalid_session_open_no_carrier_work, "session-open-invalid"},
      {"contract: blocked session open creates no delivery work",
       :assert_blocked_session_open_no_delivery_work, "session-open-blocked"},
      {"contract: successful session open creates session state and delivery work",
       :assert_successful_session_open, "session-open-success"},
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
