defmodule Atp.Transport.JsonValue do
  @moduledoc "Ecto type for arbitrary JSON values carried in ATP payload fields."

  use Ecto.Type

  @type t :: nil | boolean() | number() | String.t() | [t()] | %{String.t() => t()}

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value), do: cast_json(value)

  @impl Ecto.Type
  def dump(value), do: cast_json(value)

  @impl Ecto.Type
  def load(value), do: cast_json(value)

  defp cast_json(nil), do: {:ok, nil}
  defp cast_json(value) when is_boolean(value), do: {:ok, value}
  defp cast_json(value) when is_binary(value), do: {:ok, value}
  defp cast_json(value) when is_integer(value), do: {:ok, value}
  defp cast_json(value) when is_float(value), do: {:ok, value}

  defp cast_json(value) when is_list(value) do
    if Enum.all?(value, &json_value?/1), do: {:ok, value}, else: :error
  end

  defp cast_json(value) when is_map(value) do
    if Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end) do
      {:ok, value}
    else
      :error
    end
  end

  defp cast_json(_value), do: :error

  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value), do: true
  defp json_value?(value) when is_binary(value), do: true
  defp json_value?(value) when is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: true
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_value), do: false
end
