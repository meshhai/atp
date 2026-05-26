defmodule Atp.Transport.MessageEnvelope do
  @moduledoc "Public ATP message envelope shared by API responses and webhook payloads."

  alias Atp.Transport.A2A.Message, as: A2AMessage
  alias Atp.Transport.Message

  @spec to_map(Message.t()) :: map()
  def to_map(%Message{} = message) do
    message
    |> base_map()
    |> put_optional("session_id", message.session_id)
    |> put_optional("session_sequence", message.session_sequence)
  end

  defp base_map(%Message{} = message) do
    %{
      "id" => message.id,
      "from" => message.sender_address,
      "to" => message.recipient_address,
      "trust" => message.trust,
      "payload" => message.payload,
      "content_type" => message.content_type,
      "a2a_version" => A2AMessage.version(),
      "created_at" => DateTime.to_iso8601(message.inserted_at),
      "expires_at" => DateTime.to_iso8601(message.expires_at)
    }
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
