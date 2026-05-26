defmodule Atp.Identity do
  @moduledoc "ATP identity, account API-key, and agent registration context."

  import Ecto.Query

  alias Atp.Identity.{
    Account,
    AccountApiKey,
    Agent,
    AgentApiKey,
    ID,
    Idempotency,
    Token
  }

  alias Atp.Repo

  @type principal :: {:account, Account.t()} | {:agent, Agent.t()}

  @spec create_account(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      case attrs |> public_signup_attrs() |> insert_account() do
        {:ok, account} ->
          {key, token} = insert_account_key!(account)

          account_response(account, key, token)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @spec authenticate_bearer(String.t()) :: {:ok, principal()} | :error
  def authenticate_bearer(token) when is_binary(token) do
    token_hash = Token.hash(token)

    account_query =
      from(key in AccountApiKey,
        join: account in assoc(key, :account),
        where: key.token_hash == ^token_hash and is_nil(key.revoked_at),
        select: account
      )

    agent_query =
      from(key in AgentApiKey,
        join: agent in assoc(key, :agent),
        where:
          key.token_hash == ^token_hash and is_nil(key.revoked_at) and
            agent.status == "active",
        select: agent
      )

    cond do
      account = Repo.one(account_query) ->
        {:ok, {:account, account}}

      agent = Repo.one(agent_query) ->
        {:ok, {:agent, agent}}

      true ->
        :error
    end
  end

  @spec register_agent(Account.t(), map(), String.t() | nil, String.t()) ::
          {:ok, pos_integer(), map()} | {:error, term()}
  def register_agent(%Account{} = account, attrs, idempotency_key, route) when is_map(attrs) do
    Idempotency.run(account, route, idempotency_key, attrs, fn ->
      locked_account = lock_account!(account)

      with :ok <- enforce_agent_limit(locked_account),
           {:ok, agent, key, token} <- create_agent_with_key(locked_account, attrs) do
        {:ok, 201, registered_agent_response(agent, key, token)}
      end
    end)
  end

  @spec get_agent(Account.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_agent(%Account{} = account, agent_id) when is_binary(agent_id) do
    case Repo.get_by(Agent, id: agent_id, account_id: account.id) do
      %Agent{} = agent -> {:ok, agent_response(agent)}
      nil -> {:error, :not_found}
    end
  end

  @spec rotate_agent_key(Account.t(), String.t(), map(), String.t() | nil) ::
          {:ok, pos_integer(), map()} | {:error, term()}
  def rotate_agent_key(%Account{} = account, agent_id, attrs, idempotency_key)
      when is_binary(agent_id) and is_map(attrs) do
    route = "POST /api/agents/#{agent_id}/keys"

    Idempotency.run(account, route, idempotency_key, attrs, fn ->
      case lock_agent(account, agent_id) do
        %Agent{} = agent ->
          lock_active_agent_keys!(agent)

          with {:ok, key, token} <- rotate_key(agent) do
            {:ok, 201, agent_key_response(key, token)}
          end

        nil ->
          {:error, :not_found}
      end
    end)
  end

  @spec configure_webhook_endpoint(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          {:ok, pos_integer(), map()} | {:error, term()}
  def configure_webhook_endpoint(%Agent{} = principal, agent_id, attrs, idempotency_key, route)
      when is_binary(agent_id) and is_map(attrs) and is_binary(route) do
    Idempotency.run(principal, route, idempotency_key, attrs, fn ->
      with :ok <- ensure_own_agent(principal, agent_id),
           {:ok, url} <- fetch_webhook_url(attrs),
           {:ok, agent} <- update_webhook_endpoint(principal, url) do
        {:ok, 200, webhook_endpoint_response(agent)}
      end
    end)
  end

  defp ensure_own_agent(%Agent{id: agent_id}, agent_id), do: :ok
  defp ensure_own_agent(%Agent{}, _agent_id), do: {:error, :not_found}

  defp fetch_webhook_url(%{"url" => url}) when is_binary(url) do
    case String.trim(url) do
      "" -> {:error, :invalid_webhook_url}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_webhook_url(_attrs), do: {:error, :invalid_webhook_url}

  defp update_webhook_endpoint(%Agent{} = agent, url) do
    agent
    |> lock_agent!()
    |> Agent.webhook_changeset(%{
      webhook_url: url,
      webhook_secret: Token.generate("whsec"),
      webhook_active: true
    })
    |> Repo.update()
    |> case do
      {:ok, agent} -> {:ok, agent}
      {:error, _changeset} -> {:error, :invalid_webhook_url}
    end
  end

  defp lock_agent!(%Agent{} = agent) do
    Agent
    |> where(
      [locked_agent],
      locked_agent.id == ^agent.id and locked_agent.account_id == ^agent.account_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_account!(%Account{} = account) do
    Account
    |> where([locked_account], locked_account.id == ^account.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_agent(%Account{} = account, agent_id) do
    Agent
    |> where([agent], agent.id == ^agent_id and agent.account_id == ^account.id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_active_agent_keys!(%Agent{} = agent) do
    AgentApiKey
    |> where([key], key.agent_id == ^agent.id and is_nil(key.revoked_at))
    |> order_by([key], asc: key.id)
    |> lock("FOR UPDATE")
    |> Repo.all()

    :ok
  end

  defp insert_account(attrs) do
    %Account{id: ID.generate("acct")}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  defp public_signup_attrs(attrs) do
    attrs
    |> Map.drop(["plan", :plan])
    |> Map.put("plan", "free")
  end

  defp insert_account_key!(%Account{} = account) do
    token = Token.generate("ak")

    key =
      %AccountApiKey{id: ID.generate("acctkey")}
      |> AccountApiKey.changeset(%{
        account_id: account.id,
        token_hash: Token.hash(token)
      })
      |> Repo.insert!()

    {key, token}
  end

  defp create_agent_with_key(%Account{} = account, attrs) do
    Repo.transaction(fn ->
      agent_id = ID.generate("agt")
      agent_attrs = %{id: agent_id, account_id: account.id, address: "atp://agent/#{agent_id}"}

      case struct(Agent, agent_attrs) |> Agent.changeset(attrs) |> Repo.insert() do
        {:ok, agent} ->
          {key, token} = insert_agent_key!(agent)
          {agent, key, token}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {agent, key, token}} -> {:ok, agent, key, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_agent_key!(%Agent{} = agent) do
    token = Token.generate("agk")

    key =
      %AgentApiKey{id: ID.generate("agtkey")}
      |> AgentApiKey.changeset(%{
        account_id: agent.account_id,
        agent_id: agent.id,
        token_hash: Token.hash(token)
      })
      |> Repo.insert!()

    {key, token}
  end

  defp rotate_key(%Agent{} = agent) do
    {:ok, {key, token}} =
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        from(key in AgentApiKey,
          where: key.agent_id == ^agent.id and is_nil(key.revoked_at)
        )
        |> Repo.update_all(set: [revoked_at: now, updated_at: now])

        insert_agent_key!(agent)
      end)

    {:ok, key, token}
  end

  defp enforce_agent_limit(%Account{} = account) do
    limit = if account.plan == "basic", do: 10, else: 2

    active_count =
      Agent
      |> where([agent], agent.account_id == ^account.id and agent.status == "active")
      |> Repo.aggregate(:count)

    if active_count < limit, do: :ok, else: {:error, :plan_limit_exceeded}
  end

  defp active_agent_key_id(%Agent{} = agent) do
    AgentApiKey
    |> where([key], key.agent_id == ^agent.id and is_nil(key.revoked_at))
    |> order_by([key], desc: key.inserted_at)
    |> limit(1)
    |> select([key], key.id)
    |> Repo.one()
  end

  defp account_response(%Account{} = account, %AccountApiKey{} = key, token) do
    %{
      "id" => account.id,
      "name" => account.name,
      "plan" => account.plan,
      "account_api_key" => %{
        "id" => key.id,
        "token" => token
      }
    }
  end

  defp registered_agent_response(%Agent{} = agent, %AgentApiKey{} = key, token) do
    agent_response(agent)
    |> Map.put("agent_api_key", agent_key_response(key, token))
  end

  defp agent_response(%Agent{} = agent) do
    %{
      "id" => agent.id,
      "address" => agent.address,
      "display_name" => agent.display_name,
      "description" => agent.description,
      "active_agent_key_id" => active_agent_key_id(agent)
    }
  end

  defp agent_key_response(%AgentApiKey{} = key, token) do
    %{
      "id" => key.id,
      "token" => token
    }
  end

  defp webhook_endpoint_response(%Agent{} = agent) do
    %{
      "webhook_endpoint" => %{
        "url" => agent.webhook_url,
        "active" => agent.webhook_active,
        "endpoint_secret" => agent.webhook_secret
      }
    }
  end
end
