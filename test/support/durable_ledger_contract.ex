defmodule Atp.Support.DurableLedgerContract do
  @moduledoc """
  Reusable ExUnit contract for durable ledger delivery claim adapters.

  Adapter-specific test modules `use` this contract with an `:adapter` option.
  The generated tests exercise carrier semantics through the
  `Atp.Transport.DurableLedger` callback shape.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    quote bind_quoted: [adapter: adapter] do
      use Atp.ConnCase, async: false

      alias Atp.Support.DurableLedgerContract

      @ledger_adapter adapter

      test "contract: one claimant receives a due delivery and active leases block duplicate work",
           %{conn: conn} do
        DurableLedgerContract.assert_single_claimant(@ledger_adapter, conn, "single-claimant")
      end

      test "contract: expired delivery leases can be reclaimed", %{conn: conn} do
        DurableLedgerContract.assert_lease_reclaim(@ledger_adapter, conn, "lease-reclaim")
      end

      test "contract: stale claims cannot finish or terminalize delivery", %{conn: conn} do
        DurableLedgerContract.assert_stale_claim_rejection(
          @ledger_adapter,
          conn,
          "stale-claim"
        )
      end

      test "contract: attempts atomically update delivery and message state", %{conn: conn} do
        DurableLedgerContract.assert_attempt_recording(@ledger_adapter, conn, "attempt-recording")
      end

      test "contract: claimed ACKed and expired messages terminalize without attempts", %{
        conn: conn
      } do
        DurableLedgerContract.assert_claim_terminalization(
          @ledger_adapter,
          conn,
          "claimed-terminal"
        )
      end

      test "contract: due ACKed and expired messages terminalize without attempts", %{conn: conn} do
        DurableLedgerContract.assert_due_claim_terminalization(
          @ledger_adapter,
          conn,
          "due-terminal"
        )
      end

      test "contract: direct ACKed and expired messages terminalize without attempts", %{
        conn: conn
      } do
        DurableLedgerContract.assert_direct_claim_terminalization(
          @ledger_adapter,
          conn,
          "direct-terminal"
        )
      end

      test "contract: session webhook delivery order is preserved", %{conn: conn} do
        DurableLedgerContract.assert_session_ordering(@ledger_adapter, conn, "session-order")
      end
    end
  end

  @endpoint AtpWeb.Endpoint

  import ExUnit.Assertions
  import Phoenix.ConnTest

  alias Atp.Identity.Agent
  alias Atp.Repo
  alias Atp.Transport.{Delivery, DeliveryClaim, Message, WebhookAttempt, WebhookDelivery}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @spec assert_single_claimant(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_single_claimant(adapter, conn, key) when is_atom(adapter) and is_binary(key) do
    {delivery, _message, _recipient_agent} = prepare_due_webhook_delivery!(conn, key)

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

  @spec assert_lease_reclaim(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_lease_reclaim(adapter, conn, key) when is_atom(adapter) and is_binary(key) do
    {delivery, _message, _recipient_agent} = prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = first_claim} =
             claim_delivery(adapter, delivery.id, lease_seconds: 60)

    first_claim.delivery
    |> Ecto.Changeset.change(
      leased_until: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Repo.update!()

    assert {:ok, %DeliveryClaim{} = reclaimed_claim} =
             claim_due(adapter, lease_seconds: 120)

    assert reclaimed_claim.delivery.id == delivery.id
    assert reclaimed_claim.claim_token =~ "dcl_"
    assert reclaimed_claim.claim_token != first_claim.claim_token
    assert reclaimed_claim.attempt_number == first_claim.attempt_number

    persisted_delivery = Repo.get!(Delivery, delivery.id)

    assert persisted_delivery.status == "leased"
    assert persisted_delivery.claim_token == reclaimed_claim.claim_token
    assert persisted_delivery.leased_until == reclaimed_claim.leased_until

    :ok
  end

  @spec assert_stale_claim_rejection(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_stale_claim_rejection(adapter, conn, key) when is_atom(adapter) and is_binary(key) do
    assert_stale_finish_rejection(adapter, conn, "#{key}-finish")
    assert_stale_terminalize_rejection(adapter, conn, "#{key}-terminalize")

    :ok
  end

  @spec assert_attempt_recording(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_attempt_recording(adapter, conn, key) when is_atom(adapter) and is_binary(key) do
    assert_finished_claim_state(adapter, conn, "#{key}-delivered", :delivered)
    assert_finished_claim_state(adapter, conn, "#{key}-failed", :failed)

    :ok
  end

  @spec assert_claim_terminalization(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_claim_terminalization(adapter, conn, key) when is_atom(adapter) and is_binary(key) do
    {acked_delivery, acked_message, _acked_agent} =
      prepare_due_webhook_delivery!(conn, "#{key}-acked")

    assert {:ok, %DeliveryClaim{} = acked_claim} =
             claim_delivery(adapter, acked_delivery.id, lease_seconds: 90)

    acked_message
    |> Ecto.Changeset.change(current_ack_status: "accepted")
    |> Repo.update!()

    assert {:ok, %Message{} = terminal_acked_message} =
             terminalize_claim(adapter, acked_claim, :message_acked)

    assert terminal_acked_message.id == acked_message.id

    persisted_acked_delivery = Repo.get!(Delivery, acked_delivery.id)
    persisted_acked_message = Repo.get!(Message, acked_message.id)

    assert persisted_acked_delivery.status == "failed"
    assert persisted_acked_delivery.last_error == "message_acked"
    assert is_nil(persisted_acked_delivery.claim_token)
    assert persisted_acked_message.current_ack_status == "accepted"

    {expired_delivery, expired_message, _expired_agent} =
      prepare_due_webhook_delivery!(conn, "#{key}-expired")

    assert {:ok, %DeliveryClaim{} = expired_claim} =
             claim_delivery(adapter, expired_delivery.id, lease_seconds: 90)

    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    expired_message
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    assert {:ok, %Message{} = terminal_expired_message} =
             terminalize_claim(adapter, expired_claim, :message_expired)

    assert terminal_expired_message.id == expired_message.id
    assert terminal_expired_message.carrier_status == "expired"

    persisted_expired_delivery = Repo.get!(Delivery, expired_delivery.id)

    assert persisted_expired_delivery.status == "failed"
    assert persisted_expired_delivery.last_error == "message_expired"
    assert is_nil(persisted_expired_delivery.claim_token)
    assert Repo.aggregate(WebhookAttempt, :count, :id) == 0

    :ok
  end

  @spec assert_due_claim_terminalization(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_due_claim_terminalization(adapter, conn, key)
      when is_atom(adapter) and is_binary(key) do
    {acked_delivery, acked_message, _acked_agent, recipient} =
      prepare_due_webhook_delivery_context!(conn, "#{key}-acked")

    polling_delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], "#{key}-claim-inbox", %{
        "lease_seconds" => 60
      })

    Atp.ConnCase.ack_delivery!(
      recipient["agent_api_key"]["token"],
      polling_delivery["id"],
      "#{key}-ack",
      %{"status" => "accepted"}
    )

    assert {:ok, nil} = claim_due(adapter, lease_seconds: 90)

    persisted_acked_delivery = Repo.get!(Delivery, acked_delivery.id)
    persisted_acked_message = Repo.get!(Message, acked_message.id)

    assert persisted_acked_delivery.status == "failed"
    assert persisted_acked_delivery.last_error == "message_acked"
    assert persisted_acked_delivery.attempt_count == 0
    assert is_nil(persisted_acked_delivery.claim_token)
    assert persisted_acked_message.current_ack_status == "accepted"

    {expired_delivery, expired_message, _expired_agent} =
      prepare_due_webhook_delivery!(conn, "#{key}-expired")

    expired_message
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Repo.update!()

    assert {:ok, nil} = claim_due(adapter, lease_seconds: 90)

    persisted_expired_delivery = Repo.get!(Delivery, expired_delivery.id)
    persisted_expired_message = Repo.get!(Message, expired_message.id)

    assert persisted_expired_delivery.status == "failed"
    assert persisted_expired_delivery.last_error == "message_expired"
    assert persisted_expired_delivery.attempt_count == 0
    assert is_nil(persisted_expired_delivery.claim_token)
    assert persisted_expired_message.carrier_status == "expired"
    assert %DateTime{} = persisted_expired_message.terminal_at
    assert Repo.aggregate(WebhookAttempt, :count, :id) == 0

    :ok
  end

  @spec assert_direct_claim_terminalization(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_direct_claim_terminalization(adapter, conn, key)
      when is_atom(adapter) and is_binary(key) do
    {acked_delivery, acked_message, _acked_agent, recipient} =
      prepare_due_webhook_delivery_context!(conn, "#{key}-acked")

    polling_delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], "#{key}-claim-inbox", %{
        "lease_seconds" => 60
      })

    Atp.ConnCase.ack_delivery!(
      recipient["agent_api_key"]["token"],
      polling_delivery["id"],
      "#{key}-ack",
      %{"status" => "accepted"}
    )

    assert {:ok, %Message{} = terminal_acked_message} =
             claim_delivery(adapter, acked_delivery.id, lease_seconds: 90)

    assert terminal_acked_message.id == acked_message.id

    persisted_acked_delivery = Repo.get!(Delivery, acked_delivery.id)
    persisted_acked_message = Repo.get!(Message, acked_message.id)

    assert persisted_acked_delivery.status == "failed"
    assert persisted_acked_delivery.last_error == "message_acked"
    assert persisted_acked_delivery.attempt_count == 0
    assert is_nil(persisted_acked_delivery.claim_token)
    assert is_nil(persisted_acked_delivery.claimed_at)
    assert is_nil(persisted_acked_delivery.leased_until)
    assert persisted_acked_message.current_ack_status == "accepted"

    {expired_delivery, expired_message, _expired_agent} =
      prepare_due_webhook_delivery!(conn, "#{key}-expired")

    expired_message
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Repo.update!()

    assert {:ok, %Message{} = terminal_expired_message} =
             claim_delivery(adapter, expired_delivery.id, lease_seconds: 90)

    assert terminal_expired_message.id == expired_message.id
    assert terminal_expired_message.carrier_status == "expired"

    persisted_expired_delivery = Repo.get!(Delivery, expired_delivery.id)
    persisted_expired_message = Repo.get!(Message, expired_message.id)

    assert persisted_expired_delivery.status == "failed"
    assert persisted_expired_delivery.last_error == "message_expired"
    assert persisted_expired_delivery.attempt_count == 0
    assert is_nil(persisted_expired_delivery.claim_token)
    assert is_nil(persisted_expired_delivery.claimed_at)
    assert is_nil(persisted_expired_delivery.leased_until)
    assert persisted_expired_message.carrier_status == "expired"
    assert %DateTime{} = persisted_expired_message.terminal_at
    assert Repo.aggregate(WebhookAttempt, :count, :id) == 0

    :ok
  end

  @spec assert_session_ordering(module(), Plug.Conn.t(), String.t()) :: :ok
  def assert_session_ordering(adapter, conn, key) when is_atom(adapter) and is_binary(key) do
    {first_delivery, second_delivery} = prepare_ordered_session_webhook_deliveries!(conn, key)

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

  defp assert_stale_finish_rejection(adapter, conn, key) do
    {_delivery, message, _recipient_agent} = prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_due(adapter, lease_seconds: 90)

    stale_claim = %{
      claim
      | claim_token: "dcl_stale",
        delivery: %{claim.delivery | claim_token: "dcl_stale"}
    }

    original_delivery = Repo.get!(Delivery, claim.delivery.id)
    original_message = Repo.get!(Message, message.id)

    assert {:error, :stale_delivery_claim} =
             finish_claim(
               adapter,
               stale_claim,
               delivered_attempt_result(stale_claim, DateTime.utc_now(:microsecond))
             )

    assert Repo.aggregate(WebhookAttempt, :count, :id) == 0
    assert Repo.get!(Delivery, original_delivery.id) == original_delivery
    assert Repo.get!(Message, original_message.id) == original_message
  end

  defp assert_stale_terminalize_rejection(adapter, conn, key) do
    {_delivery, message, _recipient_agent} = prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_due(adapter, lease_seconds: 90)

    stale_claim = %{claim | delivery: %{claim.delivery | id: "dlv_missing"}}
    original_delivery = Repo.get!(Delivery, claim.delivery.id)
    original_message = Repo.get!(Message, message.id)

    assert {:error, :stale_delivery_claim} =
             terminalize_claim(adapter, stale_claim, :message_acked)

    assert Repo.aggregate(WebhookAttempt, :count, :id) == 0
    assert Repo.get!(Delivery, original_delivery.id) == original_delivery
    assert Repo.get!(Message, original_message.id) == original_message
  end

  defp assert_finished_claim_state(adapter, conn, key, result_kind) do
    {_delivery, message, recipient_agent} = prepare_due_webhook_delivery!(conn, key)

    assert {:ok, %DeliveryClaim{} = claim} =
             claim_due(adapter, lease_seconds: 90)

    result = attempt_result(result_kind, claim)

    assert {:ok, %Message{} = finished_message} =
             finish_claim(adapter, claim, result)

    assert finished_message.id == message.id
    assert finished_message.carrier_status == result.message_status

    persisted_delivery = Repo.get!(Delivery, claim.delivery.id)

    assert persisted_delivery.status == result.delivery_status
    assert persisted_delivery.attempt_count == claim.attempt_number
    assert persisted_delivery.delivered_at == result.delivered_at
    assert persisted_delivery.next_attempt_at == result.next_attempt_at
    assert persisted_delivery.last_error == result.error
    assert is_nil(persisted_delivery.claim_token)
    assert is_nil(persisted_delivery.claimed_at)
    assert is_nil(persisted_delivery.leased_until)

    assert %WebhookAttempt{} =
             attempt = Repo.get_by!(WebhookAttempt, delivery_id: claim.delivery.id)

    assert attempt.message_id == message.id
    assert attempt.recipient_agent_id == recipient_agent.id
    assert attempt.attempt_number == claim.attempt_number
    assert attempt.request_url == recipient_agent.webhook_url
    assert attempt.response_status == result.response_status
    assert attempt.error == result.error
    assert attempt.result == result.result
    assert attempt.next_attempt_at == result.next_attempt_at
  end

  defp prepare_due_webhook_delivery!(conn, key) do
    {delivery, message, recipient_agent, _recipient} =
      prepare_due_webhook_delivery_context!(conn, key)

    {delivery, message, recipient_agent}
  end

  defp prepare_due_webhook_delivery_context!(conn, key) do
    account = Atp.ConnCase.create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = Atp.ConnCase.register_agent!(account_token, "register-#{key}-sender", %{})
    recipient = Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

    Atp.ConnCase.configure_webhook!(
      recipient,
      "configure-#{key}-webhook",
      "https://recipient.example.test/atp/#{key}"
    )

    set_webhook_active!(recipient["id"], false)

    sent =
      Atp.ConnCase.send_message!(
        sender["agent_api_key"]["token"],
        "send-#{key}",
        recipient["address"],
        Atp.ConnCase.a2a_user_text(key, "claim this webhook delivery")
      )

    message = Repo.get!(Message, sent["message"]["id"])
    recipient_agent = set_webhook_active!(recipient["id"], true)

    assert {:ok, delivery} = WebhookDelivery.prepare(message, recipient_agent)

    {delivery, message, recipient_agent, recipient}
  end

  defp prepare_ordered_session_webhook_deliveries!(conn, key) do
    account = Atp.ConnCase.create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = Atp.ConnCase.register_agent!(account_token, "register-#{key}-initiator", %{})
    recipient = Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

    Atp.ConnCase.configure_webhook!(
      recipient,
      "configure-#{key}-recipient",
      "https://recipient.example.test/atp/#{key}"
    )

    set_webhook_active!(recipient["id"], false)

    opened =
      Atp.ConnCase.open_session!(
        initiator["agent_api_key"]["token"],
        "open-#{key}",
        recipient["address"],
        Atp.ConnCase.a2a_user_text("#{key}-opening", "open ordered session")
      )

    opening_delivery =
      Atp.ConnCase.claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}-opening", %{
        "lease_seconds" => 60
      })

    Atp.ConnCase.ack_delivery!(
      recipient["agent_api_key"]["token"],
      opening_delivery["id"],
      "ack-#{key}-opening",
      %{"status" => "accepted"}
    )

    first =
      send_session_message!(
        initiator["agent_api_key"]["token"],
        opened["session"]["id"],
        "send-#{key}-first",
        Atp.ConnCase.a2a_user_text("#{key}-first", "first ordered webhook")
      )

    second =
      send_session_message!(
        initiator["agent_api_key"]["token"],
        opened["session"]["id"],
        "send-#{key}-second",
        Atp.ConnCase.a2a_user_text("#{key}-second", "second ordered webhook")
      )

    recipient_agent = set_webhook_active!(recipient["id"], true)
    first_message = Repo.get!(Message, first["message_status"]["message"]["id"])
    second_message = Repo.get!(Message, second["message_status"]["message"]["id"])

    assert {:ok, first_delivery} = WebhookDelivery.prepare(first_message, recipient_agent)
    assert {:ok, second_delivery} = WebhookDelivery.prepare(second_message, recipient_agent)

    {first_delivery, second_delivery}
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

  defp set_webhook_active!(agent_id, active?) do
    Agent
    |> Repo.get!(agent_id)
    |> Ecto.Changeset.change(webhook_active: active?)
    |> Repo.update!()
  end

  defp send_session_message!(agent_token, session_id, key, payload) do
    build_conn()
    |> Atp.ConnCase.authorize(agent_token)
    |> Atp.ConnCase.idempotency_key(key)
    |> post("/api/sessions/#{session_id}/messages", %{"payload" => payload})
    |> json_response(201)
  end

  defp claim_due(adapter, opts), do: adapter.claim_due_webhook_delivery(opts)

  defp claim_delivery(adapter, delivery_id, opts),
    do: adapter.claim_webhook_delivery(delivery_id, opts)

  defp finish_claim(adapter, %DeliveryClaim{} = claim, %AttemptResult{} = result),
    do: adapter.finish_claimed_webhook_delivery(claim, result, [])

  defp terminalize_claim(adapter, %DeliveryClaim{} = claim, reason),
    do: adapter.terminalize_claimed_webhook_delivery(claim, reason, [])
end
