defmodule Atp.Transport.DurableLedger.PostgresContractTest do
  use Atp.Support.DurableLedgerContract,
    adapter: Atp.Transport.DurableLedger.Postgres,
    harness: Atp.Support.DurableLedgerContract.PostgresHarness

  import Ecto.Query

  alias Atp.Identity.{Account, Agent}
  alias Atp.Repo
  alias Atp.Transport.{Delivery, Message}
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

  test "postgres adapter advances after losing a concurrent polling claim race", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-claim-race-advance"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling claim race advance"})

      try do
        account_token = account["account_api_key"]["token"]

        sender_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-sender", %{})

        recipient_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

        sender = Repo.get!(Agent, sender_response["id"])
        recipient = Repo.get!(Agent, recipient_response["id"])
        first = accept_direct_message!(sender, recipient, "#{key}-first")
        second = accept_direct_message!(sender, recipient, "#{key}-second")
        first_message_id = first["message"]["id"]
        second_message_id = second["message"]["id"]

        lock_task = lock_message_until_release(first_message_id, self())
        assert_receive {:message_locked, ^first_message_id}, 5_000

        claim_tasks =
          for number <- 1..2 do
            claim_with_backend_task(self(), recipient, "claim-#{key}-#{number}")
          end

        assert_receive {:claim_backend_pid, first_backend_pid}, 5_000
        assert_receive {:claim_backend_pid, second_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(first_backend_pid, "first polling claim")
        assert_backend_waiting_on_lock!(second_backend_pid, "second polling claim")

        send(lock_task.pid, :release_message_lock)
        assert :ok = Task.await(lock_task, 5_000)

        claimed_message_ids =
          claim_tasks
          |> Enum.map(&Task.await(&1, 5_000))
          |> Enum.map(fn {:ok, 201, claim} -> claim["message"]["id"] end)
          |> Enum.sort()

        assert claimed_message_ids == Enum.sort([first_message_id, second_message_id])
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "postgres adapter rechecks polling eligibility after webhook delivery lease commits", %{
    conn: conn
  } do
    unboxed_repo(fn ->
      key = "polling-webhook-lease-race"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling webhook lease race"})

      try do
        account_token = account["account_api_key"]["token"]

        sender_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-sender", %{})

        recipient_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

        sender = Repo.get!(Agent, sender_response["id"])
        recipient = Repo.get!(Agent, recipient_response["id"]) |> enable_webhook!(key)
        sent = accept_direct_message!(sender, recipient, key)
        message_id = sent["message"]["id"]
        webhook_delivery = get_webhook_delivery_for_message!(message_id)

        webhook_lease_task =
          lease_delivery_until_release(webhook_delivery.id, self(), key)

        assert_receive {:delivery_leased, delivery_id}, 5_000
        assert delivery_id == webhook_delivery.id

        polling_claim_task =
          claim_with_backend_task(
            self(),
            recipient,
            "claim-#{key}-while-webhook-lease-waits"
          )

        assert_receive {:claim_backend_pid, claim_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(claim_backend_pid, "polling claim webhook lease")

        send(webhook_lease_task.pid, :release_delivery_lock)
        assert :ok = Task.await(webhook_lease_task, 5_000)

        assert {:ok, 200, %{"delivery" => nil}} = Task.await(polling_claim_task, 5_000)

        polling_deliveries =
          message_id
          |> @ledger_harness.get_deliveries_for_message!()
          |> Enum.filter(&(&1.mode == "polling"))

        assert polling_deliveries == []
      after
        delete_account!(account["id"])
      end
    end)
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

  test "postgres adapter serializes polling extension with expired lease reclaim", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-extend-reclaim-race"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling extend reclaim race"})

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
                   %{"lease_seconds" => 1},
                   "claim-#{key}",
                   @claim_route
                 )

        message_id = sent["message"]["id"]
        assert claim["message"]["id"] == message_id

        delivery_lock_task = lock_delivery_until_release(claim["id"], self())
        assert_receive {:delivery_locked, delivery_id}, 5_000
        assert delivery_id == claim["id"]

        extend_task =
          extend_with_backend_task(
            self(),
            recipient,
            claim["id"],
            key,
            120
          )

        assert_receive {:extend_backend_pid, backend_pid}, 5_000
        assert_backend_waiting_on_lock!(backend_pid, "polling lease extension")
        wait_until_after!(claim["leased_until"])

        reclaim_task =
          claim_with_backend_task(
            self(),
            recipient,
            "claim-#{key}-while-extension-waits"
          )

        assert_receive {:claim_backend_pid, claim_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(claim_backend_pid, "polling reclaim")

        send(delivery_lock_task.pid, :release_delivery_lock)
        assert :ok = Task.await(delivery_lock_task, 5_000)

        assert {:error, :lease_expired} = Task.await(extend_task, 5_000)
        assert {:ok, 201, reclaimed} = Task.await(reclaim_task, 5_000)

        assert reclaimed["id"] != claim["id"]
        assert reclaimed["message"]["id"] == message_id

        active_leases =
          message_id
          |> @ledger_harness.get_deliveries_for_message!()
          |> Enum.filter(&active_polling_lease?/1)

        assert [%Delivery{id: active_delivery_id}] = active_leases
        assert active_delivery_id == reclaimed["id"]
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "postgres adapter serializes polling lease extension with webhook claim", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-extend-webhook-race"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling extend webhook race"})

      try do
        account_token = account["account_api_key"]["token"]

        sender_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-sender", %{})

        recipient_response =
          Atp.ConnCase.register_agent!(account_token, "register-#{key}-recipient", %{})

        sender = Repo.get!(Agent, sender_response["id"])
        recipient = Repo.get!(Agent, recipient_response["id"]) |> enable_webhook!(key)
        sent = accept_direct_message!(sender, recipient, key)
        message_id = sent["message"]["id"]
        webhook_delivery = get_webhook_delivery_for_message!(message_id)

        assert {:ok, 201, claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 1},
                   "claim-#{key}",
                   @claim_route
                 )

        assert claim["message"]["id"] == message_id

        extension_lock_task =
          extend_delivery_lease_until_release(
            claim["id"],
            self(),
            120
          )

        assert_receive {:delivery_extended, delivery_id}, 5_000
        assert delivery_id == claim["id"]
        wait_until_after!(claim["leased_until"])

        webhook_claim_task =
          claim_webhook_with_backend_task(
            self(),
            webhook_delivery.id
          )

        assert_receive {:webhook_claim_backend_pid, webhook_claim_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(webhook_claim_backend_pid, "webhook claim")

        send(extension_lock_task.pid, :release_delivery_lock)
        assert :ok = Task.await(extension_lock_task, 5_000)

        assert {:error, :delivery_in_progress} = Task.await(webhook_claim_task, 5_000)

        active_leases =
          message_id
          |> @ledger_harness.get_deliveries_for_message!()
          |> Enum.filter(&active_polling_lease?/1)

        assert [%Delivery{id: active_delivery_id}] = active_leases
        assert active_delivery_id == claim["id"]
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "postgres adapter serializes polling lease extension with ACK", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-extend-ack-race"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling extend ACK race"})

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

        delivery_lock_task = lock_delivery_until_release(claim["id"], self())
        assert_receive {:delivery_locked, delivery_id}, 5_000
        assert delivery_id == claim["id"]

        extend_task =
          extend_with_backend_task(
            self(),
            recipient,
            claim["id"],
            key,
            120
          )

        assert_receive {:extend_backend_pid, extend_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(extend_backend_pid, "polling lease extension")

        ack_task = ack_with_backend_task(self(), recipient, claim["id"], key)
        assert_receive {:ack_backend_pid, ack_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(ack_backend_pid, "polling ACK")

        send(delivery_lock_task.pid, :release_delivery_lock)
        assert :ok = Task.await(delivery_lock_task, 5_000)

        extend_result = Task.await(extend_task, 5_000)
        ack_result = Task.await(ack_task, 5_000)

        assert match?({:ok, 200, _body}, extend_result) or
                 extend_result == {:error, :invalid_lease}

        assert {:ok, 201, acked} = ack_result
        assert acked["ack"]["status"] == "accepted"
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "postgres adapter does not create session lifecycle polling lease over active webhook lease",
       %{conn: conn} do
    {initiator, recipient} =
      @ledger_harness.prepare_active_webhook_session_pair!(
        conn,
        "session-lifecycle-webhook-lease"
      )

    assert {:ok, 201, opened, %{commit_value: {session_id, webhook_delivery_id}}} =
             @ledger_adapter.open_session(
               initiator,
               %{
                 "to" => recipient.address,
                 "payload" =>
                   a2a_user_text(
                     "session-lifecycle-webhook-lease-opening",
                     "open over webhook"
                   )
               },
               "open-session-lifecycle-webhook-lease",
               "POST /api/sessions"
             )

    opening_message_id = opened["message_status"]["message"]["id"]

    assert {:ok, %Atp.Transport.DeliveryClaim{} = webhook_claim} =
             @ledger_adapter.claim_webhook_delivery(webhook_delivery_id, lease_seconds: 60)

    assert webhook_claim.message.id == opening_message_id

    assert {:error, :delivery_in_progress} =
             @ledger_adapter.accept_session(
               recipient,
               session_id,
               %{},
               "accept-session-lifecycle-webhook-lease",
               "POST /api/sessions/#{session_id}/accept"
             )

    deliveries = @ledger_harness.get_deliveries_for_message!(opening_message_id)

    assert [%Delivery{id: ^webhook_delivery_id, mode: "webhook", status: "leased"}] =
             deliveries
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

  test "postgres adapter allows polling after prior session message was delivered by webhook", %{
    conn: conn
  } do
    {initiator, recipient} =
      @ledger_harness.prepare_session_pair!(conn, "polling-session-after-webhook")

    opened = open_session!(initiator, recipient, "polling-session-after-webhook")
    session_id = opened["session"]["id"]

    assert {:ok, 201, opening_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-after-webhook-opening",
               @claim_route
             )

    assert {:ok, 201, _ack} =
             @ledger_adapter.ack_delivery(
               recipient,
               opening_claim["id"],
               %{"status" => "accepted"},
               "ack-polling-session-after-webhook-opening",
               "POST /api/deliveries/#{opening_claim["id"]}/acks"
             )

    webhook_recipient = enable_webhook!(recipient, "polling-session-after-webhook")
    first = send_session_message!(initiator, session_id, "polling-session-after-webhook-first")
    first_message = @ledger_harness.get_message!(first["message_status"]["message"]["id"])
    first_delivery = get_webhook_delivery_for_message!(first_message.id)
    mark_webhook_delivery_delivered!(first_delivery, first_message)

    disable_webhook!(webhook_recipient)
    second = send_session_message!(initiator, session_id, "polling-session-after-webhook-second")

    assert {:ok, 201, second_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-polling-session-after-webhook-second",
               @claim_route
             )

    assert second_claim["message"]["id"] == second["message_status"]["message"]["id"]
  end

  test "postgres adapter blocks later webhook session delivery behind expired polling-only prior",
       %{conn: conn} do
    {initiator, recipient} =
      @ledger_harness.prepare_session_pair!(conn, "webhook-session-polling-prior")

    opened = open_session!(initiator, recipient, "webhook-session-polling-prior")
    session_id = opened["session"]["id"]

    assert {:ok, 201, opening_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-webhook-session-polling-prior-opening",
               @claim_route
             )

    assert {:ok, 201, _ack} =
             @ledger_adapter.ack_delivery(
               recipient,
               opening_claim["id"],
               %{"status" => "accepted"},
               "ack-webhook-session-polling-prior-opening",
               "POST /api/deliveries/#{opening_claim["id"]}/acks"
             )

    first = send_session_message!(initiator, session_id, "webhook-session-polling-prior-first")

    assert {:ok, 201, first_claim} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 1},
               "claim-webhook-session-polling-prior-first",
               @claim_route
             )

    assert first_claim["message"]["id"] == first["message_status"]["message"]["id"]

    first_claim["id"]
    |> @ledger_harness.get_delivery!()
    |> @ledger_harness.expire_delivery_lease!()

    enable_webhook!(recipient, "webhook-session-polling-prior")

    second = send_session_message!(initiator, session_id, "webhook-session-polling-prior-second")
    second_message_id = second["message_status"]["message"]["id"]
    second_webhook_delivery = get_webhook_delivery_for_message!(second_message_id)

    assert {:ok, nil} = @ledger_adapter.claim_due_webhook_delivery(lease_seconds: 60)

    assert {:ok, 201, reclaimed_first} =
             @ledger_adapter.claim_inbox(
               recipient,
               %{"lease_seconds" => 60},
               "claim-webhook-session-polling-prior-first-reclaim",
               @claim_route
             )

    assert reclaimed_first["message"]["id"] == first["message_status"]["message"]["id"]

    assert {:ok, %Atp.Transport.DeliveryClaim{} = second_webhook_claim} =
             @ledger_adapter.claim_due_webhook_delivery(lease_seconds: 60)

    assert second_webhook_claim.delivery.id == second_webhook_delivery.id
    assert second_webhook_claim.message.id == second_message_id
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

        first_claim_task =
          claim_with_backend_task(
            self(),
            recipient,
            "claim-#{key}-while-first-locked"
          )

        assert_receive {:claim_backend_pid, claim_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(claim_backend_pid, "locked earlier polling message")

        send(lock_task.pid, :release_message_lock)
        assert :ok = Task.await(lock_task, 5_000)

        assert {:ok, 201, first_claim} = Task.await(first_claim_task, 5_000)
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

        first_reclaim_task =
          claim_with_backend_task(
            self(),
            recipient,
            "claim-#{key}-while-first-expired-locked"
          )

        assert_receive {:claim_backend_pid, claim_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(claim_backend_pid, "locked expired polling message")

        send(lock_task.pid, :release_message_lock)
        assert :ok = Task.await(lock_task, 5_000)

        assert {:ok, 201, reclaimed_first} = Task.await(first_reclaim_task, 5_000)
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

  test "postgres adapter retries locked polling candidate when prior lease expires", %{conn: conn} do
    unboxed_repo(fn ->
      key = "polling-session-stale-later-candidate"
      account = Atp.ConnCase.create_account!(conn, %{"name" => "Polling stale candidate order"})

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
        second_message_id = second["message_status"]["message"]["id"]

        assert {:ok, 201, first_claim} =
                 @ledger_adapter.claim_inbox(
                   recipient,
                   %{"lease_seconds" => 60},
                   "claim-#{key}-first-initial",
                   @claim_route
                 )

        assert first_claim["message"]["id"] == first_message_id

        lock_task = lock_message_until_release(second_message_id, self())
        assert_receive {:message_locked, ^second_message_id}, 5_000

        later_claim_task =
          claim_with_backend_task(
            self(),
            recipient,
            "claim-#{key}-while-second-locked"
          )

        assert_receive {:claim_backend_pid, claim_backend_pid}, 5_000
        assert_backend_waiting_on_lock!(claim_backend_pid, "locked stale later polling message")

        first_claim["id"]
        |> @ledger_harness.get_delivery!()
        |> @ledger_harness.expire_delivery_lease!()

        send(lock_task.pid, :release_message_lock)
        assert :ok = Task.await(lock_task, 5_000)

        assert {:ok, 201, reclaimed_first} = Task.await(later_claim_task, 5_000)
        assert reclaimed_first["message"]["id"] == first_message_id
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

  defp lock_delivery_until_release(delivery_id, parent) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn -> hold_delivery_lock!(delivery_id, parent) end)
      :ok
    end)
  end

  defp hold_delivery_lock!(delivery_id, parent) do
    {:ok, :release_delivery_lock} =
      Repo.transaction(fn ->
        lock_delivery!(delivery_id)
        send(parent, {:delivery_locked, delivery_id})
        assert_receive :release_delivery_lock, 5_000
      end)
  end

  defp lease_delivery_until_release(delivery_id, parent, key) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn -> hold_leased_delivery_lock!(delivery_id, parent, key) end)
      :ok
    end)
  end

  defp hold_leased_delivery_lock!(delivery_id, parent, key) do
    {:ok, :release_delivery_lock} =
      Repo.transaction(fn ->
        delivery = lock_delivery!(delivery_id)
        now = DateTime.utc_now(:microsecond)

        delivery
        |> Ecto.Changeset.change(
          status: "leased",
          claim_token: "dcl_#{key}",
          claimed_at: now,
          leased_until: DateTime.add(now, 60, :second),
          attempt_count: delivery.attempt_count + 1
        )
        |> Repo.update!()

        send(parent, {:delivery_leased, delivery_id})
        assert_receive :release_delivery_lock, 5_000
      end)
  end

  defp extend_delivery_lease_until_release(delivery_id, parent, lease_seconds) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn ->
        hold_extended_delivery_lease!(delivery_id, parent, lease_seconds)
      end)

      :ok
    end)
  end

  defp hold_extended_delivery_lease!(delivery_id, parent, lease_seconds) do
    {:ok, :release_delivery_lock} =
      Repo.transaction(fn ->
        delivery = lock_delivery!(delivery_id)

        delivery
        |> Ecto.Changeset.change(
          leased_until: DateTime.add(delivery.leased_until, lease_seconds, :second)
        )
        |> Repo.update!()

        send(parent, {:delivery_extended, delivery_id})
        assert_receive :release_delivery_lock, 5_000
      end)
  end

  defp lock_delivery!(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
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

  defp extend_with_backend_task(parent, recipient, delivery_id, key, lease_seconds) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn ->
        backend_pid = db_backend_pid!()
        send(parent, {:extend_backend_pid, backend_pid})

        @ledger_adapter.extend_delivery(
          recipient,
          delivery_id,
          %{"lease_seconds" => lease_seconds},
          "extend-#{key}",
          "POST /api/deliveries/#{delivery_id}/extend"
        )
      end)
    end)
  end

  defp claim_with_backend_task(parent, recipient, key) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn ->
        backend_pid = db_backend_pid!()
        send(parent, {:claim_backend_pid, backend_pid})
        @ledger_adapter.claim_inbox(recipient, %{"lease_seconds" => 60}, key, @claim_route)
      end)
    end)
  end

  defp claim_webhook_with_backend_task(parent, delivery_id) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn ->
        backend_pid = db_backend_pid!()
        send(parent, {:webhook_claim_backend_pid, backend_pid})
        @ledger_adapter.claim_webhook_delivery(delivery_id, lease_seconds: 60)
      end)
    end)
  end

  defp ack_with_backend_task(parent, recipient, delivery_id, key) do
    Task.async(fn ->
      checked_out_unboxed_repo(fn ->
        backend_pid = db_backend_pid!()
        send(parent, {:ack_backend_pid, backend_pid})

        @ledger_adapter.ack_delivery(
          recipient,
          delivery_id,
          %{"status" => "accepted"},
          "ack-#{key}",
          "POST /api/deliveries/#{delivery_id}/acks"
        )
      end)
    end)
  end

  defp enable_webhook!(%Agent{} = agent, key) do
    agent
    |> Ecto.Changeset.change(
      webhook_active: true,
      webhook_url: "https://recipient.example.test/atp/#{key}",
      webhook_secret: "whsec_#{key}"
    )
    |> Repo.update!()
  end

  defp disable_webhook!(%Agent{} = agent) do
    agent
    |> Ecto.Changeset.change(webhook_active: false)
    |> Repo.update!()
  end

  defp get_webhook_delivery_for_message!(message_id) do
    Delivery
    |> where([delivery], delivery.message_id == ^message_id)
    |> where([delivery], delivery.mode == "webhook")
    |> Repo.one!()
  end

  defp mark_webhook_delivery_delivered!(%Delivery{} = delivery, %Message{} = message) do
    now = DateTime.utc_now(:microsecond)

    delivery
    |> Ecto.Changeset.change(status: "delivered", delivered_at: now)
    |> Repo.update!()

    message
    |> Ecto.Changeset.change(carrier_status: "delivered")
    |> Repo.update!()
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

  defp wait_until_after!(timestamp) do
    timestamp
    |> parse_timestamp!()
    |> wait_until_after!(System.monotonic_time(:millisecond) + 2_000)
  end

  defp wait_until_after!(timestamp, deadline) do
    if DateTime.compare(DateTime.utc_now(:microsecond), timestamp) == :gt do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("timestamp #{DateTime.to_iso8601(timestamp)} did not pass before deadline")
      else
        Process.sleep(10)
        wait_until_after!(timestamp, deadline)
      end
    end
  end

  defp active_polling_lease?(%Delivery{
         mode: "polling",
         status: "leased",
         leased_until: %DateTime{} = leased_until
       }) do
    DateTime.compare(leased_until, DateTime.utc_now(:microsecond)) == :gt
  end

  defp active_polling_lease?(%Delivery{}), do: false

  defp assert_backend_waiting_on_lock!(backend_pid, label) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert_backend_waiting_on_lock!(backend_pid, label, deadline)
  end

  defp assert_backend_waiting_on_lock!(backend_pid, label, deadline) do
    case backend_wait_event(backend_pid) do
      "Lock" ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("#{label} backend #{backend_pid} was not waiting on a lock")
        else
          Process.sleep(10)
          assert_backend_waiting_on_lock!(backend_pid, label, deadline)
        end
    end
  end

  defp backend_wait_event(backend_pid) do
    result =
      Repo.query!(
        "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    case result.rows do
      [[wait_event_type]] -> wait_event_type
      [] -> nil
    end
  end

  defp db_backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp later_timestamp?(later, earlier) do
    {:ok, later, 0} = DateTime.from_iso8601(later)
    {:ok, earlier, 0} = DateTime.from_iso8601(earlier)

    DateTime.compare(later, earlier) == :gt
  end
end
