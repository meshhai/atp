defmodule Atp.MessageStatusTest do
  use ExUnit.Case, async: true

  alias Atp.Identity.Agent

  alias Atp.Transport.{
    Delivery,
    Message,
    MessageStatus,
    Response
  }

  test "message status read model requires preloaded deliveries" do
    message = message()
    viewer = %Agent{id: message.sender_agent_id, account_id: message.sender_account_id}

    assert_raise ArgumentError, "message status requires preloaded deliveries", fn ->
      MessageStatus.from_preloaded_message(message, viewer)
    end
  end

  test "message status read model requires preloaded webhook attempts" do
    message = %Message{message() | deliveries: [%Delivery{id: "dlv_unloaded_attempts"}]}
    viewer = %Agent{id: message.sender_agent_id, account_id: message.sender_account_id}

    assert_raise ArgumentError, "message status requires preloaded webhook attempts", fn ->
      MessageStatus.from_preloaded_message(message, viewer)
    end
  end

  test "response renders explicit message status read model" do
    now = DateTime.utc_now(:microsecond)

    delivery = %Delivery{
      id: "dlv_status",
      mode: "polling",
      status: "leased",
      claimed_at: now,
      leased_until: DateTime.add(now, 60, :second),
      attempt_count: 0,
      max_attempts: nil,
      next_attempt_at: nil,
      delivered_at: nil,
      last_error: nil,
      webhook_attempts: []
    }

    message = %Message{message(now) | deliveries: [delivery]}
    viewer = %Agent{id: message.sender_agent_id, account_id: message.sender_account_id}

    response =
      message
      |> MessageStatus.from_preloaded_message(viewer)
      |> Response.message_status()

    assert response["message"]["id"] == message.id
    assert response["carrier_status"] == "queued"

    assert [
             %{
               "id" => "dlv_status",
               "mode" => "polling",
               "status" => "leased",
               "attempts" => []
             }
           ] = response["deliveries"]
  end

  defp message(now \\ DateTime.utc_now(:microsecond)) do
    %Message{
      id: "msg_status",
      sender_account_id: "acc_sender",
      recipient_account_id: "acc_recipient",
      sender_agent_id: "agt_sender",
      recipient_agent_id: "agt_recipient",
      sender_address: "atp://agent/agt_sender",
      recipient_address: "atp://agent/agt_recipient",
      trust: "trusted",
      payload: %{
        "messageId" => "status-message",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "hi"}]
      },
      content_type: "application/a2a+json",
      carrier_status: "queued",
      current_ack_status: nil,
      terminal_at: nil,
      expires_at: DateTime.add(now, 3600, :second),
      inserted_at: now
    }
  end
end
