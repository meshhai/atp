import Config

test_pool_size =
  System.get_env("TEST_POOL_SIZE") ||
    System.get_env("POOL_SIZE") ||
    "9"

config :atp, Atp.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "atp_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(test_pool_size),
  queue_target: 5_000,
  queue_interval: 10_000

config :atp, AtpWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "Qm8kZjXw2rhthYpoRYZg2LUHf8xOzXMdei2DflasFO05ep51+g2feuUdvlYpKs4xyz89abcdefg",
  server: false

config :atp, Atp.Identity.Idempotency,
  response_secret_key_base:
    "Qm8kZjXw2rhthYpoRYZg2LUHf8xOzXMdei2DflasFO05ep51+g2feuUdvlYpKs4xyz89abcdefg"

config :atp, Atp.Transport.WebhookDelivery,
  req_options: [
    plug: {Req.Test, Atp.Transport.WebhookDelivery},
    connect_options: [timeout: 5_000]
  ],
  webhook_url_resolver: fn
    "private.example.test" -> {:ok, [{127, 0, 0, 1}]}
    "mixed.example.test" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]}
    _host -> {:ok, [{93, 184, 216, 34}]}
  end

config :atp, Atp.Transport.WebhookDispatcher, enabled: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
