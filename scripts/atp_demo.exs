Logger.configure(level: :error)
{:ok, _apps} = Application.ensure_all_started(:atp)

alias Atp.{Identity, Transport}

defmodule AtpDemo do
  @default_delay_ms 650
  @route_messages "POST /api/messages"
  @route_claims "POST /api/inbox/claims"
  @route_sessions "POST /api/sessions"

  def run do
    suffix = demo_suffix()

    title("ATP local carrier demo")
    blank()

    {account_response, account} = create_account!(suffix)
    account_token = account_response["account_api_key"]["token"]

    step(1, "Create account")
    field("account_id", account_response["id"])
    field("plan", account_response["plan"])
    field("account_key", redact(account_token))
    blank()

    {agent_a_response, agent_a} =
      register_agent!(account, account_token, "agent-a-#{suffix}", %{
        "display_name" => "Codex A",
        "description" => "Demo sender"
      })

    step(2, "Register Agent A")
    field("agent_id", agent_a_response["id"])
    field("address", agent_a_response["address"])
    field("agent_key", redact(agent_a_response["agent_api_key"]["token"]))
    blank()

    {agent_b_response, agent_b} =
      register_agent!(account, account_token, "agent-b-#{suffix}", %{
        "display_name" => "Codex B",
        "description" => "Demo recipient"
      })

    step(3, "Register Agent B")
    field("agent_id", agent_b_response["id"])
    field("address", agent_b_response["address"])
    field("agent_key", redact(agent_b_response["agent_api_key"]["token"]))
    blank()

    message_payload = a2a_user_text("demo-msg-#{suffix}", "Can you review this plan?")

    sent =
      send_message!(
        agent_a,
        "send-message-#{suffix}",
        agent_b_response["address"],
        message_payload
      )

    step(4, "Agent A sends Agent B a typed A2A message")
    field("message_id", sent["message"]["id"])
    field("delivery_status", sent["carrier_status"])
    field("content_type", sent["message"]["content_type"])
    field("text", a2a_text(sent["message"]["payload"]))
    payload_block("A2A Message payload", sent["message"]["payload"])
    blank()

    claimed =
      claim_inbox!(agent_b, "claim-message-#{suffix}", %{
        "lease_seconds" => 60
      })

    step(5, "Agent B claims inbox")
    field("delivery_id", claimed["id"])
    field("from", claimed["message"]["from"])
    field("leased_until", claimed["leased_until"])
    field("text", a2a_text(claimed["message"]["payload"]))
    blank()

    ack_response_text = "Received. I can review it."
    ack_payload = a2a_agent_text("demo-ack-#{suffix}", ack_response_text)

    acked =
      ack_delivery!(agent_b, claimed["id"], "ack-message-#{suffix}", %{
        "status" => "completed",
        "payload" => ack_payload
      })

    step(6, "Agent B ACKs completed")
    field("delivery_id", claimed["id"])
    field("ack_status", acked["message_status"]["ack_status"])
    field("response", ack_response_text)
    payload_block("A2A ACK payload", ack_payload)
    blank()

    opening_payload = a2a_user_text("demo-open-#{suffix}", "Open a working session.")

    opened =
      open_session!(
        agent_a,
        "open-session-#{suffix}",
        agent_b_response["address"],
        opening_payload
      )

    session_id = opened["session"]["id"]

    step(7, "Agent A opens a session with Agent B")
    field("session_id", session_id)
    field("opening_message_id", opened["message_status"]["message"]["id"])
    field("session_status", opened["session"]["status"])
    field("opening_sequence", opened["message_status"]["message"]["session_sequence"])
    payload_block("A2A opening payload", opened["message_status"]["message"]["payload"])
    blank()

    opening_claim =
      claim_inbox!(agent_b, "claim-opening-#{suffix}", %{
        "lease_seconds" => 60
      })

    accepted =
      ack_delivery!(agent_b, opening_claim["id"], "accept-opening-#{suffix}", %{
        "status" => "accepted"
      })

    {:ok, %{"session" => accepted_session}} = Transport.get_session(agent_a, session_id)

    step(8, "Agent B accepts the session")
    field("opening_delivery_id", opening_claim["id"])
    field("ack_status", accepted["message_status"]["ack_status"])
    field("session_status", accepted_session["status"])
    blank()

    first_turn_payload =
      a2a_user_text("demo-session-a-#{suffix}", "First point: define the failure mode.")

    first_turn =
      send_session_message!(
        agent_a,
        session_id,
        "session-a-turn-#{suffix}",
        first_turn_payload
      )

    step(9, "Agent A sends session message")
    field("message_id", first_turn["message_status"]["message"]["id"])
    field("session_sequence", first_turn["message_status"]["message"]["session_sequence"])
    field("session_last_sequence", first_turn["session"]["last_sequence"])
    field("text", a2a_text(first_turn["message_status"]["message"]["payload"]))
    blank()

    second_turn_payload =
      a2a_agent_text(
        "demo-session-b-#{suffix}",
        "Agreed. Add retry, timeout, and escalation rules."
      )

    second_turn =
      send_session_message!(
        agent_b,
        session_id,
        "session-b-turn-#{suffix}",
        second_turn_payload
      )

    step(10, "Agent B sends ordered session reply")
    field("message_id", second_turn["message_status"]["message"]["id"])
    field("session_sequence", second_turn["message_status"]["message"]["session_sequence"])
    field("session_last_sequence", second_turn["session"]["last_sequence"])
    field("text", a2a_text(second_turn["message_status"]["message"]["payload"]))

    payload_block(
      "A2A session reply payload",
      second_turn["message_status"]["message"]["payload"]
    )

    blank()
  end

  defp create_account!(suffix) do
    {:ok, response} = Identity.create_account(%{"name" => "ATP Demo #{suffix}"})

    {:ok, {:account, account}} =
      Identity.authenticate_bearer(response["account_api_key"]["token"])

    {response, account}
  end

  defp register_agent!(account, _account_token, key, attrs) do
    {:ok, 201, response} = Identity.register_agent(account, attrs, key, "POST /api/agents")
    {:ok, {:agent, agent}} = Identity.authenticate_bearer(response["agent_api_key"]["token"])
    {response, agent}
  end

  defp send_message!(sender, key, to, payload) do
    {:ok, 201, response} =
      Transport.send_message(sender, %{"to" => to, "payload" => payload}, key, @route_messages)

    response
  end

  defp claim_inbox!(recipient, key, params) do
    {:ok, 201, response} = Transport.claim_inbox(recipient, params, key, @route_claims)
    response
  end

  defp ack_delivery!(recipient, delivery_id, key, params) do
    route = "POST /api/deliveries/#{delivery_id}/acks"
    {:ok, 201, response} = Transport.ack_delivery(recipient, delivery_id, params, key, route)
    response
  end

  defp open_session!(initiator, key, to, payload) do
    {:ok, 201, response} =
      Transport.open_session(initiator, %{"to" => to, "payload" => payload}, key, @route_sessions)

    response
  end

  defp send_session_message!(sender, session_id, key, payload) do
    route = "POST /api/sessions/#{session_id}/messages"

    {:ok, 201, response} =
      Transport.send_session_message(sender, session_id, %{"payload" => payload}, key, route)

    response
  end

  defp a2a_user_text(message_id, text), do: a2a_text(message_id, "ROLE_USER", text)

  defp a2a_agent_text(message_id, text) do
    message_id
    |> a2a_text("ROLE_AGENT", text)
    |> Map.put("contextId", "ctx_#{message_id}")
  end

  defp a2a_text(message_id, role, text) do
    %{"messageId" => message_id, "role" => role, "parts" => [%{"text" => text}]}
  end

  defp a2a_text(%{"parts" => [%{"text" => text} | _]}), do: text
  defp a2a_text(_payload), do: "(no text part)"

  defp demo_suffix do
    :crypto.strong_rand_bytes(5)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^A-Za-z0-9_-]/, "")
  end

  defp redact(token) when is_binary(token) do
    visible = min(String.length(token), 10)
    String.slice(token, 0, visible) <> "..."
  end

  defp title(text), do: IO.puts([ansi(:bright), text, ansi(:reset)])
  defp blank, do: IO.puts("")

  defp step(number, text) do
    pause()

    IO.puts([ansi(:cyan), "[", Integer.to_string(number), "] ", text, ansi(:reset)])
  end

  defp field(label, value) do
    IO.puts([
      "  ",
      ansi(:faint),
      String.pad_trailing("#{label}:", 24),
      ansi(:reset),
      to_string(value)
    ])
  end

  defp payload_block(label, payload) when is_map(payload) do
    IO.puts(["  ", ansi(:faint), label, ":", ansi(:reset)])

    payload
    |> Jason.encode!(pretty: true)
    |> String.split("\n")
    |> Enum.each(&IO.puts(["    ", &1]))
  end

  defp ansi(code) do
    if System.get_env("ATP_DEMO_NO_COLOR") in ["1", "true"],
      do: "",
      else: apply(IO.ANSI, code, [])
  end

  defp pause do
    case delay_ms() do
      delay when delay > 0 -> Process.sleep(delay)
      _delay -> :ok
    end
  end

  defp delay_ms do
    "ATP_DEMO_DELAY_MS"
    |> System.get_env(Integer.to_string(@default_delay_ms))
    |> Integer.parse()
    |> case do
      {value, ""} -> max(value, 0)
      _invalid -> @default_delay_ms
    end
  end
end

AtpDemo.run()
