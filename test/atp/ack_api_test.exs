defmodule Atp.AckAPITest do
  use Atp.ConnCase, async: true

  test "recipient ACKs a claimed delivery as accepted then completed", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    sent =
      send_message!(
        sender["agent_api_key"]["token"],
        "send-ack-message",
        recipient["address"],
        a2a_user_text("ack-message", "handle me")
      )

    delivery =
      claim_inbox!(recipient["agent_api_key"]["token"], "claim-ack-message", %{
        "lease_seconds" => 60
      })

    accepted =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "ack-accepted",
        %{"status" => "accepted", "payload" => a2a_agent_text("ack-started", "started")}
      )

    assert accepted["ack"]["id"] =~ "ack_"
    assert accepted["ack"]["delivery_id"] == delivery["id"]
    assert accepted["ack"]["message_id"] == sent["message"]["id"]
    assert accepted["ack"]["status"] == "accepted"
    assert accepted["ack"]["payload"] == a2a_agent_text("ack-started", "started")
    assert accepted["message_status"]["carrier_status"] == "delivered"
    assert accepted["message_status"]["ack_status"] == "accepted"
    assert is_nil(accepted["message_status"]["terminal_at"])

    completed =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "ack-completed",
        %{"status" => "completed", "payload" => a2a_agent_text("ack-done", "done")}
      )

    assert completed["ack"]["id"] =~ "ack_"
    assert completed["ack"]["id"] != accepted["ack"]["id"]
    assert completed["ack"]["status"] == "completed"
    assert completed["ack"]["payload"] == a2a_agent_text("ack-done", "done")
    assert completed["message_status"]["ack_status"] == "completed"

    assert {:ok, _terminal_at, 0} =
             DateTime.from_iso8601(completed["message_status"]["terminal_at"])

    status =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> get("/api/messages/#{sent["message"]["id"]}")
      |> json_response(200)

    assert status["ack_status"] == "completed"
    assert status["terminal_at"] == completed["message_status"]["terminal_at"]
  end

  test "ACK state machine rejects invalid and terminal transitions", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-transition-message",
        recipient["address"],
        a2a_user_text("transition-message", "transitions")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-transition-message", %{
          "lease_seconds" => 60
        })
      end)

    accepted =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "transition-accepted",
        %{"status" => "accepted"}
      )

    assert accepted["message_status"]["ack_status"] == "accepted"

    rejected_after_accept =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("transition-rejected")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "rejected"})
      |> json_response(409)

    assert error_code(rejected_after_accept) == "invalid_ack_transition"

    repeated_accept =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("transition-accepted-again")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "accepted"})
      |> json_response(409)

    assert error_code(repeated_accept) == "invalid_ack_transition"

    completed =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "transition-completed",
        %{"status" => "completed"}
      )

    assert completed["message_status"]["ack_status"] == "completed"

    failed_after_completed =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("transition-failed")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "failed"})
      |> json_response(409)

    assert error_code(failed_after_completed) == "terminal_ack_status"

    direct_completed_delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-direct-completed-message",
        recipient["address"],
        a2a_user_text("direct-completed-message", "complete me")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-direct-completed-message", %{
          "lease_seconds" => 60
        })
      end)

    direct_completed =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        direct_completed_delivery["id"],
        "transition-direct-completed",
        %{"status" => "completed"}
      )

    assert direct_completed["message_status"]["ack_status"] == "completed"

    assert {:ok, _terminal_at, 0} =
             DateTime.from_iso8601(direct_completed["message_status"]["terminal_at"])

    failed_delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-failed-message",
        recipient["address"],
        a2a_user_text("failed-message", "fail me")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-failed-message", %{
          "lease_seconds" => 60
        })
      end)

    accepted_before_failed =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        failed_delivery["id"],
        "transition-accepted-before-failed",
        %{"status" => "accepted"}
      )

    assert accepted_before_failed["message_status"]["ack_status"] == "accepted"

    failed =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        failed_delivery["id"],
        "transition-accepted-to-failed",
        %{"status" => "failed"}
      )

    assert failed["message_status"]["ack_status"] == "failed"

    assert {:ok, _terminal_at, 0} =
             DateTime.from_iso8601(failed["message_status"]["terminal_at"])

    rejected_delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-rejected-message",
        recipient["address"],
        a2a_user_text("rejected-message", "reject me")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-rejected-message", %{
          "lease_seconds" => 60
        })
      end)

    rejected =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        rejected_delivery["id"],
        "transition-direct-rejected",
        %{"status" => "rejected"}
      )

    assert rejected["message_status"]["ack_status"] == "rejected"

    assert {:ok, _terminal_at, 0} =
             DateTime.from_iso8601(rejected["message_status"]["terminal_at"])
  end

  test "ACK writes require idempotency and enforce status and payload policy", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-idempotent-ack-message",
        recipient["address"],
        a2a_user_text("idempotent-ack-message", "ack me")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-idempotent-ack-message", %{
          "lease_seconds" => 60
        })
      end)

    missing_key =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "completed"})
      |> json_response(400)

    assert error_code(missing_key) == "idempotency_key_required"

    missing_status =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("missing-ack-status")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{
        "payload" => a2a_agent_text("missing-ack-status", "missing")
      })
      |> json_response(422)

    assert error_code(missing_status) == "ack_status_required"

    invalid_status =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("invalid-ack-status")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "done"})
      |> json_response(422)

    assert error_code(invalid_status) == "invalid_ack_status"

    invalid_payload =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("invalid-ack-payload")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{
        "status" => "accepted",
        "payload" => %{"note" => "not an A2A Message"}
      })
      |> json_response(422)

    assert error_code(invalid_payload) == "invalid_a2a_message"

    first_ack =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "idempotent-ack",
        %{"status" => "failed", "payload" => a2a_agent_text("ack-tool-timeout", "tool timeout")}
      )

    replayed_ack =
      ack_delivery!(
        recipient["agent_api_key"]["token"],
        delivery["id"],
        "idempotent-ack",
        %{"status" => "failed", "payload" => a2a_agent_text("ack-tool-timeout", "tool timeout")}
      )

    assert replayed_ack == first_ack

    conflict =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("idempotent-ack")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{
        "status" => "failed",
        "payload" => a2a_agent_text("ack-different", "different")
      })
      |> json_response(409)

    assert error_code(conflict) == "idempotency_conflict"

    payload_delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-large-ack-message",
        recipient["address"],
        a2a_user_text("large-ack-message", "large ack")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-large-ack-message", %{
          "lease_seconds" => 60
        })
      end)

    too_large =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("ack-too-large")
      |> post("/api/deliveries/#{payload_delivery["id"]}/acks", %{
        "status" => "completed",
        "payload" => a2a_agent_text("ack-too-large", String.duplicate("x", 65_536))
      })
      |> json_response(413)

    assert error_code(too_large) == "payload_too_large"
  end

  test "only the owning recipient agent can ACK a claimed delivery", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-sender", %{"display_name" => "Sender"})

    recipient =
      register_agent!(account_token, "register-recipient", %{"display_name" => "Recipient"})

    delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-auth-ack-message",
        recipient["address"],
        a2a_user_text("auth-ack-message", "auth")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-auth-ack-message", %{
          "lease_seconds" => 60
        })
      end)

    account_key_ack =
      build_conn()
      |> authorize(account_token)
      |> idempotency_key("account-key-ack")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "accepted"})
      |> json_response(403)

    assert error_code(account_key_ack) == "agent_key_required"

    sender_ack =
      build_conn()
      |> authorize(sender["agent_api_key"]["token"])
      |> idempotency_key("sender-ack")
      |> post("/api/deliveries/#{delivery["id"]}/acks", %{"status" => "accepted"})
      |> json_response(404)

    assert error_code(sender_ack) == "not_found"

    expired_delivery =
      sender["agent_api_key"]["token"]
      |> send_message!(
        "send-expired-ack-message",
        recipient["address"],
        a2a_user_text("expired-ack-message", "expired")
      )
      |> then(fn _message ->
        claim_inbox!(recipient["agent_api_key"]["token"], "claim-expired-ack-message", %{
          "lease_seconds" => 0
        })
      end)

    expired_ack =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("expired-ack")
      |> post("/api/deliveries/#{expired_delivery["id"]}/acks", %{"status" => "accepted"})
      |> json_response(409)

    assert error_code(expired_ack) == "lease_expired"
  end
end
