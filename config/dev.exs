import Config

config :atp, Atp.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: System.get_env("ATP_DB_NAME", "atp_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

bind_ip =
  if System.get_env("ATP_BIND_ALL") in ~w(true 1) do
    {0, 0, 0, 0}
  else
    {127, 0, 0, 1}
  end

config :atp, AtpWeb.Endpoint,
  http: [ip: bind_ip, port: String.to_integer(System.get_env("ATP_PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "Xp7kZjRw3rhthYpoRYZg2LUHf8xOzXMdei2DflasFO05ep51+g2feuUdvlYpMs5abc90defghij"

config :atp, Atp.Identity.Idempotency,
  response_secret_key_base:
    "Xp7kZjRw3rhthYpoRYZg2LUHf8xOzXMdei2DflasFO05ep51+g2feuUdvlYpMs5abc90defghij"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
