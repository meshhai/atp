defmodule Atp.Transport.Payload do
  @moduledoc "ATP A2A payload validation and wire metadata."

  alias Atp.Transport.A2A.Message, as: A2AMessage

  @max_bytes 64 * 1024

  @spec content_type() :: String.t()
  def content_type, do: A2AMessage.content_type()

  @spec validate_a2a(term()) ::
          :ok | {:error, :payload_too_large | :payload_must_be_json | :invalid_a2a_message}
  def validate_a2a(payload) do
    with :ok <- validate_json_payload(payload),
         {:ok, _message} <- A2AMessage.validate(payload) do
      :ok
    end
  end

  @spec validate_optional_a2a(term() | nil) ::
          :ok | {:error, :payload_too_large | :payload_must_be_json | :invalid_a2a_message}
  def validate_optional_a2a(nil), do: :ok
  def validate_optional_a2a(payload), do: validate_a2a(payload)

  defp validate_json_payload(payload) do
    case Jason.encode(payload) do
      {:ok, json} when byte_size(json) <= @max_bytes -> :ok
      {:ok, _json} -> {:error, :payload_too_large}
      {:error, _reason} -> {:error, :payload_must_be_json}
    end
  end
end
