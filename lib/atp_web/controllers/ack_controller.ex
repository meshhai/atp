defmodule AtpWeb.AckController do
  use AtpWeb, :controller

  alias Atp.Transport
  alias AtpWeb.APIResponse

  @transport_errors %{
    not_found: :not_found,
    delivery_not_delivered: :conflict,
    lease_expired: :conflict,
    message_expired: :conflict,
    invalid_ack_transition: :conflict,
    terminal_ack_status: :conflict,
    payload_too_large: {413, :payload_too_large},
    ack_status_required: :unprocessable_entity,
    invalid_ack_status: :unprocessable_entity,
    payload_must_be_json: :unprocessable_entity,
    invalid_a2a_message: :unprocessable_entity
  }

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"id" => id} = params) do
    conn.assigns.atp_agent
    |> Transport.ack_delivery(
      id,
      Map.delete(params, "id"),
      APIResponse.idempotency_key(conn),
      "POST /api/deliveries/#{id}/acks"
    )
    |> APIResponse.send_result(conn, @transport_errors)
  end
end
