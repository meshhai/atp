defmodule AtpWeb.InboxController do
  use AtpWeb, :controller

  alias Atp.Transport
  alias AtpWeb.APIResponse

  @transport_errors %{
    invalid_lease: :unprocessable_entity
  }

  @spec create_claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_claim(conn, params) do
    conn.assigns.atp_agent
    |> Transport.claim_inbox(params, APIResponse.idempotency_key(conn), "POST /api/inbox/claims")
    |> APIResponse.send_result(conn, @transport_errors)
  end
end
