defmodule AtpWeb.SessionController do
  use AtpWeb, :controller

  alias Atp.Transport
  alias AtpWeb.APIResponse

  @transport_errors %{
    payload_too_large: {413, :payload_too_large},
    recipient_required: :unprocessable_entity,
    recipient_not_found: :unprocessable_entity,
    invalid_session_recipient: :unprocessable_entity,
    session_not_open: :conflict,
    unknown_sender_rate_limited: :too_many_requests,
    payload_required: :unprocessable_entity,
    payload_must_be_json: :unprocessable_entity,
    invalid_a2a_message: :unprocessable_entity,
    not_found: :not_found
  }

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    conn.assigns.atp_agent
    |> Transport.open_session(params, APIResponse.idempotency_key(conn), "POST /api/sessions")
    |> APIResponse.send_result(conn, @transport_errors)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case Transport.get_session(conn.assigns.atp_agent, id) do
      {:ok, body} ->
        json(conn, body)

      {:error, :not_found} ->
        APIResponse.send_error(conn, :not_found, :not_found)
    end
  end

  @spec create_message(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_message(conn, %{"id" => id} = params) do
    conn.assigns.atp_agent
    |> Transport.send_session_message(
      id,
      Map.delete(params, "id"),
      APIResponse.idempotency_key(conn),
      "POST /api/sessions/#{id}/messages"
    )
    |> APIResponse.send_result(conn, @transport_errors)
  end
end
