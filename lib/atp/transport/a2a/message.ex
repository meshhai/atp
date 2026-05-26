defmodule Atp.Transport.A2A.Message do
  @moduledoc """
  Validates the A2A Message object carried inside an ATP delivery.

  ATP owns carrier concerns such as identity, addressing, delivery, leases,
  ACKs, retries, and webhooks. The durable message body follows the A2A Message
  wire shape without ATP interpreting the payload's intent.
  """

  @content_type "application/a2a+json"
  @version "1.0"
  @roles ~w(ROLE_USER ROLE_AGENT)
  @content_keys ~w(text raw url data)
  @optional_message_strings ~w(contextId taskId)
  @optional_message_string_lists ~w(extensions referenceTaskIds)
  @optional_part_strings ~w(filename mediaType)

  @type t :: map()

  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @spec version() :: String.t()
  def version, do: @version

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_a2a_message}
  def validate(%{} = message) do
    with :ok <- required_string(message, "messageId"),
         :ok <- role(message),
         :ok <- role_context(message),
         :ok <- parts(Map.get(message, "parts")),
         :ok <- optional_object(message, "metadata"),
         :ok <- optional_strings(message, @optional_message_strings),
         :ok <- optional_string_lists(message, @optional_message_string_lists) do
      {:ok, message}
    end
  end

  def validate(_message), do: error()

  defp role(%{"role" => role}) when role in @roles, do: :ok
  defp role(_message), do: error()

  defp role_context(%{"role" => "ROLE_AGENT"} = message),
    do: required_string(message, "contextId")

  defp role_context(_message), do: :ok

  defp parts(parts) when is_list(parts) and parts != [] do
    validate_each(parts, &part/1)
  end

  defp parts(_parts), do: error()

  defp part(%{} = part) do
    with :ok <- exactly_one_content(part),
         :ok <- content_value(part),
         :ok <- optional_object(part, "metadata") do
      optional_strings(part, @optional_part_strings)
    end
  end

  defp part(_part), do: error()

  defp exactly_one_content(part) do
    case Enum.filter(@content_keys, &Map.has_key?(part, &1)) do
      [_key] -> :ok
      _keys -> error()
    end
  end

  defp content_value(part) do
    part
    |> present_content_key()
    |> valid_content_value?(part)
    |> case do
      true -> :ok
      false -> error()
    end
  end

  defp present_content_key(part), do: Enum.find(@content_keys, &Map.has_key?(part, &1))

  defp valid_content_value?("text", %{"text" => text}), do: is_binary(text)
  defp valid_content_value?("raw", %{"raw" => raw}), do: is_binary(raw)
  defp valid_content_value?("url", %{"url" => url}), do: is_binary(url)
  defp valid_content_value?("data", _part), do: true

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> non_empty(value)
      _other -> error()
    end
  end

  defp optional_strings(map, keys) do
    validate_each(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} when is_binary(value) -> non_empty(value)
        {:ok, _value} -> error()
        :error -> :ok
      end
    end)
  end

  defp optional_string_lists(map, keys) do
    validate_each(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, values} when is_list(values) -> validate_each(values, &string/1)
        {:ok, _value} -> error()
        :error -> :ok
      end
    end)
  end

  defp optional_object(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> error()
      :error -> :ok
    end
  end

  defp string(value) when is_binary(value), do: non_empty(value)
  defp string(_value), do: error()

  defp non_empty(value) do
    if String.trim(value) == "" do
      error()
    else
      :ok
    end
  end

  defp validate_each(values, validator) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp error, do: {:error, :invalid_a2a_message}
end
