defmodule Atp.ConnCase do
  @moduledoc "Test case for ATP HTTP endpoint tests."

  use ExUnit.CaseTemplate

  @endpoint AtpWeb.Endpoint

  import Phoenix.ConnTest

  using do
    quote do
      @endpoint AtpWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Atp.ConnCase
    end
  end

  setup tags do
    Atp.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @spec authorize(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def authorize(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

  @spec idempotency_key(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def idempotency_key(conn, key), do: Plug.Conn.put_req_header(conn, "idempotency-key", key)

  @spec error_code(map()) :: String.t()
  def error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code

  @spec create_account!(Plug.Conn.t(), map()) :: map()
  def create_account!(conn, attrs \\ %{}) do
    params = Map.merge(%{"name" => "Dev Network"}, attrs)

    conn
    |> post("/api/accounts", params)
    |> json_response(201)
  end

  @spec register_agent!(String.t(), String.t(), map()) :: map()
  def register_agent!(account_token, key, params) do
    build_conn()
    |> authorize(account_token)
    |> idempotency_key(key)
    |> post("/api/agents", params)
    |> json_response(201)
  end

  @spec send_message!(String.t(), String.t(), String.t(), term()) :: map()
  def send_message!(sender_token, key, recipient_address, payload) do
    build_conn()
    |> authorize(sender_token)
    |> idempotency_key(key)
    |> post("/api/messages", %{"to" => recipient_address, "payload" => payload})
    |> json_response(201)
  end

  @spec open_session!(String.t(), String.t(), String.t(), term()) :: map()
  def open_session!(initiator_token, key, recipient_address, payload) do
    build_conn()
    |> authorize(initiator_token)
    |> idempotency_key(key)
    |> post("/api/sessions", %{"to" => recipient_address, "payload" => payload})
    |> json_response(201)
  end

  @spec a2a_user_text(String.t(), String.t()) :: map()
  def a2a_user_text(message_id, text), do: a2a_text(message_id, "ROLE_USER", text)

  @spec a2a_agent_text(String.t(), String.t()) :: map()
  def a2a_agent_text(message_id, text) do
    message_id
    |> a2a_text("ROLE_AGENT", text)
    |> Map.put("contextId", "ctx_#{message_id}")
  end

  @spec a2a_message(String.t(), String.t(), [map()], map()) :: map()
  def a2a_message(message_id, role, parts, attrs \\ %{}) do
    %{"messageId" => message_id, "role" => role, "parts" => parts}
    |> Map.merge(attrs)
  end

  @spec configure_webhook!(map(), String.t(), String.t()) :: map()
  def configure_webhook!(agent, key, url \\ "https://recipient.example.test/atp/webhook") do
    build_conn()
    |> authorize(agent["agent_api_key"]["token"])
    |> idempotency_key(key)
    |> put("/api/agents/#{agent["id"]}/webhook_endpoint", %{"url" => url})
    |> json_response(200)
  end

  @spec claim_inbox!(String.t(), String.t(), map()) :: map()
  def claim_inbox!(recipient_token, key, params) do
    build_conn()
    |> authorize(recipient_token)
    |> idempotency_key(key)
    |> post("/api/inbox/claims", params)
    |> json_response(201)
  end

  @spec ack_delivery!(String.t(), String.t(), String.t(), map()) :: map()
  def ack_delivery!(recipient_token, delivery_id, key, params) do
    build_conn()
    |> authorize(recipient_token)
    |> idempotency_key(key)
    |> post("/api/deliveries/#{delivery_id}/acks", params)
    |> json_response(201)
  end

  defp a2a_text(message_id, role, text) do
    a2a_message(message_id, role, [%{"text" => text}])
  end
end
