defmodule Atp.Identity.WebhookURL.ConnectTarget do
  @moduledoc "A webhook URL target whose connection address has already passed SSRF checks."

  @enforce_keys [:url, :hostname, :host_header]
  defstruct [:url, :hostname, :host_header]

  @type t :: %__MODULE__{
          url: String.t(),
          hostname: String.t(),
          host_header: String.t()
        }
end
