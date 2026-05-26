defmodule AtpWeb.AgentController do
  use AtpWeb, :controller

  alias Atp.Identity
  alias AtpWeb.APIResponse

  @identity_errors %{
    not_found: :not_found,
    plan_limit_exceeded: :unprocessable_entity
  }

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    conn.assigns.atp_account
    |> Identity.register_agent(params, APIResponse.idempotency_key(conn), "POST /api/agents")
    |> APIResponse.send_result(conn, @identity_errors)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case Identity.get_agent(conn.assigns.atp_account, id) do
      {:ok, body} ->
        json(conn, body)

      {:error, :not_found} ->
        APIResponse.send_error(conn, :not_found, :not_found)
    end
  end

  @spec create_key(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_key(conn, %{"id" => id} = params) do
    conn.assigns.atp_account
    |> Identity.rotate_agent_key(id, Map.delete(params, "id"), APIResponse.idempotency_key(conn))
    |> APIResponse.send_result(conn, @identity_errors)
  end
end
