defmodule Atp.CrossAccountPolicyAPITest do
  use Atp.ConnCase, async: false

  alias Atp.Transport.{Delivery, WebhookDelivery, WebhookDispatcher}
  alias Ecto.Adapters.SQL.Sandbox

  test "unknown cross-account messages are untrusted and inbox-only", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      send(test_pid, :unexpected_webhook_request)
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    sender_account = create_account!(conn, %{"name" => "Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender = register_agent!(sender_token, "register-cross-sender", %{})

    recipient_account = create_account!(build_conn(), %{"name" => "Recipient Network"})
    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-cross-recipient", %{})

    configure_webhook!(recipient, "configure-cross-recipient-webhook")

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-unknown-cross-account",
        recipient["address"],
        a2a_user_text("unknown-cross-account", "hello across accounts")
      )

    assert sent["carrier_status"] == "queued"
    assert sent["message"]["from"] == sender["address"]
    assert sent["message"]["to"] == recipient["address"]
    assert sent["message"]["trust"] == "untrusted"
    assert sent["deliveries"] == []

    refute_receive :unexpected_webhook_request, 100

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-unknown-cross-account", %{
        "lease_seconds" => 60
      })

    assert delivery["message"] == sent["message"]
  end

  test "recipient can allow a sender agent for trusted webhook delivery", %{conn: conn} do
    test_pid = self()

    Req.Test.stub(WebhookDelivery, fn request_conn ->
      {:ok, body, read_conn} = Plug.Conn.read_body(request_conn)
      send(test_pid, {:webhook_request, Jason.decode!(body)})
      Plug.Conn.send_resp(read_conn, 204, "")
    end)

    sender_account = create_account!(conn, %{"name" => "Allowed Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender = register_agent!(sender_token, "register-allowed-sender", %{})

    recipient_account = create_account!(build_conn(), %{"name" => "Allowed Recipient Network"})
    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-allowed-recipient", %{})

    configure_webhook!(recipient, "configure-allowed-recipient-webhook")

    policy =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("allow-sender-agent")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "allow",
        "sender_agent_id" => sender["id"]
      })
      |> json_response(200)

    assert policy["sender_policy"]["effect"] == "allow"
    assert policy["sender_policy"]["sender_agent_id"] == sender["id"]
    assert is_nil(policy["sender_policy"]["sender_account_id"])

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-allowed-cross-account",
        recipient["address"],
        a2a_user_text("allowed-cross-account", "trusted across accounts")
      )

    assert sent["carrier_status"] == "queued"
    assert sent["message"]["trust"] == "trusted"
    assert [delivery] = sent["deliveries"]

    dispatch_webhooks!()

    assert_receive {:webhook_request, body}
    assert body["message"] == sent["message"]
    assert_delivered_delivery!(delivery["id"])
  end

  test "recipient can block a sender agent with carrier rejection and no delivery", %{conn: conn} do
    sender_account = create_account!(conn, %{"name" => "Blocked Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender = register_agent!(sender_token, "register-blocked-sender", %{})

    recipient_account = create_account!(build_conn(), %{"name" => "Blocked Recipient Network"})
    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-blocked-recipient", %{})

    policy =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("block-sender-agent")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "block",
        "sender_agent_id" => sender["id"]
      })
      |> json_response(200)

    assert policy["sender_policy"]["effect"] == "block"

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-blocked-cross-account",
        recipient["address"],
        a2a_user_text("blocked-cross-account", "blocked across accounts")
      )

    assert sent["carrier_status"] == "rejected"
    assert sent["message"]["trust"] == "untrusted"
    assert is_nil(sent["ack_status"])
    assert {:ok, _terminal_at, 0} = DateTime.from_iso8601(sent["terminal_at"])
    assert sent["deliveries"] == []

    empty_claim =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("claim-blocked-cross-account")
      |> post("/api/inbox/claims", %{"lease_seconds" => 60})
      |> json_response(200)

    assert empty_claim == %{"delivery" => nil}

    status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert status["carrier_status"] == "rejected"
    assert status["deliveries"] == []
  end

  test "policy precedence uses blocks before allows across agent and account targets", %{
    conn: conn
  } do
    sender_account = create_account!(conn, %{"name" => "Precedence Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender_a = register_agent!(sender_token, "register-precedence-sender-a", %{})
    sender_b = register_agent!(sender_token, "register-precedence-sender-b", %{})

    recipient_account = create_account!(build_conn(), %{"name" => "Precedence Recipient Network"})
    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-precedence-recipient", %{})

    account_allow =
      put_sender_policy!(recipient, "allow-precedence-sender-account", %{
        "effect" => "allow",
        "sender_account_id" => sender_account["id"]
      })

    assert account_allow["sender_policy"]["effect"] == "allow"
    assert account_allow["sender_policy"]["sender_account_id"] == sender_account["id"]

    account_allowed =
      send_message!(
        sender_b["agent_api_key"]["token"],
        "send-account-allowed-cross-account",
        recipient["address"],
        a2a_user_text("account-allowed-cross-account", "account allowed")
      )

    assert account_allowed["message"]["trust"] == "trusted"
    assert account_allowed["carrier_status"] == "queued"

    put_sender_policy!(recipient, "block-precedence-sender-agent", %{
      "effect" => "block",
      "sender_agent_id" => sender_a["id"]
    })

    agent_blocked_over_account_allow =
      send_message!(
        sender_a["agent_api_key"]["token"],
        "send-agent-blocked-over-account-allow",
        recipient["address"],
        a2a_user_text("agent-blocked-over-account-allow", "agent block wins")
      )

    assert agent_blocked_over_account_allow["carrier_status"] == "rejected"

    put_sender_policy!(recipient, "allow-precedence-sender-agent", %{
      "effect" => "allow",
      "sender_agent_id" => sender_a["id"]
    })

    put_sender_policy!(recipient, "block-precedence-sender-account", %{
      "effect" => "block",
      "sender_account_id" => sender_account["id"]
    })

    account_blocked_over_agent_allow =
      send_message!(
        sender_a["agent_api_key"]["token"],
        "send-account-blocked-over-agent-allow",
        recipient["address"],
        a2a_user_text("account-blocked-over-agent-allow", "account block wins")
      )

    assert account_blocked_over_agent_allow["carrier_status"] == "rejected"
  end

  test "same-account explicit sender blocks override default trust", %{conn: conn} do
    account = create_account!(conn, %{"name" => "Same Account Policy Network"})
    promote_to_basic!(account)

    account_token = account["account_api_key"]["token"]
    agent_blocked_sender = register_agent!(account_token, "register-same-agent-blocked", %{})
    account_blocked_sender = register_agent!(account_token, "register-same-account-blocked", %{})
    recipient = register_agent!(account_token, "register-same-block-recipient", %{})

    agent_block =
      put_sender_policy!(recipient, "block-same-account-sender-agent", %{
        "effect" => "block",
        "sender_agent_id" => agent_blocked_sender["id"]
      })

    assert agent_block["sender_policy"]["effect"] == "block"

    agent_blocked =
      send_message!(
        agent_blocked_sender["agent_api_key"]["token"],
        "send-same-account-agent-blocked",
        recipient["address"],
        a2a_user_text("same-account-agent-blocked", "agent block overrides same account")
      )

    assert agent_blocked["carrier_status"] == "rejected"
    assert agent_blocked["message"]["trust"] == "untrusted"
    assert agent_blocked["deliveries"] == []

    account_block =
      put_sender_policy!(recipient, "block-same-account-sender-account", %{
        "effect" => "block",
        "sender_account_id" => account["id"]
      })

    assert account_block["sender_policy"]["effect"] == "block"

    account_blocked =
      send_message!(
        account_blocked_sender["agent_api_key"]["token"],
        "send-same-account-account-blocked",
        recipient["address"],
        a2a_user_text("same-account-account-blocked", "account block overrides same account")
      )

    assert account_blocked["carrier_status"] == "rejected"
    assert account_blocked["message"]["trust"] == "untrusted"
    assert account_blocked["deliveries"] == []
  end

  test "unknown cross-account sends are rate limited per recipient agent and sender account", %{
    conn: conn
  } do
    sender_account = create_account!(conn, %{"name" => "Rate Limited Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender = register_agent!(sender_token, "register-rate-limited-sender", %{})

    recipient_account =
      create_account!(build_conn(), %{"name" => "Rate Limited Recipient Network"})

    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-rate-limited-recipient", %{})

    for index <- 1..20 do
      sent =
        send_message!(
          sender["agent_api_key"]["token"],
          "send-unknown-rate-limited-#{index}",
          recipient["address"],
          a2a_user_text("unknown-rate-limited-#{index}", "unknown #{index}")
        )

      assert sent["message"]["trust"] == "untrusted"
      assert sent["carrier_status"] == "queued"
    end

    rate_limited =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("send-unknown-rate-limited-21")
      |> post("/api/messages", %{
        "to" => recipient["address"],
        "payload" => a2a_user_text("unknown-rate-limited-21", "too many unknown sends")
      })
      |> json_response(429)

    assert error_code(rate_limited) == "unknown_sender_rate_limited"
  end

  test "concurrent unknown cross-account sends enforce the rate limit atomically", %{
    conn: conn
  } do
    sender_account = create_account!(conn, %{"name" => "Concurrent Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender = register_agent!(sender_token, "register-concurrent-rate-sender", %{})

    recipient_account =
      create_account!(build_conn(), %{"name" => "Concurrent Recipient Network"})

    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-concurrent-rate-recipient", %{})

    results =
      1..21
      |> Task.async_stream(
        fn index ->
          response_conn =
            build_conn()
            |> authorize(sender["agent_api_key"]["token"])
            |> idempotency_key("send-concurrent-unknown-rate-limited-#{index}")
            |> post("/api/messages", %{
              "to" => recipient["address"],
              "payload" =>
                a2a_user_text(
                  "concurrent-unknown-rate-limited-#{index}",
                  "unknown #{index}"
                )
            })

          {response_conn.status, json_response(response_conn, response_conn.status)}
        end,
        max_concurrency: 21,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {accepted, rejected} = Enum.split_with(results, &match?({201, _body}, &1))

    assert length(accepted) == 20
    assert [{429, rate_limited}] = rejected
    assert error_code(rate_limited) == "unknown_sender_rate_limited"
  end

  defp put_sender_policy!(recipient, key, attrs) do
    build_conn()
    |> authorize(recipient["agent_api_key"]["token"])
    |> idempotency_key(key)
    |> put("/api/agents/#{recipient["id"]}/sender_policies", attrs)
    |> json_response(200)
  end

  defp promote_to_basic!(account) do
    Atp.Identity.Account
    |> Atp.Repo.get!(account["id"])
    |> Ecto.Changeset.change(plan: "basic")
    |> Atp.Repo.update!()
  end

  defp dispatch_webhooks! do
    dispatcher =
      start_supervised!(%{
        id: {WebhookDispatcher, make_ref()},
        start:
          {WebhookDispatcher, :start_link,
           [[enabled: true, dispatch_on_start?: false, batch_size: 1, concurrency: 1, name: nil]]},
        restart: :temporary
      })

    Sandbox.allow(Atp.Repo, self(), dispatcher)
    Req.Test.allow(WebhookDelivery, self(), dispatcher)
    send(dispatcher, :dispatch_due)

    dispatcher
  end

  defp assert_delivered_delivery!(delivery_id) do
    assert eventually(fn ->
             delivery = Atp.Repo.get!(Delivery, delivery_id)
             delivery.status == "delivered"
           end)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
