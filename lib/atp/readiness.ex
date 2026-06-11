defmodule Atp.Readiness do
  @moduledoc """
  Coarse single-node readiness checks for ATP carrier traffic.

  The returned shape is intentionally public and sanitized. It reports only
  component names and coarse statuses, never adapter errors, process details,
  database identifiers, carrier IDs, queue depths, or runtime internals.
  """

  alias Atp.Repo
  alias Atp.Transport.Runtime.Supervisor, as: TransportRuntimeSupervisor
  alias Atp.Transport.WebhookDispatcher

  @status_ok "ok"
  @status_error "error"
  @status_disabled "disabled"
  @default_attempt_supervisor WebhookDispatcher.AttemptSupervisor

  @database_schema_requirements [
    {"atp_accounts", "accounts", ~w(id name plan inserted_at updated_at)},
    {"atp_account_api_keys", "account_api_keys",
     ~w(id account_id label token_hash last_used_at revoked_at inserted_at updated_at)},
    {"atp_agents", "agents",
     ~w(id account_id address display_name description status webhook_url webhook_secret webhook_active inserted_at updated_at)},
    {"atp_agent_api_keys", "agent_api_keys",
     ~w(id account_id agent_id label token_hash last_used_at revoked_at inserted_at updated_at)},
    {"atp_idempotency_keys", "idempotency_keys",
     ~w(id account_id key route request_hash response_status response_body principal_type principal_id inserted_at)},
    {"atp_messages", "messages",
     ~w(id sender_account_id recipient_account_id sender_agent_id recipient_agent_id sender_address recipient_address trust payload content_type carrier_status current_ack_status terminal_at expires_at inserted_at updated_at session_id session_sequence)},
    {"atp_deliveries", "deliveries",
     ~w(id message_id recipient_agent_id mode status leased_until inserted_at updated_at attempt_count max_attempts next_attempt_at delivered_at last_error claim_token claimed_at)},
    {"atp_acks", "acks",
     ~w(id message_id delivery_id recipient_agent_id status payload inserted_at)},
    {"atp_sessions", "sessions",
     ~w(id initiator_account_id recipient_account_id initiator_agent_id recipient_agent_id initiator_address recipient_address status opening_message_id last_sequence opened_at terminal_at inserted_at updated_at)},
    {"atp_agent_sender_policies", "sender_policies",
     ~w(id recipient_agent_id sender_agent_id sender_account_id effect inserted_at updated_at)},
    {"atp_webhook_attempts", "webhook_attempts",
     ~w(id delivery_id message_id recipient_agent_id attempt_number request_url response_status error result next_attempt_at inserted_at)}
  ]

  @database_schema_select_columns Enum.flat_map(
                                    @database_schema_requirements,
                                    fn {_table_name, table_alias, columns} ->
                                      Enum.map(columns, &"#{table_alias}.#{&1}")
                                    end
                                  )

  @database_schema_joins @database_schema_requirements
                         |> tl()
                         |> Enum.map_join("\n", fn {table_name, table_alias, _columns} ->
                           "LEFT JOIN #{table_name} AS #{table_alias} ON false"
                         end)

  @database_schema_query """
  SELECT
    #{Enum.join(@database_schema_select_columns, ",\n  ")}
  FROM atp_accounts AS accounts
  #{@database_schema_joins}
  LIMIT 0
  """

  @type result :: %{String.t() => String.t() | %{String.t() => String.t()}}

  @spec check(keyword()) :: result()
  def check(opts \\ []) do
    checks = %{
      "database" => database_status(Keyword.get(opts, :repo, Repo)),
      "transport_runtime" =>
        process_status(
          Keyword.get(opts, :transport_runtime_supervisor, TransportRuntimeSupervisor)
        ),
      "webhook_dispatcher" => webhook_dispatcher_status(opts)
    }

    %{"status" => overall_status(checks), "checks" => checks}
  end

  defp database_status(repo) do
    case repo.query(@database_schema_query, [], log: false, timeout: 2_000) do
      {:ok, _result} -> @status_ok
      {:error, _reason} -> @status_error
    end
  rescue
    _exception -> @status_error
  catch
    _kind, _reason -> @status_error
  end

  defp webhook_dispatcher_status(opts) do
    case webhook_dispatcher_config(opts) do
      {:ok, config} -> webhook_dispatcher_status(opts, config)
      :error -> @status_error
    end
  end

  defp webhook_dispatcher_config(opts) do
    opts
    |> Keyword.get_lazy(:webhook_dispatcher_config, fn ->
      Application.get_env(:atp, WebhookDispatcher, [])
    end)
    |> normalize_dispatcher_config()
  end

  defp normalize_dispatcher_config(config) when is_list(config) do
    if Keyword.keyword?(config), do: {:ok, config}, else: :error
  end

  defp normalize_dispatcher_config(_config), do: :error

  defp webhook_dispatcher_status(opts, config) do
    case dispatcher_enabled?(config) do
      {:ok, false} -> @status_disabled
      {:ok, true} -> enabled_webhook_dispatcher_status(opts, config)
      :error -> @status_error
    end
  end

  defp dispatcher_enabled?(config) do
    case Keyword.fetch(config, :enabled) do
      {:ok, enabled?} when is_boolean(enabled?) -> {:ok, enabled?}
      {:ok, _enabled?} -> :error
      :error -> {:ok, true}
    end
  end

  defp enabled_webhook_dispatcher_status(opts, config) do
    dispatcher_server =
      Keyword.get_lazy(opts, :webhook_dispatcher_server, fn ->
        Keyword.get(config, :name, WebhookDispatcher)
      end)

    attempt_supervisor =
      Keyword.get_lazy(opts, :webhook_dispatcher_attempt_supervisor, fn ->
        Keyword.get(config, :attempt_supervisor, @default_attempt_supervisor)
      end)

    if process_available?(dispatcher_server) and process_available?(attempt_supervisor) do
      @status_ok
    else
      @status_error
    end
  end

  defp process_status(server) do
    if process_available?(server), do: @status_ok, else: @status_error
  end

  defp process_available?(server) do
    case process_for(server) do
      pid when is_pid(pid) -> true
      _not_available -> false
    end
  end

  defp process_for(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp process_for(nil), do: nil

  defp process_for(server) when is_atom(server) do
    server
    |> Process.whereis()
    |> live_pid()
  end

  defp process_for({:global, name}) do
    name
    |> :global.whereis_name()
    |> live_pid()
  catch
    _kind, _reason -> nil
  end

  defp process_for({:via, module, name}) when is_atom(module) do
    module.whereis_name(name)
    |> live_pid()
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp process_for(_unsupported_server), do: nil

  defp live_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp live_pid(_not_pid), do: nil

  defp overall_status(checks) do
    if Enum.all?(checks, fn {_name, status} -> status in [@status_ok, @status_disabled] end) do
      @status_ok
    else
      @status_error
    end
  end
end
