defmodule AtpWeb.Plugs.Parsers do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias AtpWeb.APIResponse

  @spec init(Keyword.t()) :: Plug.opts()
  def init(opts), do: Plug.Parsers.init(opts)

  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    Plug.Parsers.ParseError ->
      conn
      |> put_status(:bad_request)
      |> json(APIResponse.error_body(:invalid_request))
      |> halt()
  end
end
