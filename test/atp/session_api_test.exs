defmodule Atp.SessionAPITest do
  use Atp.ConnCase, async: false

  alias Atp.Transport.{Runtime, WebhookDelivery}

  test "opening a session creates a pending two-party session and opening message", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-session-initiator", %{})
    recipient = register_agent!(account_token, "register-session-recipient", %{})

    opened =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("open-session")
      |> post("/api/sessions", %{
        "to" => recipient["address"],
        "payload" => a2a_user_text("open-session-message", "open a session"),
        "session_sequence" => 99
      })
      |> json_response(201)

    assert opened["session"]["id"] =~ "ses_"
    assert opened["session"]["status"] == "pending"
    assert opened["session"]["initiator_agent_id"] == initiator["id"]
    assert opened["session"]["recipient_agent_id"] == recipient["id"]
    assert opened["session"]["initiator"] == initiator["address"]
    assert opened["session"]["recipient"] == recipient["address"]
    assert opened["session"]["last_sequence"] == 1
    assert opened["session"]["opening_message_id"] == opened["message_status"]["message"]["id"]
    assert is_nil(opened["session"]["opened_at"])
    assert is_nil(opened["session"]["terminal_at"])

    assert opened["message_status"]["carrier_status"] == "queued"
    assert opened["message_status"]["message"]["session_id"] == opened["session"]["id"]
    assert opened["message_status"]["message"]["session_sequence"] == 1
    assert opened["message_status"]["message"]["from"] == initiator["address"]
    assert opened["message_status"]["message"]["to"] == recipient["address"]
    assert opened["message_status"]["message"]["payload"]["messageId"] == "open-session-message"

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-opening-session-message", %{
        "lease_seconds" => 60
      })

    assert delivery["message"] == opened["message_status"]["message"]
  end

  test "accepted opening ACK opens the session and participants send ordered messages", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-open-initiator", %{})
    recipient = register_agent!(account_token, "register-open-recipient", %{})

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-session-for-acceptance",
        recipient["address"],
        a2a_user_text("accepted-opening", "please open")
      )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-accepted-opening", %{
        "lease_seconds" => 60
      })

    accepted =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "accept-opening",
        %{"status" => "accepted"}
      )

    assert accepted["message_status"]["ack_status"] == "accepted"

    session_status =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> get("/api/sessions/#{opened["session"]["id"]}")
      |> json_response(200)

    assert session_status["session"]["status"] == "open"
    assert {:ok, _opened_at, 0} = DateTime.from_iso8601(session_status["session"]["opened_at"])
    assert is_nil(session_status["session"]["terminal_at"])

    failed_opening_ack =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("fail-already-opened-session")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "failed"})
      |> json_response(409)

    assert error_code(failed_opening_ack) == "invalid_ack_transition"

    still_open =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> get("/api/sessions/#{opened["session"]["id"]}")
      |> json_response(200)

    assert still_open["session"]["status"] == "open"

    recipient_reply =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("recipient-session-reply")
      |> post("/api/sessions/#{opened["session"]["id"]}/messages", %{
        "payload" => a2a_agent_text("recipient-reply", "session reply"),
        "session_sequence" => 99
      })
      |> json_response(201)

    assert recipient_reply["session"]["last_sequence"] == 2
    assert recipient_reply["message_status"]["message"]["session_id"] == opened["session"]["id"]
    assert recipient_reply["message_status"]["message"]["session_sequence"] == 2
    assert recipient_reply["message_status"]["message"]["from"] == recipient["address"]
    assert recipient_reply["message_status"]["message"]["to"] == initiator["address"]

    initiator_reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("initiator-session-reply")
      |> post("/api/sessions/#{opened["session"]["id"]}/messages", %{
        "payload" => a2a_user_text("initiator-reply", "next turn")
      })
      |> json_response(201)

    assert initiator_reply["session"]["last_sequence"] == 3
    assert initiator_reply["message_status"]["message"]["session_sequence"] == 3
    assert initiator_reply["message_status"]["message"]["from"] == initiator["address"]
    assert initiator_reply["message_status"]["message"]["to"] == recipient["address"]
  end

  test "recipient can accept or reject a pending session by session ID without a delivery ID", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-session-action-initiator", %{})
    recipient = register_agent!(account_token, "register-session-action-recipient", %{})

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-session-action-accept",
        recipient["address"],
        a2a_user_text("session-action-accept", "please accept")
      )

    accepted =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("accept-session-by-id")
      |> post("/api/sessions/#{opened["session"]["id"]}/accept", %{})
      |> json_response(201)

    assert accepted["session"]["id"] == opened["session"]["id"]
    assert accepted["session"]["status"] == "open"
    assert accepted["ack"]["status"] == "accepted"
    assert accepted["ack"]["message_id"] == opened["message_status"]["message"]["id"]
    assert accepted["ack"]["delivery_id"] =~ "dlv_"
    assert accepted["message_status"]["carrier_status"] == "delivered"
    assert accepted["message_status"]["ack_status"] == "accepted"

    assert [%{"id" => delivery_id, "status" => "delivered", "delivered_at" => delivered_at}] =
             accepted["message_status"]["deliveries"]

    assert delivery_id == accepted["ack"]["delivery_id"]
    assert {:ok, _delivered_at, 0} = DateTime.from_iso8601(delivered_at)

    replayed_accept =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("accept-session-by-id")
      |> post("/api/sessions/#{opened["session"]["id"]}/accept", %{})
      |> json_response(201)

    assert replayed_accept == accepted

    accepted_send =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("send-after-session-id-accept")
      |> post("/api/sessions/#{opened["session"]["id"]}/messages", %{
        "payload" => a2a_agent_text("session-action-reply", "accepted by ID")
      })
      |> json_response(201)

    assert accepted_send["session"]["last_sequence"] == 2
    assert accepted_send["message_status"]["message"]["session_sequence"] == 2

    rejected_open =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-session-action-reject",
        recipient["address"],
        a2a_user_text("session-action-reject", "please reject")
      )

    rejected =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("reject-session-by-id")
      |> post("/api/sessions/#{rejected_open["session"]["id"]}/reject", %{
        "payload" => a2a_agent_text("session-action-reject-reason", "not this time")
      })
      |> json_response(201)

    assert rejected["session"]["id"] == rejected_open["session"]["id"]
    assert rejected["session"]["status"] == "rejected"
    assert rejected["ack"]["status"] == "rejected"
    assert rejected["ack"]["payload"]["parts"] == [%{"text" => "not this time"}]
    assert rejected["message_status"]["carrier_status"] == "delivered"
    assert rejected["message_status"]["ack_status"] == "rejected"

    assert [%{"status" => "delivered", "delivered_at" => rejected_delivered_at}] =
             rejected["message_status"]["deliveries"]

    assert {:ok, _rejected_delivered_at, 0} = DateTime.from_iso8601(rejected_delivered_at)

    initiator_accept =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("initiator-cannot-accept-by-id")
      |> post("/api/sessions/#{rejected_open["session"]["id"]}/accept", %{})
      |> json_response(404)

    assert error_code(initiator_accept) == "not_found"
  end

  test "session send responses redact recipient webhook request URLs from senders", %{
    conn: conn
  } do
    Req.Test.stub(WebhookDelivery, fn request_conn ->
      Plug.Conn.send_resp(request_conn, 204, "")
    end)

    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-redacted-session-initiator", %{})
    recipient = register_agent!(account_token, "register-redacted-session-recipient", %{})

    opened =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-redacted-session",
        recipient["address"],
        a2a_user_text("redacted-session-opening", "please open")
      )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-redacted-session-opening", %{
        "lease_seconds" => 60
      })

    ack_delivery!(
      recipient["agent_api_key"]["token"],
      delivery["id"],
      "accept-redacted-session-opening",
      %{"status" => "accepted"}
    )

    configure_webhook!(
      recipient,
      "configure-redacted-session-webhook",
      "https://recipient.example.test/atp/session-webhook?token=session-hidden"
    )

    {:ok, session_pid} = Runtime.ensure_session_started(opened["session"]["id"])
    Req.Test.allow(WebhookDelivery, self(), session_pid)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Runtime.SessionSupervisor, session_pid)
    end)

    reply =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("send-redacted-session-message")
      |> post("/api/sessions/#{opened["session"]["id"]}/messages", %{
        "payload" => a2a_user_text("redacted-session-message", "do not leak webhook URL")
      })
      |> json_response(201)

    assert [delivery_status] = reply["message_status"]["deliveries"]
    assert [attempt] = delivery_status["attempts"]
    refute Map.has_key?(attempt, "request_url")
  end

  test "pending sessions reject messages and opening rejection or failure terminates them", %{
    conn: conn
  } do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-terminal-initiator", %{})
    recipient = register_agent!(account_token, "register-terminal-recipient", %{})

    pending =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-pending-session",
        recipient["address"],
        a2a_user_text("pending-opening", "pending")
      )

    pending_send =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("send-before-open")
      |> post("/api/sessions/#{pending["session"]["id"]}/messages", %{
        "payload" => a2a_user_text("before-open", "not yet")
      })
      |> json_response(409)

    assert error_code(pending_send) == "session_not_open"

    rejected_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-rejected-opening", %{
        "lease_seconds" => 60
      })

    rejected_ack =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        rejected_delivery["id"],
        "reject-opening",
        %{"status" => "rejected"}
      )

    assert rejected_ack["message_status"]["ack_status"] == "rejected"

    rejected_session =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> get("/api/sessions/#{pending["session"]["id"]}")
      |> json_response(200)

    assert rejected_session["session"]["status"] == "rejected"

    assert {:ok, _terminal_at, 0} =
             DateTime.from_iso8601(rejected_session["session"]["terminal_at"])

    failed =
      open_session!(
        initiator["agent_api_key"]["token"],
        "open-failed-session",
        recipient["address"],
        a2a_user_text("failed-opening", "fail")
      )

    failed_delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-failed-opening", %{
        "lease_seconds" => 60
      })

    failed_ack =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        failed_delivery["id"],
        "fail-opening",
        %{"status" => "failed"}
      )

    assert failed_ack["message_status"]["ack_status"] == "failed"

    failed_session =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> get("/api/sessions/#{failed["session"]["id"]}")
      |> json_response(200)

    assert failed_session["session"]["status"] == "failed"

    assert {:ok, _terminal_at, 0} =
             DateTime.from_iso8601(failed_session["session"]["terminal_at"])
  end

  test "session APIs require idempotency and two distinct authorized participants", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    initiator = register_agent!(account_token, "register-auth-initiator", %{})
    recipient = register_agent!(account_token, "register-auth-recipient", %{})

    missing_key =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> post("/api/sessions", %{
        "to" => recipient["address"],
        "payload" => a2a_user_text("missing-key-opening", "missing key")
      })
      |> json_response(400)

    assert error_code(missing_key) == "idempotency_key_required"

    self_session =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("open-self-session")
      |> post("/api/sessions", %{
        "to" => initiator["address"],
        "payload" => a2a_user_text("self-opening", "self")
      })
      |> json_response(422)

    assert error_code(self_session) == "invalid_session_recipient"

    params = %{
      "to" => recipient["address"],
      "payload" => a2a_user_text("idempotent-opening", "idempotent")
    }

    first_open =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("open-idempotent-session")
      |> post("/api/sessions", params)
      |> json_response(201)

    replayed_open =
      build_conn()
      |> authorize(initiator["agent_api_key"]["token"])
      |> idempotency_key("open-idempotent-session")
      |> post("/api/sessions", params)
      |> json_response(201)

    assert replayed_open == first_open

    unrelated_account = create_account!(build_conn(), %{"name" => "Unrelated Session Network"})
    unrelated_token = unrelated_account["account_api_key"]["token"]
    unrelated_agent = register_agent!(unrelated_token, "register-unrelated-session-agent", %{})

    unrelated_read =
      build_conn()
      |> authorize(unrelated_agent["agent_api_key"]["token"])
      |> get("/api/sessions/#{first_open["session"]["id"]}")
      |> json_response(404)

    assert error_code(unrelated_read) == "not_found"

    unrelated_write =
      build_conn()
      |> authorize(unrelated_agent["agent_api_key"]["token"])
      |> idempotency_key("unrelated-session-message")
      |> post("/api/sessions/#{first_open["session"]["id"]}/messages", %{
        "payload" => a2a_user_text("unrelated-session-message", "nope")
      })
      |> json_response(404)

    assert error_code(unrelated_write) == "not_found"
  end
end
