defmodule AtpWeb.WebhookEndpointController do
  use AtpWeb, :controller

  alias Atp.Identity
  alias AtpWeb.APIResponse

  @identity_errors %{
    invalid_webhook_url: :unprocessable_entity,
    not_found: :not_found
  }

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id} = params) do
    conn.assigns.atp_agent
    |> Identity.configure_webhook_endpoint(
      id,
      Map.delete(params, "id"),
      APIResponse.idempotency_key(conn),
      "PUT /api/agents/:id/webhook_endpoint"
    )
    |> APIResponse.send_result(conn, @identity_errors)
  end
end
