defmodule Atp.Transport.DurableLedger do
  @moduledoc """
  Transport-owned durable ledger boundary for carrier state transitions.

  ATP requires durable ledger semantics, not a specific storage engine. This
  module defines semantic carrier operations and delegates to the configured
  implementation. The current default implementation is
  `Atp.Transport.DurableLedger.Postgres`.

  Implementations must preserve atomicity across related carrier state updates,
  lease ownership, stale-claim rejection, session intake ordering, and
  session-order eligibility for delivery work. Callbacks use transport structs
  and avoid exposing storage-engine mechanics.
  """

  alias Atp.Identity.{Agent, Idempotency}
  alias Atp.Transport.{DeliveryClaim, Message}
  alias Atp.Transport.WebhookDelivery.AttemptResult

  @type prepared_after_commit :: Idempotency.prepared_after_commit() | nil
  @type direct_message_after_commit :: prepared_after_commit()
  @type direct_message_intake_result ::
          {:ok, pos_integer(), map(), direct_message_after_commit()} | {:error, term()}
  @type session_intake_after_commit :: prepared_after_commit()
  @type session_intake_result ::
          {:ok, pos_integer(), map(), session_intake_after_commit()} | {:error, term()}
  @type session_message_preflight_result :: :ok | {:ok, pos_integer(), map()} | {:error, term()}
  @type session_lifecycle_result :: {:ok, pos_integer(), map()} | {:error, term()}
  @type ack_result :: {:ok, pos_integer(), map()} | {:error, term()}
  @type polling_lease_result :: {:ok, pos_integer(), map()} | {:error, term()}
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
  Opens a session in the durable carrier ledger.

  Implementations must validate the request, apply idempotency for the
  initiator, route, key, and body, resolve the recipient, enforce sender
  policy, create the session and opening message atomically, assign the opening
  message sequence, prepare delivery work, and return stable retry results.

  Blocked openings still persist rejected session and opening message state
  without preparing delivery work. Implementations may return prepared
  post-commit work for caller completion.
  Implementations must not perform active webhook dispatch themselves.
  """
  @callback open_session(Agent.t(), map(), String.t() | nil, String.t()) ::
              session_intake_result()

  @doc """
  Performs a cheap preflight for a session message before live runtime startup.

  Implementations should validate request shape, idempotency replay eligibility,
  participant membership, and open-session state without mutating carrier state.
  Final correctness, sequence allocation, sender policy enforcement, message
  persistence, and delivery preparation remain the responsibility of
  `send_session_message/5`.
  """
  @callback preflight_session_message(
              Agent.t(),
              String.t(),
              map(),
              String.t() | nil,
              String.t()
            ) ::
              session_message_preflight_result()

  @doc """
  Accepts one session message into the durable carrier ledger.

  Implementations must validate the request, apply idempotency for the sender,
  route, key, and body, enforce participant and open-session checks, allocate
  the next session message sequence atomically, enforce sender policy, persist
  the message, prepare delivery work, and return stable retry results.

  Blocked session messages still persist rejected message state with the next
  sequence without preparing delivery work. Implementations may return prepared
  post-commit work for caller completion.
  Implementations must not perform active webhook dispatch themselves.
  """
  @callback send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
              session_intake_result()

  @doc """
  Accepts a pending session opening in the durable carrier ledger.

  Implementations must allow only the opening session recipient to accept,
  apply idempotency for that recipient, route, key, and body, validate any
  optional A2A ACK payload, record an accepted ACK for the opening delivery,
  and transition the session from pending to open atomically.

  Implementations must return stable retry results and must not perform active
  webhook dispatch themselves. Runtime process startup belongs to the caller.
  """
  @callback accept_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
              session_lifecycle_result()

  @doc """
  Rejects a pending session opening in the durable carrier ledger.

  Implementations must allow only the opening session recipient to reject,
  apply idempotency for that recipient, route, key, and body, validate any
  optional A2A ACK payload, record a rejected ACK for the opening delivery,
  and transition the pending session to a terminal rejected state atomically.

  Implementations must return stable retry results and must not perform active
  webhook dispatch themselves. Runtime process shutdown belongs to the caller.
  """
  @callback reject_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
              session_lifecycle_result()

  @doc """
  Records a recipient-owned delivery ACK in the durable carrier ledger.

  Implementations must allow only the delivery recipient to ACK, apply
  idempotency for the recipient, route, key, and body, validate delivery
  ownership, lease state, delivery validation requirements, and any optional
  A2A ACK payload, enforce ACK transition rules for accepted, completed,
  failed, and rejected outcomes, persist the ACK, update cached message status,
  and apply durable opening-session state transitions atomically.

  Implementations must return stable retry results and must not perform active
  webhook dispatch themselves. Runtime process startup or shutdown belongs to
  the caller.
  """
  @callback ack_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
              ack_result()

  @doc """
  Claims the next recipient-owned inbox polling delivery.

  Implementations must validate requested lease duration, apply idempotency for
  the recipient, route, key, and body, return stable replay results, and expose
  at most one eligible delivery. Implementations must keep active leases hidden
  across all delivery modes until expiry, allow expired leases to become
  eligible again, keep ACKed messages invisible, and preserve session order
  eligibility.
  """
  @callback claim_inbox(Agent.t(), map(), String.t() | nil, String.t()) ::
              polling_lease_result()

  @doc """
  Extends a recipient-owned polling lease for one delivery.

  Implementations must validate requested lease duration, apply idempotency for
  the recipient, route, key, and body, return stable replay results, and enforce
  recipient ownership, polling mode, leased state, and non-expired lease
  requirements before extending the lease.
  """
  @callback extend_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
              polling_lease_result()

  @doc """
  Claims the next due webhook delivery eligible for carrier work.

  Implementations must return one current lease at most, respect active leases
  across all delivery modes, reclaim expired leases, and preserve session
  delivery order eligibility.
  """
  @callback claim_due_webhook_delivery(keyword()) :: due_claim_result()

  @doc """
  Claims a specific webhook delivery for carrier work.

  Implementations must reject active leases across all delivery modes,
  terminalize already-ACKed or expired messages without requiring a webhook
  attempt, and return the same carrier result shapes as the public transport
  facade.
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

  @spec open_session(Agent.t(), map(), String.t() | nil, String.t()) ::
          session_intake_result()
  def open_session(%Agent{} = initiator, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    adapter().open_session(initiator, params, idempotency_key, route)
  end

  @spec preflight_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          session_message_preflight_result()
  def preflight_session_message(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    adapter().preflight_session_message(sender, session_id, params, idempotency_key, route)
  end

  @spec send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          session_intake_result()
  def send_session_message(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    adapter().send_session_message(sender, session_id, params, idempotency_key, route)
  end

  @spec accept_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          session_lifecycle_result()
  def accept_session(%Agent{} = recipient, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    adapter().accept_session(recipient, session_id, params, idempotency_key, route)
  end

  @spec reject_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          session_lifecycle_result()
  def reject_session(%Agent{} = recipient, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    adapter().reject_session(recipient, session_id, params, idempotency_key, route)
  end

  @spec ack_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          ack_result()
  def ack_delivery(%Agent{} = recipient, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) and is_binary(route) do
    adapter().ack_delivery(recipient, delivery_id, params, idempotency_key, route)
  end

  @spec claim_inbox(Agent.t(), map(), String.t() | nil, String.t()) ::
          polling_lease_result()
  def claim_inbox(%Agent{} = recipient, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    adapter().claim_inbox(recipient, params, idempotency_key, route)
  end

  @spec extend_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          polling_lease_result()
  def extend_delivery(%Agent{} = recipient, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) and is_binary(route) do
    adapter().extend_delivery(recipient, delivery_id, params, idempotency_key, route)
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
