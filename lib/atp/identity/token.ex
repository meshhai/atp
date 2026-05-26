defmodule Atp.Identity.Token do
  @moduledoc false

  @spec generate(String.t()) :: String.t()
  def generate(prefix) when is_binary(prefix) do
    "#{prefix}_#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
  end

  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end
end
