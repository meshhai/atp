defmodule Atp.Transport.DurableLedger do
  @moduledoc """
  Transport-owned durable ledger boundary for carrier state transitions.

  ATP requires durable ledger semantics, not a specific storage engine. This
  module defines semantic carrier operations and delegates to the configured
  implementation. The current default implementation is
  `Atp.Transport.DurableLedger.Postgres`.

  Delivery claim implementations must preserve atomicity across related carrier
  state updates, lease ownership, stale-claim rejection, and session-order eligibility.
  Callbacks use transport structs and avoid exposing storage-engine mechanics.
  """

  alias Atp.Identity.{Agent, Idempotency}
  alias Atp.Transport.{DeliveryClaim, Message}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @type direct_message_after_commit :: Idempotency.prepared_after_commit() | nil
  @type direct_message_intake_result ::
          {:ok, pos_integer(), map(), direct_message_after_commit()} | {:error, term()}
  @type terminalization_reason :: :message_acked | :message_expired
  @type claim_result :: {:ok, DeliveryClaim.t() | Message.t()} | {:error, term()}
  @type due_claim_result :: {:ok, DeliveryClaim.t() | nil} | {:error, term()}
  @type finish_result :: {:ok, Message.t()} | {:error, term()}

  @doc """
  Accepts one direct message into the durable carrier ledger.

  Implementations must validate the request, apply idempotency for the sender,
  route, key, and body, resolve the recipient, enforce sender policy, persist
  the message, prepare delivery work, and return stable retry results.

  Implementations may return prepared post-commit work for the caller to
  complete, but they must not perform active webhook dispatch themselves. This
  capability is for direct messages only; session opening and session message
  sends are separate carrier operations.
  """
  @callback accept_direct_message(Agent.t(), map(), String.t() | nil, String.t()) ::
              direct_message_intake_result()

  @doc """
  Claims the next due webhook delivery eligible for carrier work.

  Implementations must return one current lease at most, respect active leases,
  reclaim expired leases, and preserve session delivery order eligibility.
  """
  @callback claim_due_webhook_delivery(keyword()) :: due_claim_result()

  @doc """
  Claims a specific webhook delivery for carrier work.

  Implementations must reject active leases, terminalize already-ACKed or
  expired messages without requiring a webhook attempt, and return the same
  carrier result shapes as the public transport facade.
  """
  @callback claim_webhook_delivery(String.t(), keyword()) :: claim_result()

  @doc """
  Finishes a claimed webhook delivery after one delivery attempt.

  Implementations must validate the claim token and lease before atomically
  recording the attempt and updating delivery and message state.
  """
  @callback finish_claimed_webhook_delivery(DeliveryClaim.t(), AttemptResult.t(), keyword()) ::
              finish_result()

  @doc """
  Terminalizes a claimed webhook delivery without an outbound attempt.

  Implementations must validate claim ownership and only allow terminalization
  for carrier-observed ACKed or expired messages.
  """
  @callback terminalize_claimed_webhook_delivery(
              DeliveryClaim.t(),
              terminalization_reason(),
              keyword()
            ) :: finish_result()

  @spec adapter() :: module()
  def adapter do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, Atp.Transport.DurableLedger.Postgres)
  end

  @spec accept_direct_message(Agent.t(), map(), String.t() | nil, String.t()) ::
          direct_message_intake_result()
  def accept_direct_message(%Agent{} = sender, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    adapter().accept_direct_message(sender, params, idempotency_key, route)
  end

  @spec claim_due_webhook_delivery(keyword()) :: due_claim_result()
  def claim_due_webhook_delivery(opts \\ []) when is_list(opts) do
    adapter().claim_due_webhook_delivery(opts)
  end

  @spec claim_webhook_delivery(String.t(), keyword()) :: claim_result()
  def claim_webhook_delivery(delivery_id, opts \\ [])
      when is_binary(delivery_id) and is_list(opts) do
    adapter().claim_webhook_delivery(delivery_id, opts)
  end

  @spec finish_claimed_webhook_delivery(DeliveryClaim.t(), AttemptResult.t(), keyword()) ::
          finish_result()
  def finish_claimed_webhook_delivery(
        %DeliveryClaim{} = claim,
        %AttemptResult{} = result,
        opts \\ []
      )
      when is_list(opts) do
    adapter().finish_claimed_webhook_delivery(claim, result, opts)
  end

  @spec terminalize_claimed_webhook_delivery(
          DeliveryClaim.t(),
          terminalization_reason(),
          keyword()
        ) :: finish_result()
  def terminalize_claimed_webhook_delivery(%DeliveryClaim{} = claim, reason, opts \\ [])
      when reason in [:message_acked, :message_expired] and is_list(opts) do
    adapter().terminalize_claimed_webhook_delivery(claim, reason, opts)
  end
end
