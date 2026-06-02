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
    Ack,
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
  @default_polling_lease_seconds 60
  @default_webhook_claim_lease_seconds 60
  @ack_statuses ~w(accepted completed failed rejected)
  @terminal_ack_statuses ~w(completed failed rejected)

  @typep ack_flow :: :delivery | :session_lifecycle

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
  @spec preflight_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.session_message_preflight_result()
  def preflight_session_message(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    with {:ok, _payload} <- fetch_session_message_payload(params),
         :ok <- Idempotency.preflight(sender, route, idempotency_key, params) do
      validate_session_message_sender(sender, session_id)
    end
  end

  @impl DurableLedger
  @spec send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.session_intake_result()
  def send_session_message(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    with {:ok, payload} <- fetch_session_message_payload(params) do
      sender
      |> Idempotency.run_prepared_after_commit(
        route,
        idempotency_key,
        params,
        fn -> persist_session_message_send(sender, session_id, payload) end
      )
    end
  end

  @impl DurableLedger
  @spec accept_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.session_lifecycle_result()
  def accept_session(%Agent{} = recipient, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    recipient
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, payload} <- fetch_optional_payload(params),
           :ok <- Payload.validate_optional_a2a(payload) do
        persist_session_accept(recipient, session_id, payload)
      end
    end)
  end

  @impl DurableLedger
  @spec reject_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.session_lifecycle_result()
  def reject_session(%Agent{} = recipient, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) and is_binary(route) do
    recipient
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, payload} <- fetch_optional_payload(params),
           :ok <- Payload.validate_optional_a2a(payload) do
        persist_session_reject(recipient, session_id, payload)
      end
    end)
  end

  @impl DurableLedger
  @spec ack_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.ack_result()
  def ack_delivery(%Agent{} = recipient, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) and is_binary(route) do
    recipient
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, ack_status} <- fetch_ack_status(params),
           {:ok, payload} <- fetch_optional_payload(params),
           :ok <- Payload.validate_optional_a2a(payload) do
        append_ack(recipient, delivery_id, ack_status, payload, :delivery)
      end
    end)
  end

  @impl DurableLedger
  @spec claim_inbox(Agent.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.polling_lease_result()
  def claim_inbox(%Agent{} = recipient, params, idempotency_key, route)
      when is_map(params) and is_binary(route) do
    recipient
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, lease_seconds} <- fetch_polling_lease_seconds(params) do
        claim_next_polling_message(recipient, lease_seconds)
      end
    end)
  end

  @impl DurableLedger
  @spec extend_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          DurableLedger.polling_lease_result()
  def extend_delivery(%Agent{} = recipient, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) and is_binary(route) do
    recipient
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, lease_seconds} <- fetch_polling_lease_seconds(params) do
        extend_active_polling_delivery(recipient, delivery_id, lease_seconds)
      end
    end)
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
      prepared_session_intake_response(body, session, webhook_delivery_id)
    end
  end

  defp persist_session_message_send(%Agent{} = sender, session_id, payload) do
    with {:ok, session} <- fetch_locked_participant_session(sender, session_id),
         :ok <- ensure_session_open(session),
         {:ok, recipient} <- fetch_session_recipient(sender, session),
         {trust, blocked?} <- SenderPolicies.resolve(sender, recipient),
         :ok <-
           SenderPolicies.enforce_unknown_sender_rate_limit(
             sender,
             recipient,
             trust,
             blocked?
           ),
         {:ok, message, updated_session} <-
           insert_next_session_message(sender, recipient, session, trust, blocked?, payload),
         {:ok, webhook_delivery_id} <-
           prepare_deliverable_webhook_delivery(message, recipient, blocked?) do
      body = Response.session_message(updated_session, message, sender)
      prepared_session_intake_response(body, updated_session, webhook_delivery_id)
    end
  end

  defp persist_session_accept(%Agent{} = recipient, session_id, payload) do
    with {:ok, delivery_id} <- ensure_session_lifecycle_delivery(recipient, session_id) do
      append_session_lifecycle_ack(recipient, delivery_id, "accepted", payload)
    end
  end

  defp persist_session_reject(%Agent{} = recipient, session_id, payload) do
    with {:ok, delivery_id} <- ensure_session_lifecycle_delivery(recipient, session_id) do
      append_session_lifecycle_ack(recipient, delivery_id, "rejected", payload)
    end
  end

  defp claim_next_polling_message(%Agent{} = recipient, lease_seconds) do
    Repo.transaction(fn ->
      claim_next_polling_message!(recipient, lease_seconds)
    end)
    |> unwrap_polling_transaction_result()
  end

  defp claim_next_polling_message!(%Agent{} = recipient, lease_seconds) do
    now = DateTime.utc_now(:microsecond)

    case Repo.one(claimable_polling_message_query(recipient, now)) do
      nil ->
        {200, %{"delivery" => nil}}

      %Message{} = message ->
        case claim_polling_message!(message.id, recipient, lease_seconds) do
          :retry -> claim_next_polling_message!(recipient, lease_seconds)
          result -> result
        end
    end
  end

  defp claimable_polling_message_query(%Agent{} = recipient, now) do
    active_delivery_message_ids =
      from(delivery in Delivery,
        where:
          delivery.recipient_agent_id == ^recipient.id and delivery.status == "leased" and
            delivery.leased_until > ^now,
        select: delivery.message_id
      )

    from(message in Message,
      as: :message,
      where: message.recipient_agent_id == ^recipient.id,
      where: message.carrier_status in ["queued", "delivered"],
      where: is_nil(message.current_ack_status),
      where: message.expires_at > ^now,
      where: message.id not in subquery(active_delivery_message_ids),
      where: ^polling_session_order_filter(now),
      order_by: [asc: message.inserted_at],
      limit: 1
    )
  end

  defp polling_session_order_filter(now) do
    dynamic(
      [message: message],
      is_nil(message.session_id) or is_nil(message.session_sequence) or
        not exists(
          from(prior_message in Message,
            left_join: active_delivery in Delivery,
            on:
              active_delivery.message_id == prior_message.id and
                active_delivery.mode == "polling" and
                active_delivery.status == "leased" and
                active_delivery.leased_until > ^now,
            where: prior_message.session_id == parent_as(:message).session_id,
            where: prior_message.session_sequence < parent_as(:message).session_sequence,
            where: prior_message.carrier_status in ["queued", "delivered"],
            where: is_nil(prior_message.current_ack_status),
            where: prior_message.expires_at > ^now,
            where: is_nil(active_delivery.id),
            select: 1
          )
        )
    )
  end

  defp insert_polling_delivery!(%Message{} = message, %Agent{} = recipient, lease_until) do
    %Delivery{id: ID.generate("dlv")}
    |> Delivery.changeset(%{
      message_id: message.id,
      recipient_agent_id: recipient.id,
      mode: "polling",
      status: "leased",
      leased_until: lease_until
    })
    |> Repo.insert!()
  end

  defp claim_polling_message!(message_id, %Agent{} = recipient, lease_seconds) do
    lock_polling_deliveries_for_message!(message_id)

    case lock_polling_message(message_id) do
      nil ->
        :retry

      %Message{} = message ->
        claim_locked_polling_message!(message, recipient, lease_seconds)
    end
  end

  defp lock_polling_deliveries_for_message!(message_id) do
    Delivery
    |> where([delivery], delivery.message_id == ^message_id)
    |> where([delivery], delivery.mode == "polling")
    |> order_by([delivery], asc: delivery.inserted_at)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp lock_polling_message(message_id) do
    Message
    |> where([message], message.id == ^message_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp claim_locked_polling_message!(%Message{} = message, %Agent{} = recipient, lease_seconds) do
    now = DateTime.utc_now(:microsecond)

    cond do
      not claimable_polling_message?(message, recipient, now) ->
        :retry

      active_polling_delivery?(message, recipient, now) ->
        :retry

      true ->
        lease_until = DateTime.add(now, lease_seconds, :second)
        delivery = insert_polling_delivery!(message, recipient, lease_until)
        delivered_message = mark_polling_message_delivered!(message)

        {201, Response.delivery_claim(delivery, delivered_message)}
    end
  end

  defp claimable_polling_message?(%Message{} = message, %Agent{} = recipient, now) do
    message.recipient_agent_id == recipient.id and
      message.carrier_status in ["queued", "delivered"] and
      is_nil(message.current_ack_status) and
      DateTime.compare(message.expires_at, now) == :gt
  end

  defp active_polling_delivery?(%Message{} = message, %Agent{} = recipient, now) do
    Delivery
    |> where([delivery], delivery.message_id == ^message.id)
    |> where([delivery], delivery.recipient_agent_id == ^recipient.id)
    |> where([delivery], delivery.status == "leased")
    |> where([delivery], delivery.leased_until > ^now)
    |> Repo.exists?()
  end

  defp mark_polling_message_delivered!(%Message{} = message) do
    message
    |> Ecto.Changeset.change(carrier_status: "delivered")
    |> Repo.update!()
  end

  defp extend_active_polling_delivery(%Agent{} = recipient, delivery_id, lease_seconds) do
    delivery = locked_extension_delivery(recipient, delivery_id)

    now = DateTime.utc_now(:microsecond)

    cond do
      is_nil(delivery) ->
        {:error, :not_found}

      delivery.mode != "polling" or delivery.status != "leased" or is_nil(delivery.leased_until) ->
        {:error, :invalid_lease}

      DateTime.compare(delivery.leased_until, now) != :gt ->
        {:error, :lease_expired}

      true ->
        updated_delivery =
          delivery
          |> Ecto.Changeset.change(
            leased_until: DateTime.add(delivery.leased_until, lease_seconds, :second)
          )
          |> Repo.update!()

        {:ok, 200, Response.delivery_claim(updated_delivery, delivery.message)}
    end
  end

  defp locked_extension_delivery(%Agent{} = recipient, delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> where([delivery], delivery.recipient_agent_id == ^recipient.id)
    |> lock("FOR UPDATE")
    |> preload(:message)
    |> Repo.one()
  end

  defp unwrap_polling_transaction_result({:ok, {:commit_error, reason}}),
    do: {:commit_error, reason}

  defp unwrap_polling_transaction_result({:ok, {status, body}}), do: {:ok, status, body}
  defp unwrap_polling_transaction_result({:error, reason}), do: {:error, reason}

  defp prepared_session_intake_response(body, %Session{}, nil), do: {:ok, 201, body}

  defp prepared_session_intake_response(body, %Session{id: session_id}, webhook_delivery_id) do
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

  defp fetch_optional_payload(params), do: {:ok, Map.get(params, "payload")}

  defp fetch_ack_status(%{"status" => status}) when status in @ack_statuses, do: {:ok, status}
  defp fetch_ack_status(%{"status" => _status}), do: {:error, :invalid_ack_status}
  defp fetch_ack_status(_params), do: {:error, :ack_status_required}

  defp fetch_polling_lease_seconds(params) do
    case Map.get(params, "lease_seconds", @default_polling_lease_seconds) do
      seconds when is_integer(seconds) and seconds >= 0 ->
        {:ok, seconds}

      _other ->
        {:error, :invalid_lease}
    end
  end

  defp fetch_session_message_payload(params) do
    with {:ok, payload} <- fetch_payload(params),
         :ok <- Payload.validate_a2a(payload) do
      {:ok, payload}
    end
  end

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

  defp fetch_locked_participant_session(%Agent{} = agent, session_id) do
    query =
      from(session in Session,
        where: session.id == ^session_id,
        where: session.initiator_agent_id == ^agent.id or session.recipient_agent_id == ^agent.id,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  defp validate_session_message_sender(%Agent{} = sender, session_id) do
    case Repo.get(Session, session_id) do
      %Session{initiator_agent_id: agent_id, status: "open"} when agent_id == sender.id ->
        :ok

      %Session{recipient_agent_id: agent_id, status: "open"} when agent_id == sender.id ->
        :ok

      %Session{initiator_agent_id: agent_id} when agent_id == sender.id ->
        {:error, :session_not_open}

      %Session{recipient_agent_id: agent_id} when agent_id == sender.id ->
        {:error, :session_not_open}

      _other ->
        {:error, :not_found}
    end
  end

  defp ensure_session_open(%Session{status: "open"}), do: :ok
  defp ensure_session_open(%Session{}), do: {:error, :session_not_open}

  defp fetch_session_recipient(%Agent{id: id}, %Session{initiator_agent_id: id} = session) do
    session.recipient_agent_id
    |> fetch_active_agent_by_id()
    |> normalize_session_recipient()
  end

  defp fetch_session_recipient(%Agent{id: id}, %Session{recipient_agent_id: id} = session) do
    session.initiator_agent_id
    |> fetch_active_agent_by_id()
    |> normalize_session_recipient()
  end

  defp fetch_active_agent_by_id(agent_id) do
    Repo.get_by(Agent, id: agent_id, status: "active")
  end

  defp normalize_session_recipient(%Agent{} = recipient), do: {:ok, recipient}
  defp normalize_session_recipient(nil), do: {:error, :recipient_not_found}

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

  defp insert_next_session_message(
         %Agent{} = sender,
         %Agent{} = recipient,
         %Session{} = session,
         trust,
         blocked?,
         payload
       ) do
    next_sequence = session.last_sequence + 1

    with {:ok, message} <-
           insert_session_message(sender, recipient, trust, blocked?, payload, %{
             session_id: session.id,
             session_sequence: next_sequence
           }),
         {:ok, updated_session} <-
           session
           |> Session.changeset(%{last_sequence: next_sequence})
           |> Repo.update() do
      {:ok, message, updated_session}
    end
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

  defp ensure_session_lifecycle_delivery(%Agent{} = agent, session_id) do
    with {:ok, opening_message_id} <- opening_message_id_for_session_lifecycle(agent, session_id) do
      now = DateTime.utc_now(:microsecond)

      case fetch_ackable_delivery(agent, opening_message_id, now) do
        %Delivery{id: delivery_id} -> {:ok, delivery_id}
        nil -> insert_session_action_delivery(agent, opening_message_id, now)
      end
    end
  end

  defp opening_message_id_for_session_lifecycle(%Agent{} = agent, session_id) do
    case Repo.get(Session, session_id) do
      %Session{recipient_agent_id: agent_id, status: "pending", opening_message_id: message_id}
      when agent_id == agent.id and is_binary(message_id) ->
        {:ok, message_id}

      %Session{recipient_agent_id: agent_id} when agent_id == agent.id ->
        {:error, :invalid_ack_transition}

      _other ->
        {:error, :not_found}
    end
  end

  defp fetch_ackable_delivery(%Agent{} = agent, opening_message_id, now) do
    Delivery
    |> where(
      [delivery],
      delivery.message_id == ^opening_message_id and delivery.recipient_agent_id == ^agent.id
    )
    |> where(^ackable_delivery_filter(now))
    |> order_by([delivery], desc: delivery.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp ackable_delivery_filter(now) do
    dynamic(
      [delivery],
      (delivery.mode == "polling" and delivery.status == "leased" and
         not is_nil(delivery.leased_until) and delivery.leased_until > ^now) or
        (delivery.mode == "webhook" and delivery.status == "delivered")
    )
  end

  defp insert_session_action_delivery(%Agent{} = agent, opening_message_id, now) do
    lease_until = DateTime.add(now, @default_polling_lease_seconds, :second)

    %Delivery{id: ID.generate("dlv")}
    |> Delivery.changeset(%{
      message_id: opening_message_id,
      recipient_agent_id: agent.id,
      mode: "polling",
      status: "leased",
      leased_until: lease_until
    })
    |> Repo.insert()
    |> case do
      {:ok, %Delivery{id: delivery_id}} -> {:ok, delivery_id}
      {:error, _changeset} -> {:error, :invalid_ack_transition}
    end
  end

  defp append_session_lifecycle_ack(%Agent{} = agent, delivery_id, ack_status, payload)
       when ack_status in ~w(accepted rejected) do
    append_ack(agent, delivery_id, ack_status, payload, :session_lifecycle)
  end

  @spec append_ack(Agent.t(), String.t(), String.t(), map() | nil, ack_flow()) ::
          DurableLedger.ack_result()
  defp append_ack(%Agent{} = agent, delivery_id, ack_status, payload, ack_flow)
       when is_binary(delivery_id) and ack_flow in [:delivery, :session_lifecycle] do
    now = DateTime.utc_now(:microsecond)

    case fetch_locked_delivery(agent, delivery_id) do
      nil ->
        {:error, :not_found}

      %Delivery{} = delivery ->
        persist_ack(agent, delivery, ack_status, payload, now, ack_flow)
    end
  end

  @spec persist_ack(Agent.t(), Delivery.t(), String.t(), map() | nil, DateTime.t(), ack_flow()) ::
          DurableLedger.ack_result()
  defp persist_ack(
         %Agent{} = agent,
         %Delivery{} = delivery,
         ack_status,
         payload,
         now,
         ack_flow
       ) do
    with :ok <- validate_ack_lease(ack_flow, delivery, now),
         :ok <-
           validate_ack_transition(ack_flow, delivery.message.current_ack_status, ack_status),
         {:ok, opening_session} <- lock_opening_session(delivery.message),
         :ok <- expire_due_opening_session(opening_session, delivery.message, now),
         :ok <- validate_opening_session_ack(ack_flow, opening_session, ack_status),
         {:ok, delivery} <- mark_acked_delivery_delivered(delivery, now),
         {:ok, ack} <- insert_ack(delivery, ack_status, payload),
         {:ok, message} <- cache_ack_status(delivery.message, ack_status, now),
         {:ok, session} <- cache_opening_session_ack(ack_flow, opening_session, ack_status, now) do
      ack_response(ack_flow, agent, ack, message, session)
    else
      {:commit_error, reason} -> {:commit_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ack_response(:delivery, %Agent{} = agent, %Ack{} = ack, %Message{} = message, _session) do
    {:ok, 201, Response.ack(agent, ack, message)}
  end

  defp ack_response(
         :session_lifecycle,
         %Agent{} = agent,
         %Ack{} = ack,
         %Message{} = message,
         %Session{} = session
       ) do
    body =
      agent
      |> Response.ack(ack, message)
      |> Map.put("session", Response.session(session))

    {:ok, 201, body}
  end

  defp fetch_locked_delivery(%Agent{} = agent, delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> where([delivery], delivery.recipient_agent_id == ^agent.id)
    |> join(:inner, [delivery], message in assoc(delivery, :message))
    |> preload([_delivery, message], message: message)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp validate_ack_lease(
         :delivery,
         %Delivery{message: %Message{current_ack_status: "accepted"}},
         _now
       ) do
    :ok
  end

  defp validate_ack_lease(_ack_flow, %Delivery{mode: "webhook", status: "delivered"}, _now),
    do: :ok

  defp validate_ack_lease(_ack_flow, %Delivery{mode: "webhook"}, _now) do
    {:error, :delivery_not_delivered}
  end

  defp validate_ack_lease(
         _ack_flow,
         %Delivery{mode: "polling", leased_until: %DateTime{} = leased_until},
         now
       ) do
    if DateTime.compare(leased_until, now) == :gt do
      :ok
    else
      {:error, :lease_expired}
    end
  end

  defp validate_ack_transition(_ack_flow, nil, _next_status), do: :ok

  defp validate_ack_transition(_ack_flow, current_status, _next_status)
       when current_status in @terminal_ack_statuses do
    {:error, :terminal_ack_status}
  end

  defp validate_ack_transition(:session_lifecycle, "accepted", _next_status) do
    {:error, :invalid_ack_transition}
  end

  defp validate_ack_transition(:delivery, "accepted", next_status)
       when next_status in ~w(completed failed) do
    :ok
  end

  defp validate_ack_transition(:delivery, "accepted", _next_status),
    do: {:error, :invalid_ack_transition}

  defp lock_opening_session(%Message{session_id: nil}), do: {:ok, nil}

  defp lock_opening_session(%Message{} = message) do
    query =
      from(session in Session,
        where: session.id == ^message.session_id,
        where: session.opening_message_id == ^message.id,
        lock: "FOR UPDATE"
      )

    {:ok, Repo.one(query)}
  end

  defp expire_due_opening_session(
         %Session{status: "pending"} = session,
         %Message{expires_at: %DateTime{} = expires_at} = message,
         now
       ) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:ok, _message} = expire_opening_message(message, now)
      {:ok, _session} = fail_pending_opening_session(session, now)

      {:commit_error, :message_expired}
    end
  end

  defp expire_due_opening_session(%Session{}, %Message{}, _now), do: :ok
  defp expire_due_opening_session(nil, %Message{}, _now), do: :ok

  defp expire_opening_message(%Message{carrier_status: status} = message, now)
       when status in ~w(queued delivered delivery_failed) do
    message
    |> Ecto.Changeset.change(carrier_status: "expired", terminal_at: now)
    |> Repo.update()
  end

  defp expire_opening_message(%Message{} = message, _now), do: {:ok, message}

  defp fail_pending_opening_session(%Session{status: "pending"} = session, now) do
    terminalize_pending_opening_session(session, "failed", now)
  end

  defp terminalize_pending_opening_session(%Session{status: "pending"} = session, status, now)
       when status in ~w(failed rejected) do
    session
    |> Session.changeset(%{status: status, terminal_at: now})
    |> Repo.update()
  end

  defp validate_opening_session_ack(:session_lifecycle, %Session{status: "pending"}, _ack_status),
    do: :ok

  defp validate_opening_session_ack(:session_lifecycle, %Session{}, _ack_status),
    do: {:error, :invalid_ack_transition}

  defp validate_opening_session_ack(:session_lifecycle, nil, _ack_status),
    do: {:error, :invalid_ack_transition}

  defp validate_opening_session_ack(:delivery, nil, _ack_status), do: :ok

  defp validate_opening_session_ack(:delivery, %Session{status: "pending"}, "completed") do
    {:error, :invalid_ack_transition}
  end

  defp validate_opening_session_ack(:delivery, %Session{status: "pending"}, _ack_status), do: :ok

  defp validate_opening_session_ack(:delivery, %Session{}, _ack_status) do
    {:error, :invalid_ack_transition}
  end

  defp mark_acked_delivery_delivered(%Delivery{mode: "polling", status: "leased"} = delivery, now) do
    delivery
    |> Ecto.Changeset.change(status: "delivered", delivered_at: now)
    |> Repo.update()
  end

  defp mark_acked_delivery_delivered(%Delivery{} = delivery, _now), do: {:ok, delivery}

  defp insert_ack(%Delivery{} = delivery, ack_status, payload) do
    %Ack{id: ID.generate("ack")}
    |> Ack.changeset(%{
      message_id: delivery.message_id,
      delivery_id: delivery.id,
      recipient_agent_id: delivery.recipient_agent_id,
      status: ack_status,
      payload: payload
    })
    |> Repo.insert()
  end

  defp cache_ack_status(%Message{} = message, ack_status, now) do
    message
    |> Ecto.Changeset.change(
      carrier_status: delivered_carrier_status(message),
      current_ack_status: ack_status,
      terminal_at: terminal_ack_timestamp(ack_status, now)
    )
    |> Repo.update()
  end

  defp delivered_carrier_status(%Message{carrier_status: status})
       when status in ~w(queued delivery_failed) do
    "delivered"
  end

  defp delivered_carrier_status(%Message{carrier_status: status}), do: status

  defp terminal_ack_timestamp(status, now) when status in @terminal_ack_statuses, do: now
  defp terminal_ack_timestamp(_status, _now), do: nil

  defp cache_opening_session_ack(:delivery, nil, _ack_status, _now), do: {:ok, nil}

  defp cache_opening_session_ack(
         _ack_flow,
         %Session{status: "pending"} = session,
         "accepted",
         now
       ) do
    session
    |> Session.changeset(%{status: "open", opened_at: now})
    |> Repo.update()
  end

  defp cache_opening_session_ack(_ack_flow, %Session{status: "pending"} = session, status, now)
       when status in ~w(rejected failed) do
    terminalize_pending_opening_session(session, status, now)
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
