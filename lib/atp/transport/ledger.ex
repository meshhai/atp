defmodule Atp.Transport.Ledger do
  @moduledoc """
  Durable ATP carrier operations for messages, sessions, polling leases, and status reads.

  This module owns the current Postgres-backed implementation. The public
  `Atp.Transport` facade and runtime seam delegate here until later runtime
  slices move active session ownership into supervised processes.
  """

  import Ecto.Query

  alias Atp.Identity.{Agent, ID, Idempotency}
  alias Atp.Repo

  alias Atp.Transport.{
    Ack,
    Delivery,
    Message,
    Payload,
    Response,
    SenderPolicies,
    Session,
    WebhookDelivery
  }

  @default_message_ttl_seconds 7 * 24 * 60 * 60
  @default_lease_seconds 60
  @terminal_ack_statuses ~w(completed failed rejected)
  @ack_statuses ~w(accepted completed failed rejected)

  @type api_result :: {:ok, pos_integer(), map()} | {:error, term()}
  @type prepared_api_result ::
          {:ok, pos_integer(), map(), Idempotency.prepared_after_commit() | nil}
          | {:error, term()}

  @spec send_message(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  def send_message(%Agent{} = sender, params, idempotency_key, route) when is_map(params) do
    with {:ok, recipient_address} <- fetch_to_address(params),
         {:ok, payload} <- fetch_payload(params),
         :ok <- Payload.validate_a2a(payload) do
      sender
      |> Idempotency.run_after_commit(
        route,
        idempotency_key,
        params,
        fn -> persist_message_send(sender, recipient_address, payload) end,
        fn status, body, webhook_delivery_id ->
          finish_prepared_webhook_delivery(sender, status, body, webhook_delivery_id)
        end
      )
    end
  end

  @spec open_session(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  def open_session(%Agent{} = initiator, params, idempotency_key, route) when is_map(params) do
    with {:ok, recipient_address} <- fetch_to_address(params),
         {:ok, payload} <- fetch_payload(params),
         :ok <- Payload.validate_a2a(payload) do
      initiator
      |> Idempotency.run_after_commit(
        route,
        idempotency_key,
        params,
        fn -> persist_session_open(initiator, recipient_address, payload) end,
        fn status, body, commit_value ->
          finish_prepared_session_webhook_delivery(initiator, status, body, commit_value)
        end
      )
    end
  end

  @spec send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  def send_session_message(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) do
    with {:ok, status, body, prepared} <-
           prepare_session_message_send(sender, session_id, params, idempotency_key, route) do
      finish_prepared_session_message_send(sender, status, body, prepared)
    end
  end

  defp persist_message_send(%Agent{} = sender, recipient_address, payload) do
    with {:ok, recipient, trust, blocked?} <- fetch_recipient(sender, recipient_address),
         :ok <-
           SenderPolicies.enforce_unknown_sender_rate_limit(
             sender,
             recipient,
             trust,
             blocked?
           ),
         {:ok, message} <- insert_message(sender, recipient, trust, blocked?, payload),
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
      {:ok, 201, Response.session_message(session, message, initiator),
       {session.id, webhook_delivery_id}}
    end
  end

  @doc false
  @spec prepare_session_message_send(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          prepared_api_result()
  def prepare_session_message_send(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) do
    with {:ok, payload} <- fetch_session_message_payload(params) do
      sender
      |> Idempotency.run_prepared_after_commit(
        route,
        idempotency_key,
        params,
        fn -> prepare_session_message_transaction(sender, session_id, payload) end
      )
    end
  end

  @doc false
  @spec finish_prepared_session_message_send(
          Agent.t(),
          pos_integer(),
          map(),
          Idempotency.prepared_after_commit() | nil
        ) :: api_result()
  def finish_prepared_session_message_send(%Agent{}, status, body, nil) do
    {:ok, status, body}
  end

  def finish_prepared_session_message_send(%Agent{} = viewer, _status, _body, prepared) do
    Idempotency.complete_prepared_after_commit(prepared, fn status, body, commit_value ->
      finish_prepared_session_webhook_delivery(viewer, status, body, commit_value)
    end)
  end

  defp prepare_session_message_transaction(sender, session_id, payload) do
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
      prepared_session_message_response(body, updated_session, webhook_delivery_id)
    end
  end

  defp prepared_session_message_response(body, %Session{}, nil), do: {:ok, 201, body}

  defp prepared_session_message_response(
         body,
         %Session{id: session_id},
         webhook_delivery_id
       ) do
    {:ok, 201, body, {session_id, webhook_delivery_id}}
  end

  @doc false
  @spec preflight_idempotency(Agent.t(), String.t(), String.t() | nil, map()) ::
          :ok | api_result() | {:error, term()}
  def preflight_idempotency(%Agent{} = agent, route, idempotency_key, params)
      when is_binary(route) and is_map(params) do
    Idempotency.preflight(agent, route, idempotency_key, params)
  end

  @doc false
  @spec validate_session_message_params(map()) :: :ok | {:error, term()}
  def validate_session_message_params(params) when is_map(params) do
    case fetch_session_message_payload(params) do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec validate_session_message_sender(Agent.t(), String.t()) ::
          :ok | {:error, :not_found | :session_not_open}
  def validate_session_message_sender(%Agent{} = sender, session_id) when is_binary(session_id) do
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

  @spec get_session(Agent.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(%Agent{} = agent, session_id) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      %Session{} = session when session.initiator_agent_id == agent.id ->
        {:ok, %{"session" => Response.session(session)}}

      %Session{} = session when session.recipient_agent_id == agent.id ->
        {:ok, %{"session" => Response.session(session)}}

      _other ->
        {:error, :not_found}
    end
  end

  @spec fetch_open_session(String.t()) ::
          {:ok, Session.t()} | {:error, :not_found | :session_not_open}
  def fetch_open_session(session_id) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      %Session{status: "open"} = session -> {:ok, session}
      %Session{} -> {:error, :session_not_open}
      nil -> {:error, :not_found}
    end
  end

  @spec fetch_runtime_session(String.t()) ::
          {:ok, Session.t()} | {:error, :not_found | :session_not_active}
  def fetch_runtime_session(session_id) when is_binary(session_id) do
    case Session |> Repo.get(session_id) |> Repo.preload(:opening_message) do
      %Session{status: status} = session when status in ~w(pending open) ->
        {:ok, session}

      %Session{} ->
        {:error, :session_not_active}

      nil ->
        {:error, :not_found}
    end
  end

  @doc false
  @spec list_pending_session_ids() :: [String.t()]
  def list_pending_session_ids do
    Session
    |> where([session], session.status == "pending")
    |> where([session], not is_nil(session.opening_message_id))
    |> order_by([session], asc: session.inserted_at)
    |> select([session], session.id)
    |> Repo.all()
  end

  @spec expire_pending_opening_session(String.t(), DateTime.t()) ::
          {:ok, Session.t()}
          | {:error, :not_found | :opening_session_not_due | :session_not_pending}
  def expire_pending_opening_session(session_id, %DateTime{} = now) when is_binary(session_id) do
    Repo.transaction(fn ->
      with {:ok, message} <- lock_opening_message_for_session(session_id),
           {:ok, session} <- lock_pending_session_for_opening_message(session_id, message.id) do
        expire_locked_pending_opening_session(session, message, now)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Session{} = session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_opening_message_for_session(session_id) do
    Session
    |> where([session], session.id == ^session_id)
    |> select([session], %{
      status: session.status,
      opening_message_id: session.opening_message_id
    })
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      %{status: "pending", opening_message_id: opening_message_id}
      when is_binary(opening_message_id) ->
        lock_opening_message(opening_message_id)

      _session ->
        {:error, :session_not_pending}
    end
  end

  defp lock_opening_message(opening_message_id) do
    Message
    |> where([message], message.id == ^opening_message_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Message{} = message -> {:ok, message}
      nil -> {:error, :session_not_pending}
    end
  end

  defp lock_pending_session_for_opening_message(session_id, opening_message_id) do
    Session
    |> where([session], session.id == ^session_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      %Session{status: "pending", opening_message_id: ^opening_message_id} = session ->
        {:ok, session}

      %Session{} ->
        {:error, :session_not_pending}
    end
  end

  defp expire_locked_pending_opening_session(
         %Session{} = session,
         %Message{expires_at: expires_at} = message,
         now
       ) do
    if DateTime.compare(expires_at, now) == :gt do
      Repo.rollback(:opening_session_not_due)
    else
      {:ok, _message} = expire_opening_message(message, now)
      {:ok, expired_session} = fail_pending_opening_session(session, now)

      expired_session
    end
  end

  @doc false
  @spec opening_session_id_for_delivery(Agent.t(), String.t()) :: String.t() | nil
  def opening_session_id_for_delivery(%Agent{} = agent, delivery_id)
      when is_binary(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> where([delivery], delivery.recipient_agent_id == ^agent.id)
    |> join(:inner, [delivery], message in assoc(delivery, :message))
    |> join(:inner, [_delivery, message], session in Session,
      on: session.id == message.session_id and session.opening_message_id == message.id
    )
    |> select([_delivery, _message, session], session.id)
    |> Repo.one()
  end

  @spec get_message_status(Agent.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_message_status(%Agent{} = agent, message_id) when is_binary(message_id) do
    case Repo.get(Message, message_id) do
      %Message{} = message when message.sender_agent_id == agent.id ->
        {:ok, Response.message_status(message, agent)}

      %Message{} = message when message.recipient_agent_id == agent.id ->
        {:ok, Response.message_status(message, agent)}

      _other ->
        {:error, :not_found}
    end
  end

  @spec claim_inbox(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  def claim_inbox(%Agent{} = agent, params, idempotency_key, route) when is_map(params) do
    agent
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, lease_seconds} <- fetch_lease_seconds(params) do
        claim_next_message(agent, lease_seconds)
      end
    end)
  end

  @spec extend_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  def extend_delivery(%Agent{} = agent, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) do
    agent
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, lease_seconds} <- fetch_lease_seconds(params) do
        extend_active_delivery(agent, delivery_id, lease_seconds)
      end
    end)
  end

  @spec ack_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) :: api_result()
  def ack_delivery(%Agent{} = agent, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) do
    agent
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with {:ok, ack_status} <- fetch_ack_status(params),
           {:ok, payload} <- fetch_optional_payload(params),
           :ok <- Payload.validate_optional_a2a(payload) do
        append_ack(agent, delivery_id, ack_status, payload)
      end
    end)
  end

  @spec upsert_sender_policy(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  def upsert_sender_policy(%Agent{} = recipient, agent_id, params, idempotency_key, route)
      when is_binary(agent_id) and is_map(params) and is_binary(route) do
    recipient
    |> Idempotency.run(route, idempotency_key, params, fn ->
      with :ok <- ensure_own_agent(recipient, agent_id),
           {:ok, policy} <- SenderPolicies.upsert(recipient, params) do
        {:ok, 200, SenderPolicies.to_response(policy)}
      end
    end)
  end

  defp ensure_own_agent(%Agent{id: agent_id}, agent_id), do: :ok
  defp ensure_own_agent(%Agent{}, _agent_id), do: {:error, :not_found}

  defp fetch_to_address(%{"to" => address}) when is_binary(address) do
    case String.trim(address) do
      "" -> {:error, :recipient_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_to_address(_params), do: {:error, :recipient_required}

  defp fetch_payload(%{"payload" => payload}), do: {:ok, payload}
  defp fetch_payload(_params), do: {:error, :payload_required}

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
           insert_message(initiator, recipient, trust, blocked?, payload, %{
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

  defp insert_message(
         %Agent{} = sender,
         %Agent{} = recipient,
         trust,
         blocked?,
         payload,
         session_attrs \\ %{}
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
      session_id: Map.get(session_attrs, :session_id),
      session_sequence: Map.get(session_attrs, :session_sequence)
    })
    |> Repo.insert()
  end

  defp carrier_status(true), do: "rejected"
  defp carrier_status(false), do: "queued"

  defp terminal_timestamp(true, now), do: now
  defp terminal_timestamp(false, _now), do: nil

  defp fetch_lease_seconds(params) do
    case Map.get(params, "lease_seconds", @default_lease_seconds) do
      seconds when is_integer(seconds) and seconds >= 0 ->
        {:ok, seconds}

      _other ->
        {:error, :invalid_lease}
    end
  end

  defp fetch_ack_status(%{"status" => status}) when status in @ack_statuses, do: {:ok, status}
  defp fetch_ack_status(%{"status" => _status}), do: {:error, :invalid_ack_status}
  defp fetch_ack_status(_params), do: {:error, :ack_status_required}

  defp fetch_optional_payload(params), do: {:ok, Map.get(params, "payload")}

  defp claim_next_message(%Agent{} = agent, lease_seconds) do
    Repo.transaction(fn ->
      now = DateTime.utc_now(:microsecond)

      case Repo.one(claimable_message_query(agent, now)) do
        nil ->
          {200, %{"delivery" => nil}}

        %Message{} = message ->
          lease_until = DateTime.add(now, lease_seconds, :second)
          delivery = insert_polling_delivery!(message, agent, lease_until)
          delivered_message = mark_delivered!(message)

          {201, Response.delivery_claim(delivery, delivered_message)}
      end
    end)
    |> unwrap_transaction_result()
  end

  defp claimable_message_query(%Agent{} = agent, now) do
    active_delivery_message_ids =
      from(delivery in Delivery,
        where:
          delivery.recipient_agent_id == ^agent.id and delivery.status == "leased" and
            delivery.leased_until > ^now,
        select: delivery.message_id
      )

    from(message in Message,
      where: message.recipient_agent_id == ^agent.id,
      where: message.carrier_status in ["queued", "delivered"],
      where: is_nil(message.current_ack_status),
      where: message.expires_at > ^now,
      where: message.id not in subquery(active_delivery_message_ids),
      order_by: [asc: message.inserted_at],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  defp insert_polling_delivery!(%Message{} = message, %Agent{} = agent, lease_until) do
    %Delivery{id: ID.generate("dlv")}
    |> Delivery.changeset(%{
      message_id: message.id,
      recipient_agent_id: agent.id,
      mode: "polling",
      status: "leased",
      leased_until: lease_until
    })
    |> Repo.insert!()
  end

  defp mark_delivered!(%Message{} = message) do
    message
    |> Ecto.Changeset.change(carrier_status: "delivered")
    |> Repo.update!()
  end

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

  defp finish_prepared_webhook_delivery(%Agent{}, status, body, nil), do: {:ok, status, body}

  defp finish_prepared_webhook_delivery(%Agent{} = viewer, _status, _body, delivery_id) do
    with {:ok, message} <- WebhookDelivery.deliver_now(delivery_id) do
      {:ok, 201, Response.message_status(message, viewer)}
    end
  end

  defp finish_prepared_session_webhook_delivery(%Agent{}, status, body, {_session_id, nil}) do
    {:ok, status, body}
  end

  defp finish_prepared_session_webhook_delivery(
         %Agent{} = viewer,
         _status,
         _body,
         {session_id, delivery_id}
       ) do
    with {:ok, message} <- WebhookDelivery.deliver_now(delivery_id) do
      session = Repo.get!(Session, session_id)

      {:ok, 201, Response.session_message(session, message, viewer)}
    end
  end

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
           insert_message(sender, recipient, trust, blocked?, payload, %{
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

  defp extend_active_delivery(%Agent{} = agent, delivery_id, lease_seconds) do
    delivery =
      Delivery
      |> Repo.get_by(id: delivery_id, recipient_agent_id: agent.id)
      |> Repo.preload(:message)

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

  defp append_ack(%Agent{} = agent, delivery_id, ack_status, payload) do
    Repo.transaction(fn -> append_ack_in_transaction(agent, delivery_id, ack_status, payload) end)
    |> unwrap_transaction_result()
  end

  defp append_ack_in_transaction(%Agent{} = agent, delivery_id, ack_status, payload) do
    now = DateTime.utc_now(:microsecond)

    case fetch_locked_delivery(agent, delivery_id) do
      nil ->
        Repo.rollback(:not_found)

      %Delivery{} = delivery ->
        persist_ack(agent, delivery, ack_status, payload, now)
    end
  end

  defp persist_ack(%Agent{} = agent, %Delivery{} = delivery, ack_status, payload, now) do
    with :ok <- validate_ack_lease(delivery, now),
         :ok <- validate_ack_transition(delivery.message.current_ack_status, ack_status),
         {:ok, opening_session} <- lock_opening_session(delivery.message),
         :ok <- expire_due_opening_session(opening_session, delivery.message, now),
         :ok <- validate_opening_session_ack(opening_session, ack_status),
         {:ok, ack} <- insert_ack(delivery, ack_status, payload),
         {:ok, message} <- cache_ack_status(delivery.message, ack_status, now),
         {:ok, _session} <- cache_opening_session_ack_status(opening_session, ack_status, now) do
      {201, Response.ack(agent, ack, message)}
    else
      {:commit_error, reason} -> {:commit_error, reason}
      {:error, reason} -> Repo.rollback(reason)
    end
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

  defp validate_opening_session_ack(nil, _ack_status), do: :ok

  defp validate_opening_session_ack(%Session{status: "pending"}, "completed") do
    {:error, :invalid_ack_transition}
  end

  defp validate_opening_session_ack(%Session{status: "pending"}, _ack_status), do: :ok

  defp validate_opening_session_ack(%Session{}, _ack_status) do
    {:error, :invalid_ack_transition}
  end

  defp expire_due_opening_session(nil, %Message{}, _now), do: :ok

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

  defp validate_ack_lease(%Delivery{message: %Message{current_ack_status: "accepted"}}, _now) do
    :ok
  end

  defp validate_ack_lease(%Delivery{mode: "webhook", status: "delivered"}, _now), do: :ok

  defp validate_ack_lease(%Delivery{mode: "webhook"}, _now), do: {:error, :delivery_not_delivered}

  defp validate_ack_lease(
         %Delivery{mode: "polling", leased_until: %DateTime{} = leased_until},
         now
       ) do
    if DateTime.compare(leased_until, now) == :gt do
      :ok
    else
      {:error, :lease_expired}
    end
  end

  defp validate_ack_transition(nil, _next_status), do: :ok

  defp validate_ack_transition(current_status, _next_status)
       when current_status in @terminal_ack_statuses do
    {:error, :terminal_ack_status}
  end

  defp validate_ack_transition("accepted", next_status)
       when next_status in ~w(completed failed) do
    :ok
  end

  defp validate_ack_transition("accepted", _next_status), do: {:error, :invalid_ack_transition}

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
      current_ack_status: ack_status,
      terminal_at: terminal_ack_timestamp(ack_status, now)
    )
    |> Repo.update()
  end

  defp terminal_ack_timestamp(status, now) when status in @terminal_ack_statuses, do: now
  defp terminal_ack_timestamp(_status, _now), do: nil

  defp cache_opening_session_ack_status(nil, _ack_status, _now), do: {:ok, nil}

  defp cache_opening_session_ack_status(%Session{status: "pending"} = session, "accepted", now) do
    session
    |> Session.changeset(%{status: "open", opened_at: now})
    |> Repo.update()
  end

  defp cache_opening_session_ack_status(%Session{status: "pending"} = session, status, now)
       when status in ~w(rejected failed) do
    terminalize_pending_opening_session(session, status, now)
  end

  defp unwrap_transaction_result({:ok, {:commit_error, reason}}), do: {:commit_error, reason}
  defp unwrap_transaction_result({:ok, {status, body}}), do: {:ok, status, body}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
