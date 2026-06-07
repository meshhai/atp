defmodule Atp.WebhookDispatcherTest do
  use Atp.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Atp.Repo
  alias Atp.Transport.{Delivery, Message, WebhookAttempt, WebhookDelivery, WebhookDispatcher}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    old_config = Application.get_env(:atp, WebhookDispatcher)

    on_exit(fn ->
      if is_nil(old_config) do
        Application.delete_env(:atp, WebhookDispatcher)
      else
        Application.put_env(:atp, WebhookDispatcher, old_config)
      end
    end)

    :ok
  end

  test "direct message intake wakeup dispatches newly committed webhook work", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:direct_wakeup_webhook_request, headers["atp-delivery-id"]})
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    dispatcher = start_wakeup_dispatcher!(:atp_direct_wakeup_dispatcher_test)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-direct-wakeup-sender", %{})
    recipient = register_agent!(account_token, "register-direct-wakeup-recipient", %{})
    configure_webhook!(recipient, "configure-direct-wakeup-recipient")

    allow_dispatcher(dispatcher)

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-direct-wakeup-webhook",
        recipient["address"],
        a2a_user_text("direct-wakeup-webhook", "wake the dispatcher")
      )

    assert [%{"id" => delivery_id, "status" => "retry_scheduled", "attempt_count" => 0}] =
             sent["deliveries"]

    assert_receive {:direct_wakeup_webhook_request, ^delivery_id}, 500
    assert_delivered_delivery!(delivery_id)
  end

  test "session message intake wakeup dispatches newly committed webhook work", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, raw_body, request_conn} = Plug.Conn.read_body(request_conn)
      headers = Map.new(request_conn.req_headers)
      sequence = raw_body |> Jason.decode!() |> get_in(["message", "session_sequence"])

      send(
        test_pid,
        {:session_wakeup_webhook_request, headers["atp-delivery-id"], sequence}
      )

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-session-wakeup-initiator", %{})
    recipient = register_agent!(account_token, "register-session-wakeup-recipient", %{})

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-session-wakeup",
        recipient["address"],
        a2a_user_text("open-session-wakeup", "open before webhook")
      )

    opening_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-session-wakeup-opening", %{
        "lease_seconds" => 60
      })

    ack_delivery!(
      recipient["agent_api_key"]["token"],
      opening_delivery["id"],
      "accept-session-wakeup-opening",
      %{"status" => "accepted"}
    )

    configure_webhook!(recipient, "configure-session-wakeup-recipient")
    dispatcher = start_wakeup_dispatcher!(:atp_session_wakeup_dispatcher_test)
    allow_dispatcher(dispatcher)

    reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("send-session-wakeup-webhook")
      |> post("/api/sessions/#{opened["session"]["id"]}/messages", %{
        "payload" => a2a_user_text("session-wakeup-webhook", "wake for a session turn")
      })
      |> json_response(201)

    assert get_in(reply, ["message_status", "message", "session_sequence"]) == 2

    assert [%{"id" => delivery_id, "status" => "retry_scheduled", "attempt_count" => 0}] =
             reply["message_status"]["deliveries"]

    assert_receive {:session_wakeup_webhook_request, ^delivery_id, 2}, 500
    assert_delivered_delivery!(delivery_id)
  end

  test "max_in_flight limits concurrent attempts and leaves excess work unleased", %{
    conn: conn
  } do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:limited_webhook_started, delivery_id, self()})

      receive do
        :release_limited_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    delivery_ids = create_due_webhook_deliveries!(conn, 3, "limited-dispatcher")

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 10,
         max_in_flight: 2,
         interval_ms: 60_000,
         name: nil}
      )

    allow_dispatcher(dispatcher)
    send(dispatcher, :dispatch_due)

    first_started = assert_started_webhook(:limited_webhook_started)
    second_started = assert_started_webhook(:limited_webhook_started)
    started_ids = Enum.map([first_started, second_started], &elem(&1, 0))
    [unstarted_id] = delivery_ids -- started_ids

    refute_receive {:limited_webhook_started, _, _}, 100

    records = delivery_records(delivery_ids)

    for delivery_id <- started_ids do
      assert %{status: "leased", claim_token: claim_token, leased_until: %DateTime{}} =
               Map.fetch!(records, delivery_id)

      assert is_binary(claim_token)
    end

    assert %{
             status: "retry_scheduled",
             claim_token: nil,
             leased_until: nil
           } = Map.fetch!(records, unstarted_id)

    {_first_id, first_worker} = first_started
    send(first_worker, :release_limited_webhook)

    {third_started_id, third_worker} = assert_started_webhook(:limited_webhook_started)
    assert third_started_id == unstarted_id

    {_second_id, second_worker} = second_started
    send(second_worker, :release_limited_webhook)
    send(third_worker, :release_limited_webhook)

    for delivery_id <- delivery_ids do
      assert_delivered_delivery!(delivery_id)
    end
  end

  test "restart counts existing attempt tasks against max_in_flight", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:restart_bound_webhook_started, delivery_id, self()})

      receive do
        :release_restart_bound_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    delivery_ids = create_due_webhook_deliveries!(conn, 3, "restart-bound-dispatcher")
    task_supervisor = :atp_restart_bound_webhook_task_supervisor_test
    dispatcher_name = :atp_restart_bound_webhook_dispatcher_test

    start_supervised!({Task.Supervisor, name: task_supervisor})

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 10,
         max_in_flight: 2,
         interval_ms: 60_000,
         task_supervisor: task_supervisor,
         name: dispatcher_name}
      )

    allow_dispatcher(dispatcher)
    send(dispatcher, :dispatch_due)

    first_started = assert_started_webhook(:restart_bound_webhook_started)
    second_started = assert_started_webhook(:restart_bound_webhook_started)
    started_ids = Enum.map([first_started, second_started], &elem(&1, 0))
    [unstarted_id] = delivery_ids -- started_ids

    Process.exit(dispatcher, :kill)

    restarted_dispatcher = wait_for_dispatcher_restart(dispatcher_name, dispatcher)
    allow_dispatcher(restarted_dispatcher)
    send(restarted_dispatcher, :dispatch_due)

    refute_receive {:restart_bound_webhook_started, _, _}, 100

    {_first_id, first_worker} = first_started
    send(first_worker, :release_restart_bound_webhook)

    {third_started_id, third_worker} = assert_started_webhook(:restart_bound_webhook_started)
    assert third_started_id == unstarted_id

    {_second_id, second_worker} = second_started
    send(second_worker, :release_restart_bound_webhook)
    send(third_worker, :release_restart_bound_webhook)

    for delivery_id <- delivery_ids do
      assert_delivered_delivery!(delivery_id)
    end
  end

  test "task crashes record sanitized retry attempts and dispatcher continues", %{conn: conn} do
    test_pid = self()
    [crashing_id, continuing_id] = create_due_webhook_deliveries!(conn, 2, "crash-dispatcher")

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]
      send(test_pid, {:crash_record_webhook_started, delivery_id})

      if delivery_id == crashing_id do
        raise ~s(leak https://recipient.example.test/atp/webhook whsec_secret {"body":"hidden"})
      else
        Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 2,
         max_in_flight: 1,
         interval_ms: 60_000,
         name: nil}
      )

    allow_dispatcher(dispatcher)

    capture_log(fn ->
      send(dispatcher, :dispatch_due)

      assert_receive {:crash_record_webhook_started, ^crashing_id}, 500
      assert_retry_scheduled_task_exit!(crashing_id)

      assert_receive {:crash_record_webhook_started, ^continuing_id}, 500
      assert_delivered_delivery!(continuing_id)
    end)

    assert %{in_flight: in_flight} = :sys.get_state(dispatcher)
    assert map_size(in_flight) == 0
    assert Process.alive?(dispatcher)
  end

  test "task crashes respect max attempts through durable finish path", %{conn: conn} do
    test_pid = self()
    [delivery_id] = create_due_webhook_deliveries!(conn, 1, "crash-final-dispatcher")
    force_max_attempts!(delivery_id, 1)

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:final_crash_webhook_started, headers["atp-delivery-id"]})
      raise "internal crash with whsec_secret and request body"
    end)

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 1,
         max_in_flight: 1,
         interval_ms: 60_000,
         name: nil}
      )

    allow_dispatcher(dispatcher)

    capture_log(fn ->
      send(dispatcher, :dispatch_due)

      assert_receive {:final_crash_webhook_started, ^delivery_id}, 500
      assert_failed_task_exit!(delivery_id)
    end)

    assert %{in_flight: in_flight} = :sys.get_state(dispatcher)
    assert map_size(in_flight) == 0
    assert Process.alive?(dispatcher)
  end

  test "batch_size caps one scan even when worker capacity is available", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:batch_capped_webhook_started, delivery_id, self()})

      receive do
        :release_batch_capped_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    delivery_ids = create_due_webhook_deliveries!(conn, 3, "batch-capped-dispatcher")

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 1,
         max_in_flight: 3,
         interval_ms: 60_000,
         name: nil}
      )

    allow_dispatcher(dispatcher)
    send(dispatcher, :dispatch_due)

    {first_id, first_worker} = assert_started_webhook(:batch_capped_webhook_started)
    refute_receive {:batch_capped_webhook_started, _, _}, 100

    records = delivery_records(delivery_ids)

    assert %{status: "leased", claim_token: claim_token} = Map.fetch!(records, first_id)
    assert is_binary(claim_token)

    for delivery_id <- delivery_ids -- [first_id] do
      assert %{status: "retry_scheduled", claim_token: nil, leased_until: nil} =
               Map.fetch!(records, delivery_id)
    end

    send(first_worker, :release_batch_capped_webhook)
    assert_delivered_delivery!(first_id)
    refute_receive {:batch_capped_webhook_started, _, _}, 100

    send(dispatcher, :dispatch_due)
    {second_id, second_worker} = assert_started_webhook(:batch_capped_webhook_started)
    assert second_id in (delivery_ids -- [first_id])
    send(second_worker, :release_batch_capped_webhook)
    assert_delivered_delivery!(second_id)
  end

  test "periodic scan drains durable webhook work when no wakeup is delivered", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:periodic_scan_webhook_request, headers["atp-delivery-id"]})
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-periodic-scan-sender", %{})
    recipient = register_agent!(account_token, "register-periodic-scan-recipient", %{})
    configure_webhook!(recipient, "configure-periodic-scan-recipient")

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-periodic-scan-webhook",
        recipient["address"],
        a2a_user_text("periodic-scan-webhook", "recover without a wakeup")
      )

    assert [%{"id" => delivery_id, "status" => "retry_scheduled"}] = sent["deliveries"]
    refute_receive {:periodic_scan_webhook_request, ^delivery_id}, 100

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true, dispatch_on_start?: false, batch_size: 10, interval_ms: 25, name: nil}
      )

    allow_dispatcher(dispatcher)

    assert_receive {:periodic_scan_webhook_request, ^delivery_id}, 1_000
    assert_delivered_delivery!(delivery_id)
  end

  test "disabled webhook dispatcher ignores wakeups" do
    name = :atp_disabled_wakeup_dispatcher_test
    dispatcher = start_supervised!({WebhookDispatcher, enabled: false, name: name})

    assert :ok = WebhookDispatcher.wakeup(name)
    assert %{enabled?: false} = :sys.get_state(dispatcher)
  end

  defp start_wakeup_dispatcher!(name) when is_atom(name) do
    WebhookDispatcher
    |> dispatcher_config()
    |> Keyword.put(:name, name)
    |> then(&Application.put_env(:atp, WebhookDispatcher, &1))

    start_supervised!(
      {WebhookDispatcher,
       enabled: true, dispatch_on_start?: false, batch_size: 10, interval_ms: 60_000, name: name}
    )
  end

  defp dispatcher_config(module) do
    Application.get_env(:atp, module, [])
  end

  defp allow_dispatcher(dispatcher) when is_pid(dispatcher) do
    Sandbox.allow(Repo, self(), dispatcher)
    Req.Test.allow(WebhookDelivery, self(), dispatcher)
  end

  defp wait_for_dispatcher_restart(name, previous_pid, attempts_left \\ 20)

  defp wait_for_dispatcher_restart(name, previous_pid, attempts_left) when attempts_left > 0 do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous_pid ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_dispatcher_restart(name, previous_pid, attempts_left - 1)
    end
  end

  defp wait_for_dispatcher_restart(name, previous_pid, 0) do
    pid = Process.whereis(name)
    assert is_pid(pid) and pid != previous_pid
    pid
  end

  defp create_due_webhook_deliveries!(conn, count, key_prefix) do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "#{key_prefix}-sender", %{})
    recipient = register_agent!(account_token, "#{key_prefix}-recipient", %{})
    configure_webhook!(recipient, "#{key_prefix}-webhook")

    for index <- 1..count do
      sent =
        send_message!(
          sender["agent_api_key"]["token"],
          "#{key_prefix}-send-#{index}",
          recipient["address"],
          a2a_user_text("#{key_prefix}-message-#{index}", "dispatch #{index}")
        )

      assert [%{"id" => delivery_id, "status" => "retry_scheduled", "attempt_count" => 0}] =
               sent["deliveries"]

      delivery_id
    end
  end

  defp assert_started_webhook(tag) when is_atom(tag) do
    receive do
      {^tag, delivery_id, worker_pid} when is_binary(delivery_id) and is_pid(worker_pid) ->
        {delivery_id, worker_pid}
    after
      500 -> flunk("expected #{inspect(tag)}")
    end
  end

  defp delivery_records(delivery_ids) do
    Delivery
    |> where([delivery], delivery.id in ^delivery_ids)
    |> select([delivery], {
      delivery.id,
      delivery.status,
      delivery.claim_token,
      delivery.leased_until
    })
    |> Repo.all()
    |> Map.new(fn {id, status, claim_token, leased_until} ->
      {id, %{status: status, claim_token: claim_token, leased_until: leased_until}}
    end)
  end

  defp force_max_attempts!(delivery_id, max_attempts) do
    delivery = Repo.get!(Delivery, delivery_id)

    delivery
    |> Ecto.Changeset.change(max_attempts: max_attempts)
    |> Repo.update!()
  end

  defp assert_retry_scheduled_task_exit!(delivery_id, attempts_left \\ 20)

  defp assert_retry_scheduled_task_exit!(delivery_id, attempts_left) when attempts_left > 0 do
    case {Repo.get!(Delivery, delivery_id), Repo.get_by(WebhookAttempt, delivery_id: delivery_id)} do
      {%Delivery{status: "retry_scheduled", attempt_count: 1} = delivery,
       %WebhookAttempt{result: "retry_scheduled"} = attempt} ->
        assert_sanitized_task_exit_attempt!(delivery, attempt)
        assert %DateTime{} = delivery.next_attempt_at
        assert %DateTime{} = attempt.next_attempt_at
        assert is_nil(delivery.claim_token)
        assert is_nil(delivery.leased_until)
        delivery

      {%Delivery{}, _attempt} ->
        Process.sleep(10)
        assert_retry_scheduled_task_exit!(delivery_id, attempts_left - 1)
    end
  end

  defp assert_retry_scheduled_task_exit!(delivery_id, 0) do
    assert %Delivery{status: "retry_scheduled", attempt_count: 1} =
             delivery =
             Repo.get!(Delivery, delivery_id)

    assert %WebhookAttempt{result: "retry_scheduled"} =
             attempt =
             Repo.get_by!(WebhookAttempt, delivery_id: delivery_id)

    assert_sanitized_task_exit_attempt!(delivery, attempt)
  end

  defp assert_failed_task_exit!(delivery_id, attempts_left \\ 20)

  defp assert_failed_task_exit!(delivery_id, attempts_left) when attempts_left > 0 do
    case {Repo.get!(Delivery, delivery_id), Repo.get_by(WebhookAttempt, delivery_id: delivery_id)} do
      {%Delivery{status: "failed", attempt_count: 1} = delivery,
       %WebhookAttempt{result: "failed"} = attempt} ->
        assert_sanitized_task_exit_attempt!(delivery, attempt)
        assert is_nil(delivery.next_attempt_at)
        assert is_nil(attempt.next_attempt_at)
        assert is_nil(delivery.claim_token)
        assert is_nil(delivery.leased_until)

        assert %Message{carrier_status: "delivery_failed"} =
                 Repo.get!(Message, delivery.message_id)

        delivery

      {%Delivery{}, _attempt} ->
        Process.sleep(10)
        assert_failed_task_exit!(delivery_id, attempts_left - 1)
    end
  end

  defp assert_failed_task_exit!(delivery_id, 0) do
    assert %Delivery{status: "failed", attempt_count: 1} =
             delivery =
             Repo.get!(Delivery, delivery_id)

    assert %WebhookAttempt{result: "failed"} =
             attempt =
             Repo.get_by!(WebhookAttempt, delivery_id: delivery_id)

    assert_sanitized_task_exit_attempt!(delivery, attempt)
  end

  defp assert_sanitized_task_exit_attempt!(%Delivery{} = delivery, %WebhookAttempt{} = attempt) do
    assert delivery.last_error == "internal_task_exit"
    assert attempt.error == "internal_task_exit"
    assert attempt.attempt_number == 1
    assert is_nil(attempt.response_status)
    refute attempt.error =~ "whsec"
    refute attempt.error =~ "recipient.example.test"
    refute attempt.error =~ "body"
  end

  defp assert_delivered_delivery!(delivery_id, attempts_left \\ 20)

  defp assert_delivered_delivery!(delivery_id, attempts_left) when attempts_left > 0 do
    case Repo.get!(Delivery, delivery_id) do
      %Delivery{status: "delivered", attempt_count: 1} = delivery ->
        delivery

      %Delivery{} ->
        Process.sleep(10)
        assert_delivered_delivery!(delivery_id, attempts_left - 1)
    end
  end

  defp assert_delivered_delivery!(delivery_id, 0) do
    assert %Delivery{status: "delivered", attempt_count: 1} =
             Repo.get!(Delivery, delivery_id)
  end
end
