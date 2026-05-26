defmodule AtpWeb.APIResponse do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  @messages %{
    "ack_status_required" => "An ACK status is required.",
    "account_key_required" => "An account API key is required for this operation.",
    "agent_key_required" => "An agent API key is required for this operation.",
    "cross_account_not_supported" => "Cross-account delivery is not supported by this endpoint.",
    "delivery_not_delivered" => "The delivery has not been delivered by the carrier.",
    "idempotency_conflict" =>
      "The idempotency key was already used with a different request body.",
    "idempotency_in_progress" => "The idempotency key is already processing.",
    "idempotency_key_required" => "An Idempotency-Key header is required.",
    "invalid_account" => "The account request is invalid.",
    "invalid_ack_status" => "The ACK status is invalid.",
    "invalid_ack_transition" => "The ACK transition is invalid.",
    "invalid_a2a_message" => "The payload must be a valid A2A Message object.",
    "invalid_lease" => "The requested delivery lease is invalid.",
    "invalid_request" => "The request is invalid.",
    "invalid_sender_policy" => "The sender policy request is invalid.",
    "invalid_session_recipient" => "A session requires two distinct agent participants.",
    "invalid_webhook_url" => "The webhook endpoint URL must be a public http or https URL.",
    "lease_expired" => "The delivery lease has expired.",
    "message_expired" => "The message has expired.",
    "not_found" => "The requested resource was not found.",
    "payload_must_be_json" => "The payload must be valid JSON.",
    "payload_required" => "A payload field is required.",
    "payload_too_large" => "The encoded JSON payload exceeds 64KB.",
    "plan_limit_exceeded" => "The account plan limit has been exceeded.",
    "recipient_not_found" => "The recipient agent was not found.",
    "recipient_required" => "A recipient address is required.",
    "session_not_open" => "The session is not open.",
    "terminal_ack_status" => "The message already has a terminal ACK status.",
    "unauthorized" => "Authentication is required.",
    "unknown_sender_rate_limited" =>
      "Unknown cross-account sender limit exceeded for this recipient.",
    "unexpected_error" => "An unexpected error occurred."
  }

  @default_result_errors %{
    idempotency_key_required: :bad_request,
    idempotency_conflict: :conflict,
    idempotency_in_progress: :conflict
  }

  @type api_result :: {:ok, pos_integer(), map()} | {:error, term()}
  @type error_mapping ::
          %{
            optional(atom()) =>
              atom() | pos_integer() | {atom() | pos_integer(), atom() | String.t()}
          }

  @spec idempotency_key(Plug.Conn.t()) :: String.t() | nil
  def idempotency_key(conn), do: conn |> get_req_header("idempotency-key") |> List.first()

  @spec send_result(api_result(), Plug.Conn.t(), error_mapping()) :: Plug.Conn.t()
  def send_result(result, conn, mapping \\ %{})

  def send_result({:ok, status, body}, conn, _mapping) do
    send_success(conn, status, body)
  end

  def send_result({:error, reason}, conn, mapping) when is_atom(reason) do
    {status, code} =
      @default_result_errors
      |> Map.merge(mapping)
      |> Map.get(reason, {:unprocessable_entity, :invalid_request})
      |> normalize_error_mapping(reason)

    send_error(conn, status, code)
  end

  def send_result({:error, _reason}, conn, _mapping) do
    send_error(conn, :unprocessable_entity, :invalid_request)
  end

  @spec send_success(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def send_success(conn, status, body) when is_integer(status) and is_map(body) do
    conn
    |> put_status(status)
    |> json(body)
  end

  @spec send_error(Plug.Conn.t(), atom() | pos_integer(), atom() | String.t()) :: Plug.Conn.t()
  def send_error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(error_body(code))
  end

  @spec error_body(atom() | String.t()) :: map()
  def error_body(code) when is_atom(code), do: code |> Atom.to_string() |> error_body()

  def error_body(code) when is_binary(code) do
    %{
      "error" => %{
        "code" => code,
        "message" => Map.get(@messages, code, "The request could not be completed.")
      }
    }
  end

  defp normalize_error_mapping({status, code}, _reason), do: {status, code}
  defp normalize_error_mapping(status, reason), do: {status, reason}
end
