defmodule Atp.Support.DurableLedgerContract do
  @moduledoc """
  Reusable ExUnit contract for durable ledger delivery claim adapters.

  Adapter-specific test modules `use` this contract with an `:adapter` and a
  `:harness`. The shared contract exercises carrier semantics through the
  `Atp.Transport.DurableLedger` callback shape. Adapter-specific setup,
  persistence reads, and state mutations live in the harness.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    harness = Keyword.fetch!(opts, :harness)
    case_template = Keyword.get(opts, :case_template, Atp.ConnCase)

    quote do
      use unquote(case_template), async: false

      alias Atp.Support.DurableLedgerContract

      @ledger_adapter unquote(adapter)
      @ledger_harness unquote(harness)

      test "contract: one claimant receives a due delivery and active leases block duplicate work",
           %{conn: conn} do
        DurableLedgerContract.assert_single_claimant(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "single-claimant"
        )
      end

      test "contract: expired delivery leases can be reclaimed", %{conn: conn} do
        DurableLedgerContract.assert_lease_reclaim(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "lease-reclaim"
        )
      end

      test "contract: stale claims cannot finish or terminalize delivery", %{conn: conn} do
        DurableLedgerContract.assert_stale_claim_rejection(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "stale-claim"
        )
      end

      test "contract: attempts atomically update delivery and message state", %{conn: conn} do
        DurableLedgerContract.assert_attempt_recording(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "attempt-recording"
        )
      end

      test "contract: claimed ACKed and expired messages terminalize without attempts", %{
        conn: conn
      } do
        DurableLedgerContract.assert_claim_terminalization(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "claimed-terminal"
        )
      end

      test "contract: due ACKed and expired messages terminalize without attempts", %{conn: conn} do
        DurableLedgerContract.assert_due_claim_terminalization(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "due-terminal"
        )
      end

      test "contract: direct ACKed and expired messages terminalize without attempts", %{
        conn: conn
      } do
        DurableLedgerContract.assert_direct_claim_terminalization(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "direct-terminal"
        )
      end

      test "contract: session webhook delivery order is preserved", %{conn: conn} do
        DurableLedgerContract.assert_session_ordering(
          @ledger_adapter,
          @ledger_harness,
          conn,
          "session-order"
        )
      end
    end
  end

  import ExUnit.Assertions

  alias Atp.Transport.{DeliveryClaim, Message, WebhookAttempt}
  alias Atp.Transport.WebhookDelivery.AttemptResult

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

  defp claim_due(adapter, opts), do: adapter.claim_due_webhook_delivery(opts)

  defp claim_delivery(adapter, delivery_id, opts),
    do: adapter.claim_webhook_delivery(delivery_id, opts)

  defp finish_claim(adapter, %DeliveryClaim{} = claim, %AttemptResult{} = result),
    do: adapter.finish_claimed_webhook_delivery(claim, result, [])

  defp terminalize_claim(adapter, %DeliveryClaim{} = claim, reason),
    do: adapter.terminalize_claimed_webhook_delivery(claim, reason, [])
end
