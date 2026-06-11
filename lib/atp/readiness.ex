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

  @database_schema_query """
  SELECT
    agents.id,
    messages.id,
    messages.carrier_status,
    messages.session_id,
    messages.session_sequence,
    deliveries.id,
    deliveries.mode,
    deliveries.status,
    deliveries.claim_token,
    deliveries.claimed_at,
    sessions.id,
    sessions.status,
    webhook_attempts.id,
    webhook_attempts.result
  FROM atp_agents AS agents
  JOIN atp_messages AS messages ON false
  JOIN atp_deliveries AS deliveries ON false
  JOIN atp_sessions AS sessions ON false
  JOIN atp_webhook_attempts AS webhook_attempts ON false
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
    config = webhook_dispatcher_config(opts)

    if Keyword.get(config, :enabled, true) == false do
      @status_disabled
    else
      opts
      |> Keyword.get_lazy(:webhook_dispatcher_server, fn ->
        Keyword.get(config, :name, WebhookDispatcher)
      end)
      |> process_status()
    end
  end

  defp webhook_dispatcher_config(opts) do
    opts
    |> Keyword.get_lazy(:webhook_dispatcher_config, fn ->
      Application.get_env(:atp, WebhookDispatcher, [])
    end)
    |> normalize_keyword()
  end

  defp normalize_keyword(config) when is_list(config), do: config
  defp normalize_keyword(_config), do: []

  defp process_status(server) do
    case process_for(server) do
      pid when is_pid(pid) -> @status_ok
      _not_available -> @status_error
    end
  end

  defp process_for(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp process_for(nil), do: nil

  defp process_for(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> if(Process.alive?(pid), do: pid)
      _not_found -> nil
    end
  end

  defp process_for(_unsupported_server), do: nil

  defp overall_status(checks) do
    if Enum.all?(checks, fn {_name, status} -> status in [@status_ok, @status_disabled] end) do
      @status_ok
    else
      @status_error
    end
  end
end
