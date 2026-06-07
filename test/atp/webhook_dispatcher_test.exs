defmodule Atp.WebhookDispatcherTest do
  use Atp.ConnCase, async: false

  alias Atp.Repo
  alias Atp.Transport.{Delivery, WebhookDelivery, WebhookDispatcher}
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
