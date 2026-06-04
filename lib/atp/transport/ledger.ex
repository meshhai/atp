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
end
