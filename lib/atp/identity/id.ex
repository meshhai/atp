defmodule Atp.Identity.ID do
  @moduledoc false

  @spec generate(String.t()) :: String.t()
  def generate(prefix) when is_binary(prefix) do
    "#{prefix}_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
  end
end
