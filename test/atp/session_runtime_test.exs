defmodule Atp.SessionRuntimeTest do
  use Atp.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Atp.Identity.{Account, Agent, Idempotency}
  alias Atp.Repo

  alias Atp.Transport.{
    Delivery,
    DurableLedger,
    Ledger,
    Message,
    Runtime,
    Session,
    WebhookDelivery,
    WebhookDispatcher
  }

  alias Atp.Transport.Runtime.{PendingSessionRehydrator, SessionServer, SessionState}
  alias Ecto.Adapters.SQL.Sandbox

  @session_registry Atp.Transport.Runtime.SessionRegistry
  @session_supervisor Atp.Transport.Runtime.SessionSupervisor

  defmodule RecordingSessionSendLedger do
    @behaviour DurableLedger

    @impl DurableLedger
    def accept_direct_message(_sender, _params, _idempotency_key, _route) do
      {:error, :unexpected_direct_message}
    end

    @impl DurableLedger
    def open_session(_initiator, _params, _idempotency_key, _route) do
      {:error, :unexpected_open_session}
    end

    @impl DurableLedger
    def preflight_session_message(sender, session_id, params, idempotency_key, route) do
      test_pid =
        :atp
        |> Application.fetch_env!(__MODULE__)
        |> Keyword.fetch!(:test_pid)

      send(test_pid, {
        :durable_session_preflight,
        sender,
        session_id,
        params,
        idempotency_key,
        route
      })

      :ok
    end

    @impl DurableLedger
    def send_session_message(sender, session_id, params, idempotency_key, route) do
      test_pid =
        :atp
        |> Application.fetch_env!(__MODULE__)
        |> Keyword.fetch!(:test_pid)

      send(test_pid, {
        :durable_session_send,
        sender,
        session_id,
        params,
        idempotency_key,
        route
      })

      {:ok, 201,
       %{
         "session" => %{"id" => session_id, "last_sequence" => 2},
         "message_status" => %{
           "message" => %{"id" => "msg_recorded", "session_id" => session_id}
         }
       }, nil}
    end

    @impl DurableLedger
    def accept_session(recipient, session_id, params, idempotency_key, route) do
      test_pid =
        :atp
        |> Application.fetch_env!(__MODULE__)
        |> Keyword.fetch!(:test_pid)

      send(test_pid, {
        :durable_session_accept,
        recipient,
        session_id,
        params,
        idempotency_key,
        route
      })

      {:ok, 201,
       %{
         "ack" => %{"status" => "accepted"},
         "session" => %{"id" => session_id, "status" => "open"}
       }}
    end

    @impl DurableLedger
    def reject_session(recipient, session_id, params, idempotency_key, route) do
      test_pid =
        :atp
        |> Application.fetch_env!(__MODULE__)
        |> Keyword.fetch!(:test_pid)

      send(test_pid, {
        :durable_session_reject,
        recipient,
        session_id,
        params,
        idempotency_key,
        route
      })

      {:ok, 201,
       %{
         "ack" => %{"status" => "rejected"},
         "session" => %{"id" => session_id, "status" => "rejected"}
       }}
    end

    @impl DurableLedger
    def ack_delivery(_recipient, _delivery_id, _params, _idempotency_key, _route) do
      {:error, :unexpected_ack}
    end

    @impl DurableLedger
    def claim_due_webhook_delivery(_opts), do: {:error, :unexpected_claim}

    @impl DurableLedger
    def claim_webhook_delivery(_delivery_id, _opts), do: {:error, :unexpected_claim}

    @impl DurableLedger
    def finish_claimed_webhook_delivery(_claim, _result, _opts) do
      {:error, :unexpected_finish}
    end

    @impl DurableLedger
    def terminalize_claimed_webhook_delivery(_claim, _reason, _opts) do
      {:error, :unexpected_terminalize}
    end
  end

  test "ATP application starts the session runtime registry and supervisor" do
    assert is_pid(Process.whereis(@session_registry))
    assert is_pid(Process.whereis(@session_supervisor))
  end

  test "disabled agent tokens are rejected before agent routes or runtime startup", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-disabled-auth-sender", %{})
    recipient = register_agent!(account_token, "register-disabled-auth-recipient", %{})
    sender_token = sender["agent_api_key"]["token"]
    recipient_token = recipient["agent_api_key"]["token"]

    send_message!(
      sender_token,
      "send-disabled-auth-claimable",
      recipient["address"],
      a2a_user_text("disabled-auth-claimable", "disabled agent cannot claim")
    )

    send_message!(
      sender_token,
      "send-disabled-auth-ackable",
      recipient["address"],
      a2a_user_text("disabled-auth-ackable", "disabled agent cannot ack")
    )

    ackable_delivery =
      claim_inbox!(recipient_token, "claim-disabled-auth-ackable", %{"lease_seconds" => 60})

    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "disabled-auth-runtime")

    session_id = session["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    disable_agent!(sender["id"])
    disable_agent!(recipient["id"])
    disable_agent!(initiator["id"])

    send_response =
      build_conn()
      |> authorize(sender_token)
      |> idempotency_key("send-disabled-auth-message")
      |> post("/api/messages", %{
        "to" => recipient["address"],
        "payload" => a2a_user_text("disabled-auth-send", "must be rejected")
      })
      |> json_response(401)

    assert error_code(send_response) == "unauthorized"

    claim_response =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("claim-disabled-auth-message")
      |> post("/api/inbox/claims", %{"lease_seconds" => 60})
      |> json_response(401)

    assert error_code(claim_response) == "unauthorized"

    ack_response =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("ack-disabled-auth-message")
      |> post("/api/deliveries/#{ackable_delivery["id"]}/acks", %{"status" => "accepted"})
      |> json_response(401)

    assert error_code(ack_response) == "unauthorized"

    webhook_response =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("configure-disabled-auth-webhook")
      |> put("/api/agents/#{recipient["id"]}/webhook_endpoint", %{
        "url" => "https://recipient.example.test/atp/webhook"
      })
      |> json_response(401)

    assert error_code(webhook_response) == "unauthorized"
    assert [] = Registry.lookup(@session_registry, session_id)

    runtime_get_response =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> get("/api/sessions/#{session_id}")
      |> json_response(401)

    assert error_code(runtime_get_response) == "unauthorized"
    assert [] = Registry.lookup(@session_registry, session_id)

    runtime_send_response =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("disabled-auth-runtime-send")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("disabled-auth-runtime-send", "do not boot runtime")
      })
      |> json_response(401)

    assert error_code(runtime_send_response) == "unauthorized"
    assert [] = Registry.lookup(@session_registry, session_id)
  end

  test "runtime supervisor can start an isolated registry and session supervisor" do
    assert {:error, {:already_started, pid}} = Atp.Transport.Runtime.Supervisor.start_link()
    assert is_pid(pid)

    suffix = System.unique_integer([:positive])
    name = :"atp_runtime_supervisor_test_#{suffix}"
    registry = :"atp_session_registry_test_#{suffix}"
    supervisor = :"atp_session_supervisor_test_#{suffix}"

    pid =
      start_supervised!(
        {Atp.Transport.Runtime.Supervisor,
         name: name, session_registry: registry, session_supervisor: supervisor}
      )

    assert is_pid(pid)
    assert is_pid(Process.whereis(registry))
    assert is_pid(Process.whereis(supervisor))
  end

  test "ensure_session_started starts and reuses a hydrated open session process", %{conn: conn} do
    session = open_accepted_session!(conn, "runtime-reuse")
    session_id = session["id"]

    on_exit(fn -> stop_session_server(session_id) end)

    assert {:ok, pid} = Runtime.ensure_session_started(session_id)
    assert [{^pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert {:ok, ^pid} = Runtime.ensure_session_started(session_id)
    assert session_supervised?(pid)

    assert %SessionState{
             session_id: ^session_id,
             status: "open",
             last_sequence: 1,
             opening_message_id: opening_message_id
           } = :sys.get_state(pid)

    assert opening_message_id == session["opening_message_id"]
  end

  test "SessionServer hydrates when supervised by a test supervisor", %{conn: conn} do
    session = open_accepted_session!(conn, "runtime-start-supervised")
    session_id = session["id"]

    pid = start_supervised!({SessionServer, session_id})

    assert %SessionState{
             session_id: ^session_id,
             status: "open",
             last_sequence: 1,
             opening_message_id: opening_message_id
           } = :sys.get_state(pid)

    assert opening_message_id == session["opening_message_id"]
  end

  test "ensure_session_started returns clear errors for missing and non-open sessions", %{
    conn: conn
  } do
    pending_session = open_pending_session_without_runtime_context!(conn, "runtime-errors")

    assert {:error, :not_found} = Runtime.ensure_session_started("ses_missing_for_runtime_test")
    assert {:error, :session_not_open} = Runtime.ensure_session_started(pending_session["id"])
    assert [] = Registry.lookup(@session_registry, pending_session["id"])
  end

  test "runtime introspection returns an empty active session list" do
    stop_all_session_servers()

    assert Runtime.list_active_sessions() == []
  end

  test "runtime introspection summarizes active sessions without payloads or tokens", %{
    conn: conn
  } do
    stop_all_session_servers()
    session = open_accepted_session!(conn, "runtime-introspection-active")
    session_id = session["id"]

    on_exit(fn -> stop_session_server(session_id) end)

    assert {:ok, pid} = Runtime.ensure_session_started(session_id)

    assert [
             %{
               session_id: ^session_id,
               pid: ^pid,
               runtime_status: :running,
               session_status: "open",
               last_sequence: 1,
               lifecycle_timer_active: false,
               lifecycle_deadline_at: nil,
               process_started_at: %DateTime{},
               hydrated_at: %DateTime{},
               hydration_count: hydration_count
             } = summary
           ] = Runtime.list_active_sessions()

    assert hydration_count >= 1

    summary_keys =
      summary
      |> Enum.map(fn {key, _value} -> key end)
      |> Enum.sort()

    assert summary_keys == [
             :hydrated_at,
             :hydration_count,
             :last_sequence,
             :lifecycle_deadline_at,
             :lifecycle_timer_active,
             :pid,
             :process_started_at,
             :runtime_status,
             :session_id,
             :session_status
           ]
  end

  test "public open starts a pending session process with an opening expiry timer", %{
    conn: conn
  } do
    pending_session = open_pending_session!(conn, "runtime-pending-expiry-timer")
    session_id = pending_session["id"]

    on_exit(fn -> stop_session_server(session_id) end)

    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert session_supervised?(pid)

    opening_message = Repo.get!(Message, pending_session["opening_message_id"])

    assert %SessionState{
             session_id: ^session_id,
             status: "pending",
             lifecycle_deadline_at: deadline_at,
             lifecycle_timer_ref: timer_ref
           } = :sys.get_state(pid)

    assert DateTime.compare(deadline_at, opening_message.expires_at) == :eq
    assert is_reference(timer_ref)
  end

  test "pending opening expiry timer persists terminal state and stops the process", %{
    conn: conn
  } do
    pending_session =
      open_pending_session_without_runtime_context!(conn, "runtime-pending-expiry-fired")

    session_id = pending_session["id"]
    opening_message_id = pending_session["opening_message_id"]
    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    opening_message_id
    |> then(&Repo.get!(Message, &1))
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    pid = start_supervised!({SessionServer, session_id})
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    _registry_state = :sys.get_state(@session_registry)
    assert [] = Registry.lookup(@session_registry, session_id)

    persisted_session = Repo.get!(Session, session_id)
    assert persisted_session.status == "failed"
    assert %DateTime{} = persisted_session.terminal_at

    persisted_opening = Repo.get!(Message, opening_message_id)
    assert persisted_opening.carrier_status == "expired"
    assert %DateTime{} = persisted_opening.terminal_at
  end

  test "accepted opening ACK warms a hydrated session process", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "runtime-opening-ack")

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-opening-ack",
        recipient["address"],
        a2a_user_text("opening-runtime-opening-ack", "warm the runtime")
      )

    session_id = opened["session"]["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-runtime-opening-ack", %{
        "lease_seconds" => 60
      })

    assert [{pending_pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    assert %SessionState{
             session_id: ^session_id,
             status: "pending",
             lifecycle_timer_ref: pending_timer_ref
           } = :sys.get_state(pending_pid)

    assert is_reference(pending_timer_ref)

    accepted =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "accept-runtime-opening-ack",
        %{"status" => "accepted"}
      )

    assert accepted["message_status"]["ack_status"] == "accepted"
    assert [{^pending_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert session_supervised?(pending_pid)

    assert %SessionState{
             session_id: ^session_id,
             status: "open",
             last_sequence: 1,
             opening_message_id: opening_message_id,
             lifecycle_deadline_at: nil,
             lifecycle_timer_ref: nil
           } = :sys.get_state(pending_pid)

    assert opening_message_id == opened["session"]["opening_message_id"]
  end

  test "accepted session by ID warms a hydrated session process", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "runtime-session-id-accept")

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-session-id-accept",
        recipient["address"],
        a2a_user_text("opening-runtime-session-id-accept", "warm by session ID")
      )

    session_id = opened["session"]["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert [{pending_pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    assert %SessionState{
             session_id: ^session_id,
             status: "pending",
             lifecycle_timer_ref: pending_timer_ref
           } = :sys.get_state(pending_pid)

    assert is_reference(pending_timer_ref)

    accepted =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("accept-runtime-session-id")
      |> post("/api/sessions/#{session_id}/accept", %{})
      |> json_response(201)

    assert accepted["ack"]["status"] == "accepted"
    assert accepted["session"]["status"] == "open"
    assert [{^pending_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert session_supervised?(pending_pid)

    assert %SessionState{
             session_id: ^session_id,
             status: "open",
             last_sequence: 1,
             opening_message_id: opening_message_id,
             lifecycle_deadline_at: nil,
             lifecycle_timer_ref: nil
           } = :sys.get_state(pending_pid)

    assert opening_message_id == opened["session"]["opening_message_id"]
  end

  test "accepted opening ACK expires a due opening message before opening the session", %{
    conn: conn
  } do
    {initiator, recipient} = register_session_agents!(conn, "runtime-opening-ack-expired")

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-opening-ack-expired",
        recipient["address"],
        a2a_user_text("opening-runtime-opening-ack-expired", "expire before ACK")
      )

    session_id = opened["session"]["id"]
    opening_message_id = opened["session"]["opening_message_id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-runtime-opening-ack-expired", %{
        "lease_seconds" => 60
      })

    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    Message
    |> Repo.get!(opening_message_id)
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    ref = Process.monitor(pid)

    response =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("accept-runtime-opening-ack-expired")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "accepted"})
      |> json_response(409)

    assert error_code(response) == "message_expired"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert [] = Registry.lookup(@session_registry, session_id)

    persisted_session = Repo.get!(Session, session_id)
    assert persisted_session.status == "failed"
    assert %DateTime{} = persisted_session.terminal_at
    refute persisted_session.opened_at

    persisted_opening = Repo.get!(Message, opening_message_id)
    assert persisted_opening.carrier_status == "expired"
    assert %DateTime{} = persisted_opening.terminal_at
    refute persisted_opening.current_ack_status
  end

  test "accepted session by ID expires a due opening message and stops the pending process", %{
    conn: conn
  } do
    {initiator, recipient} = register_session_agents!(conn, "runtime-session-id-accept-expired")

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-session-id-accept-expired",
        recipient["address"],
        a2a_user_text("runtime-session-id-accept-expired", "expire before accept")
      )

    session_id = opened["session"]["id"]
    opening_message_id = opened["session"]["opening_message_id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    Message
    |> Repo.get!(opening_message_id)
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    ref = Process.monitor(pid)

    response =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("accept-runtime-session-id-expired")
      |> post("/api/sessions/#{session_id}/accept", %{})
      |> json_response(409)

    assert error_code(response) == "message_expired"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert [] = Registry.lookup(@session_registry, session_id)

    persisted_session = Repo.get!(Session, session_id)
    assert persisted_session.status == "failed"
    assert %DateTime{} = persisted_session.terminal_at
    refute persisted_session.opened_at

    persisted_opening = Repo.get!(Message, opening_message_id)
    assert persisted_opening.carrier_status == "expired"
    assert %DateTime{} = persisted_opening.terminal_at
    refute persisted_opening.current_ack_status
  end

  test "rejected session by ID stops the pending process", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "runtime-session-id-reject")

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-session-id-reject",
        recipient["address"],
        a2a_user_text("opening-runtime-session-id-reject", "reject by session ID")
      )

    session_id = opened["session"]["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert [{pending_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    ref = Process.monitor(pending_pid)

    rejected =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("reject-runtime-session-id")
      |> post("/api/sessions/#{session_id}/reject", %{
        "payload" => a2a_agent_text("runtime-session-id-reject", "reject by ID")
      })
      |> json_response(201)

    assert rejected["ack"]["status"] == "rejected"
    assert rejected["session"]["status"] == "rejected"
    assert_receive {:DOWN, ^ref, :process, ^pending_pid, :normal}, 5_000
    assert [] = Registry.lookup(@session_registry, session_id)
  end

  test "opening ACK and expiry can race without deadlocking", %{conn: conn} do
    unboxed_repo(fn ->
      key = "runtime-opening-expiry-race-#{System.unique_integer([:positive])}"
      account = create_account!(conn, %{"name" => "Runtime race #{key}"})

      try do
        account_token = account["account_api_key"]["token"]
        initiator = register_agent!(account_token, "register-#{key}-initiator", %{})
        recipient = register_agent!(account_token, "register-#{key}-recipient", %{})

        assert {:ok, 201, opened, _prepared} =
                 DurableLedger.open_session(
                   Repo.get!(Agent, initiator["id"]),
                   %{
                     "to" => recipient["address"],
                     "payload" => a2a_user_text("opening-#{key}", "open runtime session")
                   },
                   "open-#{key}",
                   "POST /api/sessions"
                 )

        pending_session = opened["session"]
        session_id = pending_session["id"]
        opening_message_id = pending_session["opening_message_id"]

        delivery =
          claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}", %{
            "lease_seconds" => 60
          })

        expired_at = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

        Message
        |> Repo.get!(opening_message_id)
        |> Ecto.Changeset.change(expires_at: expired_at)
        |> Repo.update!()

        recipient_agent = Repo.get!(Agent, recipient["id"])
        route = "POST /api/deliveries/#{delivery["id"]}/acks"
        parent = self()
        session_lock_task = start_session_lock!(session_id, parent)

        try do
          expiry_task =
            Task.async(fn ->
              checked_out_unboxed_repo(fn ->
                backend_pid = db_backend_pid!()
                send(parent, {:expiry_backend_pid, backend_pid})

                result =
                  Ledger.expire_pending_opening_session(
                    session_id,
                    DateTime.utc_now(:microsecond)
                  )

                send(parent, {:expiry_finished, result})
                result
              end)
            end)

          assert_receive {:expiry_backend_pid, expiry_backend_pid}, 5_000
          assert_backend_waiting_on_lock!(expiry_backend_pid, "expiry")
          refute message_lock_available?(opening_message_id)

          ack_task =
            Task.async(fn ->
              checked_out_unboxed_repo(fn ->
                backend_pid = db_backend_pid!()
                send(parent, {:ack_backend_pid, backend_pid})

                result =
                  Ledger.ack_delivery(
                    recipient_agent,
                    delivery["id"],
                    %{"status" => "accepted"},
                    "accept-#{key}",
                    route
                  )

                send(parent, {:ack_finished, result})
                result
              end)
            end)

          assert_receive {:ack_backend_pid, ack_backend_pid}, 5_000
          assert_backend_waiting_on_lock!(ack_backend_pid, "ack")

          send(session_lock_task.pid, :release_session_lock)

          results =
            await_task_results!(
              ack: ack_task,
              expiry: expiry_task,
              session_lock: session_lock_task
            )

          assert results[:ack] in [
                   {:error, :message_expired},
                   {:error, :invalid_ack_transition}
                 ]

          assert match?({:ok, %Session{status: "failed"}}, results[:expiry]) or
                   results[:expiry] == {:error, :session_not_pending}

          persisted_session = Repo.get!(Session, session_id)
          assert persisted_session.status == "failed"
          assert %DateTime{} = persisted_session.terminal_at
          refute persisted_session.opened_at

          persisted_opening = Repo.get!(Message, opening_message_id)
          assert persisted_opening.carrier_status == "expired"
          assert %DateTime{} = persisted_opening.terminal_at
          refute persisted_opening.current_ack_status

          assert {:ok, %{"session" => %{"status" => "failed"}}} =
                   Ledger.get_session(Repo.get!(Agent, initiator["id"]), session_id)
        after
          send(session_lock_task.pid, :release_session_lock)
          Task.shutdown(session_lock_task, :brutal_kill)
        end
      after
        delete_account!(account["id"])
      end
    end)
  end

  test "accepted opening ACK returns durable success when runtime warming fails", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "runtime-opening-ack-warm-fails")

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-opening-ack-warm-fails",
        recipient["address"],
        a2a_user_text("opening-runtime-opening-ack-warm-fails", "open without runtime")
      )

    session_id = opened["session"]["id"]

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-runtime-opening-ack-warm-fails", %{
        "lease_seconds" => 60
      })

    on_exit(fn ->
      ensure_runtime_supervisor_running()
      stop_session_server(session_id)
    end)

    ensure_runtime_supervisor_running()
    :ok = Supervisor.terminate_child(Atp.Supervisor, Atp.Transport.Runtime.Supervisor)
    assert is_nil(Process.whereis(@session_registry))
    assert is_nil(Process.whereis(@session_supervisor))

    log =
      capture_log(fn ->
        accepted =
          ack_delivery!(
            recipient["agent_api_key"]["token"],
            delivery["id"],
            "accept-runtime-opening-ack-warm-fails",
            %{"status" => "accepted"}
          )

        assert accepted["message_status"]["ack_status"] == "accepted"
      end)

    assert log =~ "Failed to warm accepted ATP session runtime"
    assert is_nil(Process.whereis(@session_registry))
    assert is_nil(Process.whereis(@session_supervisor))

    assert {:ok, %{"session" => %{"status" => "open"}}} =
             Ledger.get_session(Repo.get!(Agent, initiator["id"]), session_id)
  end

  test "terminal opening ACKs do not warm session processes", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "runtime-terminal-opening-ack")

    rejected =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-rejected-opening-ack",
        recipient["address"],
        a2a_user_text("opening-runtime-rejected-opening-ack", "reject the runtime")
      )

    rejected_session_id = rejected["session"]["id"]
    assert [{rejected_pid, _metadata}] = Registry.lookup(@session_registry, rejected_session_id)
    rejected_ref = Process.monitor(rejected_pid)

    rejected_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-runtime-rejected-opening-ack", %{
        "lease_seconds" => 60
      })

    rejected_ack =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        rejected_delivery["id"],
        "reject-runtime-opening-ack",
        %{"status" => "rejected"}
      )

    assert rejected_ack["message_status"]["ack_status"] == "rejected"
    assert_receive {:DOWN, ^rejected_ref, :process, ^rejected_pid, :normal}
    _registry_state = :sys.get_state(@session_registry)
    assert [] = Registry.lookup(@session_registry, rejected_session_id)

    failed =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-runtime-failed-opening-ack",
        recipient["address"],
        a2a_user_text("opening-runtime-failed-opening-ack", "fail the runtime")
      )

    failed_session_id = failed["session"]["id"]
    assert [{failed_pid, _metadata}] = Registry.lookup(@session_registry, failed_session_id)
    failed_ref = Process.monitor(failed_pid)

    failed_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-runtime-failed-opening-ack", %{
        "lease_seconds" => 60
      })

    failed_ack =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        failed_delivery["id"],
        "fail-runtime-opening-ack",
        %{"status" => "failed"}
      )

    assert failed_ack["message_status"]["ack_status"] == "failed"
    assert_receive {:DOWN, ^failed_ref, :process, ^failed_pid, :normal}
    _registry_state = :sys.get_state(@session_registry)
    assert [] = Registry.lookup(@session_registry, failed_session_id)
  end

  test "idempotent accepted opening ACK replay warms an absent session process", %{conn: conn} do
    %{recipient: recipient, session: pending_session} =
      open_pending_session_context_without_runtime!(conn, "runtime-opening-ack-replay")

    session_id = pending_session["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-runtime-opening-ack-replay", %{
        "lease_seconds" => 60
      })

    route = "POST /api/deliveries/#{delivery["id"]}/acks"

    assert {:ok, 201, accepted} =
             Ledger.ack_delivery(
               Repo.get!(Agent, recipient["id"]),
               delivery["id"],
               %{"status" => "accepted"},
               "accept-runtime-opening-ack-replay",
               route
             )

    assert [] = Registry.lookup(@session_registry, session_id)

    replayed =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "accept-runtime-opening-ack-replay",
        %{"status" => "accepted"}
      )

    assert replayed == accepted
    assert [{replayed_pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    assert %SessionState{session_id: ^session_id, status: "open", last_sequence: 1} =
             :sys.get_state(replayed_pid)
  end

  test "public get lazily boots an absent open session process from durable state", %{
    conn: conn
  } do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-get-lazy-boot")

    session_id = session["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert [] = Registry.lookup(@session_registry, session_id)

    reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-get-lazy-boot-send")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("runtime-get-lazy-boot-send", "persisted before get")
      })
      |> json_response(201)

    assert reply["message_status"]["message"]["session_sequence"] == 2
    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    stop_registered_session_server(pid)
    refute session_supervised?(pid)

    session_status =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> get("/api/sessions/#{session_id}")
      |> json_response(200)

    assert session_status["session"]["last_sequence"] == 2
    assert [{recovered_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    refute recovered_pid == pid

    assert %SessionState{session_id: ^session_id, status: "open", last_sequence: 2} =
             :sys.get_state(recovered_pid)
  end

  test "crashed session processes restart and rehydrate from the ledger", %{conn: conn} do
    session = open_accepted_session!(conn, "runtime-restart")
    session_id = session["id"]

    on_exit(fn -> stop_session_server(session_id) end)

    assert {:ok, pid} = Runtime.ensure_session_started(session_id)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    _supervisor_state = :sys.get_state(@session_supervisor)
    assert [{restarted_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    refute restarted_pid == pid

    assert %SessionState{
             session_id: ^session_id,
             status: "open",
             last_sequence: 1,
             opening_message_id: opening_message_id
           } = :sys.get_state(restarted_pid)

    assert opening_message_id == session["opening_message_id"]
  end

  test "public sends continue from the ledger after runtime supervisor restart", %{
    conn: conn
  } do
    %{initiator: initiator, session: session} =
      open_accepted_session_context!(conn, "runtime-supervisor-restart")

    session_id = session["id"]

    on_exit(fn ->
      ensure_runtime_supervisor_running()
      stop_session_server(session_id)
    end)

    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert session_supervised?(pid)

    :ok = Supervisor.terminate_child(Atp.Supervisor, Atp.Transport.Runtime.Supervisor)
    assert is_nil(Process.whereis(@session_registry))
    assert is_nil(Process.whereis(@session_supervisor))

    assert {:ok, _runtime_pid} =
             Supervisor.restart_child(Atp.Supervisor, Atp.Transport.Runtime.Supervisor)

    assert is_pid(Process.whereis(@session_registry))
    assert is_pid(Process.whereis(@session_supervisor))
    assert [] = Registry.lookup(@session_registry, session_id)

    reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-supervisor-restart-send")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("runtime-supervisor-restart-send", "after restart")
      })
      |> json_response(201)

    assert reply["message_status"]["message"]["session_sequence"] == 2
    assert [{recovered_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    refute recovered_pid == pid

    assert %SessionState{session_id: ^session_id, status: "open", last_sequence: 2} =
             :sys.get_state(recovered_pid)
  end

  test "registry replacement terminates stale session children before recovery", %{conn: conn} do
    session = open_accepted_session!(conn, "runtime-registry-replaced")
    session_id = session["id"]

    on_exit(fn ->
      ensure_runtime_supervisor_running()
      stop_session_server(session_id)
    end)

    assert {:ok, pid} = Runtime.ensure_session_started(session_id)
    old_registry = Process.whereis(@session_registry)
    old_session_supervisor = Process.whereis(@session_supervisor)

    registry_ref = Process.monitor(old_registry)
    supervisor_ref = Process.monitor(old_session_supervisor)
    session_ref = Process.monitor(pid)

    _log =
      capture_log(fn ->
        :sys.terminate(old_registry, :registry_replaced)

        assert_receive {:DOWN, ^registry_ref, :process, ^old_registry, :registry_replaced}, 500
        assert_receive {:DOWN, ^supervisor_ref, :process, ^old_session_supervisor, _reason}, 500
        assert_receive {:DOWN, ^session_ref, :process, ^pid, _reason}, 500
      end)

    _runtime_state = :sys.get_state(Atp.Transport.Runtime.Supervisor)

    refute Process.whereis(@session_registry) == old_registry
    refute Process.whereis(@session_supervisor) == old_session_supervisor
    assert [] = Registry.lookup(@session_registry, session_id)

    assert {:ok, recovered_pid} = Runtime.ensure_session_started(session_id)
    refute recovered_pid == pid
    assert [{^recovered_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
  end

  test "runtime supervisor restart rehydrates pending opening sessions with timers", %{
    conn: conn
  } do
    pending_session =
      open_pending_session_without_runtime_context!(conn, "runtime-rehydrate-pending")

    session_id = pending_session["id"]

    on_exit(fn ->
      ensure_runtime_supervisor_running()
      stop_session_server(session_id)
    end)

    assert [] = Registry.lookup(@session_registry, session_id)

    restart_runtime_supervisor!()

    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert session_supervised?(pid)

    assert %SessionState{
             session_id: ^session_id,
             status: "pending",
             lifecycle_deadline_at: %DateTime{},
             lifecycle_timer_ref: timer_ref
           } = :sys.get_state(pid)

    assert is_reference(timer_ref)
  end

  test "pending session rehydrator retries after pending-list failures" do
    parent = self()
    session_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    attempts = start_supervised!({Elixir.Agent, fn -> 0 end})

    list_pending_session_ids = fn ->
      attempt =
        Elixir.Agent.get_and_update(attempts, fn current_attempt ->
          next_attempt = current_attempt + 1
          {next_attempt, next_attempt}
        end)

      send(parent, {:pending_rehydrate_attempt, attempt})

      if attempt == 1 do
        raise "temporary pending session list failure"
      else
        []
      end
    end

    capture_log(fn ->
      start_supervised!(
        {PendingSessionRehydrator,
         session_supervisor: session_supervisor,
         list_pending_session_ids: list_pending_session_ids,
         retry_interval_ms: 10}
      )

      assert_receive {:pending_rehydrate_attempt, 1}, 500
      assert_receive {:pending_rehydrate_attempt, 2}, 500
    end)
  end

  test "pending session rehydrator retries after individual session start failures" do
    parent = self()
    session_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    attempts = start_supervised!({Elixir.Agent, fn -> 0 end})

    list_pending_session_ids = fn ->
      attempt =
        Elixir.Agent.get_and_update(attempts, fn current_attempt ->
          next_attempt = current_attempt + 1
          {next_attempt, next_attempt}
        end)

      send(parent, {:pending_start_rehydrate_attempt, attempt})
      ["ses_missing_for_rehydrator_retry"]
    end

    capture_log(fn ->
      rehydrator =
        start_supervised!(
          {PendingSessionRehydrator,
           session_supervisor: session_supervisor,
           list_pending_session_ids: list_pending_session_ids,
           retry_interval_ms: 10}
        )

      assert_receive {:pending_start_rehydrate_attempt, 1}, 500
      assert_receive {:pending_start_rehydrate_attempt, 2}, 500
      GenServer.stop(rehydrator)
    end)
  end

  test "public session message sends use the warmed process and update runtime state", %{
    conn: conn
  } do
    %{initiator: initiator, session: session} =
      open_accepted_session_context!(conn, "runtime-send")

    session_id = session["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-send-message")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("runtime-send-message", "through runtime")
      })
      |> json_response(201)

    assert reply["session"]["last_sequence"] == 2
    assert reply["message_status"]["message"]["session_sequence"] == 2
    assert [{^pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    assert %SessionState{session_id: ^session_id, last_sequence: 2} = :sys.get_state(pid)
  end

  test "session webhook dispatch happens outside the session server call path", %{
    conn: conn
  } do
    %{initiator: initiator, recipient: recipient, session: session} =
      open_accepted_session_context!(conn, "runtime-session-webhook-read")

    session_id = session["id"]
    initiator_token = initiator["agent_api_key"]["token"]
    test_pid = self()

    on_exit(fn -> stop_session_server(session_id) end)

    configure_webhook!(recipient, "configure-runtime-session-webhook-read")

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      session_status =
        build_conn()
        |> authorize(initiator_token)
        |> get("/api/sessions/#{session_id}")
        |> json_response(200)

      send(
        test_pid,
        {:session_webhook_read, Atp.Repo.in_transaction?(),
         session_status["session"]["last_sequence"]}
      )

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    reply =
      build_conn()
      |> authorize(initiator_token)
      |> idempotency_key("runtime-session-webhook-read-send")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("runtime-session-webhook-read-send", "webhook reads session")
      })
      |> json_response(201)

    assert_receive {:session_webhook_read, false, 2}, 500
    assert reply["session"]["last_sequence"] == 2
    assert reply["message_status"]["carrier_status"] == "delivered"
  end

  test "concurrent trusted session webhook dispatch preserves session sequence order", %{
    conn: conn
  } do
    %{initiator: initiator, recipient: recipient, session: session} =
      open_accepted_session_context!(conn, "runtime-session-webhook-order")

    session_id = session["id"]
    initiator_token = initiator["agent_api_key"]["token"]
    test_pid = self()

    on_exit(fn -> stop_session_server(session_id) end)

    configure_webhook!(recipient, "configure-runtime-session-webhook-order")

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, raw_body, read_conn} = Plug.Conn.read_body(request_conn)
      sequence = raw_body |> Jason.decode!() |> get_in(["message", "session_sequence"])

      send(test_pid, {:session_webhook_started, sequence})

      if sequence == 2 do
        receive do
          :release_first_session_webhook -> :ok
        after
          1_000 -> raise "timed out waiting to release first session webhook"
        end
      end

      Plug.Conn.send_resp(read_conn, 204, "")
    end)

    first_task =
      session_message_task(
        initiator_token,
        session_id,
        "runtime-session-webhook-order-first",
        "first ordered webhook"
      )

    Req.Test.allow(WebhookDelivery, self(), first_task.pid)
    send(first_task.pid, :send_session_message)

    assert_receive {:session_webhook_started, 2}, 500

    second_task =
      session_message_task(
        initiator_token,
        session_id,
        "runtime-session-webhook-order-second",
        "second ordered webhook"
      )

    Req.Test.allow(WebhookDelivery, self(), second_task.pid)
    send(second_task.pid, :send_session_message)

    refute_receive {:session_webhook_started, 3}, 100
    send(first_task.pid, :release_first_session_webhook)
    assert_receive {:session_webhook_started, 3}, 500

    first_reply = Task.await(first_task, 5_000)
    second_reply = Task.await(second_task, 5_000)

    assert get_in(first_reply, ["message_status", "message", "session_sequence"]) == 2
    assert get_in(second_reply, ["message_status", "message", "session_sequence"]) == 3
  end

  test "webhook dispatcher does not bypass session sequence order while earlier webhook is in progress",
       %{
         conn: conn
       } do
    %{initiator: initiator, recipient: recipient, session: session} =
      open_accepted_session_context!(conn, "runtime-session-webhook-dispatcher-order")

    session_id = session["id"]
    initiator_token = initiator["agent_api_key"]["token"]
    test_pid = self()

    on_exit(fn -> stop_session_server(session_id) end)

    configure_webhook!(recipient, "configure-runtime-session-webhook-dispatcher-order")

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, raw_body, read_conn} = Plug.Conn.read_body(request_conn)
      sequence = raw_body |> Jason.decode!() |> get_in(["message", "session_sequence"])

      send(test_pid, {:dispatcher_order_webhook_started, sequence})

      if sequence == 2 do
        receive do
          :release_first_dispatcher_order_webhook -> :ok
        after
          1_000 -> raise "timed out waiting to release first dispatcher-order webhook"
        end
      end

      Plug.Conn.send_resp(read_conn, 204, "")
    end)

    first_task =
      session_message_task(
        initiator_token,
        session_id,
        "runtime-session-webhook-dispatcher-order-first",
        "first dispatcher ordered webhook"
      )

    Req.Test.allow(WebhookDelivery, self(), first_task.pid)
    send(first_task.pid, :send_session_message)

    assert_receive {:dispatcher_order_webhook_started, 2}, 500

    second_task =
      session_message_task(
        initiator_token,
        session_id,
        "runtime-session-webhook-dispatcher-order-second",
        "second dispatcher ordered webhook"
      )

    Req.Test.allow(WebhookDelivery, self(), second_task.pid)
    send(second_task.pid, :send_session_message)

    assert %Delivery{status: "retry_scheduled"} =
             assert_session_webhook_delivery!(session_id, 3)

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true, dispatch_on_start?: false, batch_size: 10, interval_ms: 60_000, name: nil}
      )

    Sandbox.allow(Atp.Repo, self(), dispatcher)
    Req.Test.allow(WebhookDelivery, self(), dispatcher)
    send(dispatcher, :dispatch_due)
    _state = :sys.get_state(dispatcher)

    refute_receive {:dispatcher_order_webhook_started, 3}, 100

    send(first_task.pid, :release_first_dispatcher_order_webhook)
    assert_receive {:dispatcher_order_webhook_started, 3}, 500

    first_reply = Task.await(first_task, 5_000)
    second_reply = Task.await(second_task, 5_000)

    assert get_in(first_reply, ["message_status", "message", "session_sequence"]) == 2
    assert get_in(second_reply, ["message_status", "message", "session_sequence"]) == 3
  end

  test "concurrent public sends to the same session receive unique sequence numbers", %{
    conn: conn
  } do
    %{initiator: initiator, session: session} =
      open_accepted_session_context!(conn, "runtime-concurrent-sends")

    session_id = session["id"]
    initiator_token = initiator["agent_api_key"]["token"]
    on_exit(fn -> stop_session_server(session_id) end)

    replies =
      1..5
      |> Task.async_stream(
        fn number ->
          build_conn()
          |> authorize(initiator_token)
          |> idempotency_key("runtime-concurrent-send-#{number}")
          |> post("/api/sessions/#{session_id}/messages", %{
            "payload" =>
              a2a_user_text(
                "runtime-concurrent-send-#{number}",
                "concurrent message #{number}"
              )
          })
          |> json_response(201)
        end,
        max_concurrency: 5,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, reply} -> reply end)

    {sequences, last_sequences} =
      Enum.reduce(replies, {[], []}, fn reply, {sequences, last_sequences} ->
        sequence = get_in(reply, ["message_status", "message", "session_sequence"])
        last_sequence = get_in(reply, ["session", "last_sequence"])

        {[sequence | sequences], [last_sequence | last_sequences]}
      end)

    assert Enum.sort(sequences) == [2, 3, 4, 5, 6]
    assert Enum.sort(last_sequences) == [2, 3, 4, 5, 6]
    assert [{pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    assert %SessionState{session_id: ^session_id, last_sequence: 6} = :sys.get_state(pid)
  end

  test "public sends continue after a session process crash", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_context!(conn, "runtime-send-recovery")

    session_id = session["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    assert {:ok, pid} = Runtime.ensure_session_started(session_id)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    _supervisor_state = :sys.get_state(@session_supervisor)
    assert [{recovered_pid, _metadata}] = Registry.lookup(@session_registry, session_id)
    refute recovered_pid == pid

    reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-recovered-send")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("runtime-recovered-send", "after recovery")
      })
      |> json_response(201)

    assert reply["message_status"]["message"]["session_sequence"] == 2
    assert [{^recovered_pid, _metadata}] = Registry.lookup(@session_registry, session_id)

    assert %SessionState{session_id: ^session_id, last_sequence: 2} =
             :sys.get_state(recovered_pid)
  end

  test "recipient can send the next message through the runtime", %{conn: conn} do
    %{recipient: recipient, session: session} =
      open_accepted_session_context!(conn, "runtime-recipient-send")

    session_id = session["id"]
    on_exit(fn -> stop_session_server(session_id) end)

    reply =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("runtime-recipient-send-message")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_agent_text("runtime-recipient-send-message", "recipient reply")
      })
      |> json_response(201)

    assert reply["session"]["last_sequence"] == 2
    assert reply["message_status"]["message"]["from"] == recipient["address"]
  end

  test "session sends reject invalid payloads before starting runtime", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-invalid-payload")

    session_id = session["id"]
    assert [] = Registry.lookup(@session_registry, session_id)

    response =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-invalid-payload-send")
      |> post("/api/sessions/#{session_id}/messages", %{})
      |> json_response(422)

    assert error_code(response) == "payload_required"
    assert [] = Registry.lookup(@session_registry, session_id)
  end

  test "session sends reject missing idempotency keys before starting runtime", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-idempotency-required")

    session_id = session["id"]
    assert [] = Registry.lookup(@session_registry, session_id)

    response =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("missing-idempotency-session-send", "missing key")
      })
      |> json_response(400)

    assert error_code(response) == "idempotency_key_required"
    assert [] = Registry.lookup(@session_registry, session_id)
  end

  test "session sends replay idempotent responses before starting runtime", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-idempotency-replay")

    session_id = session["id"]
    assert [] = Registry.lookup(@session_registry, session_id)

    params = %{
      "payload" => a2a_user_text("idempotent-replay-session-send", "replay me")
    }

    initiator_agent = Repo.get!(Agent, initiator["id"])
    route = "POST /api/sessions/#{session_id}/messages"
    replay_body = %{"idempotent" => true}

    assert {:ok, 201, ^replay_body} =
             Idempotency.run(
               initiator_agent,
               route,
               "runtime-idempotency-replay-send",
               params,
               fn ->
                 {:ok, 201, replay_body}
               end
             )

    replayed_reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-idempotency-replay-send")
      |> post("/api/sessions/#{session_id}/messages", params)
      |> json_response(201)

    assert replayed_reply == replay_body
    assert [] = Registry.lookup(@session_registry, session_id)
  end

  test "session sends reject idempotency conflicts before starting runtime", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-idempotency-conflict")

    session_id = session["id"]
    assert [] = Registry.lookup(@session_registry, session_id)

    original_params = %{
      "payload" => a2a_user_text("idempotency-conflict-original", "original")
    }

    initiator_agent = Repo.get!(Agent, initiator["id"])
    route = "POST /api/sessions/#{session_id}/messages"

    assert {:ok, 201, %{"idempotent" => true}} =
             Idempotency.run(
               initiator_agent,
               route,
               "runtime-idempotency-conflict-send",
               original_params,
               fn -> {:ok, 201, %{"idempotent" => true}} end
             )

    response =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("runtime-idempotency-conflict-send")
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text("idempotency-conflict-changed", "changed")
      })
      |> json_response(409)

    assert error_code(response) == "idempotency_conflict"
    assert [] = Registry.lookup(@session_registry, session_id)
  end

  test "session server keeps runtime state when the ledger rejects a send", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-server-error-state")

    session_id = session["id"]
    pid = start_supervised!({SessionServer, session_id})
    before_state = :sys.get_state(pid)

    assert {:error, :payload_required} =
             SessionServer.send_session_message(
               pid,
               Repo.get!(Agent, initiator["id"]),
               %{},
               "runtime-server-error-state-send",
               "POST /api/sessions/#{session_id}/messages"
             )

    assert :sys.get_state(pid) == before_state
  end

  test "session server persists sends through the durable ledger", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-server-durable-ledger")

    session_id = session["id"]
    pid = start_supervised!({SessionServer, session_id})

    original_ledger_config = Application.get_env(:atp, DurableLedger)
    original_recorder_config = Application.get_env(:atp, RecordingSessionSendLedger)

    on_exit(fn ->
      restore_application_env(DurableLedger, original_ledger_config)
      restore_application_env(RecordingSessionSendLedger, original_recorder_config)
    end)

    Application.put_env(:atp, DurableLedger, adapter: RecordingSessionSendLedger)
    Application.put_env(:atp, RecordingSessionSendLedger, test_pid: self())

    sender = Repo.get!(Agent, initiator["id"])

    params = %{
      "payload" => a2a_user_text("runtime-server-durable-ledger", "via durable ledger")
    }

    route = "POST /api/sessions/#{session_id}/messages"

    assert {:ok, 201, body} =
             SessionServer.send_session_message(
               pid,
               sender,
               params,
               "runtime-server-durable-ledger-send",
               route
             )

    assert body["message_status"]["message"]["id"] == "msg_recorded"

    assert_received {
      :durable_session_send,
      ^sender,
      ^session_id,
      ^params,
      "runtime-server-durable-ledger-send",
      ^route
    }
  end

  test "runtime preflights session sends through the durable ledger before startup", %{conn: conn} do
    %{initiator: initiator, session: session} =
      open_accepted_session_without_runtime_context!(conn, "runtime-preflight-durable-ledger")

    session_id = session["id"]
    original_ledger_config = Application.get_env(:atp, DurableLedger)
    original_recorder_config = Application.get_env(:atp, RecordingSessionSendLedger)

    on_exit(fn ->
      stop_session_server(session_id)
      restore_application_env(DurableLedger, original_ledger_config)
      restore_application_env(RecordingSessionSendLedger, original_recorder_config)
    end)

    Application.put_env(:atp, DurableLedger, adapter: RecordingSessionSendLedger)
    Application.put_env(:atp, RecordingSessionSendLedger, test_pid: self())

    sender = Repo.get!(Agent, initiator["id"])

    params = %{
      "payload" => a2a_user_text("runtime-preflight-durable-ledger", "via durable ledger")
    }

    route = "POST /api/sessions/#{session_id}/messages"

    assert {:ok, 201, body} =
             Runtime.send_session_message(
               sender,
               session_id,
               params,
               "runtime-preflight-durable-ledger-send",
               route
             )

    assert body["message_status"]["message"]["id"] == "msg_recorded"

    assert_received {
      :durable_session_preflight,
      ^sender,
      ^session_id,
      ^params,
      "runtime-preflight-durable-ledger-send",
      ^route
    }

    assert_received {
      :durable_session_send,
      ^sender,
      ^session_id,
      ^params,
      "runtime-preflight-durable-ledger-send",
      ^route
    }
  end

  test "runtime routes session accept and reject through the durable ledger" do
    original_ledger_config = Application.get_env(:atp, DurableLedger)
    original_recorder_config = Application.get_env(:atp, RecordingSessionSendLedger)

    on_exit(fn ->
      restore_application_env(DurableLedger, original_ledger_config)
      restore_application_env(RecordingSessionSendLedger, original_recorder_config)
    end)

    Application.put_env(:atp, DurableLedger, adapter: RecordingSessionSendLedger)
    Application.put_env(:atp, RecordingSessionSendLedger, test_pid: self())

    recipient = %Agent{
      id: "agt_runtime_lifecycle_recipient",
      account_id: "acc_runtime_lifecycle",
      address: "atp://agent/agt_runtime_lifecycle_recipient",
      status: "active"
    }

    accept_params = %{
      "payload" => a2a_user_text("runtime-lifecycle-accept", "accept through durable ledger")
    }

    assert capture_log(fn ->
             assert {:ok, 201,
                     %{
                       "ack" => %{"status" => "accepted"},
                       "session" => %{"id" => "ses_runtime_lifecycle_accept", "status" => "open"}
                     }} =
                      Runtime.accept_session(
                        recipient,
                        "ses_runtime_lifecycle_accept",
                        accept_params,
                        "runtime-lifecycle-accept",
                        "POST /api/sessions/ses_runtime_lifecycle_accept/accept"
                      )
           end) =~ "Failed to warm accepted ATP session runtime"

    assert_received {
      :durable_session_accept,
      ^recipient,
      "ses_runtime_lifecycle_accept",
      ^accept_params,
      "runtime-lifecycle-accept",
      "POST /api/sessions/ses_runtime_lifecycle_accept/accept"
    }

    reject_params = %{
      "payload" => a2a_user_text("runtime-lifecycle-reject", "reject through durable ledger")
    }

    assert {:ok, 201,
            %{
              "ack" => %{"status" => "rejected"},
              "session" => %{"id" => "ses_runtime_lifecycle_reject", "status" => "rejected"}
            }} =
             Runtime.reject_session(
               recipient,
               "ses_runtime_lifecycle_reject",
               reject_params,
               "runtime-lifecycle-reject",
               "POST /api/sessions/ses_runtime_lifecycle_reject/reject"
             )

    assert_received {
      :durable_session_reject,
      ^recipient,
      "ses_runtime_lifecycle_reject",
      ^reject_params,
      "runtime-lifecycle-reject",
      "POST /api/sessions/ses_runtime_lifecycle_reject/reject"
    }
  end

  test "durable session sends reject non-open sessions", %{conn: conn} do
    {initiator_data, recipient_data} = register_session_agents!(conn, "ledger-non-open-session")

    session =
      open_session!(
        initiator_data["agent_api_key"]["token"],
        "open-ledger-non-open-session",
        recipient_data["address"],
        a2a_user_text("opening-ledger-non-open-session", "not open")
      )["session"]

    initiator = Repo.get!(Agent, session["initiator_agent_id"])
    recipient = Repo.get!(Agent, session["recipient_agent_id"])

    assert {:error, :session_not_open} =
             DurableLedger.preflight_session_message(
               recipient,
               session["id"],
               %{"payload" => a2a_user_text("ledger-non-open-preflight", "not open")},
               "ledger-non-open-preflight-send",
               "POST /api/sessions/#{session["id"]}/messages"
             )

    assert {:error, :session_not_open} =
             DurableLedger.send_session_message(
               initiator,
               session["id"],
               %{"payload" => a2a_user_text("ledger-non-open-session", "not open")},
               "ledger-non-open-session-send",
               "POST /api/sessions/#{session["id"]}/messages"
             )
  end

  test "durable session sends require a participant and an active counterparty", %{conn: conn} do
    %{initiator: initiator, recipient: recipient, session: session} =
      open_accepted_session_without_runtime_context!(conn, "ledger-session-participants")

    account = create_account!(build_conn(), %{"name" => "Unrelated Runtime Network"})

    unrelated =
      register_agent!(account["account_api_key"]["token"], "register-ledger-unrelated", %{})

    assert {:error, :not_found} =
             DurableLedger.send_session_message(
               Repo.get!(Agent, unrelated["id"]),
               session["id"],
               %{"payload" => a2a_user_text("ledger-unrelated-session", "not a participant")},
               "ledger-unrelated-session-send",
               "POST /api/sessions/#{session["id"]}/messages"
             )

    disable_agent!(recipient["id"])

    assert {:error, :recipient_not_found} =
             DurableLedger.send_session_message(
               Repo.get!(Agent, initiator["id"]),
               session["id"],
               %{"payload" => a2a_user_text("ledger-inactive-counterparty", "recipient gone")},
               "ledger-inactive-counterparty-send",
               "POST /api/sessions/#{session["id"]}/messages"
             )
  end

  test "blocked opening sessions are rejected immediately", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "ledger-blocked-opening")

    block_response =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("ledger-blocked-opening-policy")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "block",
        "sender_agent_id" => initiator["id"]
      })
      |> json_response(200)

    assert block_response["sender_policy"]["effect"] == "block"

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-ledger-blocked-opening",
        recipient["address"],
        a2a_user_text("opening-ledger-blocked-opening", "blocked")
      )

    assert opened["session"]["status"] == "rejected"
    assert opened["message_status"]["carrier_status"] == "rejected"
  end

  test "opening delivery cannot complete before acceptance", %{conn: conn} do
    {initiator, recipient} = register_session_agents!(conn, "ledger-opening-complete")

    _opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-ledger-opening-complete",
        recipient["address"],
        a2a_user_text("opening-ledger-opening-complete", "complete too early")
      )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-ledger-opening-complete", %{
        "lease_seconds" => 60
      })

    response =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("ack-ledger-opening-complete")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "completed"})
      |> json_response(409)

    assert error_code(response) == "invalid_ack_transition"
  end

  defp open_accepted_session!(conn, key) do
    %{session: session} = open_accepted_session_without_runtime_context!(conn, key)
    session
  end

  defp open_accepted_session_without_runtime_context!(conn, key) do
    %{initiator: initiator, recipient: recipient, session: pending_session} =
      open_pending_session_context_without_runtime!(conn, key)

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}", %{
        "lease_seconds" => 60
      })

    route = "POST /api/deliveries/#{delivery["id"]}/acks"

    assert {:ok, 201, _accepted} =
             Ledger.ack_delivery(
               Repo.get!(Agent, recipient["id"]),
               delivery["id"],
               %{"status" => "accepted"},
               "accept-#{key}",
               route
             )

    assert {:ok, session_status} =
             Ledger.get_session(Repo.get!(Agent, initiator["id"]), pending_session["id"])

    %{initiator: initiator, recipient: recipient, session: session_status["session"]}
  end

  defp open_accepted_session_context!(conn, key) do
    {initiator, recipient} = register_session_agents!(conn, key)

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-#{key}",
        recipient["address"],
        a2a_user_text("opening-#{key}", "open runtime session")
      )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-#{key}", %{
        "lease_seconds" => 60
      })

    _accepted =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "accept-#{key}",
        %{"status" => "accepted"}
      )

    session_status =
      conn
      |> authorize(initiator["agent_api_key"]["token"])
      |> get("/api/sessions/#{opened["session"]["id"]}")
      |> json_response(200)

    %{initiator: initiator, recipient: recipient, session: session_status["session"]}
  end

  defp open_pending_session!(conn, key) do
    {initiator, recipient} = register_session_agents!(conn, key)

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-#{key}",
        recipient["address"],
        a2a_user_text("opening-#{key}", "open runtime session")
      )

    opened["session"]
  end

  defp open_pending_session_without_runtime_context!(conn, key) do
    %{session: session} = open_pending_session_context_without_runtime!(conn, key)
    session
  end

  defp open_pending_session_context_without_runtime!(conn, key) do
    {initiator, recipient} = register_session_agents!(conn, key)

    assert {:ok, 201, opened, _prepared} =
             DurableLedger.open_session(
               Repo.get!(Agent, initiator["id"]),
               %{
                 "to" => recipient["address"],
                 "payload" => a2a_user_text("opening-#{key}", "open runtime session")
               },
               "open-#{key}",
               "POST /api/sessions"
             )

    %{initiator: initiator, recipient: recipient, session: opened["session"]}
  end

  defp session_message_task(initiator_token, session_id, key, text) do
    Task.async(fn ->
      receive do
        :send_session_message -> :ok
      end

      build_conn()
      |> authorize(initiator_token)
      |> idempotency_key(key)
      |> post("/api/sessions/#{session_id}/messages", %{
        "payload" => a2a_user_text(key, text)
      })
      |> json_response(201)
    end)
  end

  defp assert_session_webhook_delivery!(session_id, session_sequence) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert_session_webhook_delivery!(session_id, session_sequence, deadline)
  end

  defp assert_session_webhook_delivery!(session_id, session_sequence, deadline) do
    case session_webhook_delivery(session_id, session_sequence) do
      %Delivery{} = delivery ->
        delivery

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk(
            "session webhook delivery was not created for session #{session_id} sequence #{session_sequence}"
          )
        else
          receive do
          after
            10 -> assert_session_webhook_delivery!(session_id, session_sequence, deadline)
          end
        end
    end
  end

  defp session_webhook_delivery(session_id, session_sequence) do
    Delivery
    |> join(:inner, [delivery], message in assoc(delivery, :message))
    |> where([delivery, message], delivery.mode == "webhook")
    |> where([_delivery, message], message.session_id == ^session_id)
    |> where([_delivery, message], message.session_sequence == ^session_sequence)
    |> Repo.one()
  end

  defp start_session_lock!(session_id, parent) do
    task = Task.async(fn -> hold_session_lock!(session_id, parent) end)

    assert_receive :session_locked, 5_000
    task
  end

  defp hold_session_lock!(session_id, parent) do
    checked_out_unboxed_repo(fn ->
      Repo.transaction(fn -> wait_with_session_lock!(session_id, parent) end)
    end)
  end

  defp wait_with_session_lock!(session_id, parent) do
    lock_session!(session_id)
    send(parent, :session_locked)
    assert_receive :release_session_lock, 5_000
    :ok
  end

  defp lock_session!(session_id) do
    Session
    |> where([session], session.id == ^session_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp message_lock_available?(message_id) do
    Repo.transaction(fn ->
      Message
      |> where([message], message.id == ^message_id)
      |> lock("FOR UPDATE NOWAIT")
      |> Repo.one!()
    end)

    true
  rescue
    error in Postgrex.Error ->
      if lock_not_available?(error) do
        false
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp lock_not_available?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_not_available?(%Postgrex.Error{postgres: %{code: "55P03"}}), do: true
  defp lock_not_available?(%Postgrex.Error{}), do: false

  defp assert_backend_waiting_on_lock!(backend_pid, label) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert_backend_waiting_on_lock!(backend_pid, label, deadline)
  end

  defp assert_backend_waiting_on_lock!(backend_pid, label, deadline) do
    case backend_wait_event(backend_pid) do
      {"Lock", _wait_event, _state} ->
        :ok

      wait_state ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk(
            "#{label} task did not reach the expected database lock wait: #{inspect(wait_state)}"
          )
        else
          receive do
          after
            10 -> assert_backend_waiting_on_lock!(backend_pid, label, deadline)
          end
        end
    end
  end

  defp backend_wait_event(backend_pid) do
    %{rows: [[wait_event_type, wait_event, state]]} =
      Repo.query!(
        """
        SELECT wait_event_type, wait_event, state
        FROM pg_stat_activity
        WHERE pid = $1
        """,
        [backend_pid]
      )

    {wait_event_type, wait_event, state}
  end

  defp db_backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
    backend_pid
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

  defp await_task_results!(named_tasks) do
    Enum.map(named_tasks, fn {name, task} ->
      result = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

      case result do
        {:ok, value} ->
          {name, value}

        {:exit, reason} ->
          flunk("#{name} task exited while racing opening ACK and expiry: #{inspect(reason)}")

        nil ->
          flunk("#{name} task timed out while racing opening ACK and expiry")
      end
    end)
  end

  defp register_session_agents!(conn, key) do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-#{key}-initiator", %{})
    recipient = register_agent!(account_token, "register-#{key}-recipient", %{})

    {initiator, recipient}
  end

  defp disable_agent!(agent_id) do
    Agent
    |> Repo.get!(agent_id)
    |> Ecto.Changeset.change(status: "disabled")
    |> Repo.update!()
  end

  defp session_supervised?(pid) do
    @session_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.any?(fn
      {_id, ^pid, :worker, [SessionServer]} -> true
      _child -> false
    end)
  end

  defp stop_all_session_servers do
    if Process.whereis(@session_supervisor) do
      @session_supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_id, pid, :worker, [SessionServer]} when is_pid(pid) ->
          stop_registered_session_server(pid)

        _child ->
          :ok
      end)
    end
  end

  defp ensure_runtime_supervisor_running do
    if is_nil(Process.whereis(Atp.Transport.Runtime.Supervisor)) do
      case Supervisor.restart_child(Atp.Supervisor, Atp.Transport.Runtime.Supervisor) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end

    :ok
  end

  defp restart_runtime_supervisor! do
    ensure_runtime_supervisor_running()
    :ok = Supervisor.terminate_child(Atp.Supervisor, Atp.Transport.Runtime.Supervisor)
    assert is_nil(Process.whereis(@session_registry))
    assert is_nil(Process.whereis(@session_supervisor))

    assert {:ok, _runtime_pid} =
             Supervisor.restart_child(Atp.Supervisor, Atp.Transport.Runtime.Supervisor)

    _runtime_state = :sys.get_state(Atp.Transport.Runtime.Supervisor)
    :ok
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:atp, key)
  defp restore_application_env(key, config), do: Application.put_env(:atp, key, config)

  defp stop_session_server(session_id) do
    if Process.whereis(@session_registry) do
      case Registry.lookup(@session_registry, session_id) do
        [{pid, _metadata}] -> stop_registered_session_server(pid)
        [] -> :ok
      end
    else
      :ok
    end
  end

  defp stop_registered_session_server(pid) do
    ref = Process.monitor(pid)

    case DynamicSupervisor.terminate_child(@session_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> GenServer.stop(pid, :normal, 5_000)
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  catch
    :exit, _reason -> :ok
  end
end
