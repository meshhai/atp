defmodule Atp.Transport.DurableLedger.PostgresContractTest do
  use Atp.Support.DurableLedgerContract,
    adapter: Atp.Transport.DurableLedger.Postgres,
    harness: Atp.Support.DurableLedgerContract.PostgresHarness

  import Ecto.Query

  alias Atp.Identity.{Account, Agent}
  alias Atp.Repo
  alias Atp.Transport.Message
  alias Ecto.Adapters.SQL.Sandbox

  @claim_route "POST /api/inbox/claims"

  test "postgres adapter claims polling inbox messages and reclaims expired leases", %{
    conn: conn
  } do
    {sender, recipient} = @ledger_harness.prepare_direct_message_pair!(conn, "polling-claim")
    sent = accept_direct_message!(sender, recipient, "polling-claim")
    message_id = sent["message"]["id"]

    assert {:ok, 201, claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-claim",
               @claim_route
             )

    assert claim["message"]["id"] == message_id

    delivery = @ledger_harness.get_delivery!(claim["id"])
    delivered_message = @ledger_harness.get_message!(message_id)

    assert delivery.mode == "polling"
    assert delivery.status == "leased"
    assert delivery.recipient_agent_id == recipient.id
    assert delivery.message_id == message_id
    assert delivered_message.carrier_status == "delivered"

    assert {:ok, 201, ^claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-claim",
               @claim_route
             )

    assert {:ok, 200, %{"delivery" => nil}} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-hidden",
               @claim_route
             )

    @ledger_harness.expire_delivery_lease!(delivery)

    assert {:ok, 201, reclaimed} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-reclaimed",
               @claim_route
             )

    assert reclaimed["id"] != claim["id"]
    assert reclaimed["message"]["id"] == message_id
  end

  test "postgres adapter keeps ACKed and expired messages out of polling claims", %{conn: conn} do
    {sender, recipient} = @ledger_harness.prepare_direct_message_pair!(conn, "polling-invisible")
    acked = accept_direct_message!(sender, recipient, "polling-invisible-acked")
    expired = accept_direct_message!(sender, recipient, "polling-invisible-expired")

    assert {:ok, 201, acked_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-invisible-acked",
               @claim_route
             )

    assert acked_claim["message"]["id"] == acked["message"]["id"]

    assert {:ok, 201, _ack} =
             @ledger_adapter.ack_delivery(
               recipient,
               acked_claim["id"],
               %{"status" => "accepted"},
               "ack-polling-invisible",
               "POST /api/deliveries/#{acked_claim["id"]}/acks"
             )

    expired_message = @ledger_harness.get_message!(expired["message"]["id"])
    @ledger_harness.expire_message!(expired_message)

    assert {:ok, 200, %{"delivery" => nil}} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-invisible-empty",
               @claim_route
             )
  end

  test "postgres adapter extends polling leases and validates lease state", %{conn: conn} do
    {sender, recipient} = @ledger_harness.prepare_direct_message_pair!(conn, "polling-extend")
    sent = accept_direct_message!(sender, recipient, "polling-extend")

    assert {:ok, 201, claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-extend",
               @claim_route
             )

    assert claim["message"]["id"] == sent["message"]["id"]

    extend_route = "POST /api/deliveries/#{claim["id"]}/extend"

    assert {:ok, 200, extended} =
             @ledger_adapter.extend_delivery(
               recipient,
               claim["id"],
               %{"lease_seconds" => 120},
               "extend-polling-extend",
               extend_route
             )

    assert extended["id"] == claim["id"]
    assert extended["message"] == claim["message"]
    assert later_timestamp?(extended["leased_until"], claim["leased_until"])

    assert {:ok, 200, ^extended} =
             @ledger_adapter.extend_delivery(
               recipient,
               claim["id"],
               %{"lease_seconds" => 120},
               "extend-polling-extend",
               extend_route
             )

    assert {:error, :not_found} =
             @ledger_adapter.extend_delivery(
               sender,
               claim["id"],
               %{"lease_seconds" => 120},
               "extend-polling-wrong-owner",
               extend_route
             )

    assert {:error, :invalid_lease} =
             @ledger_adapter.extend_delivery(
               recipient,
               claim["id"],
               %{"lease_seconds" => -1},
               "extend-polling-invalid-seconds",
               extend_route
             )

    delivery = @ledger_harness.get_delivery!(claim["id"])
    @ledger_harness.expire_delivery_lease!(delivery)

    assert {:error, :lease_expired} =
             @ledger_adapter.extend_delivery(
               recipient,
               claim["id"],
               %{"lease_seconds" => 120},
               "extend-polling-expired",
               extend_route
             )

    {webhook_delivery, _message, webhook_recipient} =
      @ledger_harness.prepare_due_webhook_delivery!(conn, "polling-extend-webhook")

    assert {:error, :invalid_lease} =
             @ledger_adapter.extend_delivery(
               webhook_recipient,
               webhook_delivery.id,
               %{"lease_seconds" => 120},
               "extend-polling-webhook",
               "POST /api/deliveries/#{webhook_delivery.id}/extend"
             )
  end

  test "postgres adapter serializes concurrent polling lease extensions", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-extend-concurrent"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling extend concurrency"})

      try do
        account_token = account["account_api_key"]["token"]

        sender_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-sender", %{})

        recipient_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

        sender = Repo.get!(Agent, sender_response["id"])
        recipient = Repo.get!(Agent, recipient_response["id"])
        sent = accept_direct_message!(sender, recipient, key)

        assert {:ok, 201, claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}",
                   @claim_route
                 )

        assert claim["message"]["id"] == sent["message"]["id"]
        parent = self()

        tasks =
          for lease_seconds <- [60, 120] do
            concurrent_extend_task(parent, recipient, claim["id"], key, lease_seconds)
          end

        assert_receive {:extend_ready, 60}, 5_000
        assert_receive {:extend_ready, 120}, 5_000
        Enum.each(tasks, fn task -> send(task.pid, :extend_delivery) end)

        results = Enum.map(tasks, &Task.await(&1, 5_000))

        assert Enum.all?(results, &match?({:ok, 200, _body}, &1))

        final_delivery = @ledger_harness.get_delivery!(claim["id"])
        original_lease = parse_timestamp!(claim["leased_until"])

        assert DateTime.compare(
                 final_delivery.leased_until,
                 DateTime.add(original_lease, 170, :second)
               ) == :gt
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "postgres adapter claims polling session messages in sequence", %{conn: conn} do
    {initiator, recipient} = @ledger_harness.prepare_session_pair!(conn, "polling-session-order")
    opened = open_session!(initiator, recipient, "polling-session-order")
    session_id = opened["session"]["id"]
    opening_message_id = opened["message_status"]["message"]["id"]

    assert {:ok, 201, opening_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-opening",
               @claim_route
             )

    assert opening_claim["message"]["id"] == opening_message_id

    assert {:ok, 201, _ack} =
             @ledger_adapter.ack_delivery(
               recipient,
               opening_claim["id"],
               %{"status" => "accepted"},
               "ack-polling-session-opening",
               "POST /api/deliveries/#{opening_claim["id"]}/acks"
             )

    first = send_session_message!(initiator, session_id, "polling-session-order-first")
    second = send_session_message!(initiator, session_id, "polling-session-order-second")

    assert {:ok, 201, first_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-first",
               @claim_route
             )

    assert first_claim["message"]["id"] == first["message_status"]["message"]["id"]

    assert {:ok, 201, second_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-second",
               @claim_route
             )

    assert second_claim["message"]["id"] == second["message_status"]["message"]["id"]
  end

  test "postgres adapter does not let expired earlier session messages block polling claims", %{
    conn: conn
  } do
    {initiator, recipient} =
      @ledger_harness.prepare_session_pair!(conn, "polling-session-expired-prior")

    opened = open_session!(initiator, recipient, "polling-session-expired-prior")
    session_id = opened["session"]["id"]

    assert {:ok, 201, opening_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-expired-opening",
               @claim_route
             )

    assert {:ok, 201, _ack} =
             @ledger_adapter.ack_delivery(
               recipient,
               opening_claim["id"],
               %{"status" => "accepted"},
               "ack-polling-session-expired-opening",
               "POST /api/deliveries/#{opening_claim["id"]}/acks"
             )

    first = send_session_message!(initiator, session_id, "polling-session-expired-first")
    second = send_session_message!(initiator, session_id, "polling-session-expired-second")

    first_message = @ledger_harness.get_message!(first["message_status"]["message"]["id"])
    @ledger_harness.expire_message!(first_message)

    assert {:ok, 201, second_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-expired-second",
               @claim_route
             )

    assert second_claim["message"]["id"] == second["message_status"]["message"]["id"]
  end

  test "postgres adapter does not skip locked earlier polling session messages", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-session-locked-order"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling locked order"})

      try do
        account_token = account["account_api_key"]["token"]
        initiator_response = Atp.ConnCase.register_agent!(account_token, "register-#{key}-i", %{})
        recipient_response = Atp.ConnCase.register_agent!(account_token, "register-#{key}-r", %{})
        initiator = Repo.get!(Agent, initiator_response["id"])
        recipient = Repo.get!(Agent, recipient_response["id"])

        opened = open_session!(initiator, recipient, key)
        session_id = opened["session"]["id"]

        assert {:ok, 201, opening_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-opening",
                   @claim_route
                 )

        assert {:ok, 201, _ack} =
                 @ledger_adapter.ack_delivery(
                   recipient,
                   opening_claim["id"],
                   %{"status" => "accepted"},
                   "ack-#{key}-opening",
                   "POST /api/deliveries/#{opening_claim["id"]}/acks"
                 )

        first = send_session_message!(initiator, session_id, "#{key}-first")
        second = send_session_message!(initiator, session_id, "#{key}-second")
        first_message_id = first["message_status"]["message"]["id"]

        lock_task = lock_message_until_release(first_message_id, self())
        assert_receive {:message_locked, ^first_message_id}, 5_000

        assert {:ok, 200, %{"delivery" => nil}} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-while-first-locked",
                   @claim_route
                 )

        send(lock_task.pid, :release_message_lock)
        assert :ok = Task.await(lock_task, 5_000)

        assert {:ok, 201, first_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-first",
                   @claim_route
                 )

        assert first_claim["message"]["id"] == first_message_id

        assert {:ok, 201, second_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-second",
                   @claim_route
                 )

        assert second_claim["message"]["id"] == second["message_status"]["message"]["id"]
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "postgres adapter does not skip locked earlier messages after polling lease expiry", %{
    conn: conn
  } do
    unboxed_repo(fn ->
      key = "polling-session-expired-lease-locked"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling expired lease order"})

      try do
        account_token = account["account_api_key"]["token"]
        initiator_response = Atp.ConnCase.register_agent!(account_token, "register-#{key}-i", %{})
        recipient_response = Atp.ConnCase.register_agent!(account_token, "register-#{key}-r", %{})
        initiator = Repo.get!(Agent, initiator_response["id"])
        recipient = Repo.get!(Agent, recipient_response["id"])

        opened = open_session!(initiator, recipient, key)
        session_id = opened["session"]["id"]

        assert {:ok, 201, opening_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-opening",
                   @claim_route
                 )

        assert {:ok, 201, _ack} =
                 @ledger_adapter.ack_delivery(
                   recipient,
                   opening_claim["id"],
                   %{"status" => "accepted"},
                   "ack-#{key}-opening",
                   "POST /api/deliveries/#{opening_claim["id"]}/acks"
                 )

        first = send_session_message!(initiator, session_id, "#{key}-first")
        second = send_session_message!(initiator, session_id, "#{key}-second")

        assert {:ok, 201, first_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-first-initial",
                   @claim_route
                 )

        first_message_id = first["message_status"]["message"]["id"]
        assert first_claim["message"]["id"] == first_message_id

        first_claim["id"]
        |> @ledger_harness.get_delivery!()
        |> @ledger_harness.expire_delivery_lease!()

        lock_task = lock_message_until_release(first_message_id, self())
        assert_receive {:message_locked, ^first_message_id}, 5_000

        assert {:ok, 200, %{"delivery" => nil}} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-while-first-expired-locked",
                   @claim_route
                 )

        send(lock_task.pid, :release_message_lock)
        assert :ok = Task.await(lock_task, 5_000)

        assert {:ok, 201, reclaimed_first} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-first-reclaimed",
                   @claim_route
                 )

        assert reclaimed_first["message"]["id"] == first_message_id

        assert {:ok, 201, second_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-second",
                   @claim_route
                 )

        assert second_claim["message"]["id"] == second["message_status"]["message"]["id"]
      after
        delete_account!(account["id"])
      end
    end)
  end

  defp accept_direct_message!(sender, recipient, key) do
    assert {:ok, 201, body, _prepared} =
             @ledger_adapter.accept_direct_message(
               sender,
               %{
                 "to" => recipient.address,
                 "payload" => a2a_user_text(key, "durable polling lease")
               },
               "send-#{key}",
               "POST /api/messages"
             )

    body
  end

  defp open_session!(initiator, recipient, key) do
    assert {:ok, 201, body, _prepared} =
             @ledger_adapter.open_session(
               initiator,
               %{
                 "to" => recipient.address,
                 "payload" => a2a_user_text("#{key}-opening", "open durable polling session")
               },
               "open-#{key}",
               "POST /api/sessions"
             )

    body
  end

  defp send_session_message!(sender, session_id, key) do
    assert {:ok, 201, body, _prepared} =
             @ledger_adapter.send_session_message(
               sender,
               session_id,
               %{"payload" => a2a_user_text(key, "durable polling session message")},
               "send-#{key}",
               "POST /api/sessions/#{session_id}/messages"
             )

    body
  end

  defp lock_message_until_release(message_id, parent) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn -> hold_message_lock!(message_id, parent) end)
      :ok
    end)
  end

  defp hold_message_lock!(message_id, parent) do
    {:ok, :release_message_lock} =
      Repo.transaction(fn ->
        lock_message!(message_id)
        send(parent, {:message_locked, message_id})
        assert_receive :release_message_lock, 5_000
      end)
  end

  defp lock_message!(message_id) do
    Message
    |> where([message], message.id == ^message_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp concurrent_extend_task(parent, recipient, delivery_id, key, lease_seconds) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn ->
        send(parent, {:extend_ready, lease_seconds})
        assert_receive :extend_delivery, 5_000

        @ledger_adapter.extend_delivery(
          recipient,
          delivery_id,
          %{"lease_seconds" => lease_seconds},
          "extend-#{key}-#{lease_seconds}",
          "POST /api/deliveries/#{delivery_id}/extend"
        )
      end)
    end)
  end

  defp unboxed_repo(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp checked_out_unboxed_repo(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.checkout(fun)
    end)
  end

  defp delete_account!(account_id) do
    Account
    |> Repo.get!(account_id)
    |> Repo.delete!()
  end

  defp parse_timestamp!(timestamp) do
    {:ok, parsed, 0} = DateTime.from_iso8601(timestamp)
    parsed
  end

  defp later_timestamp?(later, earlier) do
    {:ok, later, 0} = DateTime.from_iso8601(later)
    {:ok, earlier, 0} = DateTime.from_iso8601(earlier)

    DateTime.compare(later, earlier) == :gt
  end
end
