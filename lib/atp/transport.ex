defmodule Atp.Transport do
  @moduledoc "Public ATP carrier facade for messages, sessions, polling leases, and status reads."

  alias Atp.Identity.{Agent, Idempotency}
  alias Atp.Transport.{DurableLedger, Runtime}

  @type api_result :: {:ok, pos_integer(), map()} | {:error, term()}

  @spec send_message(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  def send_message(%Agent{} = sender, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    with {:ok, status, body, prepared} <-
           DurableLedger.accept_direct_message(sender, params, idempotency_key, route) do
      finish_direct_message_intake(sender, status, body, prepared)
    end
  end

  defp finish_direct_message_intake(%Agent{}, status, body, nil), do: {:ok, status, body}

  defp finish_direct_message_intake(%Agent{}, _status, _body, prepared) do
    Idempotency.complete_prepared_after_commit(prepared, &complete_queued_intake/3)
  end

  defp complete_queued_intake(status, body, _commit_value) do
    {:ok, status, body}
  end

  @spec open_session(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  defdelegate open_session(initiator, params, idempotency_key, route), to: Runtime

  @spec accept_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  defdelegate accept_session(recipient, session_id, params, idempotency_key, route), to: Runtime

  @spec reject_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  defdelegate reject_session(recipient, session_id, params, idempotency_key, route), to: Runtime

  @spec send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  defdelegate send_session_message(sender, session_id, params, idempotency_key, route),
    to: Runtime

  @spec get_session(Agent.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_session(agent, session_id), to: Runtime

  @spec get_message_status(Agent.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_message_status(agent, message_id), to: DurableLedger

  @spec claim_inbox(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  defdelegate claim_inbox(agent, params, idempotency_key, route), to: DurableLedger

  @doc false
  @spec claim_webhook_delivery(String.t(), keyword()) ::
          {:ok, Atp.Transport.DeliveryClaim.t() | Atp.Transport.Message.t()} | {:error, term()}
  defdelegate claim_webhook_delivery(delivery_id, opts \\ []), to: DurableLedger

  @doc false
  @spec claim_due_webhook_delivery(keyword()) ::
          {:ok, Atp.Transport.DeliveryClaim.t() | nil} | {:error, term()}
  defdelegate claim_due_webhook_delivery(opts \\ []), to: DurableLedger

  @doc false
  @spec finish_claimed_webhook_delivery(
          Atp.Transport.DeliveryClaim.t(),
          Atp.Transport.WebhookDelivery.AttemptResult.t(),
          keyword()
        ) ::
          {:ok, Atp.Transport.Message.t()} | {:error, term()}
  defdelegate finish_claimed_webhook_delivery(claim, result, opts \\ []), to: DurableLedger

  @spec extend_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  defdelegate extend_delivery(agent, delivery_id, params, idempotency_key, route),
    to: DurableLedger

  @spec ack_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) :: api_result()
  defdelegate ack_delivery(agent, delivery_id, params, idempotency_key, route), to: Runtime

  @spec upsert_sender_policy(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  defdelegate upsert_sender_policy(recipient, agent_id, params, idempotency_key, route),
    to: DurableLedger
end
