defmodule Atp.Transport.Runtime.Supervisor do
  @moduledoc "ATP live carrier-plane supervisor."

  use Supervisor

  alias Atp.Transport.Runtime.PendingSessionRehydrator

  @session_registry Atp.Transport.Runtime.SessionRegistry
  @session_supervisor Atp.Transport.Runtime.SessionSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    session_registry = Keyword.get(opts, :session_registry, @session_registry)
    session_supervisor = Keyword.get(opts, :session_supervisor, @session_supervisor)

    children = [
      {Registry, keys: :unique, name: session_registry},
      {DynamicSupervisor, strategy: :one_for_one, name: session_supervisor},
      {PendingSessionRehydrator, session_supervisor: session_supervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
