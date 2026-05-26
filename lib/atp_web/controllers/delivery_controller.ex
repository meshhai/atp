defmodule AtpWeb.DeliveryController do
  use AtpWeb, :controller

  alias Atp.Transport
  alias AtpWeb.APIResponse

  @transport_errors %{
    not_found: :not_found,
    lease_expired: :conflict,
    invalid_lease: :unprocessable_entity
  }

  @spec extend(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def extend(conn, %{"id" => id} = params) do
    conn.assigns.atp_agent
    |> Transport.extend_delivery(
      id,
      Map.delete(params, "id"),
      APIResponse.idempotency_key(conn),
      "POST /api/deliveries/#{id}/extend"
    )
    |> APIResponse.send_result(conn, @transport_errors)
  end
end
