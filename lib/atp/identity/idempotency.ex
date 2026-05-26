defmodule Atp.Identity.Idempotency do
  @moduledoc false

  import Ecto.Query

  alias Atp.Identity.{Account, Agent, ID, IdempotencyKey}
  alias Atp.Repo

  @encrypted_response_body_v1 "encrypted_v1"
  @response_body_salt "atp idempotency response body v1"
  @response_body_max_age_seconds 86_400

  @type callback_result :: {:ok, pos_integer(), map()} | {:error, term()}
  @type commit_error_result :: {:commit_error, term()}
  @type after_commit_callback_result ::
          {:ok, pos_integer(), map(), term()} | callback_result() | commit_error_result()
  @type prepared_after_commit :: %{
          entry_id: String.t(),
          status: pos_integer(),
          body: map(),
          commit_value: term()
        }
  @type principal :: Account.t() | Agent.t()
  @type principal_scope :: %{
          account_id: String.t(),
          principal_id: String.t(),
          principal_type: String.t()
        }

  @spec preflight(principal(), String.t(), String.t() | nil, map()) ::
          :ok
          | callback_result()
          | {:error, :idempotency_conflict | :idempotency_in_progress | :idempotency_key_required}
  def preflight(principal, route, key, request_params)
      when is_binary(route) do
    with {:ok, key} <- normalize_key(key),
         {:ok, scope} <- principal_scope(principal) do
      request_hash = request_hash(request_params)

      case fetch_entry(scope, route, key) do
        nil -> :ok
        %IdempotencyKey{} = entry -> replay_existing(entry, request_hash)
      end
    end
  end

  @spec run(
          principal(),
          String.t(),
          String.t() | nil,
          map(),
          (-> callback_result() | commit_error_result())
        ) ::
          callback_result()
          | {:error, :idempotency_conflict | :idempotency_in_progress | :idempotency_key_required}
  def run(principal, route, key, request_params, callback)
      when is_binary(route) and is_function(callback, 0) do
    with {:ok, key} <- normalize_key(key),
         {:ok, scope} <- principal_scope(principal) do
      request_hash = request_hash(request_params)

      scope
      |> run_transactionally(route, key, request_hash, callback)
      |> unwrap_transaction()
    end
  end

  @spec run_after_commit(
          principal(),
          String.t(),
          String.t() | nil,
          map(),
          (-> after_commit_callback_result()),
          (pos_integer(), map(), term() -> callback_result())
        ) ::
          callback_result()
          | {:error, :idempotency_conflict | :idempotency_in_progress | :idempotency_key_required}
  def run_after_commit(principal, route, key, request_params, callback, after_commit)
      when is_binary(route) and is_function(callback, 0) and is_function(after_commit, 3) do
    with {:ok, key} <- normalize_key(key),
         {:ok, scope} <- principal_scope(principal) do
      request_hash = request_hash(request_params)

      scope
      |> run_transactionally_before_commit(route, key, request_hash, callback)
      |> complete_after_commit(after_commit)
    end
  end

  @spec run_prepared_after_commit(
          principal(),
          String.t(),
          String.t() | nil,
          map(),
          (-> after_commit_callback_result())
        ) ::
          {:ok, pos_integer(), map(), prepared_after_commit() | nil}
          | {:error,
             term()
             | :idempotency_conflict
             | :idempotency_in_progress
             | :idempotency_key_required}
  def run_prepared_after_commit(principal, route, key, request_params, callback)
      when is_binary(route) and is_function(callback, 0) do
    with {:ok, key} <- normalize_key(key),
         {:ok, scope} <- principal_scope(principal) do
      request_hash = request_hash(request_params)

      scope
      |> run_transactionally_before_commit(route, key, request_hash, callback)
      |> unwrap_prepared_after_commit()
    end
  end

  @spec complete_prepared_after_commit(
          prepared_after_commit(),
          (pos_integer(), map(), term() -> callback_result())
        ) :: callback_result()
  def complete_prepared_after_commit(
        %{entry_id: entry_id, status: status, body: body, commit_value: commit_value},
        after_commit
      )
      when is_binary(entry_id) and is_integer(status) and is_map(body) and
             is_function(after_commit, 3) do
    case after_commit.(status, body, commit_value) do
      {:ok, final_status, final_body} when is_integer(final_status) and is_map(final_body) ->
        complete_entry!(entry_id, final_status, final_body)
        {:ok, final_status, final_body}

      {:error, _reason} ->
        complete_entry!(entry_id, status, body)
        {:ok, status, body}
    end
  end

  defp normalize_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:error, :idempotency_key_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_key(_key), do: {:error, :idempotency_key_required}

  defp request_hash(params) do
    params
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp principal_scope(%Account{} = account) do
    {:ok, %{account_id: account.id, principal_type: "account", principal_id: account.id}}
  end

  defp principal_scope(%Agent{} = agent) do
    {:ok, %{account_id: agent.account_id, principal_type: "agent", principal_id: agent.id}}
  end

  defp principal_scope(_principal), do: {:error, :invalid_idempotency_principal}

  defp run_transactionally(scope, route, key, request_hash, callback) do
    Repo.transaction(fn ->
      scope
      |> reserve_or_lock_entry(route, key, request_hash)
      |> run_reserved_or_replay(callback, request_hash)
      |> case do
        {:ok, status, body} -> {:ok, status, body}
        {:commit_error, reason} -> {:commit_error, reason}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp run_transactionally_before_commit(scope, route, key, request_hash, callback) do
    Repo.transaction(fn ->
      scope
      |> reserve_or_lock_entry(route, key, request_hash)
      |> run_reserved_or_prepare(callback, request_hash)
      |> case do
        {:ok, status, body} ->
          {:ok, status, body}

        {:after_commit, entry_id, status, body, commit_value} ->
          {:after_commit, entry_id, status, body, commit_value}

        {:commit_error, reason} ->
          {:commit_error, reason}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp reserve_or_lock_entry(scope, route, key, request_hash) do
    entry_id = ID.generate("idem")
    now = DateTime.utc_now(:microsecond)

    {inserted_count, _rows} =
      Repo.insert_all(
        IdempotencyKey,
        [
          %{
            id: entry_id,
            account_id: scope.account_id,
            principal_id: scope.principal_id,
            principal_type: scope.principal_type,
            key: key,
            route: route,
            request_hash: request_hash,
            inserted_at: now
          }
        ],
        conflict_target: [:account_id, :principal_type, :principal_id, :route, :key],
        on_conflict: :nothing
      )

    if inserted_count == 1 do
      {:reserved, locked_entry!(entry_id)}
    else
      {:existing, locked_entry!(scope, route, key)}
    end
  end

  defp locked_entry!(entry_id) do
    IdempotencyKey
    |> where([entry], entry.id == ^entry_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp locked_entry!(scope, route, key) do
    scope
    |> entry_query(route, key)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp fetch_entry(scope, route, key) do
    scope
    |> entry_query(route, key)
    |> Repo.one()
  end

  defp entry_query(scope, route, key) do
    IdempotencyKey
    |> where(
      [entry],
      entry.account_id == ^scope.account_id and
        entry.principal_type == ^scope.principal_type and
        entry.principal_id == ^scope.principal_id and
        entry.route == ^route and entry.key == ^key
    )
  end

  defp run_reserved_or_replay({:reserved, %IdempotencyKey{} = entry}, callback, _request_hash) do
    persist_result(entry, callback)
  end

  defp run_reserved_or_replay({:existing, %IdempotencyKey{} = entry}, _callback, request_hash) do
    replay_existing(entry, request_hash)
  end

  defp run_reserved_or_prepare({:reserved, %IdempotencyKey{} = entry}, callback, _request_hash) do
    case callback.() do
      {:ok, status, body, commit_value} when is_integer(status) and is_map(body) ->
        {:after_commit, entry.id, status, body, commit_value}

      {:ok, status, body} when is_integer(status) and is_map(body) ->
        complete_entry!(entry, status, body)
        {:ok, status, body}

      {:commit_error, reason} ->
        delete_entry!(entry)
        {:commit_error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_reserved_or_prepare({:existing, %IdempotencyKey{} = entry}, _callback, request_hash) do
    replay_existing(entry, request_hash)
  end

  defp replay_existing(%IdempotencyKey{request_hash: request_hash} = entry, request_hash)
       when is_integer(entry.response_status) and is_map(entry.response_body) do
    case decode_response_body(entry.response_body) do
      {:ok, body} -> {:ok, entry.response_status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_existing(%IdempotencyKey{request_hash: request_hash} = entry, request_hash)
       when is_nil(entry.response_status) or is_nil(entry.response_body) do
    {:error, :idempotency_in_progress}
  end

  defp replay_existing(%IdempotencyKey{}, _request_hash) do
    {:error, :idempotency_conflict}
  end

  defp persist_result(%IdempotencyKey{} = entry, callback) do
    case callback.() do
      {:ok, status, body} when is_integer(status) and is_map(body) ->
        complete_entry!(entry, status, body)

        {:ok, status, body}

      {:commit_error, reason} ->
        delete_entry!(entry)
        {:commit_error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_entry!(%IdempotencyKey{} = entry) do
    Repo.delete!(entry)
  end

  defp encode_response_body(body) when is_map(body) do
    %{
      "encoding" => @encrypted_response_body_v1,
      "ciphertext" =>
        Plug.Crypto.encrypt(secret_key_base!(), @response_body_salt, body,
          max_age: @response_body_max_age_seconds
        )
    }
  end

  defp complete_entry!(entry_or_id, status, body) when is_integer(status) and is_map(body) do
    entry =
      case entry_or_id do
        %IdempotencyKey{} = entry -> entry
        entry_id when is_binary(entry_id) -> Repo.get!(IdempotencyKey, entry_id)
      end

    entry
    |> IdempotencyKey.completion_changeset(%{
      response_status: status,
      response_body: encode_response_body(body)
    })
    |> Repo.update!()
  end

  defp decode_response_body(%{
         "encoding" => @encrypted_response_body_v1,
         "ciphertext" => ciphertext
       })
       when is_binary(ciphertext) do
    # Idempotency retention is owned by persisted rows until explicit cleanup exists.
    case Plug.Crypto.decrypt(secret_key_base!(), @response_body_salt, ciphertext,
           max_age: :infinity
         ) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _body} -> {:error, :idempotency_response_unreadable}
      {:error, _reason} -> {:error, :idempotency_response_unreadable}
    end
  end

  defp decode_response_body(body) when is_map(body), do: {:ok, body}

  defp secret_key_base! do
    :atp
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:response_secret_key_base)
  end

  defp unwrap_transaction({:ok, {:commit_error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp complete_after_commit(
         {:ok, {:after_commit, entry_id, status, body, commit_value}},
         after_commit
       ) do
    case after_commit.(status, body, commit_value) do
      {:ok, final_status, final_body} when is_integer(final_status) and is_map(final_body) ->
        complete_entry!(entry_id, final_status, final_body)
        {:ok, final_status, final_body}

      {:error, _reason} ->
        # The durable mutation already committed, so close the idempotency row
        # with the prepared response instead of leaving retries stuck forever.
        complete_entry!(entry_id, status, body)
        {:ok, status, body}
    end
  end

  defp complete_after_commit({:ok, {:commit_error, reason}}, _after_commit) do
    {:error, reason}
  end

  defp complete_after_commit({:ok, result}, _after_commit), do: result
  defp complete_after_commit({:error, reason}, _after_commit), do: {:error, reason}

  defp unwrap_prepared_after_commit({:ok, {:after_commit, entry_id, status, body, commit_value}}) do
    prepared = %{
      entry_id: entry_id,
      status: status,
      body: body,
      commit_value: commit_value
    }

    {:ok, status, body, prepared}
  end

  defp unwrap_prepared_after_commit({:ok, {:commit_error, reason}}), do: {:error, reason}
  defp unwrap_prepared_after_commit({:ok, {:ok, status, body}}), do: {:ok, status, body, nil}
  defp unwrap_prepared_after_commit({:error, reason}), do: {:error, reason}
end
