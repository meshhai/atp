defmodule AtpWeb.AccountController do
  use AtpWeb, :controller

  alias Atp.Identity
  alias AtpWeb.APIResponse

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case Identity.create_account(params) do
      {:ok, body} ->
        APIResponse.send_success(conn, 201, body)

      {:error, _changeset} ->
        APIResponse.send_error(conn, :unprocessable_entity, :invalid_account)
    end
  end
end
