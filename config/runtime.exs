import Config

if System.get_env("PHX_SERVER") do
  config :atp, AtpWeb.Endpoint, server: true
end

config :atp, AtpWeb.Endpoint, http: [port: String.to_integer(System.get_env("ATP_PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("ATP_DATABASE_URL") ||
      System.get_env("DATABASE_URL") ||
      raise """
      environment variable ATP_DATABASE_URL or DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :atp, Atp.Repo,
    url: database_url,
    pool_size:
      String.to_integer(System.get_env("ATP_POOL_SIZE") || System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :atp, Atp.Identity.Idempotency, response_secret_key_base: secret_key_base

  atp_host = System.get_env("ATP_HOST") || "localhost"

  config :atp, AtpWeb.Endpoint,
    url: [host: atp_host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
