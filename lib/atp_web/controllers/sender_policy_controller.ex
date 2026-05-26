defmodule AtpWeb.SenderPolicyController do
  use AtpWeb, :controller

  alias Atp.Transport
  alias AtpWeb.APIResponse

  @transport_errors %{
    invalid_sender_policy: :unprocessable_entity,
    not_found: :not_found
  }

  @spec upsert(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upsert(conn, %{"id" => id} = params) do
    conn.assigns.atp_agent
    |> Transport.upsert_sender_policy(
      id,
      Map.delete(params, "id"),
      APIResponse.idempotency_key(conn),
      "PUT /api/agents/:id/sender_policies"
    )
    |> APIResponse.send_result(conn, @transport_errors)
  end
end
