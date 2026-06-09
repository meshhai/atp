defmodule Atp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Atp.Repo,
      Atp.Transport.Runtime.Supervisor,
      {DynamicSupervisor,
       name: Atp.Transport.WebhookDispatcher.AttemptSupervisor, strategy: :one_for_one},
      Atp.Transport.WebhookDispatcher,
      AtpWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Atp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
