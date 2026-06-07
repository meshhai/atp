defmodule Atp.WebhookAPITest do
  use Atp.ConnCase, async: true

  alias Atp.Transport.{
    Delivery,
    WebhookAttempt,
    WebhookDelivery,
    WebhookDispatcher,
    WebhookSignature
  }

  alias Ecto.Adapters.SQL.Sandbox

  test "an agent configures an active webhook endpoint with a generated secret", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    agent = register_agent!(account_token, "register-webhook-agent", %{})

    url = "https://recipient.example.test/atp/webhook"
    configured = configure_webhook!(agent, "configure-webhook", url)

    assert configured["webhook_endpoint"]["url"] == url
    assert configured["webhook_endpoint"]["active"] == true
    assert String.starts_with?(configured["webhook_endpoint"]["endpoint_secret"], "whsec_")

    replayed = configure_webhook!(agent, "configure-webhook", url)

    assert replayed == configured
  end

  test "webhook endpoint setup rejects local and private network URLs", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    agent = register_agent!(account_token, "register-private-webhook-agent", %{})
    agent_token = agent["agent_api_key"]["token"]

    blocked_urls = [
      "http://",
      "http://:4000/atp/webhook",
      "ftp://recipient.example.test/atp/webhook",
      "http://localhost/atp/webhook",
      "http://app.localhost/atp/webhook",
      "http://127.0.0.1/atp/webhook",
      "http://10.0.0.1/atp/webhook",
      "http://100.64.0.1/atp/webhook",
      "http://172.16.0.1/atp/webhook",
      "http://192.168.0.1/atp/webhook",
      "http://169.254.169.254/latest/meta-data",
      "http://192.0.2.1/atp/webhook",
      "http://198.18.0.1/atp/webhook",
      "http://198.51.100.1/atp/webhook",
      "http://203.0.113.1/atp/webhook",
      "http://224.0.0.1/atp/webhook",
      "http://[::]/atp/webhook",
      "http://[::1]/atp/webhook",
      "http://[::ffff:127.0.0.1]/atp/webhook",
      "http://[::ffff:10.0.0.1]/atp/webhook",
      "http://[64:ff9b::7f00:1]/atp/webhook",
      "http://[fc00::1]/atp/webhook",
      "http://[fe80::1]/atp/webhook",
      "http://[ff00::1]/atp/webhook"
    ]

    for {url, index} <- Enum.with_index(blocked_urls) do
      response =
        build_conn()
        |> authorize(agent_token)
        |> idempotency_key("configure-private-webhook-#{index}")
        |> put("/api/agents/#{agent["id"]}/webhook_endpoint", %{"url" => url})
        |> json_response(422)

      assert error_code(response) == "invalid_webhook_url"
    end
  end

  test "webhook endpoint setup accepts public IP literal URLs", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    agent = register_agent!(account_token, "register-public-ip-webhook-agent", %{})

    public_urls = [
      "http://8.8.8.8/atp/webhook",
      "https://[2001:4860:4860::8888]/atp/webhook"
    ]

    for {url, index} <- Enum.with_index(public_urls) do
      configured = configure_webhook!(agent, "configure-public-ip-webhook-#{index}", url)

      assert configured["webhook_endpoint"]["url"] == url
    end
  end

  test "webhook endpoint setup stores long URLs and rejects API limit overflows", %{conn: conn} do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-long-webhook-sender", %{})
    recipient = register_agent!(account_token, "register-long-webhook-recipient", %{})
    agent_token = recipient["agent_api_key"]["token"]

    long_url = "https://recipient.example.test/atp/webhook/#{String.duplicate("a", 600)}"

    assert String.length(long_url) > 255
    assert String.length(long_url) <= 2_048

    configured = configure_webhook!(recipient, "configure-long-webhook", long_url)

    assert configured["webhook_endpoint"]["url"] == long_url

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-long-webhook",
        recipient["address"],
        a2a_user_text("long-webhook-message", "persist the long webhook URL")
      )

    assert %{"carrier_status" => "delivered"} =
             deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])

    recipient_status =
      build_conn()
      |> authorize(agent_token)
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert [%{"attempts" => [%{"request_url" => ^long_url}]}] = recipient_status["deliveries"]

    too_long_url = "https://recipient.example.test/atp/webhook/#{String.duplicate("b", 2_100)}"

    overflow =
      build_conn()
      |> authorize(agent_token)
      |> idempotency_key("configure-too-long-webhook")
      |> put("/api/agents/#{recipient["id"]}/webhook_endpoint", %{"url" => too_long_url})
      |> json_response(422)

    assert error_code(overflow) == "invalid_webhook_url"
  end

  test "webhook endpoint setup is scoped to the authenticated agent and requires a URL", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    agent = register_agent!(account_token, "register-scoped-webhook-agent", %{})
    other_agent = register_agent!(account_token, "register-other-webhook-agent", %{})
    agent_token = agent["agent_api_key"]["token"]

    missing =
      build_conn()
      |> authorize(agent_token)
      |> idempotency_key("configure-missing-webhook")
      |> put("/api/agents/#{agent["id"]}/webhook_endpoint", %{})
      |> json_response(422)

    assert error_code(missing) == "invalid_webhook_url"

    blank =
      build_conn()
      |> authorize(agent_token)
      |> idempotency_key("configure-blank-webhook")
      |> put("/api/agents/#{agent["id"]}/webhook_endpoint", %{"url" => "   "})
      |> json_response(422)

    assert error_code(blank) == "invalid_webhook_url"

    other_agent_update =
      build_conn()
      |> authorize(agent_token)
      |> idempotency_key("configure-other-agent-webhook")
      |> put("/api/agents/#{other_agent["id"]}/webhook_endpoint", %{
        "url" => "https://recipient.example.test/atp/webhook"
      })
      |> json_response(404)

    assert error_code(other_agent_update) == "not_found"
  end

  test "trusted messages to active webhook endpoints queue before signed delivery", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, body, body_conn} = Plug.Conn.read_body(request_conn)
      headers = Map.new(body_conn.req_headers)

      send(test_pid, {:webhook_request, headers, body})

      Plug.Conn.send_resp(body_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-webhook-sender", %{})
    recipient = register_agent!(account_token, "register-webhook-recipient", %{})

    webhook_url = "https://recipient.example.test/atp/webhook?token=sender-hidden"
    configured = configure_webhook!(recipient, "configure-recipient-webhook", webhook_url)

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-signed-webhook",
        recipient["address"],
        a2a_user_text("signed-webhook-message", "deliver by webhook")
      )

    assert sent["carrier_status"] == "queued"
    assert is_nil(sent["ack_status"])

    assert [
             %{
               "id" => delivery_id,
               "mode" => "webhook",
               "status" => "retry_scheduled",
               "attempt_count" => 0,
               "attempts" => []
             }
           ] = sent["deliveries"]

    refute_receive {:webhook_request, _headers, _body}, 100

    assert {:ok, _message} = WebhookDelivery.deliver_now(delivery_id)

    assert_receive {:webhook_request, headers, raw_body}

    body = Jason.decode!(raw_body)
    timestamp = headers["atp-timestamp"]
    signature = headers["atp-signature"]

    expected_signature =
      WebhookSignature.sign(
        timestamp,
        raw_body,
        configured["webhook_endpoint"]["endpoint_secret"]
      )

    assert headers["atp-delivery-id"] == body["delivery"]["id"]
    assert headers["atp-message-id"] == sent["message"]["id"]
    assert signature == expected_signature
    assert body["delivery"]["mode"] == "webhook"
    assert body["message"] == sent["message"]

    status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert status["carrier_status"] == "delivered"
    assert is_nil(status["ack_status"])

    assert [
             %{
               "id" => ^delivery_id,
               "mode" => "webhook",
               "status" => "delivered",
               "attempt_count" => 1,
               "attempts" => [
                 %{
                   "attempt_number" => 1,
                   "result" => "delivered",
                   "response_status" => 204
                 }
               ]
             }
           ] = status["deliveries"]

    assert [sender_status_delivery] = status["deliveries"]
    assert [sender_status_attempt] = sender_status_delivery["attempts"]
    refute Map.has_key?(sender_status_attempt, "request_url")

    recipient_status =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert [recipient_status_delivery] = recipient_status["deliveries"]
    assert [recipient_status_attempt] = recipient_status_delivery["attempts"]
    assert recipient_status_attempt["request_url"] == webhook_url

    assert delivery_id == body["delivery"]["id"]
  end

  test "direct send replay to active webhooks returns the committed response once", %{
    conn: conn
  } do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, body, request_conn} = Plug.Conn.read_body(request_conn)

      send(test_pid, {:webhook_request, Jason.decode!(body)})

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-webhook-replay-sender", %{})
    recipient = register_agent!(account_token, "register-webhook-replay-recipient", %{})

    configure_webhook!(
      recipient,
      "configure-webhook-replay-recipient",
      "https://recipient.example.test/atp/replay"
    )

    params = %{
      "to" => recipient["address"],
      "payload" => a2a_user_text("webhook-replay-message", "deliver once")
    }

    first =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("send-webhook-replay")
      |> post("/api/messages", params)
      |> json_response(201)

    assert first["carrier_status"] == "queued"

    assert [
             %{
               "id" => delivery_id,
               "mode" => "webhook",
               "status" => "retry_scheduled",
               "attempt_count" => 0,
               "attempts" => []
             }
           ] = first["deliveries"]

    refute_receive {:webhook_request, _body}, 100

    assert {:ok, _message} = WebhookDelivery.deliver_now(delivery_id)
    assert_receive {:webhook_request, webhook_body}
    assert webhook_body["message"] == first["message"]

    delivered_status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{first["message"]["id"]}")
      |> json_response(200)

    assert delivered_status["carrier_status"] == "delivered"

    assert [%{"mode" => "webhook", "status" => "delivered", "attempt_count" => 1}] =
             delivered_status["deliveries"]

    replay =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("send-webhook-replay")
      |> post("/api/messages", params)
      |> json_response(201)

    assert replay == first
    refute_receive {:webhook_request, _body}, 100
  end

  test "webhook delivery rejects DNS targets that resolve to private addresses", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      send(test_pid, :unsafe_webhook_requested)
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    promote_to_basic!(account)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-private-dns-sender", %{})

    for host <- ["private.example.test", "mixed.example.test"] do
      recipient = register_agent!(account_token, "register-#{host}-recipient", %{})

      configure_webhook!(
        recipient,
        "configure-#{host}-recipient",
        "https://#{host}/atp/webhook"
      )

      sent =
        send_message!(
          sender["agent_api_key"]["token"],
          "send-#{host}-webhook",
          recipient["address"],
          a2a_user_text("#{host}-webhook", "do not deliver to private dns")
        )

      assert sent["carrier_status"] == "queued"
      refute_receive :unsafe_webhook_requested, 100

      failed_status = deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])

      assert failed_status["carrier_status"] == "delivery_failed"

      assert [
               %{
                 "status" => "failed",
                 "attempt_count" => 1,
                 "attempts" => [
                   %{
                     "result" => "failed",
                     "response_status" => nil,
                     "error" => "unsafe_webhook_url"
                   }
                 ]
               }
             ] = failed_status["deliveries"]
    end

    refute_receive :unsafe_webhook_requested, 100
  end

  test "webhook delivery connects to the validated IP and preserves the original host", %{
    conn: conn
  } do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)

      send(
        test_pid,
        {:safe_webhook_request, request_conn.host, request_conn.request_path,
         request_conn.query_string, headers}
      )

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-safe-connect-webhook-sender", %{})
    recipient = register_agent!(account_token, "register-safe-connect-webhook-recipient", %{})

    configure_webhook!(
      recipient,
      "configure-safe-connect-webhook-recipient",
      "https://recipient.example.test:8443/atp/webhook?mode=safe"
    )

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-safe-connect-webhook",
        recipient["address"],
        a2a_user_text("safe-connect-webhook", "connect to validated IP")
      )

    assert sent["carrier_status"] == "queued"

    assert %{"carrier_status" => "delivered"} =
             deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])

    assert_receive {:safe_webhook_request, "93.184.216.34", "/atp/webhook", "mode=safe", headers}

    assert headers["host"] == "recipient.example.test:8443"
  end

  test "webhook delivery does not follow redirects to private URLs", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:redirect_webhook_requested, request_conn.host, headers["host"]})

      request_conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/latest/meta-data")
      |> Plug.Conn.send_resp(302, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-redirect-webhook-sender", %{})
    recipient = register_agent!(account_token, "register-redirect-webhook-recipient", %{})
    configure_webhook!(recipient, "configure-redirect-webhook-recipient")

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-redirect-webhook",
        recipient["address"],
        a2a_user_text("redirect-webhook", "do not follow redirects")
      )

    assert sent["carrier_status"] == "queued"
    failed_status = deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])

    assert failed_status["carrier_status"] == "delivery_failed"

    assert [
             %{
               "status" => "failed",
               "attempt_count" => 1,
               "attempts" => [
                 %{"result" => "failed", "response_status" => 302, "error" => nil}
               ]
             }
           ] = failed_status["deliveries"]

    assert_receive {:redirect_webhook_requested, "93.184.216.34", "recipient.example.test"}
    refute_receive {:redirect_webhook_requested, _host, _host_header}, 100
  end

  test "direct webhook delivery helper prepares and sends a delivery", %{conn: conn} do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-direct-helper-sender", %{})
    recipient = register_agent!(account_token, "register-direct-helper-recipient", %{})

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-direct-helper-message",
        recipient["address"],
        a2a_user_text("direct-helper-message", "deliver through helper")
      )

    configure_webhook!(recipient, "configure-direct-helper-recipient")

    message = Atp.Repo.get!(Atp.Transport.Message, sent["message"]["id"])
    recipient_agent = Atp.Repo.get!(Atp.Identity.Agent, recipient["id"])

    assert {:ok, delivered_message} = WebhookDelivery.deliver_now(message, recipient_agent)
    assert delivered_message.carrier_status == "delivered"

    delivered_delivery = Atp.Repo.get_by!(Delivery, message_id: message.id, mode: "webhook")
    assert {:ok, already_delivered_message} = WebhookDelivery.deliver_now(delivered_delivery.id)
    assert already_delivered_message.id == delivered_message.id
  end

  test "direct webhook delivery reports unknown delivery ids" do
    assert WebhookDelivery.deliver_now("dlv_missing") == {:error, :not_found}
  end

  test "stale webhook deliveries fail without crashing after endpoint is removed", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-stale-webhook-sender", %{})
    recipient = register_agent!(account_token, "register-stale-webhook-recipient", %{})

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-stale-webhook-message",
        recipient["address"],
        a2a_user_text("stale-webhook-message", "endpoint removed before dispatch")
      )

    configure_webhook!(recipient, "configure-stale-webhook-recipient")

    message = Atp.Repo.get!(Atp.Transport.Message, sent["message"]["id"])
    recipient_agent = Atp.Repo.get!(Atp.Identity.Agent, recipient["id"])

    assert {:ok, delivery} = WebhookDelivery.prepare(message, recipient_agent)

    recipient_agent
    |> Ecto.Changeset.change(webhook_active: false, webhook_url: nil, webhook_secret: nil)
    |> Atp.Repo.update!()

    assert {:ok, failed_message} = WebhookDelivery.deliver_now(delivery.id)
    assert failed_message.id == message.id
    assert failed_message.carrier_status == "delivery_failed"

    persisted_delivery = Atp.Repo.get!(Delivery, delivery.id)
    assert persisted_delivery.status == "failed"
    assert persisted_delivery.last_error == "webhook_endpoint_inactive"

    refute Atp.Repo.get_by(WebhookAttempt, delivery_id: delivery.id)
  end

  test "direct webhook delivery leases before posting so retry dispatch cannot duplicate it", %{
    conn: conn
  } do
    test_pid = self()
    release_webhook = make_ref()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:leased_webhook_started, headers["atp-delivery-id"]})

      receive do
        ^release_webhook -> Plug.Conn.send_resp(request_conn, 204, "")
      end
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-lease-before-post-sender", %{})
    recipient = register_agent!(account_token, "register-lease-before-post-recipient", %{})
    configure_webhook!(recipient, "configure-lease-before-post-recipient")

    delivery_id =
      prepare_unsent_webhook_delivery!(
        sender,
        recipient,
        "lease-before-post",
        a2a_user_text("lease-before-post", "lease before post")
      )

    task =
      Task.async(fn ->
        receive do
          :deliver -> WebhookDelivery.deliver_now(delivery_id)
        end
      end)

    Sandbox.allow(Atp.Repo, self(), task.pid)
    Req.Test.allow(WebhookDelivery, self(), task.pid)

    send(task.pid, :deliver)

    assert_receive {:leased_webhook_started, ^delivery_id}, 500

    active_delivery = Atp.Repo.get!(Delivery, delivery_id)
    assert active_delivery.status == "leased"
    assert active_delivery.claim_token =~ "dcl_"
    assert %DateTime{} = active_delivery.claimed_at
    assert DateTime.compare(active_delivery.leased_until, DateTime.utc_now(:microsecond)) == :gt

    assert WebhookDelivery.deliver_now(delivery_id) == {:error, :delivery_in_progress}
    assert WebhookDelivery.deliver_due(limit: 10) == {:ok, []}

    send(task.pid, release_webhook)
    assert {:ok, _message} = Task.await(task, 1_000)
    assert_delivered_delivery!(delivery_id)
  end

  test "webhook requests are sent by delivery workers after intake commits", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      send(test_pid, {:webhook_in_transaction?, Atp.Repo.in_transaction?()})
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-commit-sender", %{})
    recipient = register_agent!(account_token, "register-commit-recipient", %{})

    configure_webhook!(recipient, "configure-commit-recipient-webhook")

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-committed-webhook",
        recipient["address"],
        a2a_user_text("committed-webhook-message", "visible after commit")
      )

    refute_receive {:webhook_in_transaction?, _in_transaction?}, 100

    assert %{"carrier_status" => "delivered"} =
             deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])

    assert_receive {:webhook_in_transaction?, false}
  end

  test "recipient can ACK a signed webhook delivery id and cannot extend it as a lease", %{
    conn: conn
  } do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-webhook-ack-sender", %{})
    recipient = register_agent!(account_token, "register-webhook-ack-recipient", %{})

    configure_webhook!(recipient, "configure-webhook-ack-recipient")

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-webhook-ack-message",
        recipient["address"],
        a2a_user_text("webhook-ack-message", "ack by webhook delivery id")
      )

    assert [
             %{
               "id" => delivery_id,
               "mode" => "webhook",
               "status" => "retry_scheduled",
               "attempt_count" => 0
             }
           ] = sent["deliveries"]

    status = deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])

    assert [
             %{
               "id" => ^delivery_id,
               "mode" => "webhook",
               "status" => "delivered",
               "leased_until" => nil
             }
           ] = status["deliveries"]

    rejected_extend =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("extend-webhook-delivery")
      |> post("/api/deliveries/#{delivery_id}/extend", %{"lease_seconds" => 120})
      |> json_response(422)

    assert error_code(rejected_extend) == "invalid_lease"

    acked =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery_id,
        "ack-webhook-delivery",
        %{"status" => "accepted", "payload" => a2a_agent_text("webhook-received", "received")}
      )

    assert acked["ack"]["delivery_id"] == delivery_id
    assert acked["ack"]["status"] == "accepted"
    assert acked["message_status"]["ack_status"] == "accepted"
  end

  test "recipient cannot ACK webhook deliveries until the carrier delivery succeeds", %{
    conn: conn
  } do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 503, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-undelivered-ack-sender", %{})
    recipient = register_agent!(account_token, "register-undelivered-ack-recipient", %{})

    configure_webhook!(recipient, "configure-undelivered-ack-recipient")

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-undelivered-ack-message",
        recipient["address"],
        a2a_user_text("undelivered-webhook-message", "not delivered yet")
      )

    assert [%{"id" => delivery_id, "status" => "retry_scheduled"}] = sent["deliveries"]

    ack =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("ack-undelivered-webhook")
      |> post("/api/deliveries/#{delivery_id}/acks", %{"status" => "accepted"})
      |> json_response(409)

    assert error_code(ack) == "delivery_not_delivered"
  end

  test "webhook signature verification uses deterministic timestamped HMAC fixtures" do
    timestamp = "1700000000"
    body = ~s({"message":"hello"})
    secret = "whsec_test"

    signature = WebhookSignature.sign(timestamp, body, secret)

    assert signature ==
             "t=1700000000,v1=4c7308b09c49c6b8d68c446406c87e8f9e58c19262d196a851b5d54eeed95cd5"

    assert WebhookSignature.verify(signature, timestamp, body, secret, 300, 1_700_000_100) == :ok

    assert WebhookSignature.verify(signature, timestamp, body, secret, 300, 1_700_001_000) ==
             {:error, :timestamp_out_of_tolerance}

    assert WebhookSignature.verify(signature, timestamp, body <> " ", secret, 300, 1_700_000_100) ==
             {:error, :invalid_signature}

    assert WebhookSignature.verify(signature, "not-a-timestamp", body, secret, 300, 1_700_000_100) ==
             {:error, :timestamp_out_of_tolerance}

    current_timestamp =
      DateTime.utc_now(:second)
      |> DateTime.to_unix()
      |> Integer.to_string()

    current_signature = WebhookSignature.sign(current_timestamp, body, secret)
    assert WebhookSignature.verify(current_signature, current_timestamp, body, secret, 300) == :ok
  end

  test "webhook retry classification follows transport status and plan policy", %{conn: conn} do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      case request_conn.request_path do
        "/too-many" ->
          Plug.Conn.send_resp(request_conn, 429, "")

        "/server-error" ->
          Plug.Conn.send_resp(request_conn, 503, "")

        "/timeout" ->
          Req.Test.transport_error(request_conn, :timeout)

        "/network-error" ->
          Req.Test.transport_error(request_conn, :closed)

        "/bad-request" ->
          Plug.Conn.send_resp(request_conn, 400, "")
      end
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-retry-sender", %{})
    recipient = register_agent!(account_token, "register-retry-recipient", %{})

    too_many =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/too-many",
        "too-many",
        a2a_user_text("rate-limited-webhook", "rate limited")
      )

    assert_retry_scheduled(too_many, 429, nil, 3)

    server_error =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/server-error",
        "server-error",
        a2a_user_text("server-error-webhook", "server error")
      )

    assert_retry_scheduled(server_error, 503, nil, 3)

    timeout =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/timeout",
        "timeout",
        a2a_user_text("timeout-webhook", "timeout")
      )

    assert_retry_scheduled(timeout, nil, "timeout", 3)

    network_error =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/network-error",
        "network-error",
        a2a_user_text("network-error-webhook", "network error")
      )

    assert_retry_scheduled(network_error, nil, "closed", 3)

    bad_request =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/bad-request",
        "bad-request",
        a2a_user_text("bad-request-webhook", "bad request")
      )

    assert bad_request["carrier_status"] == "delivery_failed"
    assert [failed_delivery] = bad_request["deliveries"]
    assert failed_delivery["status"] == "failed"
    assert failed_delivery["attempt_count"] == 1
    assert failed_delivery["max_attempts"] == 3
    assert is_nil(failed_delivery["next_attempt_at"])
    assert [%{"result" => "failed", "response_status" => 400}] = failed_delivery["attempts"]

    basic = create_account!(build_conn())
    promote_to_basic!(basic)
    basic_token = basic["account_api_key"]["token"]
    basic_sender = register_agent!(basic_token, "register-basic-retry-sender", %{})
    basic_recipient = register_agent!(basic_token, "register-basic-retry-recipient", %{})

    basic_server_error =
      send_after_configuring_webhook!(
        basic_sender,
        basic_recipient,
        "/server-error",
        "basic-server-error",
        a2a_user_text("basic-server-error-webhook", "basic server error")
      )

    assert_retry_scheduled(basic_server_error, 503, nil, 8)
  end

  test "webhook retries stop at the plan attempt cap", %{conn: conn} do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 503, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-capped-retry-sender", %{})
    recipient = register_agent!(account_token, "register-capped-retry-recipient", %{})

    sent =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/server-error",
        "capped-server-error",
        a2a_user_text("capped-server-error-webhook", "eventually fail")
      )

    assert [%{"id" => delivery_id, "attempt_count" => 1, "max_attempts" => 3}] =
             sent["deliveries"]

    assert {:ok, _message} = WebhookDelivery.deliver_now(delivery_id)

    after_second =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert [%{"status" => "retry_scheduled", "attempt_count" => 2}] = after_second["deliveries"]

    assert {:ok, _message} = WebhookDelivery.deliver_now(delivery_id)

    after_third =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert after_third["carrier_status"] == "delivery_failed"

    assert [
             %{
               "status" => "failed",
               "attempt_count" => 3,
               "max_attempts" => 3,
               "next_attempt_at" => nil,
               "attempts" => attempts
             }
           ] = after_third["deliveries"]

    assert Enum.map(attempts, & &1["attempt_number"]) == [1, 2, 3]
    assert [_first_attempt, _second_attempt, %{"result" => "failed"}] = attempts
  end

  test "active polling leases block webhook delivery for the same message", %{conn: conn} do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 400, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-race-webhook-sender", %{})
    recipient = register_agent!(account_token, "register-race-webhook-recipient", %{})
    configure_webhook!(recipient, "configure-race-webhook-recipient")

    delivery_id =
      prepare_unsent_webhook_delivery!(
        sender,
        recipient,
        "polling-webhook-race",
        a2a_user_text("polling-webhook-race", "poll before webhook failure")
      )

    webhook_delivery = Atp.Repo.get!(Delivery, delivery_id)

    polling_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-polling-webhook-race", %{
        "lease_seconds" => 60
      })

    assert polling_delivery["message"]["id"] == webhook_delivery.message_id

    assert WebhookDelivery.deliver_now(delivery_id) == {:error, :delivery_in_progress}
    assert WebhookDelivery.deliver_due(limit: 10) == {:ok, []}

    Atp.Repo.get!(Delivery, polling_delivery["id"])
    |> Ecto.Changeset.change(
      leased_until: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Atp.Repo.update!()

    assert {:ok, delivered_message} = WebhookDelivery.deliver_now(delivery_id)
    assert delivered_message.carrier_status == "delivered"

    status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{webhook_delivery.message_id}")
      |> json_response(200)

    assert status["carrier_status"] == "delivered"

    assert [
             %{
               "status" => "failed",
               "attempts" => [%{"result" => "failed", "response_status" => 400}]
             }
           ] = Enum.filter(status["deliveries"], &(&1["id"] == delivery_id))
  end

  test "webhook retries stop after message expiry without another request", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      send(test_pid, :webhook_requested)
      Plug.Conn.send_resp(request_conn, 503, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-expired-retry-sender", %{})
    recipient = register_agent!(account_token, "register-expired-retry-recipient", %{})

    sent =
      send_after_configuring_webhook!(
        sender,
        recipient,
        "/server-error",
        "expired-server-error",
        a2a_user_text("expired-server-error-webhook", "expires before retry")
      )

    assert_receive :webhook_requested
    assert [%{"id" => delivery_id}] = sent["deliveries"]

    expire_message!(sent["message"]["id"])

    assert {:ok, _message} = WebhookDelivery.deliver_now(delivery_id)
    refute_receive :webhook_requested, 100

    status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert status["carrier_status"] == "expired"
    assert {:ok, _terminal_at, 0} = DateTime.from_iso8601(status["terminal_at"])
    assert [%{"status" => "failed", "attempt_count" => 1}] = status["deliveries"]
  end

  test "webhook retries stop after accepted or terminal ACKs from polling delivery", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:webhook_requested, headers["atp-message-id"]})
      Plug.Conn.send_resp(request_conn, 503, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-acked-retry-sender", %{})
    recipient = register_agent!(account_token, "register-acked-retry-recipient", %{})
    configure_webhook!(recipient, "configure-acked-retry-recipient")

    accepted =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-accepted-retry-message",
        recipient["address"],
        a2a_user_text("accepted-retry-message", "polling ack should stop webhook retry")
      )

    accepted_after_attempt =
      deliver_webhook_and_fetch_status!(accepted, sender["agent_api_key"]["token"])

    assert_receive {:webhook_requested, accepted_message_id}
    assert accepted_message_id == accepted["message"]["id"]

    assert [%{"id" => accepted_webhook_delivery_id, "status" => "retry_scheduled"}] =
             accepted_after_attempt["deliveries"]

    accepted_polling_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-accepted-retry-message", %{
        "lease_seconds" => 60
      })

    ack_delivery!(
      recipient["agent_api_key"]["token"],
      accepted_polling_delivery["id"],
      "ack-accepted-retry-message",
      %{"status" => "accepted"}
    )

    assert {:ok, _message} = WebhookDelivery.deliver_now(accepted_webhook_delivery_id)
    refute_receive {:webhook_requested, ^accepted_message_id}, 100

    accepted_status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{accepted["message"]["id"]}")
      |> json_response(200)

    assert accepted_status["ack_status"] == "accepted"

    assert [%{"status" => "failed", "attempt_count" => 1, "last_error" => "message_acked"}] =
             Enum.filter(accepted_status["deliveries"], &(&1["mode"] == "webhook"))

    completed =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-completed-retry-message",
        recipient["address"],
        a2a_user_text("completed-retry-message", "terminal polling ack should stop webhook retry")
      )

    completed_after_attempt =
      deliver_webhook_and_fetch_status!(completed, sender["agent_api_key"]["token"])

    assert_receive {:webhook_requested, completed_message_id}
    assert completed_message_id == completed["message"]["id"]

    assert [%{"id" => completed_webhook_delivery_id, "status" => "retry_scheduled"}] =
             completed_after_attempt["deliveries"]

    completed_polling_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-completed-retry-message", %{
        "lease_seconds" => 60
      })

    ack_delivery!(
      recipient["agent_api_key"]["token"],
      completed_polling_delivery["id"],
      "ack-completed-retry-message",
      %{"status" => "completed"}
    )

    assert {:ok, _message} = WebhookDelivery.deliver_now(completed_webhook_delivery_id)
    refute_receive {:webhook_requested, ^completed_message_id}, 100

    completed_status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{completed["message"]["id"]}")
      |> json_response(200)

    assert completed_status["ack_status"] == "completed"

    assert [%{"status" => "failed", "attempt_count" => 1, "last_error" => "message_acked"}] =
             Enum.filter(completed_status["deliveries"], &(&1["mode"] == "webhook"))
  end

  test "due webhook delivery recovery sends prepared and stale leased rows", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery = Atp.Repo.get!(Delivery, headers["atp-delivery-id"])

      send(
        test_pid,
        {:due_webhook_request, headers["atp-delivery-id"], delivery.claim_token,
         delivery.claimed_at}
      )

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-due-sender", %{})
    recipient = register_agent!(account_token, "register-due-recipient", %{})
    configure_webhook!(recipient, "configure-due-recipient")

    prepared_id =
      sender
      |> prepare_unsent_webhook_delivery!(
        recipient,
        "prepared-recovery",
        a2a_user_text("prepared-recovery", "recover prepared delivery")
      )

    stale_id =
      sender
      |> prepare_unsent_webhook_delivery!(
        recipient,
        "stale-lease-recovery",
        a2a_user_text("stale-lease-recovery", "recover stale lease")
      )
      |> lease_in_past!()

    assert {:ok, [{:ok, _prepared_message}, {:ok, _stale_message}]} =
             WebhookDelivery.deliver_due(limit: 10)

    assert_receive {:due_webhook_request, ^prepared_id, prepared_claim_token, %DateTime{}}
    assert prepared_claim_token =~ "dcl_"

    assert_receive {:due_webhook_request, ^stale_id, stale_claim_token, %DateTime{}}
    assert stale_claim_token =~ "dcl_"

    assert_delivered_delivery!(prepared_id)
    assert_delivered_delivery!(stale_id)
  end

  test "due webhook delivery recovery uses a fresh lease for each claimed row", %{conn: conn} do
    test_pid = self()
    stale_batch_now = DateTime.add(DateTime.utc_now(:microsecond), -120, :second)

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      delivery = Atp.Repo.get!(Delivery, headers["atp-delivery-id"])

      send(
        test_pid,
        {:fresh_due_claim, headers["atp-delivery-id"], delivery.claimed_at, delivery.leased_until}
      )

      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-fresh-due-sender", %{})
    recipient = register_agent!(account_token, "register-fresh-due-recipient", %{})
    configure_webhook!(recipient, "configure-fresh-due-recipient")

    first_id =
      prepare_unsent_webhook_delivery!(
        sender,
        recipient,
        "fresh-due-first",
        a2a_user_text("fresh-due-first", "first delivery")
      )

    second_id =
      prepare_unsent_webhook_delivery!(
        sender,
        recipient,
        "fresh-due-second",
        a2a_user_text("fresh-due-second", "second delivery")
      )

    assert {:ok, [{:ok, _first_message}, {:ok, _second_message}]} =
             WebhookDelivery.deliver_due(limit: 2, now: stale_batch_now)

    assert_receive {:fresh_due_claim, ^first_id, first_claimed_at, first_leased_until}
    assert_receive {:fresh_due_claim, ^second_id, second_claimed_at, second_leased_until}

    assert DateTime.compare(first_claimed_at, stale_batch_now) == :gt
    assert DateTime.compare(second_claimed_at, stale_batch_now) == :gt
    assert DateTime.compare(first_leased_until, DateTime.utc_now(:microsecond)) == :gt
    assert DateTime.compare(second_leased_until, DateTime.utc_now(:microsecond)) == :gt

    assert_delivered_delivery!(first_id)
    assert_delivered_delivery!(second_id)
    assert Atp.Repo.aggregate(Atp.Transport.WebhookAttempt, :count, :id) == 2
  end

  test "due webhook delivery recovery ignores invalid limits" do
    assert WebhookDelivery.deliver_due(limit: 0) == {:ok, []}
  end

  test "due webhook delivery recovery surfaces claim errors" do
    assert WebhookDelivery.deliver_due(limit: 1, lease_seconds: 0) ==
             {:ok, [{:error, :invalid_lease}]}
  end

  test "webhook dispatcher drains durable due delivery rows", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      headers = Map.new(request_conn.req_headers)
      send(test_pid, {:dispatcher_webhook_request, headers["atp-delivery-id"]})
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-dispatcher-sender", %{})
    recipient = register_agent!(account_token, "register-dispatcher-recipient", %{})
    configure_webhook!(recipient, "configure-dispatcher-recipient")

    delivery_id =
      prepare_unsent_webhook_delivery!(
        sender,
        recipient,
        "dispatcher-recovery",
        a2a_user_text("dispatcher-recovery", "recover through dispatcher")
      )

    dispatcher =
      start_supervised!(
        {WebhookDispatcher,
         enabled: true, dispatch_on_start?: false, batch_size: 10, interval_ms: 60_000, name: nil}
      )

    Sandbox.allow(Atp.Repo, self(), dispatcher)
    Req.Test.allow(WebhookDelivery, self(), dispatcher)
    send(dispatcher, :dispatch_due)

    assert_receive {:dispatcher_webhook_request, ^delivery_id}
    _state = :sys.get_state(dispatcher)
    assert_delivered_delivery!(delivery_id)
  end

  test "disabled webhook dispatcher ignores dispatch ticks" do
    name = :atp_disabled_webhook_dispatcher_test
    pid = start_supervised!({WebhookDispatcher, enabled: false, name: name})

    assert Process.whereis(name) == pid
    send(pid, :dispatch_due)

    assert %{enabled?: false} = :sys.get_state(pid)
  end

  defp send_after_configuring_webhook!(sender, recipient, path, key, payload) do
    configure_webhook!(
      recipient,
      "configure-webhook-#{key}",
      "https://recipient.example.test#{path}"
    )

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-webhook-#{key}",
        recipient["address"],
        payload
      )

    deliver_webhook_and_fetch_status!(sent, sender["agent_api_key"]["token"])
  end

  defp deliver_webhook_and_fetch_status!(message_status, viewer_token) do
    assert [%{"id" => delivery_id, "mode" => "webhook"}] = message_status["deliveries"]
    assert {:ok, _message} = WebhookDelivery.deliver_now(delivery_id)

    build_conn()
    |> authorize(viewer_token)
    |> get("/api/messages/#{message_status["message"]["id"]}")
    |> json_response(200)
  end

  defp assert_retry_scheduled(response, response_status, error_fragment, max_attempts) do
    assert response["carrier_status"] == "queued"
    assert [delivery] = response["deliveries"]
    assert delivery["status"] == "retry_scheduled"
    assert delivery["attempt_count"] == 1
    assert delivery["max_attempts"] == max_attempts
    assert {:ok, _next_attempt_at, 0} = DateTime.from_iso8601(delivery["next_attempt_at"])

    assert [
             %{
               "result" => "retry_scheduled",
               "response_status" => ^response_status,
               "error" => error
             }
           ] = delivery["attempts"]

    if error_fragment do
      assert error =~ error_fragment
    else
      assert is_nil(error)
    end
  end

  defp promote_to_basic!(account) do
    Atp.Identity.Account
    |> Atp.Repo.get!(account["id"])
    |> Ecto.Changeset.change(plan: "basic")
    |> Atp.Repo.update!()
  end

  defp expire_message!(message_id) do
    Atp.Transport.Message
    |> Atp.Repo.get!(message_id)
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Atp.Repo.update!()
  end

  defp prepare_unsent_webhook_delivery!(sender, recipient, key, payload) do
    set_webhook_active!(recipient["id"], false)

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-unsent-webhook-#{key}",
        recipient["address"],
        payload
      )

    message = Atp.Repo.get!(Atp.Transport.Message, sent["message"]["id"])
    recipient_agent = set_webhook_active!(recipient["id"], true)

    assert {:ok, delivery} = WebhookDelivery.prepare(message, recipient_agent)

    delivery.id
  end

  defp set_webhook_active!(agent_id, active?) do
    Atp.Identity.Agent
    |> Atp.Repo.get!(agent_id)
    |> Ecto.Changeset.change(webhook_active: active?)
    |> Atp.Repo.update!()
  end

  defp lease_in_past!(delivery_id) do
    Atp.Transport.Delivery
    |> Atp.Repo.get!(delivery_id)
    |> Ecto.Changeset.change(
      status: "leased",
      leased_until: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
    )
    |> Atp.Repo.update!()

    delivery_id
  end

  defp assert_delivered_delivery!(delivery_id, attempts_left \\ 20)

  defp assert_delivered_delivery!(delivery_id, attempts_left) when attempts_left > 0 do
    delivery = Atp.Repo.get!(Atp.Transport.Delivery, delivery_id)

    case delivery do
      %Atp.Transport.Delivery{status: "delivered"} ->
        assert is_nil(delivery.claim_token)
        assert is_nil(delivery.claimed_at)
        assert is_nil(delivery.leased_until)
        assert delivery.attempt_count == 1

      %Atp.Transport.Delivery{} ->
        Process.sleep(10)
        assert_delivered_delivery!(delivery_id, attempts_left - 1)
    end
  end

  defp assert_delivered_delivery!(delivery_id, 0) do
    delivery = Atp.Repo.get!(Atp.Transport.Delivery, delivery_id)

    assert delivery.status == "delivered"
    assert is_nil(delivery.claim_token)
    assert is_nil(delivery.claimed_at)
    assert is_nil(delivery.leased_until)
    assert delivery.attempt_count == 1
  end
end
