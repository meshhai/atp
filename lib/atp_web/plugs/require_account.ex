defmodule AtpWeb.Plugs.RequireAccount do
  @moduledoc false

  import Plug.Conn

  alias AtpWeb.APIResponse

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:atp_principal] do
      {:account, account} ->
        assign(conn, :atp_account, account)

      _other ->
        conn
        |> APIResponse.send_error(:forbidden, :account_key_required)
        |> halt()
    end
  end
end
