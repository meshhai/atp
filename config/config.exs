import Config

config :atp,
  ecto_repos: [Atp.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :atp, Atp.Transport.DurableLedger, adapter: Atp.Transport.DurableLedger.Postgres

config :atp, AtpWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: AtpWeb.ErrorJSON],
    layout: false
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
