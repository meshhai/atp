defmodule AtpWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :atp

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  if Code.ensure_loaded?(Tidewave) do
    plug(Tidewave)
  end

  plug(AtpWeb.Plugs.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: 128_000,
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(AtpWeb.Router)
end
