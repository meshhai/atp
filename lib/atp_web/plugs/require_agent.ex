defmodule AtpWeb.Plugs.RequireAgent do
  @moduledoc false

  import Plug.Conn

  alias AtpWeb.APIResponse

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:atp_principal] do
      {:agent, agent} ->
        assign(conn, :atp_agent, agent)

      _other ->
        conn
        |> APIResponse.send_error(:forbidden, :agent_key_required)
        |> halt()
    end
  end
end
