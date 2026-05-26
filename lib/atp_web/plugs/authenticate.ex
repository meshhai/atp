defmodule AtpWeb.Plugs.Authenticate do
  @moduledoc false

  import Plug.Conn

  alias Atp.Identity
  alias AtpWeb.APIResponse

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, principal} <- Identity.authenticate_bearer(token) do
      assign(conn, :atp_principal, principal)
    else
      :error ->
        conn
        |> APIResponse.send_error(:unauthorized, :unauthorized)
        |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _other -> :error
    end
  end
end
