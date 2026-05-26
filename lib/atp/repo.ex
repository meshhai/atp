defmodule Atp.Repo do
  use Ecto.Repo,
    otp_app: :atp,
    adapter: Ecto.Adapters.Postgres
end
