defmodule Atp.WebhookDispatcherTest do
  use Atp.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Atp.Repo
  alias Atp.Transport.{Delivery, Message, WebhookAttempt, WebhookDelivery, WebhookDispatcher}
  alias Ecto.Adapters.SQL.Sandbox

  @dispatcher_scan_event [:atp, :transport, :webhook_dispatcher, :scan]
  @dispatcher_claim_event [:atp, :transport, :webhook_dispatcher, :claim]
  @dispatcher_attempt_start_event [:atp, :transport, :webhook_dispatcher, :attempt, :start]
  @dispatcher_attempt_finish_event [:atp, :transport, :webhook_dispatcher, :attempt, :finish]
  @dispatcher_task_exit_event [:atp, :transport, :webhook_dispatcher, :attempt, :exit]

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

  test "shutdown waits for in-flight attempts without starting new claims", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:shutdown_wait_webhook_started, delivery_id, self()})

      receive do
        :release_shutdown_wait_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    delivery_ids = create_due_webhook_deliveries!(conn, 2, "shutdown-wait-dispatcher")

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 10,
         max_in_flight: 1,
         shutdown_wait_ms: 500,
         interval_ms: 60_000,
         name: nil}
      )

    allow_dispatcher(dispatcher)
    send(dispatcher, :dispatch_due)

    {started_id, worker} = assert_started_webhook(:shutdown_wait_webhook_started)
    [unstarted_id] = delivery_ids -- [started_id]

    stop_task =
      Task.async(fn ->
        result = GenServer.stop(dispatcher, :normal, 1_000)
        send(test_pid, {:shutdown_wait_stop_returned, result})
        result
      end)

    refute_receive {:shutdown_wait_stop_returned, _result}, 50

    send(worker, :release_shutdown_wait_webhook)

    assert :ok = Task.await(stop_task, 1_000)
    assert_receive {:shutdown_wait_stop_returned, :ok}, 100
    assert_delivered_delivery!(started_id)
    refute_receive {:shutdown_wait_webhook_started, ^unstarted_id, _worker}, 100

    assert %{
             status: "retry_scheduled",
             claim_token: nil,
             leased_until: nil
           } = Map.fetch!(delivery_records([unstarted_id]), unstarted_id)
  end

  test "shutdown timeout leaves unfinished leased work recoverable after lease expiry", %{
    conn: conn
  } do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:shutdown_expiry_webhook_started, delivery_id, self()})

      receive do
        :release_shutdown_expiry_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    [delivery_id] = create_due_webhook_deliveries!(conn, 1, "shutdown-expiry-dispatcher")
    attempt_supervisor = :atp_shutdown_expiry_webhook_attempt_supervisor_test
    attempt_supervisor_id = :atp_shutdown_expiry_webhook_attempt_supervisor_child_test

    start_supervised!(
      {DynamicSupervisor, name: attempt_supervisor, strategy: :one_for_one},
      id: attempt_supervisor_id
    )

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 1,
         max_in_flight: 1,
         shutdown_wait_ms: 10,
         interval_ms: 60_000,
         attempt_supervisor: attempt_supervisor,
         name: nil},
        id: :atp_shutdown_expiry_first_dispatcher_test
      )

    allow_dispatcher(dispatcher)
    send(dispatcher, :dispatch_due)

    assert_receive {:shutdown_expiry_webhook_started, ^delivery_id, first_worker}, 500

    stop_task = Task.async(fn -> GenServer.stop(dispatcher, :normal, 1_000) end)
    assert :ok = Task.await(stop_task, 1_000)

    assert %{status: "leased", claim_token: claim_token, leased_until: %DateTime{}} =
             Map.fetch!(delivery_records([delivery_id]), delivery_id)

    assert is_binary(claim_token)

    stop_supervised!(attempt_supervisor_id)
    refute_process_alive!(first_worker)
    expire_delivery_lease!(delivery_id)

    start_supervised!(
      {DynamicSupervisor, name: attempt_supervisor, strategy: :one_for_one},
      id: attempt_supervisor_id
    )

    restarted_dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 1,
         max_in_flight: 1,
         shutdown_wait_ms: 10,
         interval_ms: 60_000,
         attempt_supervisor: attempt_supervisor,
         name: nil},
        id: :atp_shutdown_expiry_second_dispatcher_test
      )

    allow_dispatcher(restarted_dispatcher)
    send(restarted_dispatcher, :dispatch_due)

    assert_receive {:shutdown_expiry_webhook_started, ^delivery_id, second_worker}, 500
    send(second_worker, :release_shutdown_expiry_webhook)

    assert_delivered_delivery!(delivery_id)
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
    attempt_supervisor = :atp_restart_bound_webhook_attempt_supervisor_test
    dispatcher_name = :atp_restart_bound_webhook_dispatcher_test

    start_supervised!({DynamicSupervisor, name: attempt_supervisor, strategy: :one_for_one})

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 10,
         max_in_flight: 2,
         interval_ms: 60_000,
         attempt_supervisor: attempt_supervisor,
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

  test "restart preserves claim metadata for re-monitored task exits", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:restart_exit_webhook_started, delivery_id, self()})

      receive do
        :release_restart_exit_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    [delivery_id] = create_due_webhook_deliveries!(conn, 1, "restart-exit-dispatcher")
    attempt_supervisor = :atp_restart_exit_webhook_attempt_supervisor_test
    dispatcher_name = :atp_restart_exit_webhook_dispatcher_test

    start_supervised!({DynamicSupervisor, name: attempt_supervisor, strategy: :one_for_one})

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 1,
         max_in_flight: 1,
         interval_ms: 60_000,
         attempt_supervisor: attempt_supervisor,
         name: dispatcher_name}
      )

    allow_dispatcher(dispatcher)
    send(dispatcher, :dispatch_due)

    assert_receive {:restart_exit_webhook_started, ^delivery_id, worker}, 500

    Process.exit(dispatcher, :kill)

    restarted_dispatcher = wait_for_dispatcher_restart(dispatcher_name, dispatcher)
    allow_dispatcher(restarted_dispatcher)

    log =
      capture_log(fn ->
        Process.exit(worker, :kill)
        assert_retry_scheduled_task_exit!(delivery_id)
        assert_dispatcher_idle!(restarted_dispatcher)
      end)

    assert_sanitized_task_crash_log!(log)
    assert Process.alive?(restarted_dispatcher)
  end

  test "externally stopped workers record durable task-exit attempts while dispatcher runs", %{
    conn: conn
  } do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:external_stop_webhook_started, delivery_id, self()})

      receive do
        :release_external_stop_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    delivery_ids = create_due_webhook_deliveries!(conn, 2, "external-stop-dispatcher")

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
    send(dispatcher, :dispatch_due)

    {first_id, first_worker} = assert_started_webhook(:external_stop_webhook_started)
    Process.exit(first_worker, :shutdown)
    assert_retry_scheduled_task_exit!(first_id)

    {second_id, second_worker} = assert_started_webhook(:external_stop_webhook_started)
    Process.exit(second_worker, {:shutdown, :external_stop})
    assert_retry_scheduled_task_exit!(second_id)

    assert Enum.sort([first_id, second_id]) == Enum.sort(delivery_ids)
    assert_dispatcher_idle!(dispatcher)
    assert Process.alive?(dispatcher)
  end

  test "session webhook ordering continues within scan budget after prior attempt finishes", %{
    conn: conn
  } do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, raw_body, request_conn} = Plug.Conn.read_body(request_conn)
      headers = Map.new(request_conn.req_headers)
      sequence = raw_body |> Jason.decode!() |> get_in(["message", "session_sequence"])
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:session_ordered_webhook_started, sequence, delivery_id, self()})

      if sequence == 2 do
        receive do
          :release_session_ordered_webhook -> :ok
        end
      end

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    %{deliveries: %{2 => first_delivery_id, 3 => second_delivery_id}} =
      create_due_session_webhook_deliveries!(conn, "ordered-dispatcher")

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

    assert_receive {:session_ordered_webhook_started, 2, ^first_delivery_id, first_worker}, 500
    refute_receive {:session_ordered_webhook_started, 3, ^second_delivery_id, _worker}, 100

    assert %Delivery{status: "retry_scheduled", claim_token: nil, leased_until: nil} =
             Repo.get!(Delivery, second_delivery_id)

    send(first_worker, :release_session_ordered_webhook)

    assert_receive {:session_ordered_webhook_started, 3, ^second_delivery_id, _second_worker},
                   500

    assert_delivered_delivery!(first_delivery_id)
    assert_delivered_delivery!(second_delivery_id)
  end

  test "dispatcher emits safe telemetry for scans claims and successful attempts", %{conn: conn} do
    test_pid = self()
    attach_dispatcher_telemetry!(test_pid)

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]

      send(test_pid, {:telemetry_success_webhook_started, delivery_id, self()})

      receive do
        :release_telemetry_success_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    [delivery_id] =
      create_due_webhook_deliveries!(conn, 1, "telemetry-success-dispatcher",
        text: "telemetry-hidden-body",
        webhook_url: "https://recipient.example.test/atp/webhook?token=telemetry-hidden-url"
      )

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
    send(dispatcher, :dispatch_due)

    assert_receive {:webhook_dispatcher_telemetry, @dispatcher_scan_event, scan_measurements,
                    %{trigger: :timer} = scan_metadata},
                   500

    assert scan_measurements.in_flight == 0
    assert scan_measurements.max_in_flight == 1
    assert scan_measurements.available_capacity == 1
    assert scan_metadata.batch_size == 1
    assert_safe_telemetry!(scan_measurements, scan_metadata)

    assert_receive {:webhook_dispatcher_telemetry, @dispatcher_claim_event, claim_measurements,
                    %{delivery_id: ^delivery_id, result: :claimed} = claim_metadata},
                   500

    assert claim_metadata.message_id == message_id_for_delivery!(delivery_id)
    assert claim_metadata.attempt_number == 1
    assert claim_measurements.in_flight == 0
    assert_safe_telemetry!(claim_measurements, claim_metadata)

    assert_receive {:webhook_dispatcher_telemetry, @dispatcher_attempt_start_event,
                    start_measurements,
                    %{delivery_id: ^delivery_id, attempt_number: 1} = start_metadata},
                   500

    assert start_measurements.in_flight == 1
    assert_safe_telemetry!(start_measurements, start_metadata)

    assert_receive {:telemetry_success_webhook_started, ^delivery_id, worker}, 500
    send(worker, :release_telemetry_success_webhook)

    assert_receive {:webhook_dispatcher_telemetry, @dispatcher_attempt_finish_event,
                    finish_measurements,
                    %{
                      delivery_id: ^delivery_id,
                      attempt_number: 1,
                      result: "delivered",
                      message_status: "delivered"
                    } = finish_metadata},
                   500

    assert finish_measurements.in_flight == 0
    assert_safe_telemetry!(finish_measurements, finish_metadata)

    assert_delivered_delivery!(delivery_id)
  end

  test "dispatcher emits safe telemetry for retries failures and task exits", %{conn: conn} do
    test_pid = self()
    attach_dispatcher_telemetry!(test_pid)

    [retry_id, failed_id, crash_id] =
      create_due_webhook_deliveries!(conn, 3, "telemetry-outcomes-dispatcher",
        text: "telemetry-hidden-body",
        webhook_url: "https://recipient.example.test/atp/webhook?token=telemetry-hidden-url"
      )

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery_id = headers["atp-delivery-id"]
      send(test_pid, {:telemetry_outcome_webhook_started, delivery_id})

      cond do
        delivery_id == retry_id ->
          Plug.Conn.send_resp(request_conn, 500, "")

        delivery_id == failed_id ->
          Plug.Conn.send_resp(request_conn, 400, "")

        delivery_id == crash_id ->
          raise ~s(leak https://recipient.example.test/atp/webhook whsec_secret telemetry-hidden-body)
      end
    end)

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true,
         dispatch_on_start?: false,
         batch_size: 3,
         max_in_flight: 1,
         interval_ms: 60_000,
         name: nil}
      )

    allow_dispatcher(dispatcher)

    log =
      capture_log(fn ->
        send(dispatcher, :dispatch_due)

        assert_receive {:telemetry_outcome_webhook_started, ^retry_id}, 500

        assert_receive {:webhook_dispatcher_telemetry, @dispatcher_attempt_finish_event,
                        retry_measurements,
                        %{
                          delivery_id: ^retry_id,
                          result: "retry_scheduled",
                          message_status: "queued"
                        } = retry_metadata},
                       500

        assert_safe_telemetry!(retry_measurements, retry_metadata)
        assert_retry_scheduled_delivery!(retry_id)

        assert_receive {:telemetry_outcome_webhook_started, ^failed_id}, 500

        assert_receive {:webhook_dispatcher_telemetry, @dispatcher_attempt_finish_event,
                        failed_measurements,
                        %{
                          delivery_id: ^failed_id,
                          result: "failed",
                          message_status: "delivery_failed"
                        } = failed_metadata},
                       500

        assert_safe_telemetry!(failed_measurements, failed_metadata)
        assert_failed_delivery!(failed_id)

        assert_receive {:telemetry_outcome_webhook_started, ^crash_id}, 500

        assert_receive {:webhook_dispatcher_telemetry, @dispatcher_task_exit_event,
                        exit_measurements,
                        %{
                          delivery_id: ^crash_id,
                          result: "retry_scheduled",
                          message_status: "queued",
                          error_class: "internal_task_exit"
                        } = exit_metadata},
                       500

        assert_safe_telemetry!(exit_measurements, exit_metadata)
        assert_retry_scheduled_task_exit!(crash_id)
      end)

    assert_sanitized_task_crash_log!(log)
    assert Process.alive?(dispatcher)
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

    log =
      capture_log(fn ->
        send(dispatcher, :dispatch_due)

        assert_receive {:crash_record_webhook_started, ^crashing_id}, 500
        assert_retry_scheduled_task_exit!(crashing_id)

        assert_receive {:crash_record_webhook_started, ^continuing_id}, 500
        assert_delivered_delivery!(continuing_id)
      end)

    assert_sanitized_task_crash_log!(log)
    assert_dispatcher_idle!(dispatcher)
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

    log =
      capture_log(fn ->
        send(dispatcher, :dispatch_due)

        assert_receive {:final_crash_webhook_started, ^delivery_id}, 500
        assert_failed_task_exit!(delivery_id)
      end)

    assert_sanitized_task_crash_log!(log)
    assert_dispatcher_idle!(dispatcher)
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

  test "configured via dispatcher name receives wakeups", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:via_wakeup_webhook_request, headers["atp-delivery-id"]})
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    [delivery_id] = create_due_webhook_deliveries!(conn, 1, "via-wakeup-dispatcher")
    registry = :atp_via_wakeup_registry_test
    start_supervised!({Registry, keys: :unique, name: registry})
    dispatcher_name = {:via, Registry, {registry, :dispatcher}}
    dispatcher = start_wakeup_dispatcher!(dispatcher_name)

    allow_dispatcher(dispatcher)
    assert :ok = WebhookDispatcher.wakeup()

    assert_receive {:via_wakeup_webhook_request, ^delivery_id}, 500
    assert_delivered_delivery!(delivery_id)
  end

  test "configured global dispatcher name receives wakeups", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:global_wakeup_webhook_request, headers["atp-delivery-id"]})
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    [delivery_id] = create_due_webhook_deliveries!(conn, 1, "global-wakeup-dispatcher")
    global_key = {:atp_global_wakeup_dispatcher_test, System.unique_integer([:positive])}
    dispatcher = start_wakeup_dispatcher!({:global, global_key})

    allow_dispatcher(dispatcher)
    assert :ok = WebhookDispatcher.wakeup()

    assert_receive {:global_wakeup_webhook_request, ^delivery_id}, 500
    assert_delivered_delivery!(delivery_id)
  end

  test "disabled webhook dispatcher ignores wakeups" do
    name = :atp_disabled_wakeup_dispatcher_test
    dispatcher = start_supervised!({WebhookDispatcher, enabled: false, name: name})

    assert :ok = WebhookDispatcher.wakeup(name)
    assert %{enabled?: false} = :sys.get_state(dispatcher)
  end

  defp start_wakeup_dispatcher!(name) do
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

  defp attach_dispatcher_telemetry!(test_pid) do
    handler_id = "webhook-dispatcher-test-#{System.unique_integer([:positive])}"

    events = [
      @dispatcher_scan_event,
      @dispatcher_claim_event,
      @dispatcher_attempt_start_event,
      @dispatcher_attempt_finish_event,
      @dispatcher_task_exit_event
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:webhook_dispatcher_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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

  defp refute_process_alive!(pid, attempts_left \\ 20)

  defp refute_process_alive!(pid, attempts_left) when attempts_left > 0 do
    if Process.alive?(pid) do
      Process.sleep(10)
      refute_process_alive!(pid, attempts_left - 1)
    else
      :ok
    end
  end

  defp refute_process_alive!(pid, 0) do
    refute Process.alive?(pid)
  end

  defp assert_dispatcher_idle!(dispatcher, attempts_left \\ 20)

  defp assert_dispatcher_idle!(dispatcher, attempts_left) when attempts_left > 0 do
    case :sys.get_state(dispatcher) do
      %{in_flight: in_flight} when map_size(in_flight) == 0 ->
        :ok

      _state ->
        Process.sleep(10)
        assert_dispatcher_idle!(dispatcher, attempts_left - 1)
    end
  end

  defp assert_dispatcher_idle!(dispatcher, 0) do
    assert %{in_flight: in_flight} = :sys.get_state(dispatcher)
    assert map_size(in_flight) == 0
  end

  defp create_due_webhook_deliveries!(conn, count, key_prefix, opts \\ []) do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "#{key_prefix}-sender", %{})
    recipient = register_agent!(account_token, "#{key_prefix}-recipient", %{})
    webhook_url = Keyword.get(opts, :webhook_url, "https://recipient.example.test/atp/webhook")
    text = Keyword.get(opts, :text, "dispatch")

    configure_webhook!(recipient, "#{key_prefix}-webhook", webhook_url)

    for index <- 1..count do
      sent =
        send_message!(
          sender["agent_api_key"]["token"],
          "#{key_prefix}-send-#{index}",
          recipient["address"],
          a2a_user_text("#{key_prefix}-message-#{index}", "#{text} #{index}")
        )

      assert [%{"id" => delivery_id, "status" => "retry_scheduled", "attempt_count" => 0}] =
               sent["deliveries"]

      delivery_id
    end
  end

  defp create_due_session_webhook_deliveries!(conn, key_prefix) do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "#{key_prefix}-initiator", %{})
    recipient = register_agent!(account_token, "#{key_prefix}-recipient", %{})

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "#{key_prefix}-open",
        recipient["address"],
        a2a_user_text("#{key_prefix}-opening", "open ordered session")
      )

    opening_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "#{key_prefix}-claim-opening", %{
        "lease_seconds" => 60
      })

    ack_delivery!(
      recipient["agent_api_key"]["token"],
      opening_delivery["id"],
      "#{key_prefix}-accept-opening",
      %{"status" => "accepted"}
    )

    configure_webhook!(recipient, "#{key_prefix}-webhook")

    session_id = opened["session"]["id"]
    initiator_token = initiator["agent_api_key"]["token"]

    first =
      send_session_message!(
        initiator_token,
        session_id,
        "#{key_prefix}-send-1",
        a2a_user_text("#{key_prefix}-message-1", "first ordered webhook")
      )

    second =
      send_session_message!(
        initiator_token,
        session_id,
        "#{key_prefix}-send-2",
        a2a_user_text("#{key_prefix}-message-2", "second ordered webhook")
      )

    %{
      session_id: session_id,
      deliveries: %{
        2 => session_webhook_delivery_id!(first, 2),
        3 => session_webhook_delivery_id!(second, 3)
      }
    }
  end

  defp send_session_message!(initiator_token, session_id, key, payload) do
    build_conn()
    |> authorize(initiator_token)
    |> idempotency_key(key)
    |> post("/api/sessions/#{session_id}/messages", %{"payload" => payload})
    |> json_response(201)
  end

  defp session_webhook_delivery_id!(reply, sequence) do
    assert get_in(reply, ["message_status", "message", "session_sequence"]) == sequence

    assert [%{"id" => delivery_id, "status" => "retry_scheduled", "attempt_count" => 0}] =
             reply["message_status"]["deliveries"]

    delivery_id
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

  defp message_id_for_delivery!(delivery_id) do
    delivery_id
    |> then(&Repo.get!(Delivery, &1))
    |> Map.fetch!(:message_id)
  end

  defp force_max_attempts!(delivery_id, max_attempts) do
    delivery = Repo.get!(Delivery, delivery_id)

    delivery
    |> Ecto.Changeset.change(max_attempts: max_attempts)
    |> Repo.update!()
  end

  defp expire_delivery_lease!(delivery_id) do
    delivery = Repo.get!(Delivery, delivery_id)

    delivery
    |> Ecto.Changeset.change(leased_until: DateTime.add(DateTime.utc_now(), -1, :second))
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

  defp assert_retry_scheduled_delivery!(delivery_id, attempts_left \\ 20)

  defp assert_retry_scheduled_delivery!(delivery_id, attempts_left) when attempts_left > 0 do
    case Repo.get!(Delivery, delivery_id) do
      %Delivery{status: "retry_scheduled", attempt_count: 1} = delivery ->
        assert is_nil(delivery.claim_token)
        assert is_nil(delivery.leased_until)
        delivery

      %Delivery{} ->
        Process.sleep(10)
        assert_retry_scheduled_delivery!(delivery_id, attempts_left - 1)
    end
  end

  defp assert_retry_scheduled_delivery!(delivery_id, 0) do
    assert %Delivery{status: "retry_scheduled", attempt_count: 1} =
             Repo.get!(Delivery, delivery_id)
  end

  defp assert_failed_delivery!(delivery_id, attempts_left \\ 20)

  defp assert_failed_delivery!(delivery_id, attempts_left) when attempts_left > 0 do
    case Repo.get!(Delivery, delivery_id) do
      %Delivery{status: "failed", attempt_count: 1} = delivery ->
        assert is_nil(delivery.claim_token)
        assert is_nil(delivery.leased_until)
        delivery

      %Delivery{} ->
        Process.sleep(10)
        assert_failed_delivery!(delivery_id, attempts_left - 1)
    end
  end

  defp assert_failed_delivery!(delivery_id, 0) do
    assert %Delivery{status: "failed", attempt_count: 1} =
             Repo.get!(Delivery, delivery_id)
  end

  defp assert_safe_telemetry!(measurements, metadata) do
    rendered = inspect({measurements, metadata})

    refute rendered =~ "recipient.example.test"
    refute rendered =~ "telemetry-hidden-url"
    refute rendered =~ "telemetry-hidden-body"
    refute rendered =~ "whsec"
    refute rendered =~ "request"
    refute rendered =~ "payload"
  end

  defp assert_sanitized_task_crash_log!(log) do
    refute log =~ "https://recipient.example.test/atp/webhook"
    refute log =~ "recipient.example.test"
    refute log =~ "telemetry-hidden-body"
    refute log =~ "whsec_secret"
    refute log =~ ~s({"body":"hidden"})
    refute log =~ "request body"
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
