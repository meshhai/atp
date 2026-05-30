defmodule Atp.Transport.DurableLedger.Postgres do
  @moduledoc """
  Default durable ledger adapter backed by Postgres/Ecto.

  Ecto and database locking remain implementation details of this adapter. It
  exposes only the carrier operations defined by `Atp.Transport.DurableLedger`.
  """

  import Ecto.Query

  alias Atp.Identity.{Agent, ID, Idempotency}
  alias Atp.Repo

  alias Atp.Transport.{
    Delivery,
    DeliveryClaim,
    DurableLedger,
    Message,
    Payload,
    Response,
    SenderPolicies,
    Session,
    WebhookAttempt,
    WebhookDelivery
  }

  alias Atp.Transport.WebhookDelivery.AttemptResult

  @behaviour DurableLedger

  @default_message_ttl_seconds 7 * 24 * 60 * 60
  @default_webhook_claim_lease_seconds 60

  @impl DurableLedger
  @spec accept_direct_message(Agent.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.direct_message_intake_result()
  def accept_direct_message(%Agent{} = sender, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    with {:ok, recipient_address} <- fetch_to_address(params),
         {:ok, payload} <- fetch_payload(params),
         :ok <- Payload.validate_a2a(payload) do
      sender
      |> Idempotency.run_prepared_after_commit(
        route,
        idempotency_key,
        params,
        fn -> persist_direct_message_send(sender, recipient_address, payload) end
      )
    end
  end

  @impl DurableLedger
  @spec open_session(Agent.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.session_intake_result()
  def open_session(%Agent{} = initiator, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    with {:ok, recipient_address} <- fetch_to_address(params),
         {:ok, payload} <- fetch_payload(params),
         :ok <- Payload.validate_a2a(payload) do
      initiator
      |> Idempotency.run_prepared_after_commit(
        route,
        idempotency_key,
        params,
        fn -> persist_session_open(initiator, recipient_address, payload) end
      )
    end
  end

  @impl DurableLedger
  @spec send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.session_intake_result()
  def send_session_message(%Agent{}, session_id, params, _idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    {:error, :session_intake_not_implemented}
  end

  defp persist_direct_message_send(%Agent{} = sender, recipient_address, payload) do
    with {:ok, recipient, trust, blocked?} <- fetch_recipient(sender, recipient_address),
         :ok <-
           SenderPolicies.enforce_unknown_sender_rate_limit(
             sender,
             recipient,
             trust,
             blocked?
           ),
         {:ok, message} <- insert_direct_message(sender, recipient, trust, blocked?, payload),
         {:ok, webhook_delivery_id} <-
           prepare_deliverable_webhook_delivery(message, recipient, blocked?) do
      {:ok, 201, Response.message_status(message, sender), webhook_delivery_id}
    end
  end

  defp persist_session_open(%Agent{} = initiator, recipient_address, payload) do
    with {:ok, recipient, trust, blocked?} <- fetch_recipient(initiator, recipient_address),
         :ok <- ensure_distinct_session_participant(initiator, recipient),
         :ok <-
           SenderPolicies.enforce_unknown_sender_rate_limit(
             initiator,
             recipient,
             trust,
             blocked?
           ),
         {:ok, session, message} <-
           insert_opening_session_message(initiator, recipient, trust, blocked?, payload),
         {:ok, webhook_delivery_id} <-
           prepare_deliverable_webhook_delivery(message, recipient, blocked?) do
      body = Response.session_message(session, message, initiator)
      prepared_session_open_response(body, session, webhook_delivery_id)
    end
  end

  defp prepared_session_open_response(body, %Session{}, nil), do: {:ok, 201, body}

  defp prepared_session_open_response(body, %Session{id: session_id}, webhook_delivery_id) do
    {:ok, 201, body, {session_id, webhook_delivery_id}}
  end

  @impl DurableLedger
  @spec claim_webhook_delivery(String.t(), keyword()) :: DurableLedger.claim_result()
  def claim_webhook_delivery(delivery_id, opts) when is_binary(delivery_id) and is_list(opts) do
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_webhook_claim_lease_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case validate_lease_seconds(lease_seconds) do
      :ok ->
        Repo.transaction(fn ->
          claim_locked_webhook_delivery!(delivery_id, now, lease_seconds)
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl DurableLedger
  @spec claim_due_webhook_delivery(keyword()) :: DurableLedger.due_claim_result()
  def claim_due_webhook_delivery(opts) when is_list(opts) do
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_webhook_claim_lease_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case validate_lease_seconds(lease_seconds) do
      :ok ->
        Repo.transaction(fn ->
          claim_next_due_webhook_delivery!(now, lease_seconds)
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl DurableLedger
  @spec finish_claimed_webhook_delivery(DeliveryClaim.t(), AttemptResult.t(), keyword()) ::
          DurableLedger.finish_result()
  def finish_claimed_webhook_delivery(
        %DeliveryClaim{delivery: %Delivery{id: delivery_id}} = claim,
        %AttemptResult{} = result,
        opts
      )
      when is_binary(delivery_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transaction(fn ->
      finish_locked_webhook_delivery!(delivery_id, claim, result, now)
    end)
  end

  @impl DurableLedger
  @spec terminalize_claimed_webhook_delivery(
          DeliveryClaim.t(),
          DurableLedger.terminalization_reason(),
          keyword()
        ) :: DurableLedger.finish_result()
  def terminalize_claimed_webhook_delivery(
        %DeliveryClaim{delivery: %Delivery{id: delivery_id}} = claim,
        reason,
        opts
      )
      when is_binary(delivery_id) and reason in [:message_acked, :message_expired] and
             is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transaction(fn ->
      terminalize_locked_webhook_delivery!(delivery_id, claim, reason, now)
    end)
  end

  defp fetch_to_address(%{"to" => address}) when is_binary(address) do
    case String.trim(address) do
      "" -> {:error, :recipient_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_to_address(_params), do: {:error, :recipient_required}

  defp fetch_payload(%{"payload" => payload}), do: {:ok, payload}
  defp fetch_payload(_params), do: {:error, :payload_required}

  defp fetch_recipient(%Agent{} = sender, address) do
    case Repo.get_by(Agent, address: address, status: "active") do
      %Agent{} = recipient ->
        SenderPolicies.resolve(sender, recipient)
        |> then(fn {trust, blocked?} -> {:ok, recipient, trust, blocked?} end)

      nil ->
        {:error, :recipient_not_found}
    end
  end

  defp ensure_distinct_session_participant(%Agent{id: id}, %Agent{id: id}) do
    {:error, :invalid_session_recipient}
  end

  defp ensure_distinct_session_participant(%Agent{}, %Agent{}), do: :ok

  defp insert_direct_message(
         %Agent{} = sender,
         %Agent{} = recipient,
         trust,
         blocked?,
         payload
       ) do
    now = DateTime.utc_now(:microsecond)

    %Message{id: ID.generate("msg")}
    |> Message.changeset(%{
      sender_account_id: sender.account_id,
      recipient_account_id: recipient.account_id,
      sender_agent_id: sender.id,
      recipient_agent_id: recipient.id,
      sender_address: sender.address,
      recipient_address: recipient.address,
      trust: trust,
      payload: payload,
      content_type: Payload.content_type(),
      carrier_status: carrier_status(blocked?),
      terminal_at: terminal_timestamp(blocked?, now),
      expires_at: DateTime.add(now, @default_message_ttl_seconds, :second)
    })
    |> Repo.insert()
  end

  defp insert_opening_session_message(
         %Agent{} = initiator,
         %Agent{} = recipient,
         trust,
         blocked?,
         payload
       ) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, session} <- insert_session(initiator, recipient, blocked?, now),
         {:ok, message} <-
           insert_session_message(initiator, recipient, trust, blocked?, payload, %{
             session_id: session.id,
             session_sequence: 1
           }),
         {:ok, updated_session} <- cache_opening_message(session, message.id) do
      {:ok, updated_session, message}
    end
  end

  defp insert_session(%Agent{} = initiator, %Agent{} = recipient, blocked?, now) do
    %Session{id: ID.generate("ses")}
    |> Session.changeset(%{
      initiator_account_id: initiator.account_id,
      recipient_account_id: recipient.account_id,
      initiator_agent_id: initiator.id,
      recipient_agent_id: recipient.id,
      initiator_address: initiator.address,
      recipient_address: recipient.address,
      status: initial_session_status(blocked?),
      last_sequence: 1,
      terminal_at: terminal_timestamp(blocked?, now)
    })
    |> Repo.insert()
  end

  defp initial_session_status(true), do: "rejected"
  defp initial_session_status(false), do: "pending"

  defp cache_opening_message(%Session{} = session, message_id) do
    session
    |> Session.changeset(%{opening_message_id: message_id})
    |> Repo.update()
  end

  defp insert_session_message(
         %Agent{} = sender,
         %Agent{} = recipient,
         trust,
         blocked?,
         payload,
         session_attrs
       ) do
    now = DateTime.utc_now(:microsecond)

    %Message{id: ID.generate("msg")}
    |> Message.changeset(%{
      sender_account_id: sender.account_id,
      recipient_account_id: recipient.account_id,
      sender_agent_id: sender.id,
      recipient_agent_id: recipient.id,
      sender_address: sender.address,
      recipient_address: recipient.address,
      trust: trust,
      payload: payload,
      content_type: Payload.content_type(),
      carrier_status: carrier_status(blocked?),
      terminal_at: terminal_timestamp(blocked?, now),
      expires_at: DateTime.add(now, @default_message_ttl_seconds, :second),
      session_id: Map.fetch!(session_attrs, :session_id),
      session_sequence: Map.fetch!(session_attrs, :session_sequence)
    })
    |> Repo.insert()
  end

  defp carrier_status(true), do: "rejected"
  defp carrier_status(false), do: "queued"

  defp terminal_timestamp(true, now), do: now
  defp terminal_timestamp(false, _now), do: nil

  defp prepare_trusted_webhook_delivery(
         %Message{trust: "trusted"} = message,
         %Agent{webhook_active: true, webhook_url: url, webhook_secret: secret} = recipient
       )
       when is_binary(url) and is_binary(secret) do
    with {:ok, delivery} <- WebhookDelivery.prepare(message, recipient) do
      {:ok, delivery.id}
    end
  end

  defp prepare_trusted_webhook_delivery(%Message{}, %Agent{}), do: {:ok, nil}

  defp prepare_deliverable_webhook_delivery(%Message{}, %Agent{}, true), do: {:ok, nil}

  defp prepare_deliverable_webhook_delivery(%Message{} = message, %Agent{} = recipient, false) do
    prepare_trusted_webhook_delivery(message, recipient)
  end

  defp valid_lease_seconds?(seconds), do: is_integer(seconds) and seconds > 0

  defp validate_lease_seconds(seconds) do
    if valid_lease_seconds?(seconds), do: :ok, else: {:error, :invalid_lease}
  end

  defp claim_locked_webhook_delivery!(delivery_id, now, lease_seconds) do
    case locked_webhook_delivery(delivery_id) do
      nil ->
        Repo.rollback(:not_found)

      %Delivery{} = delivery ->
        claim_or_terminalize_webhook_delivery!(delivery, now, lease_seconds)
    end
  end

  defp finish_locked_webhook_delivery!(delivery_id, claim, result, now) do
    case fetch_locked_webhook_claim_delivery(delivery_id) do
      nil ->
        Repo.rollback(:stale_delivery_claim)

      %Delivery{} = delivery ->
        finish_validated_webhook_delivery!(delivery, claim, result, now)
    end
  end

  defp finish_validated_webhook_delivery!(delivery, claim, result, now) do
    case validate_webhook_delivery_claim(delivery, claim, result, now) do
      :ok ->
        insert_claimed_webhook_attempt!(claim, result)
        update_claimed_webhook_delivery!(delivery, result)
        update_claimed_webhook_message!(delivery.message, result)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp terminalize_locked_webhook_delivery!(delivery_id, claim, reason, now) do
    case fetch_locked_webhook_claim_delivery(delivery_id) do
      nil ->
        Repo.rollback(:stale_delivery_claim)

      %Delivery{} = delivery ->
        terminalize_validated_webhook_delivery!(delivery, claim, reason, now)
    end
  end

  defp terminalize_validated_webhook_delivery!(delivery, claim, reason, now) do
    case validate_webhook_terminal_claim(delivery, claim, reason, now) do
      :ok ->
        terminalize_claimed_webhook_delivery!(delivery, reason, now)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp claim_next_due_webhook_delivery!(now, lease_seconds) do
    case Repo.one(claimable_webhook_delivery_query(now)) do
      nil ->
        nil

      %Delivery{} = delivery ->
        case claim_or_terminalize_webhook_delivery!(delivery, now, lease_seconds) do
          %DeliveryClaim{} = claim -> claim
          %Message{} -> nil
        end
    end
  end

  defp locked_webhook_delivery(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id and delivery.mode == "webhook")
    |> lock("FOR UPDATE")
    |> preload([:message, :recipient_agent])
    |> Repo.one()
  end

  defp claimable_webhook_delivery_query(now) do
    Delivery
    |> join(:inner, [delivery], message in assoc(delivery, :message), as: :message)
    |> where([delivery], delivery.mode == "webhook")
    |> where(^due_webhook_delivery_filter(now))
    |> where(^webhook_session_order_filter())
    |> order_by([delivery], asc: delivery.inserted_at)
    |> limit(1)
    |> lock("FOR UPDATE SKIP LOCKED")
  end

  defp due_webhook_delivery_filter(now) do
    dynamic(
      [delivery],
      (delivery.status == "retry_scheduled" and
         (is_nil(delivery.next_attempt_at) or delivery.next_attempt_at <= ^now)) or
        (delivery.status == "leased" and not is_nil(delivery.leased_until) and
           delivery.leased_until <= ^now)
    )
  end

  defp webhook_session_order_filter do
    dynamic(
      [message: message],
      is_nil(message.session_id) or is_nil(message.session_sequence) or
        not exists(
          from(prior_delivery in Delivery,
            join: prior_message in Message,
            on: prior_message.id == prior_delivery.message_id,
            where: prior_delivery.mode == "webhook",
            where: prior_delivery.status not in ["delivered", "failed"],
            where: prior_message.session_id == parent_as(:message).session_id,
            where: prior_message.session_sequence < parent_as(:message).session_sequence,
            select: 1
          )
        )
    )
  end

  defp claim_or_terminalize_webhook_delivery!(
         %Delivery{} = delivery,
         %DateTime{} = now,
         lease_seconds
       ) do
    delivery = Repo.preload(delivery, :message)

    cond do
      delivery.status in ["delivered", "failed"] ->
        delivery.message

      active_webhook_claim?(delivery, now) ->
        Repo.rollback(:delivery_in_progress)

      acked?(delivery.message) ->
        stop_delivery_after_ack!(delivery)

      expired?(delivery.message, now) ->
        expire_delivery!(delivery, now)

      true ->
        claim_webhook_delivery!(delivery, now, lease_seconds)
    end
  end

  defp active_webhook_claim?(
         %Delivery{status: "leased", leased_until: %DateTime{} = leased_until},
         now
       ) do
    DateTime.compare(leased_until, now) == :gt
  end

  defp active_webhook_claim?(%Delivery{}, _now), do: false

  defp acked?(%Message{current_ack_status: status}), do: not is_nil(status)

  defp expired?(%Message{expires_at: %DateTime{} = expires_at}, now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp claim_webhook_delivery!(%Delivery{} = delivery, now, lease_seconds) do
    claim_token = ID.generate("dcl")
    leased_until = DateTime.add(now, lease_seconds, :second)
    attempt_number = delivery.attempt_count + 1

    claimed_delivery =
      delivery
      |> Ecto.Changeset.change(
        status: "leased",
        claim_token: claim_token,
        claimed_at: now,
        leased_until: leased_until
      )
      |> Repo.update!()
      |> Repo.preload([:message, :recipient_agent], force: true)

    %DeliveryClaim{
      delivery: claimed_delivery,
      message: claimed_delivery.message,
      recipient_agent: claimed_delivery.recipient_agent,
      claim_token: claim_token,
      leased_until: leased_until,
      attempt_number: attempt_number
    }
  end

  defp stop_delivery_after_ack!(%Delivery{message: %Message{} = message} = delivery) do
    delivery
    |> Ecto.Changeset.change(
      status: "failed",
      claim_token: nil,
      claimed_at: nil,
      leased_until: nil,
      next_attempt_at: nil,
      last_error: "message_acked"
    )
    |> Repo.update!()

    message
  end

  defp expire_delivery!(%Delivery{message: %Message{} = message} = delivery, now) do
    delivery
    |> Ecto.Changeset.change(
      status: "failed",
      claim_token: nil,
      claimed_at: nil,
      leased_until: nil,
      next_attempt_at: nil,
      last_error: "message_expired"
    )
    |> Repo.update!()

    Message
    |> where([persisted_message], persisted_message.id == ^message.id)
    |> where([persisted_message], persisted_message.carrier_status != "delivered")
    |> Repo.update_all(set: [carrier_status: "expired", terminal_at: now, updated_at: now])

    Repo.get!(Message, message.id)
  end

  defp fetch_locked_webhook_claim_delivery(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> where([delivery], delivery.mode == "webhook")
    |> join(:inner, [delivery], message in assoc(delivery, :message))
    |> preload([_delivery, message], message: message)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp validate_webhook_delivery_claim(
         %Delivery{} = delivery,
         %DeliveryClaim{} = claim,
         %AttemptResult{} = result,
         now
       ) do
    with :ok <- validate_webhook_delivery_claim(delivery, claim, now) do
      if result.attempt_number == claim.attempt_number do
        :ok
      else
        {:error, :stale_delivery_claim}
      end
    end
  end

  defp validate_webhook_delivery_claim(
         %Delivery{} = delivery,
         %DeliveryClaim{} = claim,
         now
       ) do
    cond do
      delivery.id != claim.delivery.id ->
        {:error, :stale_delivery_claim}

      delivery.message_id != claim.message.id ->
        {:error, :stale_delivery_claim}

      delivery.recipient_agent_id != claim.recipient_agent.id ->
        {:error, :stale_delivery_claim}

      delivery.status != "leased" ->
        {:error, :stale_delivery_claim}

      delivery.claim_token != claim.claim_token ->
        {:error, :stale_delivery_claim}

      not current_webhook_claim_lease?(delivery, claim, now) ->
        {:error, :stale_delivery_claim}

      true ->
        :ok
    end
  end

  defp validate_webhook_terminal_claim(delivery, claim, reason, now) do
    case validate_webhook_delivery_claim(delivery, claim, now) do
      :ok -> validate_webhook_terminal_reason(delivery.message, reason, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_webhook_terminal_reason(%Message{} = message, :message_acked, _now) do
    if acked?(message), do: :ok, else: {:error, :stale_delivery_claim}
  end

  defp validate_webhook_terminal_reason(%Message{} = message, :message_expired, now) do
    if expired?(message, now), do: :ok, else: {:error, :stale_delivery_claim}
  end

  defp current_webhook_claim_lease?(
         %Delivery{leased_until: %DateTime{} = leased_until},
         %DeliveryClaim{leased_until: %DateTime{} = claimed_leased_until},
         now
       ) do
    DateTime.compare(leased_until, claimed_leased_until) == :eq and
      DateTime.compare(leased_until, now) == :gt
  end

  defp current_webhook_claim_lease?(%Delivery{}, %DeliveryClaim{}, _now), do: false

  defp insert_claimed_webhook_attempt!(%DeliveryClaim{} = claim, %AttemptResult{} = result) do
    %WebhookAttempt{id: ID.generate("wha")}
    |> WebhookAttempt.changeset(%{
      delivery_id: claim.delivery.id,
      message_id: claim.message.id,
      recipient_agent_id: claim.recipient_agent.id,
      attempt_number: result.attempt_number,
      request_url: claim.recipient_agent.webhook_url,
      response_status: result.response_status,
      error: result.error,
      result: result.result,
      next_attempt_at: result.next_attempt_at
    })
    |> Repo.insert!()
  end

  defp update_claimed_webhook_delivery!(%Delivery{} = delivery, %AttemptResult{} = result) do
    delivery
    |> Ecto.Changeset.change(
      attempt_count: result.attempt_number,
      status: result.delivery_status,
      claim_token: nil,
      claimed_at: nil,
      leased_until: nil,
      next_attempt_at: result.next_attempt_at,
      delivered_at: result.delivered_at,
      last_error: result.error
    )
    |> Repo.update!()
  end

  defp terminalize_claimed_webhook_delivery!(
         %Delivery{} = delivery,
         :message_acked,
         _now
       ) do
    delivery
    |> Ecto.Changeset.change(
      status: "failed",
      claim_token: nil,
      claimed_at: nil,
      leased_until: nil,
      next_attempt_at: nil,
      last_error: "message_acked"
    )
    |> Repo.update!()

    delivery.message
  end

  defp terminalize_claimed_webhook_delivery!(
         %Delivery{message: %Message{} = message} = delivery,
         :message_expired,
         now
       ) do
    delivery
    |> Ecto.Changeset.change(
      status: "failed",
      claim_token: nil,
      claimed_at: nil,
      leased_until: nil,
      next_attempt_at: nil,
      last_error: "message_expired"
    )
    |> Repo.update!()

    Message
    |> where([persisted_message], persisted_message.id == ^message.id)
    |> where([persisted_message], persisted_message.carrier_status != "delivered")
    |> Repo.update_all(set: [carrier_status: "expired", terminal_at: now, updated_at: now])

    Repo.get!(Message, message.id)
  end

  defp update_claimed_webhook_message!(%Message{} = message, %AttemptResult{
         message_status: message_status
       }) do
    now = DateTime.utc_now(:microsecond)

    Message
    |> where([persisted_message], persisted_message.id == ^message.id)
    |> where([persisted_message], persisted_message.carrier_status != "delivered")
    |> Repo.update_all(set: [carrier_status: message_status, updated_at: now])

    Repo.get!(Message, message.id)
  end
end
