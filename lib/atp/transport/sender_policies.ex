defmodule Atp.Transport.SenderPolicies do
  @moduledoc "Recipient-owned sender allow/block policy resolution."

  import Ecto.Query

  alias Atp.Identity.{Account, Agent, ID}
  alias Atp.Repo
  alias Atp.Transport.{Message, SenderPolicy}

  @unknown_sender_rate_limit 20
  @unknown_sender_rate_window_seconds 60 * 60
  @policy_precedence %{
    {:agent, "block"} => 1,
    {:account, "block"} => 2,
    {:agent, "allow"} => 3,
    {:account, "allow"} => 4
  }

  @type trust :: String.t()
  @type resolution :: {trust(), blocked? :: boolean()}

  @spec resolve(Agent.t(), Agent.t()) :: resolution()
  def resolve(%Agent{} = sender, %Agent{} = recipient) do
    case effect(sender, recipient) do
      "block" -> {"untrusted", true}
      "allow" -> {"trusted", false}
      _effect when sender.account_id == recipient.account_id -> {"trusted", false}
      _effect -> {"untrusted", false}
    end
  end

  @spec enforce_unknown_sender_rate_limit(Agent.t(), Agent.t(), trust(), boolean()) ::
          :ok | {:error, :unknown_sender_rate_limited}
  def enforce_unknown_sender_rate_limit(
        %Agent{} = sender,
        %Agent{} = recipient,
        "untrusted",
        false
      )
      when sender.account_id != recipient.account_id do
    window_start =
      DateTime.utc_now(:microsecond)
      |> DateTime.add(-@unknown_sender_rate_window_seconds, :second)

    lock_unknown_sender_rate_limit_scope!(recipient)

    count =
      Message
      |> where([message], message.sender_account_id == ^sender.account_id)
      |> where([message], message.recipient_agent_id == ^recipient.id)
      |> where([message], message.trust == "untrusted")
      |> where([message], message.carrier_status != "rejected")
      |> where([message], message.inserted_at >= ^window_start)
      |> Repo.aggregate(:count)

    if count < @unknown_sender_rate_limit do
      :ok
    else
      {:error, :unknown_sender_rate_limited}
    end
  end

  def enforce_unknown_sender_rate_limit(%Agent{}, %Agent{}, _trust, _blocked?), do: :ok

  defp lock_unknown_sender_rate_limit_scope!(%Agent{} = recipient) do
    Agent
    |> where([agent], agent.id == ^recipient.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()

    :ok
  end

  @spec upsert(Agent.t(), map()) ::
          {:ok, SenderPolicy.t()} | {:error, :invalid_sender_policy | :not_found}
  def upsert(%Agent{} = recipient, %{"effect" => effect} = params)
      when effect in ~w(allow block) do
    case attrs(recipient, params) do
      {:ok, attrs} -> upsert_attrs(attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert(%Agent{}, _params), do: {:error, :invalid_sender_policy}

  @spec to_response(SenderPolicy.t()) :: map()
  def to_response(%SenderPolicy{} = policy) do
    %{
      "sender_policy" => %{
        "id" => policy.id,
        "recipient_agent_id" => policy.recipient_agent_id,
        "sender_agent_id" => policy.sender_agent_id,
        "sender_account_id" => policy.sender_account_id,
        "effect" => policy.effect,
        "updated_at" => timestamp(policy.updated_at)
      }
    }
  end

  defp effect(%Agent{} = sender, %Agent{} = recipient) do
    SenderPolicy
    |> where([policy], policy.recipient_agent_id == ^recipient.id)
    |> where(
      [policy],
      policy.sender_agent_id == ^sender.id or policy.sender_account_id == ^sender.account_id
    )
    |> Repo.all()
    |> Enum.map(&policy_precedence(&1, sender))
    |> Enum.min_by(fn {precedence, _effect} -> precedence end, fn -> nil end)
    |> case do
      {_precedence, effect} -> effect
      nil -> nil
    end
  end

  defp policy_precedence(%SenderPolicy{} = policy, %Agent{} = sender) do
    scope =
      cond do
        policy.sender_agent_id == sender.id -> :agent
        policy.sender_account_id == sender.account_id -> :account
      end

    precedence = Map.fetch!(@policy_precedence, {scope, policy.effect})
    {precedence, policy.effect}
  end

  defp attrs(%Agent{} = recipient, params) do
    sender_agent_id = Map.get(params, "sender_agent_id")
    sender_account_id = Map.get(params, "sender_account_id")
    effect = Map.fetch!(params, "effect")

    cond do
      present?(sender_agent_id) and present?(sender_account_id) ->
        {:error, :invalid_sender_policy}

      present?(sender_agent_id) ->
        sender_agent_attrs(recipient, sender_agent_id, effect)

      present?(sender_account_id) ->
        sender_account_attrs(recipient, sender_account_id, effect)

      true ->
        {:error, :invalid_sender_policy}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp sender_agent_attrs(%Agent{} = recipient, sender_agent_id, effect) do
    case Repo.get_by(Agent, id: sender_agent_id, status: "active") do
      %Agent{} ->
        {:ok,
         %{
           recipient_agent_id: recipient.id,
           sender_agent_id: sender_agent_id,
           sender_account_id: nil,
           effect: effect
         }}

      nil ->
        {:error, :not_found}
    end
  end

  defp sender_account_attrs(%Agent{} = recipient, sender_account_id, effect) do
    case Repo.get(Account, sender_account_id) do
      %Account{} ->
        {:ok,
         %{
           recipient_agent_id: recipient.id,
           sender_agent_id: nil,
           sender_account_id: sender_account_id,
           effect: effect
         }}

      nil ->
        {:error, :not_found}
    end
  end

  defp upsert_attrs(attrs) do
    %SenderPolicy{id: ID.generate("spol")}
    |> SenderPolicy.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:effect, :updated_at]},
      conflict_target: conflict_target(attrs),
      returning: true
    )
    |> case do
      {:ok, policy} -> {:ok, policy}
      {:error, _changeset} -> {:error, :invalid_sender_policy}
    end
  end

  defp conflict_target(%{sender_agent_id: sender_agent_id}) when is_binary(sender_agent_id) do
    {:unsafe_fragment, "(recipient_agent_id, sender_agent_id) WHERE sender_agent_id IS NOT NULL"}
  end

  defp conflict_target(%{sender_account_id: sender_account_id})
       when is_binary(sender_account_id) do
    {:unsafe_fragment,
     "(recipient_agent_id, sender_account_id) WHERE sender_account_id IS NOT NULL"}
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
