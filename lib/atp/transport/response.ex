defmodule Atp.Transport.Response do
  @moduledoc false

  alias Atp.Identity.Agent

  alias Atp.Transport.{
    Ack,
    Delivery,
    Message,
    MessageEnvelope,
    Session,
    WebhookAttempt
  }

  @type response_map :: %{String.t() => term()}

  @spec session_message(Session.t(), Message.t(), Agent.t()) :: response_map()
  def session_message(%Session{} = session, %Message{} = message, %Agent{} = viewer) do
    %{
      "session" => session(session),
      "message_status" => message_status(message, viewer)
    }
  end

  @spec session_transcript(Session.t(), [Message.t()], Agent.t()) :: response_map()
  def session_transcript(%Session{} = session, messages, %Agent{} = viewer)
      when is_list(messages) do
    %{
      "session" => session(session),
      "messages" => Enum.map(messages, &message_status(&1, viewer))
    }
  end

  @spec session(Session.t()) :: response_map()
  def session(%Session{} = session) do
    %{
      "id" => session.id,
      "status" => session.status,
      "initiator_agent_id" => session.initiator_agent_id,
      "recipient_agent_id" => session.recipient_agent_id,
      "initiator" => session.initiator_address,
      "recipient" => session.recipient_address,
      "opening_message_id" => session.opening_message_id,
      "last_sequence" => session.last_sequence,
      "opened_at" => timestamp(session.opened_at),
      "terminal_at" => timestamp(session.terminal_at),
      "created_at" => timestamp(session.inserted_at)
    }
  end

  @spec message_status(Message.t(), Agent.t()) :: response_map()
  def message_status(%Message{} = message, %Agent{} = viewer) do
    %{
      "message" => MessageEnvelope.to_map(message),
      "carrier_status" => message.carrier_status,
      "ack_status" => message.current_ack_status,
      "terminal_at" => timestamp(message.terminal_at),
      "deliveries" => delivery_statuses(message, expose_request_url?(message, viewer))
    }
  end

  @spec delivery_claim(Delivery.t(), Message.t()) :: response_map()
  def delivery_claim(%Delivery{} = delivery, %Message{} = message) do
    %{
      "id" => delivery.id,
      "leased_until" => timestamp(delivery.leased_until),
      "message" => MessageEnvelope.to_map(message)
    }
  end

  @spec ack(Agent.t(), Ack.t(), Message.t()) :: response_map()
  def ack(%Agent{} = viewer, %Ack{} = ack, %Message{} = message) do
    %{
      "ack" => %{
        "id" => ack.id,
        "message_id" => ack.message_id,
        "delivery_id" => ack.delivery_id,
        "status" => ack.status,
        "payload" => ack.payload,
        "created_at" => timestamp(ack.inserted_at)
      },
      "message_status" => message_status(message, viewer)
    }
  end

  defp expose_request_url?(%Message{} = message, %Agent{} = viewer) do
    message.recipient_agent_id == viewer.id
  end

  defp delivery_statuses(%Message{deliveries: deliveries}, expose_request_url?)
       when is_list(deliveries) do
    deliveries
    |> Enum.sort_by(&delivery_sort_key/1)
    |> Enum.map(&delivery_status(&1, expose_request_url?))
  end

  defp delivery_statuses(%Message{}, _expose_request_url?), do: []

  defp delivery_status(%Delivery{} = delivery, expose_request_url?) do
    %{
      "id" => delivery.id,
      "mode" => delivery.mode,
      "status" => delivery.status,
      "claimed_at" => timestamp(delivery.claimed_at),
      "leased_until" => timestamp(delivery.leased_until),
      "attempt_count" => delivery.attempt_count,
      "max_attempts" => delivery.max_attempts,
      "next_attempt_at" => timestamp(delivery.next_attempt_at),
      "delivered_at" => timestamp(delivery.delivered_at),
      "last_error" => delivery.last_error,
      "attempts" => webhook_attempts(delivery.webhook_attempts, expose_request_url?)
    }
  end

  defp delivery_sort_key(%Delivery{inserted_at: %DateTime{} = inserted_at, id: id}) do
    {DateTime.to_unix(inserted_at, :microsecond), id}
  end

  defp delivery_sort_key(%Delivery{id: id}), do: {0, id}

  defp webhook_attempts(attempts, expose_request_url?) when is_list(attempts) do
    attempts
    |> Enum.sort_by(& &1.attempt_number)
    |> Enum.map(&webhook_attempt(&1, expose_request_url?))
  end

  defp webhook_attempt(%WebhookAttempt{} = attempt, expose_request_url?) do
    response = %{
      "id" => attempt.id,
      "attempt_number" => attempt.attempt_number,
      "response_status" => attempt.response_status,
      "error" => attempt.error,
      "result" => attempt.result,
      "next_attempt_at" => timestamp(attempt.next_attempt_at),
      "created_at" => timestamp(attempt.inserted_at)
    }

    if expose_request_url? do
      Map.put(response, "request_url", attempt.request_url)
    else
      response
    end
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
