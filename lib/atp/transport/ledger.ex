defmodule Atp.Transport.Ledger do
  @moduledoc """
  Durable ATP carrier operations for sessions, sender policies, and status reads.

  This module owns remaining Postgres-backed carrier operations that have not
  moved behind semantic durable ledger callbacks yet.
  """

  import Ecto.Query

  alias Atp.Identity.{Agent, Idempotency}
  alias Atp.Repo

  alias Atp.Transport.{
    Message,
    Response,
    SenderPolicies,
    Session
  }

  @type api_result :: {:ok, pos_integer(), map()} | {:error, term()}

  @spec get_session(Agent.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(%Agent{} = agent, session_id) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      %Session{} = session when session.initiator_agent_id == agent.id ->
        {:ok, session_transcript_response(session, agent)}

      %Session{} = session when session.recipient_agent_id == agent.id ->
        {:ok, session_transcript_response(session, agent)}

      _other ->
        {:error, :not_found}
    end
  end

  defp session_transcript_response(%Session{} = session, %Agent{} = viewer) do
    messages =
      Message
      |> where([message], message.session_id == ^session.id)
      |> order_by([message], asc: message.session_sequence, asc: message.inserted_at)
      |> Repo.all()

    Response.session_transcript(session, messages, viewer)
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
end
