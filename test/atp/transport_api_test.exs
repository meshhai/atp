defmodule Atp.TransportAPITest do
  use Atp.ConnCase, async: true

  alias Atp.Identity.Agent
  alias Atp.{Repo, Transport}

  test "an agent sends a same-account A2A message that the recipient claims by lease", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    sent =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("send-message")
      |> post("/api/messages", %{
        "to" => recipient["address"],
        "payload" =>
          a2a_message(
            "client-hello",
            "ROLE_USER",
            [
              %{"text" => "hello"},
              %{"data" => %{"external_ref" => %{"url" => "https://example.test/artifact.json"}}}
            ],
            %{"metadata" => %{"purpose" => "smoke"}}
          )
      })
      |> json_response(201)

    assert sent["carrier_status"] == "queued"
    assert is_nil(sent["ack_status"])
    assert sent["message"]["id"] =~ "msg_"
    assert sent["message"]["from"] == sender["address"]
    assert sent["message"]["to"] == recipient["address"]
    assert sent["message"]["trust"] == "trusted"
    assert sent["message"]["content_type"] == "application/a2a+json"
    assert sent["message"]["a2a_version"] == "1.0"
    assert sent["message"]["payload"]["messageId"] == "client-hello"
    assert sent["message"]["payload"]["role"] == "ROLE_USER"

    assert sent["message"]["payload"]["parts"] == [
             %{"text" => "hello"},
             %{"data" => %{"external_ref" => %{"url" => "https://example.test/artifact.json"}}}
           ]

    assert {:ok, _created_at, 0} = DateTime.from_iso8601(sent["message"]["created_at"])
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(sent["message"]["expires_at"])
    refute Map.has_key?(sent["message"], "kind")
    refute Map.has_key?(sent["message"], "capability")
    refute Map.has_key?(sent["message"], "task")
    refute Map.has_key?(sent["message"], "job")
    refute Map.has_key?(sent["message"], "work")

    delivery =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("claim-message")
      |> post("/api/inbox/claims", %{"lease_seconds" => 60})
      |> json_response(201)

    assert delivery["id"] =~ "dlv_"
    assert {:ok, _leased_until, 0} = DateTime.from_iso8601(delivery["leased_until"])
    assert delivery["message"] == sent["message"]

    status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert status["message"] == sent["message"]
    assert status["carrier_status"] == "delivered"
    assert is_nil(status["ack_status"])

    recipient_status =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert recipient_status["message"] == sent["message"]
  end

  test "account keys read statuses for messages involving owned agents and hide unrelated messages",
       %{conn: conn} do
    sender_account = create_account!(conn, %{"name" => "Status Sender Network"})
    sender_token = sender_account["account_api_key"]["token"]
    sender = register_agent!(sender_token, "register-status-sender", %{})

    recipient_account = create_account!(build_conn(), %{"name" => "Status Recipient Network"})
    recipient_token = recipient_account["account_api_key"]["token"]
    recipient = register_agent!(recipient_token, "register-status-recipient", %{})

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-account-visible-message",
        recipient["address"],
        a2a_user_text("account-visible-message", "visible to account owners")
      )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-account-visible-message", %{
        "lease_seconds" => 60
      })

    message_id = sent["message"]["id"]

    sender_account_status =
      build_conn()
      |> authorize(sender_token)
      |> get("/api/messages/#{message_id}")
      |> json_response(200)

    assert sender_account_status["message"] == sent["message"]
    assert sender_account_status["carrier_status"] == "delivered"
    assert is_nil(sender_account_status["ack_status"])

    assert [%{"id" => delivery_id, "mode" => "polling", "status" => "leased"}] =
             sender_account_status["deliveries"]

    assert delivery_id == delivery["id"]

    recipient_account_status =
      build_conn()
      |> authorize(recipient_token)
      |> get("/api/messages/#{message_id}")
      |> json_response(200)

    assert recipient_account_status == sender_account_status

    sender_agent_status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{message_id}")
      |> json_response(200)

    assert sender_agent_status == sender_account_status

    unrelated_account = create_account!(build_conn(), %{"name" => "Unrelated Status Network"})
    unrelated_token = unrelated_account["account_api_key"]["token"]

    unrelated_status =
      build_conn()
      |> authorize(unrelated_token)
      |> get("/api/messages/#{message_id}")
      |> json_response(404)

    assert error_code(unrelated_status) == "not_found"
  end

  test "active leases hide messages and expired leases allow another claim", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    leased_message =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-hidden-message",
        recipient["address"],
        a2a_user_text("hidden-message", "leased")
      )

    first_claim =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-hidden-message", %{
        "lease_seconds" => 60
      })

    assert first_claim["message"]["id"] == leased_message["message"]["id"]

    empty_claim =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("claim-hidden-message-again")
      |> post("/api/inbox/claims", %{"lease_seconds" => 60})
      |> json_response(200)

    assert empty_claim == %{"delivery" => nil}

    expiring_message =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-expiring-message",
        recipient["address"],
        a2a_user_text("expiring-message", "expires immediately")
      )

    expiring_claim =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-expiring-message", %{
        "lease_seconds" => 0
      })

    assert expiring_claim["message"]["id"] == expiring_message["message"]["id"]

    reclaimed =
      claim_inbox!(recipient["agent_api_key"]["token"], "reclaim-expired-message", %{
        "lease_seconds" => 60
      })

    assert reclaimed["id"] != expiring_claim["id"]
    assert reclaimed["message"]["id"] == expiring_message["message"]["id"]
  end

  test "only the owning recipient agent can extend a delivery lease", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    send_message!(
      sender["agent_api_key"]["token"],
      "send-extension-message",
      recipient["address"],
      a2a_user_text("extension-message", "extend me")
    )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-extension-message", %{
        "lease_seconds" => 60
      })

    extended =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("extend-delivery")
      |> post("/api/deliveries/#{delivery["id"]}/extend", %{"lease_seconds" => 120})
      |> json_response(200)

    assert extended["id"] == delivery["id"]
    assert extended["message"] == delivery["message"]
    assert {:ok, original_lease, 0} = DateTime.from_iso8601(delivery["leased_until"])
    assert {:ok, extended_lease, 0} = DateTime.from_iso8601(extended["leased_until"])
    assert DateTime.compare(extended_lease, original_lease) == :gt

    other_agent_result =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("extend-delivery-as-other")
      |> post("/api/deliveries/#{delivery["id"]}/extend", %{"lease_seconds" => 120})
      |> json_response(404)

    assert error_code(other_agent_result) == "not_found"

    expired_delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-expired-extension-message",
        recipient["address"],
        a2a_user_text("expired-extension-message", "expired")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-expired-extension-message", %{
          "lease_seconds" => 0
        })
      end)

    expired_extend =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("extend-expired-delivery")
      |> post("/api/deliveries/#{expired_delivery["id"]}/extend", %{"lease_seconds" => 120})
      |> json_response(409)

    assert error_code(expired_extend) == "lease_expired"
  end

  test "send, claim, and extend writes require idempotency and replay stable responses", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    sender_token = sender["agent_api_key"]["token"]
    recipient_token = recipient["agent_api_key"]["token"]

    send_params = %{
      "to" => recipient["address"],
      "payload" => a2a_user_text("idempotent-message", "idempotent")
    }

    missing_send_key =
      build_conn()
      |> authorize(sender_token)
      |> post("/api/messages", send_params)
      |> json_response(400)

    assert error_code(missing_send_key) == "idempotency_key_required"

    first_send =
      build_conn()
      |> authorize(sender_token)
      |> idempotency_key("send-idempotent-message")
      |> post("/api/messages", send_params)
      |> json_response(201)

    send_replay =
      build_conn()
      |> authorize(sender_token)
      |> idempotency_key("send-idempotent-message")
      |> post("/api/messages", send_params)
      |> json_response(201)

    assert send_replay == first_send

    send_conflict =
      build_conn()
      |> authorize(sender_token)
      |> idempotency_key("send-idempotent-message")
      |> post("/api/messages", %{
        send_params
        | "payload" => a2a_user_text("changed-idempotent-message", "changed")
      })
      |> json_response(409)

    assert error_code(send_conflict) == "idempotency_conflict"

    missing_claim_key =
      build_conn()
      |> authorize(recipient_token)
      |> post("/api/inbox/claims", %{"lease_seconds" => 60})
      |> json_response(400)

    assert error_code(missing_claim_key) == "idempotency_key_required"

    invalid_claim_lease =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("claim-invalid-lease")
      |> post("/api/inbox/claims", %{"lease_seconds" => "sixty"})
      |> json_response(422)

    assert error_code(invalid_claim_lease) == "invalid_lease"

    first_claim =
      claim_inbox!(recipient_token, "claim-idempotent-message", %{"lease_seconds" => 60})

    claim_replay =
      claim_inbox!(recipient_token, "claim-idempotent-message", %{"lease_seconds" => 60})

    assert claim_replay == first_claim

    missing_extend_key =
      build_conn()
      |> authorize(recipient_token)
      |> post("/api/deliveries/#{first_claim["id"]}/extend", %{"lease_seconds" => 60})
      |> json_response(400)

    assert error_code(missing_extend_key) == "idempotency_key_required"

    invalid_extend_lease =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("extend-invalid-lease")
      |> post("/api/deliveries/#{first_claim["id"]}/extend", %{"lease_seconds" => -1})
      |> json_response(422)

    assert error_code(invalid_extend_lease) == "invalid_lease"

    first_extend =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("extend-idempotent-delivery")
      |> post("/api/deliveries/#{first_claim["id"]}/extend", %{"lease_seconds" => 60})
      |> json_response(200)

    extend_replay =
      build_conn()
      |> authorize(recipient_token)
      |> idempotency_key("extend-idempotent-delivery")
      |> post("/api/deliveries/#{first_claim["id"]}/extend", %{"lease_seconds" => 60})
      |> json_response(200)

    assert extend_replay == first_extend
  end

  test "idempotency keys are scoped to the authenticated agent principal", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    alpha = register_agent!(account_token, "register-alpha", %{"display_name" => "Alpha"})
    beta = register_agent!(account_token, "register-beta", %{"display_name" => "Beta"})

    params = %{
      "to" => beta["address"],
      "payload" => a2a_user_text("same-body-message", "same body")
    }

    alpha_send =
      build_conn()
      |> authorize(alpha["agent_api_key"]["token"])
      |> idempotency_key("same-agent-key")
      |> post("/api/messages", params)
      |> json_response(201)

    beta_send =
      build_conn()
      |> authorize(beta["agent_api_key"]["token"])
      |> idempotency_key("same-agent-key")
      |> post("/api/messages", params)
      |> json_response(201)

    assert alpha_send["message"]["from"] == alpha["address"]
    assert beta_send["message"]["from"] == beta["address"]
    refute beta_send["message"]["id"] == alpha_send["message"]["id"]
  end

  test "message send is agent-scoped and enforces A2A payload policy", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    account_key_send =
      build_conn()
      |> authorize(account_token)
      |> idempotency_key("account-key-send")
      |> post("/api/messages", %{
        "to" => recipient["address"],
        "payload" => a2a_user_text("account-key-message", "nope")
      })
      |> json_response(403)

    assert error_code(account_key_send) == "agent_key_required"

    missing_recipient_field =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("missing-recipient-field")
      |> post("/api/messages", %{"payload" => a2a_user_text("missing-recipient", "missing")})
      |> json_response(422)

    assert error_code(missing_recipient_field) == "recipient_required"

    blank_recipient =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("blank-recipient")
      |> post("/api/messages", %{
        "to" => "   ",
        "payload" => a2a_user_text("blank-recipient", "missing recipient")
      })
      |> json_response(422)

    assert error_code(blank_recipient) == "recipient_required"

    missing_recipient =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("missing-recipient")
      |> post("/api/messages", %{
        "to" => "atp://agent/agt_missing",
        "payload" => a2a_user_text("missing-recipient-agent", "missing recipient")
      })
      |> json_response(422)

    assert error_code(missing_recipient) == "recipient_not_found"

    missing_payload =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("missing-payload")
      |> post("/api/messages", %{"to" => recipient["address"]})
      |> json_response(422)

    assert error_code(missing_payload) == "payload_required"

    sender_agent = Repo.get!(Agent, sender["id"])

    assert {:error, :payload_must_be_json} =
             Transport.send_message(
               sender_agent,
               %{"to" => recipient["address"], "payload" => {:not, "json"}},
               "non-json-payload",
               "POST /api/messages"
             )

    invalid_shape =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("invalid-a2a-message")
      |> post("/api/messages", %{
        "to" => recipient["address"],
        "payload" => %{"text" => "not an A2A Message"}
      })
      |> json_response(422)

    assert error_code(invalid_shape) == "invalid_a2a_message"

    too_large_payload =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("too-large-payload")
      |> post("/api/messages", %{
        "to" => recipient["address"],
        "payload" => a2a_user_text("too-large-message", String.duplicate("x", 65_536))
      })
      |> json_response(413)

    assert error_code(too_large_payload) == "payload_too_large"

    valid_a2a =
      send_message!(
        sender["agent_api_key"]["token"],
        "valid-a2a-payload",
        recipient["address"],
        a2a_message(
          "valid-a2a-message",
          "ROLE_USER",
          [
            %{"text" => "review this"},
            %{"data" => [1, true, nil, %{"external_ref" => "s3://bucket/key"}]},
            %{
              "url" => "https://example.test/artifact.json",
              "filename" => "artifact.json",
              "mediaType" => "application/json"
            },
            %{"raw" => "aGVsbG8=", "filename" => "hello.txt", "mediaType" => "text/plain"}
          ],
          %{
            "contextId" => "ctx_valid",
            "taskId" => "task_valid",
            "referenceTaskIds" => ["task_prior"],
            "extensions" => ["https://example.test/a2a/extensions/review"],
            "metadata" => %{"trace_id" => "trace_valid"}
          }
        )
      )

    assert valid_a2a["message"]["payload"]["messageId"] == "valid-a2a-message"

    assert valid_a2a["message"]["payload"]["parts"] |> Enum.at(1) == %{
             "data" => [1, true, nil, %{"external_ref" => "s3://bucket/key"}]
           }

    for {payload, index} <- Enum.with_index([[1], "string", 42, false, nil]) do
      invalid_json_shape =
        build_conn()
        |> authorize(sender["agent_api_key"]["token"])
        |> idempotency_key("invalid-json-shape-#{index}")
        |> post("/api/messages", %{"to" => recipient["address"], "payload" => payload})
        |> json_response(422)

      assert error_code(invalid_json_shape) == "invalid_a2a_message"
    end

    unrelated_account = create_account!(build_conn(), %{"name" => "Unrelated Network"})
    unrelated_token = unrelated_account["account_api_key"]["token"]
    unrelated_agent = register_agent!(unrelated_token, "register-unrelated-agent", %{})

    unrelated_status =
      build_conn()
      |> authorize(unrelated_agent["agent_api_key"]["token"])
      |> get("/api/messages/#{valid_a2a["message"]["id"]}")
      |> json_response(404)

    assert error_code(unrelated_status) == "not_found"
  end
end
